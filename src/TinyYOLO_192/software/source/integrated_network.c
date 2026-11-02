/* G228 pipeline source; the G227 register and model ABI is retained.
 * Single resident DDR graph. No reference tensors or inter-layer host inputs.
 * The exact same graph/operator code is built natively and for Cortex-A9.
 * ARM build schedules all 24 convolutions in PL: 22 INT8 and two exact
 * floating-point heads. Non-convolution operators remain on ARM. No NMS. */
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <math.h>
#include <limits.h>
#include "tinyyolo_integer_ops.h"
#ifdef TINYYOLO_HOST
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#define COUNTS_PER_SECOND CLOCKS_PER_SEC
#elif defined(TINYYOLO_LINUX)
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include "../../linux/tinyyolo_uapi.h"
#define COUNTS_PER_SECOND 1000000000ULL
#else
#include "xparameters.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#ifdef SDT
#include "xiltimer.h"
#else
#include "xtime_l.h"
#endif
#include "sleep.h"
#endif

typedef struct {uint32_t off,bytes,birth,last,trace,dtype;} Tensor;
typedef struct {uint32_t ci,co,h,w,k,pad,chunks,weights,bias,mul,shift,acc_trace;
                int32_t zx,zy;float sy;} Conv;
typedef struct {uint32_t kind,layer,a,b,c,d,out,p0,p1,channels,h,w,mode;} Step;
#include "network_config.h"

#define GUARD 64U
#define NIL UINT32_MAX
#define POLL_LIMIT 100000U
#ifndef TINYYOLO_LINUX
#define BASE XPAR_TINYYOLO_ACCEL_0_BASEADDR
#define TY_CTRL 0x00U
#define STATUS 0x04U
#define RESULT 0x08U
#define BIAS 0x0cU
#define ACTIVATION 0x10U
#define WEIGHT 0x20U
#endif

#ifdef TINYYOLO_LINUX
float *g_frame_input;
static int ty_input_prequantized;
uint8_t *g_params,*g_arena,*g_acc_buffer,*g_pad_buffer;
/* Production Linux execution never enables full intermediate tracing. */
uint8_t g_trace[1];
#else
float g_frame_input[INPUT_VALUES] __attribute__((aligned(64)));
uint8_t g_params[PARAM_BYTES] __attribute__((aligned(64)));
uint8_t g_arena[ARENA_BYTES] __attribute__((aligned(64)));
uint8_t g_acc_buffer[ACC_BYTES+2U*GUARD] __attribute__((aligned(64)));
uint8_t g_pad_buffer[PAD_BYTES+2U*GUARD] __attribute__((aligned(64)));
uint8_t g_trace[TRACE_BYTES] __attribute__((aligned(64)));
#endif
uint32_t g_offsets[MAX_TAPS] __attribute__((aligned(64)));
float g_final[FINAL_VALUES] __attribute__((aligned(64)));
/* Per step: elapsed ticks low/high, actual MAC chunks, outputs, tensor FNV. */
uint32_t g_step_stats[STEP_COUNT][5] __attribute__((aligned(64)));
volatile uint32_t g_phase,g_status,g_exit,g_frame_id,g_completed_frames;
volatile uint32_t g_step,g_protocol,g_first_guard,g_guard_checks,g_mac_chunks;
volatile uint32_t g_elapsed_ms,g_parameter_hash;
#ifdef TINYYOLO_LINUX
volatile uint32_t g_trace_enabled;
#else
volatile uint32_t g_trace_enabled=1U;
#endif
volatile uint32_t g_timer_frequency=(uint32_t)COUNTS_PER_SECOND;
volatile uint32_t g_parameter_validation_count;
volatile uint32_t g_pl_feature_mask=56U;
uint32_t g230_fused_step=UINT32_MAX,g230_fused_mode;
#ifndef TINYYOLO_HOST
#ifdef TINYYOLO_LINUX
uint8_t (*g_head_tables)[524352];
float (*g_head_output)[HEAD_LARGE_PIXELS];
#else
uint8_t g_head_tables[2][524352] __attribute__((aligned(64)));
float g_head_output[2][HEAD_LARGE_PIXELS] __attribute__((aligned(64)));
#endif
uint32_t g_head_tables_ready;
#endif

