/* Host MMIO model exercises the actual resident driver, not the RTL.
 * Numerical inference is validated separately with RTL and board readback. */
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <limits.h>
#define TINYYOLO_DRIVER_TEST
#define COUNTS_PER_SECOND 1000U
#define GUARD 64U
#define NIL UINT32_MAX
typedef struct {uint32_t off,bytes,birth,last,trace,dtype;} Tensor;
typedef struct {uint32_t ci,co,h,w,k,pad,chunks,weights,bias,mul,shift,acc_trace;int32_t zx,zy;float sy;} Conv;
typedef struct {uint32_t kind,layer,a,b,c,d,out,p0,p1,channels,h,w,mode;} Step;
#include "../software/source/network_config.h"
uint8_t g_params[PARAM_BYTES] __attribute__((aligned(64)));
uint8_t g_arena[ARENA_BYTES] __attribute__((aligned(64)));
uint8_t g_acc_buffer[ACC_BYTES+128] __attribute__((aligned(64)));
uint8_t g_trace[TRACE_BYTES] __attribute__((aligned(64)));
uint8_t g_head_tables[2][524352] __attribute__((aligned(64)));
float g_head_output[2][HEAD_LARGE_PIXELS] __attribute__((aligned(64)));
uint32_t g_head_tables_ready,g_step,g_trace_enabled,g_mac_chunks,g_pl_feature_mask=56;
uint32_t g230_fused_step=UINT32_MAX,g230_fused_mode;
static uint64_t now;
static uint32_t registers[15],model_options,model_status,model_build;
static uint32_t model_idle=1,model_writes,model_macs,model_outputs,model_cycles;
static unsigned mmio_writes,cache_disables,cache_enables,starts,barriers;
static int force_busy,corrupt_counter,force_fault;
static uint64_t ticks(void){return ++now;}
static void *tensor(uint32_t i){return g_arena+tensors[i].off+GUARD;}
static void g222_test_barrier(void){barriers++;}
static void Xil_DCacheFlush(void){}
static void Xil_DCacheInvalidate(void){}
static void Xil_DCacheDisable(void){cache_disables++;}
static void Xil_DCacheEnable(void){cache_enables++;}
static uint32_t Xil_In32(uint32_t address){
 uint32_t off=address-0x40000000U;
 if(off==0x4c)return model_build;
 if(off==4)return model_status;
 if(off==0x84)return model_idle;
 if(off==0x48)return model_cycles;
 if(off==0x54)return starts?1U:0U;
 if(off==0x58)return model_writes+(uint32_t)corrupt_counter;
 if(off==0x5c)return model_macs;
 if(off==0x60)return model_outputs;
 if(off==0x70 || off==0x74 || off==0x80)return starts?1U:0U;
 if(off==0x88)return model_cycles;
 if(off==0xe0)return starts?1U:0U; /* profile event 11: read beats */
 if(off==0xf8)return model_writes;
 return 0;
}
static void Xil_Out32(uint32_t address,uint32_t value){
 uint32_t off=address-0x40000000U,n,plane,co,qp,oc;
 mmio_writes++;
 if(off==0x44){model_options=value;return;}
 if(off>=8 && off<=64){registers[(off-8)/4]=value;return;}
 if(off!=0)return;
 if(value==2){model_status=0;return;}
 if(value!=1)return;
 starts++;plane=registers[9]*registers[10];co=registers[8];n=plane*co;
 model_outputs=n;
 if(model_options&4){model_macs=n*256U;model_writes=n;}
 else{
  model_macs=n*((registers[7]*registers[11]*registers[11]+MAC_LANES-1U)/MAC_LANES);
  qp=(model_options&64)?plane/4:plane;
  model_writes=(model_options&1)?0:n;
  if(model_options&32)for(oc=0;oc<co;oc++)model_writes+=((oc+1)*qp-1)/8-(oc*qp)/8+1;
  else model_writes+=qp*co;
 }
 model_cycles=100000000U+model_writes;
 model_status=force_busy?1U:force_fault?4U:2U;
}
#include "../software/source/g225_pl_driver.inc"
#include "../software/source/g230_head_driver.inc"
static unsigned checked;
#define CHECK(x) do{if(!(x)){fprintf(stderr,"DRIVER_FAIL line=%u check=%s\n",(unsigned)__LINE__,#x);exit(1);}}while(0)
static void reset_model(void){
 g_g222_lock=g_g222_unsafe=g_pl_calls=g_mac_chunks=0;
 model_status=0;model_build=G222_BUILD;model_idle=1;model_cycles=0;
 force_busy=corrupt_counter=force_fault=0;starts=mmio_writes=cache_enables=cache_disables=0;
 now=0;memset((void*)g_g222_layer_valid,0,sizeof(g_g222_layer_valid));
}
static int run_int(void){const Step *s=&steps[g_step];return conv_int(s->layer,tensor(s->a),tensor(s->out));}
int main(int argc,char **argv){
 uint32_t i,mode;FILE *f;
 CHECK(argc==2);f=fopen(argv[1],"rb");CHECK(f!=NULL);CHECK(fread(g_params,1,PARAM_BYTES,f)==PARAM_BYTES);CHECK(fclose(f)==0);
 for(mode=0;mode<2;mode++){
  reset_model();g_trace_enabled=mode;
  CHECK(g222_frame_begin()==0 && mmio_writes==0 && g_g222_last_layer==UINT32_MAX);
  for(i=0;i<STEP_COUNT;i++){
   const Step *s=&steps[i];g_step=i;
   if(s->kind==4){CHECK(run_int()==0);CHECK(g_g222_layer_valid[s->layer]==1);checked++;}
   if(s->kind==2 && s->mode==4){CHECK(g230_head(s)==0);checked++;}
  }
  CHECK(g_pl_calls==24 && starts==24 && g_mac_chunks==EXPECTED_MAC_CHUNKS);
  CHECK(cache_enables==24 && cache_disables==24 && !g_g222_lock);
  for(i=0;i<24;i++)CHECK(g_g222_layer_valid[i]==1);
 }
 for(i=0;i<STEP_COUNT;i++)if(steps[i].kind==4)break;
 g_step=i;g_trace_enabled=0;
 reset_model();model_build=0;CHECK(g222_frame_begin()==101 && mmio_writes==0);checked++;
 reset_model();model_build=0;CHECK(run_int()==101 && mmio_writes==0 && cache_disables==0);checked++;
 reset_model();model_status=1;CHECK(run_int()==108 && mmio_writes==0);checked++;
 reset_model();model_idle=0;CHECK(run_int()==109 && mmio_writes==0);checked++;
 reset_model();CHECK(conv_int(24,tensor(steps[i].a),tensor(steps[i].out))==100 && mmio_writes==0);checked++;
 reset_model();CHECK(conv_int(steps[i].layer,(int8_t*)tensor(steps[i].a)+1,tensor(steps[i].out))==100 && mmio_writes==0);checked++;
 reset_model();force_busy=1;CHECK(run_int()==103 && g_g222_unsafe==1 && cache_enables==0 && starts==1);
 {unsigned previous=mmio_writes;CHECK(run_int()==107 && mmio_writes==previous);}checked++;
 reset_model();corrupt_counter=1;CHECK(run_int()==105 && g_g222_unsafe==0 && cache_enables==1 && starts==1);checked++;
 reset_model();force_fault=1;CHECK(run_int()==104 && g_g222_unsafe==0 && cache_enables==1);checked++;
 printf("DRIVER_PASS cases=%u all_PL=24 trace_and_production=1 sticky_timeout=1 no_writes_on_preflight_fault=1\n",checked);return 0;
}
