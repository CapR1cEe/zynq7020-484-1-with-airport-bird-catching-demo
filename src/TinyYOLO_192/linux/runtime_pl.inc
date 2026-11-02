/* Shared graph, Linux DMA-offset submissions. No /dev/mem or cache controls. */
static int ty_fd=-1;
static uint8_t *ty_dma;
#include "tinyyolo_hot_cache.h"
static struct ty_hot_cache ty_hot;
static int ty_ocm_mapped;
static const volatile void *ty_cpu_param(uint32_t offset,uint32_t bytes)
{
    const volatile void *p=ty_hot_find(&ty_hot,offset,bytes);
    if(!p){fprintf(stderr,"CPU lookup-cache entry missing\n");exit(1);}
    return p;
}
volatile uint32_t g_pl_stats[24][10],g_hp_stats[24][6],g_phase_stats[24][30];
volatile uint32_t g_g222_layer_valid[24],g_pl_calls,g_zero_skipped[24],g_layer_options[24];
volatile uint32_t g_g222_last_code,g_g222_frame_sequence;
static int g230_prepare_heads(void);
static const char *ty_trace_prefix;
static int ty_file_write(const char *path,const void *src,size_t bytes);
static int ty_trace_step(uint32_t step,const void *data,uint32_t bytes)
{
    char path[4096];
    if(!ty_trace_prefix)return 0;
    if(snprintf(path,sizeof(path),"%s.%04u.step%02u.bin",ty_trace_prefix,
                g_frame_id,step)>=(int)sizeof(path))return 1;
    return ty_file_write(path,data,bytes);
}

static uint32_t ty_offset(const void *pointer)
{
    uintptr_t value=(uintptr_t)pointer,base=(uintptr_t)ty_dma;
    if(value<base || value-base>=TY_DMA_BYTES){fprintf(stderr,"DMA offset outside allocation\n");exit(1);}
    return (uint32_t)(value-base);
}
static int ty_submit_layer(uint32_t li,struct ty_submit *s,uint32_t writes,uint32_t macs,uint32_t n)
{
    uint64_t total,sum=0;uint32_t i;
    s->timeout_ms=600000U;
    if(ioctl(ty_fd,TY_IOC_SUBMIT,s)) {perror("TY_IOC_SUBMIT (terminal, no retry)");return 120;}
    memcpy((void*)g_pl_stats[li],s->pl,sizeof(s->pl));
    memcpy((void*)g_hp_stats[li],s->hp,sizeof(s->hp));
    memcpy((void*)g_phase_stats[li],s->phase,sizeof(s->phase));
    g_zero_skipped[li]=s->skipped;g_layer_options[li]=s->options;
    total=(uint64_t)s->pl[2]|((uint64_t)s->pl[3]<<32);
    if(s->status!=2U || s->error || !total || s->hp[5]!=1U ||
       s->pl[5]!=writes || s->pl[6]!=macs || s->pl[7]!=n ||
       !s->hp[0] || s->hp[4]!=s->hp[0] || s->hp[1]<s->hp[0] ||
       (uint64_t)s->hp[1]>(uint64_t)s->hp[0]*8U ||
       (uint64_t)s->pl[4]!=(uint64_t)s->hp[2]+s->hp[3]+s->hp[4])return 121;
    for(i=0;i<15U;i++) {
        uint64_t counter=(uint64_t)s->phase[2U*i]|((uint64_t)s->phase[2U*i+1U]<<32);
        if(counter>total)return 122;
        if(i<8U) {if(sum>total-counter)return 122;sum+=counter;}
    }
    if(sum!=total || ((uint64_t)s->phase[22]|((uint64_t)s->phase[23]<<32))!=s->hp[1] ||
       ((uint64_t)s->phase[28]|((uint64_t)s->phase[29]<<32))!=writes)return 122;
    g_g222_layer_valid[li]=1;g_pl_calls++;
    return 0;
}
static int g222_frame_begin(void)
{
    struct ty_info info;
    if(g_trace_enabled)return 123;
    if(ioctl(ty_fd,TY_IOC_INFO,&info)){perror("TY_IOC_INFO");return 124;}
    if(info.abi!=TY_ABI || info.build_id!=TY_BUILD || !ty_clock_matches(info.pl_hz,240000000U) ||
       !ty_clock_matches(info.fclk_hz,100000000U) || info.dma_bytes!=TY_DMA_BYTES || info.faulted)return 125;
    memset((void*)g_g222_layer_valid,0,sizeof(g_g222_layer_valid));
    g_g222_frame_sequence++;return 0;
}
static int conv_int(uint32_t li,const int8_t *input,int8_t *out)
{
    const Conv *l;uint32_t options,n,qp,writes,oc;struct ty_submit s;
    if(li>=24U)return 126;
    l=&convs[li];n=l->co*l->h*l->w;
    memset(&s,0,sizeof(s));options=(g_pl_feature_mask&56U)|1U;g230_fused_step=UINT32_MAX;
    /* Layer snapshots must retain the unfused convolution output. Production
     * still uses LUT/pool fusion and the validated mask 48. */
    if(!ty_trace_prefix && g_step+1U<STEP_COUNT) {
        const Step *current=&steps[g_step],*next=&steps[g_step+1U];
        if(next->kind==2U && next->a==current->out && next->mode<=2U &&
           tensors[current->out].last==g_step+1U) {
            options|=2U;g230_fused_step=g_step+1U;g230_fused_mode=next->mode;
            s.lut_offset=ty_offset(g_params+next->p0);
            if(next->mode==2U)options|=64U;
        }
    }
    s.options=options;
    s.cfg[0]=ty_offset(input);s.cfg[1]=ty_offset(g_params+l->weights);
    s.cfg[2]=ty_offset(g_params+l->bias);s.cfg[3]=ty_offset(g_params+l->mul);
    s.cfg[4]=ty_offset(g_params+l->shift);s.cfg[5]=ty_offset(g_acc_buffer+GUARD);
    s.cfg[6]=ty_offset(out);s.cfg[7]=l->ci;s.cfg[8]=l->co;s.cfg[9]=l->h;s.cfg[10]=l->w;
    s.cfg[11]=l->k;s.cfg[12]=l->pad;s.cfg[13]=(uint32_t)l->zx;s.cfg[14]=(uint32_t)l->zy;
    qp=l->h*l->w/((options&64U)?4U:1U);writes=0;
    if(options&32U)for(oc=0;oc<l->co;oc++)writes+=((oc+1U)*qp-1U)/8U-(oc*qp)/8U+1U;
    else writes=qp*l->co;
    {int rc=ty_submit_layer(li,&s,writes,n*l->chunks,n);if(rc)return rc;}
    g_mac_chunks+=n*l->chunks;return 0;
}
static int g230_head(const Step *step)
{
    uint32_t li=step->out==steps[34].out?17U:21U,hi=li==17U?0U:1U,n=step->h*step->w;
    if(step!=&steps[34] && step!=&steps[42])return 116;
    struct ty_submit s;int rc=g230_prepare_heads();if(rc)return rc;
    memset(&s,0,sizeof(s));s.options=4U;
    s.cfg[0]=ty_offset(tensor(step->a));s.cfg[1]=ty_offset(g_head_tables[hi]);
    s.cfg[6]=ty_offset(g_head_output[hi]);s.cfg[7]=256U;s.cfg[8]=1U;
    s.cfg[9]=step->h;s.cfg[10]=step->w;
    return ty_submit_layer(li,&s,n,n*256U,n);
}