__attribute__((noinline,noclone,used)) void network_ready(void) {__asm__ volatile("nop" ::: "memory");}
__attribute__((noinline,noclone,used)) void network_finished(void) {__asm__ volatile("nop\n\tnop" ::: "memory");}

static uint64_t ticks(void) {
#ifdef TINYYOLO_HOST
    return (uint64_t)clock();
#elif defined(TINYYOLO_LINUX)
    struct timespec t;
    if(clock_gettime(CLOCK_MONOTONIC,&t)){perror("clock_gettime");exit(1);}
    return (uint64_t)t.tv_sec*1000000000ULL+(uint64_t)t.tv_nsec;
#else
    XTime t;XTime_GetTime(&t);return (uint64_t)t;
#endif
}
static uint32_t fnv(const void *data,uint32_t bytes) {
    const uint8_t *p=(const uint8_t*)data;uint32_t h=2166136261U,i;
    for(i=0;i<bytes;i++){h^=p[i];h*=16777619U;}return h;
}
static void *tensor(uint32_t i) {return g_arena+tensors[i].off+GUARD;}
static int guard_one(const uint8_t *p,uint32_t bytes) {
    uint32_t i;for(i=0;i<GUARD;i++)if(p[i]!=0xc7U || p[GUARD+bytes+i]!=0x7cU)return 1;
    g_guard_checks++;return 0;
}
static void guard_init(uint8_t *p,uint32_t bytes) {
    memset(p,0xc7,GUARD);memset(p+GUARD+bytes,0x7c,GUARD);
}
static int guards(uint32_t step) {
    uint32_t i;
    for(i=0;i<TENSOR_COUNT;i++)if(tensors[i].birth<=step && tensors[i].last>=step)
        if(guard_one(g_arena+tensors[i].off,tensors[i].bytes)){g_first_guard=i;return 1;}
    if(guard_one(g_acc_buffer,ACC_BYTES)){g_first_guard=TENSOR_COUNT;return 1;}
    if(guard_one(g_pad_buffer,PAD_BYTES)){g_first_guard=TENSOR_COUNT+1U;return 1;}
    return 0;
}
static int64_t round_even(double x) {
    double ax=fabs(x),f;uint64_t q=(uint64_t)ax;f=ax-(double)q;
    if(f>0.5 || (f==0.5 && (q&1U)))q++;
    return x<0?-(int64_t)q:(int64_t)q;
}
static int quant_input(int8_t *out) {
#ifdef TINYYOLO_LINUX
    // Camera INT8 input already occupies this tensor in the shared DMA arena.
    // Its producer release and runtime acquire happen before run_frame starts.
    if(ty_input_prequantized)return out==(int8_t*)tensor(steps[0].out)?0:21;
#endif
    uint32_t i;for(i=0;i<INPUT_VALUES;i++) {
        float f=g_frame_input[i]/INPUT_SCALE;int64_t q;
        if(!isfinite(f))return 21;
        if(f>=255.0f)q=255;else if(f<=-255.0f)q=-255;else q=round_even((double)f);
        q+=INPUT_ZERO_POINT;if(q< -128)q=-128;if(q>127)q=127;out[i]=(int8_t)q;
    }return 0;
}
#ifdef TINYYOLO_HOST
static int conv_int(uint32_t li,const int8_t *input,int8_t *out) {
    const Conv *l=&convs[li];uint32_t plane=l->h*l->w,pw=l->w+2U*l->pad,ph=l->h+2U*l->pad;
    uint32_t pp=pw*ph,taps=l->ci*l->k*l->k,oc,ch,y,x,t;
    int8_t *pad=(int8_t*)g_pad_buffer+GUARD;
    int32_t *acc=(int32_t*)(g_acc_buffer+GUARD);
    const int8_t *weight=(const int8_t*)g_params+l->weights;
    const int32_t *bias=(const int32_t*)(g_params+l->bias);
    const uint64_t *mul=(const uint64_t*)(g_params+l->mul);
    const uint32_t *shift=(const uint32_t*)(g_params+l->shift);
    uint64_t begin=ticks();
    if(l->ci*pp>PAD_BYTES || l->co*plane*4U>ACC_BYTES || taps>MAX_TAPS)return 26;
    if(l->pad) {
        memset(pad,(uint8_t)(int8_t)l->zx,l->ci*pp);
        for(oc=0;oc<l->ci;oc++)for(y=0;y<l->h;y++)
            memcpy(pad+oc*pp+(y+l->pad)*pw+l->pad,input+oc*plane+y*l->w,l->w);
    } else memcpy(pad,input,l->ci*plane);
    for(t=0;t<taps;t++)g_offsets[t]=(t/(l->k*l->k))*pp+((t%(l->k*l->k))/l->k)*pw+t%l->k;
    for(oc=0;oc<l->co;oc++) {
        if(!mul[oc] || shift[oc]<1 || shift[oc]>62)return 27;
        for(ch=0;ch<l->chunks;ch++) {
            const int8_t *ww=weight+(oc*l->chunks+ch)*MAC_LANES;
            const uint32_t *offset=g_offsets+ch*MAC_LANES;
            uint32_t count=taps-ch*MAC_LANES;if(count>MAC_LANES)count=MAC_LANES;
            for(y=0;y<l->h;y++) {
                for(x=0;x<l->w;x++) {
                    uint32_t ix=oc*plane+y*l->w+x;
                    const int8_t *p=pad+y*pw+x;int32_t a,dot=0;int64_t sum;
                    /* At most MAC_LANES signed INT8 products.
                     * Keep the original INT32 overflow gate at EVERY chunk.
                     * Zero padded activation lanes contribute exactly zero. */
                    for(t=0;t+3U<count;t+=4U)
                        dot+=(int32_t)p[offset[t]]*(int32_t)ww[t]
                            +(int32_t)p[offset[t+1U]]*(int32_t)ww[t+1U]
                            +(int32_t)p[offset[t+2U]]*(int32_t)ww[t+2U]
                            +(int32_t)p[offset[t+3U]]*(int32_t)ww[t+3U];
                    for(;t<count;t++)dot+=(int32_t)p[offset[t]]*(int32_t)ww[t];
                    sum=(int64_t)(ch?acc[ix]:bias[oc])+dot;
                    if(sum<INT32_MIN || sum>INT32_MAX)return 22;a=(int32_t)sum;
                    g_mac_chunks++;acc[ix]=a;
                    if(ch+1U==l->chunks) {
                        uint64_t magnitude=a<0?(uint64_t)(-(int64_t)a):(uint64_t)a;
                        if(magnitude>(uint64_t)INT64_MAX/mul[oc])return 28;
                        out[ix]=tinyyolo_requant_integer(a,mul[oc],shift[oc],l->zy);
                    }
                }
                if(ticks()-begin>(uint64_t)COUNTS_PER_SECOND*1800U)return 29;
            }
        }
    }
    if(g_trace_enabled)memcpy(g_trace+l->acc_trace,acc,l->co*plane*4U);
    return 0;
}
#elif defined(TINYYOLO_LINUX)
#include "../../linux/runtime_pl.inc"
#else
#include "g225_pl_driver.inc"
#endif
#ifndef TINYYOLO_HOST
#include "g230_head_driver.inc"
#endif
#ifndef TINYYOLO_LINUX
static const volatile void *ty_cpu_param(uint32_t offset,uint32_t bytes)
{
    (void)bytes;return g_params+offset;
}
#endif
static int bridge(const Step *s) {
    const int8_t *q=(const int8_t*)tensor(s->a);
    const volatile void *table=ty_cpu_param(s->p0,s->mode==4?1024U:256U);
    const volatile int8_t *lut=(const volatile int8_t*)table;
    int8_t *out=(int8_t*)tensor(s->out);const volatile float *flut=(const volatile float*)table;
    float *fout=(float*)out;uint32_t c,y,x,oh=s->mode==2?s->h/2U:s->h,ow=s->mode==2?s->w/2U:s->w;
    uint32_t count=s->channels*s->h*s->w;
    if(g230_fused_step==g_step && (s->mode==0 || s->mode==2)) {
        memcpy(out,q,tensors[s->out].bytes);return 0;
    }
#ifndef TINYYOLO_HOST
    if(s->mode==4) {
        int code=g230_head(s);if(code)return code;
#ifdef TINYYOLO_LINUX
        if(!g_trace_enabled && !ty_trace_prefix)return 0;
#else
        if(!g_trace_enabled)return 0;
#endif
    }
#endif
    if(s->mode==0){for(x=0;x<count;x++)out[x]=lut[(int)q[x]+128];return 0;}
    if(s->mode==4){for(x=0;x<count;x++)fout[x]=flut[(int)q[x]+128];return 0;}
    /* Interior windows need no bounds branches. Apply the activation LUT
     * BEFORE max: quantized SiLU is not monotone over all signed inputs. */
    if(s->mode==2 && !(s->h&1U) && !(s->w&1U)) {
        for(c=0;c<s->channels;c++)for(y=0;y<oh;y++) {
            const int8_t *row=q+c*s->h*s->w+2U*y*s->w;
            int8_t *dst=out+c*oh*ow+y*ow;
            for(x=0;x<ow;x++) {
                int8_t a=lut[(int)row[2U*x]+128],b=lut[(int)row[2U*x+1U]+128];
                int8_t d=lut[(int)row[s->w+2U*x]+128],e=lut[(int)row[s->w+2U*x+1U]+128];
                if(b>a)a=b;if(d>a)a=d;if(e>a)a=e;dst[x]=a;
            }
        }return 0;
    }
    for(c=0;c<s->channels;c++)for(y=0;y<oh;y++)for(x=0;x<ow;x++) {
        uint32_t ix=c*oh*ow+y*ow+x;
        if(s->mode==0)out[ix]=lut[(int)q[ix]+128];
        else if(s->mode==4)fout[ix]=flut[(int)q[ix]+128];
        else {
            uint32_t dy,dx,by=s->mode==2?2U*y:y,bx=s->mode==2?2U*x:x;
            int8_t v=INT8_MIN;
            for(dy=0;dy<2;dy++)for(dx=0;dx<2;dx++)if(by+dy<s->h && bx+dx<s->w) {
                int8_t raw=q[c*s->h*s->w+(by+dy)*s->w+bx+dx];
                int8_t a=g230_fused_step==g_step?raw:lut[(int)raw+128];if(a>v)v=a;
            }out[ix]=v;
        }
    }return 0;
}
static int branch(const Step *s) {
    const int8_t *q8=(const int8_t*)tensor(s->a),*q4=(const int8_t*)tensor(s->b);
    const volatile int8_t *l8=(const volatile int8_t*)ty_cpu_param(s->p0,256U);
    const volatile int8_t *l4=(const volatile int8_t*)ty_cpu_param(s->p1,256U);
    int8_t *out=(int8_t*)tensor(s->out);uint32_t c,y,x;
    for(c=0;c<128;c++)for(y=0;y<HEAD_SMALL;y++) {
        int8_t *row=out+c*HEAD_LARGE_PIXELS+2U*y*HEAD_LARGE;
        for(x=0;x<HEAD_SMALL;x++) {
            int8_t value=l8[(int)q8[c*HEAD_SMALL_PIXELS+y*HEAD_SMALL+x]+128];
            row[2U*x]=value;row[2U*x+1U]=value;
        }memcpy(row+HEAD_LARGE,row,HEAD_LARGE);
    }
    for(c=0;c<256U*HEAD_LARGE_PIXELS;c++)out[128U*HEAD_LARGE_PIXELS+c]=l4[(int)q4[c]+128];
    return 0;
}
static int conv_float(const Step *s) {
#ifndef TINYYOLO_HOST
    if((s->layer!=17U && s->layer!=21U) || !g_g222_layer_valid[s->layer])return 116;
    memcpy(tensor(s->out),g_head_output[s->layer==17U?0U:1U],tensors[s->out].bytes);
    return 0;
#else
    const Conv *l=&convs[s->layer];const float *q=(const float*)tensor(s->a);
    const float *w=(const float*)(g_params+l->weights),*b=(const float*)(g_params+l->bias);
    float *out=(float*)tensor(s->out);uint32_t i,c,j,n=l->h*l->w;
    /* Eight adjacent pixels reuse each weight and load contiguous channels.
     * Every pixel retains ascending-channel FP64 accumulation and one final
     * FP32 cast. Compile with -ffp-contract=off, without fast-math. */
    for(i=0;i<n;i+=8U) {
        double sum[8];uint32_t count=n-i;if(count>8U)count=8U;
        for(j=0;j<count;j++)sum[j]=b[0];
        for(c=0;c<l->ci;c++)for(j=0;j<count;j++)sum[j]+=(double)q[c*n+i+j]*w[c];
        for(j=0;j<count;j++)out[i+j]=(float)sum[j];
    }
    return 0;
#endif
}
static int layout(const Step *s) {
    const int8_t *q22=(const int8_t*)tensor(s->a),*q18=(const int8_t*)tensor(s->b);
    float *out=(float*)tensor(s->out);float lut22[256],lut18[256];uint32_t c,i;
    /* Exhaustive INT8 dequantization tables: 512 exact FP32 products replace
     * 54080 per-frame products. No graph scales or parameters are altered. */
    for(i=0;i<256U;i++) {
        lut22[i]=(float)((int)i-128-convs[22].zy)*convs[22].sy;
        lut18[i]=(float)((int)i-128-convs[18].zy)*convs[18].sy;
    }
    for(c=0;c<64;c++) {
        for(i=0;i<HEAD_LARGE_PIXELS;i++)out[c*DETECTION_POSITIONS+i]=lut22[(int)q22[c*HEAD_LARGE_PIXELS+i]+128];
        for(i=0;i<HEAD_SMALL_PIXELS;i++)out[c*DETECTION_POSITIONS+HEAD_LARGE_PIXELS+i]=lut18[(int)q18[c*HEAD_SMALL_PIXELS+i]+128];
    }
    memcpy(out+64U*DETECTION_POSITIONS,tensor(s->c),HEAD_LARGE_PIXELS*4U);
    memcpy(out+64U*DETECTION_POSITIONS+HEAD_LARGE_PIXELS,tensor(s->d),HEAD_SMALL_PIXELS*4U);return 0;
}
static int softmax(const Step *s) {
    const float *v=(const float*)tensor(s->a);int8_t *out=(int8_t*)tensor(s->out);
    uint32_t b,i,k;for(b=0;b<4;b++)for(i=0;i<DETECTION_POSITIONS;i++) {
        double max=-INFINITY,total=0,e[16];
        for(k=0;k<16;k++)if(v[(b*16U+k)*DETECTION_POSITIONS+i]>max)max=v[(b*16U+k)*DETECTION_POSITIONS+i];
        for(k=0;k<16;k++){e[k]=exp((double)v[(b*16U+k)*DETECTION_POSITIONS+i]-max);total+=e[k];}
        if(!isfinite(total)||total<=0)return 30;
        for(k=0;k<16;k++) {
            int64_t q=round_even(e[k]/total/DFL_INPUT_SCALE)+DFL_INPUT_ZERO_POINT;
            if(q< -128)q=-128;if(q>127)q=127;out[(k*4U+b)*DETECTION_POSITIONS+i]=(int8_t)q;
        }
    }return 0;
}
static int decode(const Step *s) {
    const int8_t *q=(const int8_t*)tensor(s->a);const float *head=(const float*)tensor(s->b);
    const volatile float *anchor=(const volatile float*)ty_cpu_param(ANCHOR_OFFSET,2U*DETECTION_POSITIONS*4U);
    const volatile float *stride=(const volatile float*)ty_cpu_param(STRIDE_OFFSET,DETECTION_POSITIONS*4U);
    float *out=(float*)tensor(s->out);uint32_t i;
    for(i=0;i<DETECTION_POSITIONS;i++) {
        float dl=(float)((int)q[i]-convs[23].zy)*convs[23].sy;
        float dt=(float)((int)q[DETECTION_POSITIONS+i]-convs[23].zy)*convs[23].sy;
        float dr=(float)((int)q[2U*DETECTION_POSITIONS+i]-convs[23].zy)*convs[23].sy;
        float db=(float)((int)q[3U*DETECTION_POSITIONS+i]-convs[23].zy)*convs[23].sy;
        float lx=anchor[i]-dl,ly=anchor[DETECTION_POSITIONS+i]-dt,rx=anchor[i]+dr,ry=anchor[DETECTION_POSITIONS+i]+db;
        double z=head[64U*DETECTION_POSITIONS+i],e=exp(z>=0?-z:z);
        out[i]=((lx+rx)/2.0f)*stride[i];out[DETECTION_POSITIONS+i]=((ly+ry)/2.0f)*stride[i];
        out[2U*DETECTION_POSITIONS+i]=(rx-lx)*stride[i];out[3U*DETECTION_POSITIONS+i]=(ry-ly)*stride[i];
        out[4U*DETECTION_POSITIONS+i]=(float)(z>=0?1.0/(1.0+e):e/(1.0+e));
    }return 0;
}
static int validate_schedule(void) {
    uint32_t i,j,k;
    if(!g_trace_enabled && g_parameter_validation_count && g_parameter_hash==PARAM_HASH)return 0;
    g_parameter_hash=fnv(g_params,PARAM_BYTES);g_parameter_validation_count++;
    if(g_parameter_hash!=PARAM_HASH)return 31;
    for(i=0;i<TENSOR_COUNT;i++) {
        const Tensor *t=&tensors[i];
        if(t->off%64U || !t->bytes || t->off+2U*GUARD+t->bytes>ARENA_BYTES ||
           t->birth>t->last || t->last>=STEP_COUNT || t->trace+t->bytes>TRACE_BYTES)return 32;
        for(j=i+1;j<TENSOR_COUNT;j++) {
            const Tensor *u=&tensors[j];
            if(t->birth<=u->last && u->birth<=t->last && t->off<u->off+u->bytes+2U*GUARD &&
               u->off<t->off+t->bytes+2U*GUARD)return 33;
        }
    }
    for(i=0;i<STEP_COUNT;i++) {
        const Step *s=&steps[i];uint32_t a[4]={s->a,s->b,s->c,s->d};
        if(s->out>=TENSOR_COUNT || tensors[s->out].birth!=i)return 34;
        for(k=0;k<4;k++)if(a[k]!=NIL && (a[k]>=TENSOR_COUNT || tensors[a[k]].birth>=i || tensors[a[k]].last<i))return 35;
    }return 0;
}
static int run_frame(void) {
    uint32_t i;int code;uint64_t begin=ticks();g_mac_chunks=g_guard_checks=0;g_first_guard=NIL;g230_fused_step=NIL;
    if(g_trace_enabled)memset(g_arena,0xa5,ARENA_BYTES);memset(g_step_stats,0,sizeof(g_step_stats));
#ifdef TINYYOLO_LINUX
    if(ty_trace_prefix && !ty_input_prequantized)memset(g_arena,0xa5,ARENA_BYTES);
#endif
    memset(g_final,0xa5,sizeof(g_final));if(g_trace_enabled)memset(g_trace,0xa5,sizeof(g_trace));
    guard_init(g_acc_buffer,ACC_BYTES);guard_init(g_pad_buffer,PAD_BYTES);
    code=validate_schedule();if(code)return code;
    for(i=0;i<STEP_COUNT;i++) {
        const Step *s=&steps[i];const Tensor *t=&tensors[s->out];uint64_t a,b;uint32_t before=g_mac_chunks;
        g_step=i;guard_init(g_arena+t->off,t->bytes);a=ticks();
        switch(s->kind) {
            case 1:code=quant_input((int8_t*)tensor(s->out));break;
            case 2:code=bridge(s);break;
            case 3:code=branch(s);break;
            case 4:code=conv_int(s->layer,(const int8_t*)tensor(s->a),(int8_t*)tensor(s->out));break;
            case 5:code=conv_float(s);break;
            case 6:code=layout(s);break;
            case 7:code=softmax(s);break;
            case 8:code=decode(s);break;
            default:code=36;
        }
        b=ticks()-a;g_step_stats[i][0]=(uint32_t)b;g_step_stats[i][1]=(uint32_t)(b>>32);
        g_step_stats[i][2]=g_mac_chunks-before;g_step_stats[i][3]=t->bytes/(t->dtype?4U:1U);
        if(code)return code;if(g_trace_enabled && guards(i))return 37;
#ifdef TINYYOLO_LINUX
        if(ty_trace_prefix && guards(i))return 37;
#endif
        if(g_trace_enabled)memcpy(g_trace+t->trace,tensor(s->out),t->bytes);
        g_step_stats[i][4]=g_trace_enabled?fnv(tensor(s->out),t->bytes):0U;
#ifdef TINYYOLO_LINUX
        /* Bounded, opt-in snapshots are consumed before the DDR arena is reused.
         * They do not enable the bare-metal full-trace buffer or change math. */
        if(ty_trace_step(i,tensor(s->out),t->bytes))return 127;
#endif
#if !defined(TINYYOLO_HOST) && !defined(TINYYOLO_LINUX)
        if(g_trace_enabled)xil_printf("NET frame=%u step=%u kind=%u layer=%u chunks=%u hash=%08x\r\n",
            (unsigned)g_frame_id,(unsigned)i,(unsigned)s->kind,(unsigned)s->layer,
            (unsigned)g_step_stats[i][2],(unsigned)g_step_stats[i][4]);
#endif
    }
    memcpy(g_final,tensor(FINAL_TENSOR),sizeof(g_final));
    for(i=0;i<FINAL_VALUES;i++)if(!isfinite(g_final[i]))return 38;
    if(g_mac_chunks!=EXPECTED_MAC_CHUNKS)return 39;
    g_elapsed_ms=(uint32_t)((ticks()-begin)*1000U/COUNTS_PER_SECOND);g_completed_frames++;return 0;
}

#ifdef TINYYOLO_HOST
static void load(const char *p,void *dst,size_t n) {
    FILE *f=fopen(p,"rb");if(!f || fread(dst,1,n,f)!=n || fgetc(f)!=EOF){fprintf(stderr,"Bad file %s\n",p);exit(2);}fclose(f);
}
static void save(const char *p,const void *src,size_t n) {
    FILE *f=fopen(p,"wbx");if(!f || fwrite(src,1,n,f)!=n || fclose(f)){fprintf(stderr,"Cannot save %s\n",p);exit(2);}
}
int main(int argc,char **argv) {
    int code;if(argc!=6 && argc!=7)return 64;load(argv[1],g_params,sizeof(g_params));load(argv[2],g_frame_input,sizeof(g_frame_input));
    code=run_frame();if(code){fprintf(stderr,"NET HOST FAIL code=%d step=%u guard=%u\n",code,g_step,g_first_guard);return 1;}
    save(argv[3],g_final,sizeof(g_final));save(argv[4],g_trace,sizeof(g_trace));save(argv[5],g_step_stats,sizeof(g_step_stats));
    if(argc==7)save(argv[6],g_acc_buffer,sizeof(g_acc_buffer));
    printf("NET HOST PASS steps=%u chunks=%u elapsed_ms=%u arena=%u trace=%u guards=%u\n",
        STEP_COUNT,g_mac_chunks,g_elapsed_ms,ARENA_BYTES,TRACE_BYTES,g_guard_checks);return 0;
}
#elif defined(TINYYOLO_LINUX)
#include "../../linux/runtime_main.inc"
#else
int main(void) {
    Xil_DCacheDisable();Xil_ICacheEnable();
    xil_printf("G228 P3 all 24 convolutions in PL; exact FP64 heads; no NMS\r\n");
    for(;;) {
        int code;Xil_DCacheDisable();g_phase=1;__asm__ volatile("dsb sy" ::: "memory");network_ready();
        if(g_exit){for(;;)sleep(1);}
        code=g222_frame_begin();
        if(!code) {
            g_phase=2;g_status=1;Xil_DCacheInvalidate();Xil_DCacheEnable();
            code=run_frame();
        }
        g_protocol=(uint32_t)code;g_status=code?3U:2U;
        /* Unsafe exit leaves D-cache off and never consumes PL outputs. */
        if(!g_g222_unsafe)Xil_DCacheFlush();
        Xil_DCacheDisable();g_phase=3;__asm__ volatile("dsb sy" ::: "memory");
        xil_printf("NET %s frame=%u completed=%u chunks=%u guards=%u elapsed_ms=%u protocol=%u\r\n",
            code?"FAIL":"PASS",(unsigned)g_frame_id,(unsigned)g_completed_frames,
            (unsigned)g_mac_chunks,(unsigned)g_guard_checks,(unsigned)g_elapsed_ms,(unsigned)g_protocol);
        network_finished();
        /* Any failed frame is terminal. No retry, reset or controller clear. */
        if(code){g_phase=4U;__asm__ volatile("dsb sy" ::: "memory");for(;;)sleep(1);}
    }
}
#endif
