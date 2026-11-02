static uint32_t ty_used;
static void *ty_allocate(uint32_t bytes)
{
    uint32_t off=(ty_used+63U)&~63U;
    if(bytes>TY_DMA_BYTES || off>TY_DMA_BYTES-bytes){fprintf(stderr,"DMA arena too small\n");exit(1);}
    ty_used=off+bytes;return ty_dma+off;
}
static int ty_file_read(const char *path,void *dst,size_t bytes)
{
    FILE *f=fopen(path,"rb");int rc;
    if(!f){perror(path);return 1;}
    rc=fread(dst,1,bytes,f)!=bytes || fgetc(f)!=EOF;
    if(fclose(f))rc=1;
    if(rc)fprintf(stderr,"Wrong size/read failure: %s\n",path);
    return rc;
}
static int ty_file_write(const char *path,const void *src,size_t bytes)
{
    int fd=open(path,O_WRONLY|O_CREAT|O_EXCL,0644);FILE *f;int rc;
    if(fd<0){perror(path);return 1;}
    f=fdopen(fd,"wb");if(!f){close(fd);return 1;}
    rc=fwrite(src,1,bytes,f)!=bytes;
    if(fclose(f))rc=1;
    return rc;
}
#include "tinyyolo_input.h"
static int ty_open_device(const char *path)
{
    if(!strncmp(path,"fd:",3)) {
        char *end;long descriptor;
        errno=0;descriptor=strtol(path+3,&end,10);
        if(errno || end==path+3 || *end || descriptor<0 || descriptor>INT_MAX) {
            errno=EINVAL;return -1;
        }
        return fcntl((int)descriptor,F_DUPFD_CLOEXEC,0);
    }
    return open(path,O_RDWR|O_CLOEXEC);
}
static int ty_prepare_cpu_cache(const struct ty_info *info)
{
    uint32_t i;const char *mode=getenv("TINYYOLO_CPU_CACHE");
    int require_ocm=mode && !strcmp(mode,"ocm");
    if(mode && strcmp(mode,"ocm") && strcmp(mode,"ram") && strcmp(mode,"auto")) {
        fprintf(stderr,"TINYYOLO_CPU_CACHE must be auto, ram or ocm\n");return 1;
    }
    memset(&ty_hot,0,sizeof(ty_hot));ty_hot.capacity=TY_OCM_BYTES;
    if((!mode || strcmp(mode,"ram")) && info->ocm_bytes==TY_OCM_BYTES &&
       info->ocm_flags==TY_OCM_DEVICE_MAPPING) {
        ty_hot.memory=mmap(NULL,TY_OCM_BYTES,PROT_READ|PROT_WRITE,MAP_SHARED,ty_fd,TY_OCM_MMAP_OFFSET);
        if(ty_hot.memory==MAP_FAILED)ty_hot.memory=NULL;
        else {ty_ocm_mapped=1;ty_hot.device=1;}
    }
    if(require_ocm && !ty_ocm_mapped){fprintf(stderr,"Requested OCM pool is unavailable\n");return 1;}
    if(!ty_hot.memory)ty_hot.memory=malloc(TY_OCM_BYTES);
    if(!ty_hot.memory){perror("CPU lookup cache");return 1;}
    for(i=0;i<STEP_COUNT;i++) {
        const Step *s=&steps[i];
        if(s->kind==2 && ty_hot_add(&ty_hot,g_params,PARAM_BYTES,s->p0,s->mode==4?1024U:256U))return 1;
        if(s->kind==3 && (ty_hot_add(&ty_hot,g_params,PARAM_BYTES,s->p0,256U) ||
                         ty_hot_add(&ty_hot,g_params,PARAM_BYTES,s->p1,256U)))return 1;
    }
    if(ty_hot_add(&ty_hot,g_params,PARAM_BYTES,ANCHOR_OFFSET,2U*DETECTION_POSITIONS*4U) ||
       ty_hot_add(&ty_hot,g_params,PARAM_BYTES,STRIDE_OFFSET,DETECTION_POSITIONS*4U))return 1;
    if(ty_ocm_mapped && mprotect(ty_hot.memory,TY_OCM_BYTES,PROT_READ)) {perror("OCM read protection");return 1;}
    return 0;
}
int main(int argc,char **argv)
{
    int code=1,streamed,shared,no_frame_files;uint32_t frame,repeat=1;struct ty_info info;
    void *shared_output=NULL;
    const char *zero_skip=getenv("TINYYOLO_ZERO_SKIP");
    if(argc!=5 && argc!=6){fprintf(stderr,"Usage: %s /dev/tinyyolo0|fd:N parameters.bin frame.float32.bin|-|@dma|@dma-int8 output-prefix [frames]\n",argv[0]);return 64;}
    if(zero_skip && strcmp(zero_skip,"0") && strcmp(zero_skip,"1")) {
        fprintf(stderr,"TINYYOLO_ZERO_SKIP must be 0 or 1\n");return 64;
    }
    g_pl_feature_mask=zero_skip && !strcmp(zero_skip,"0")?48U:56U;
    streamed=!strcmp(argv[3],"-");
    ty_input_prequantized=!strcmp(argv[3],"@dma-int8");
    shared=!strcmp(argv[3],"@dma") || ty_input_prequantized;
    no_frame_files=shared && getenv("TINYYOLO_NO_FRAME_FILES") &&
        !strcmp(getenv("TINYYOLO_NO_FRAME_FILES"),"1");
    if(argc==6){char *end;unsigned long value=strtoul(argv[5],&end,10);if(*end || value<1 || value>10000)return 64;repeat=(uint32_t)value;}
    ty_fd=ty_open_device(argv[1]);if(ty_fd<0){perror(argv[1]);return 1;}
    if(ioctl(ty_fd,TY_IOC_INFO,&info) || info.abi!=TY_ABI || info.build_id!=TY_BUILD ||
       info.dma_bytes!=TY_DMA_BYTES || !ty_clock_matches(info.pl_hz,240000000U) ||
       !ty_clock_matches(info.fclk_hz,100000000U) || info.faulted) {
        fprintf(stderr,"Device ABI/build/clock/fault check failed\n");goto done;
    }
    ty_dma=mmap(NULL,TY_DMA_BYTES,PROT_READ|PROT_WRITE,MAP_SHARED,ty_fd,0);
    if(ty_dma==MAP_FAILED){perror("mmap");ty_dma=NULL;goto done;}
    g_params=ty_allocate(PARAM_BYTES);g_arena=ty_allocate(ARENA_BYTES);
    g_acc_buffer=ty_allocate(ACC_BYTES+2U*GUARD);g_pad_buffer=ty_allocate(PAD_BYTES+2U*GUARD);
    g_frame_input=ty_input_prequantized?NULL:ty_allocate(INPUT_VALUES*4U);g_head_tables=ty_allocate(2U*524352U);
    g_head_output=ty_allocate(2U*HEAD_LARGE_PIXELS*4U);
    if(shared)shared_output=ty_allocate(FINAL_VALUES*4U);
    if(ty_file_read(argv[2],g_params,PARAM_BYTES) ||
       (!streamed && !shared && ty_file_read(argv[3],g_frame_input,INPUT_VALUES*4U)) ||
       validate_schedule() || ty_prepare_cpu_cache(&info))goto done;
    if(ty_input_prequantized && (INPUT_SCALE!=0x1.010102p-8f || INPUT_ZERO_POINT!=-128 ||
       steps[0].kind!=1U || tensors[steps[0].out].dtype!=0U || tensors[steps[0].out].bytes!=INPUT_VALUES)) {
        fprintf(stderr,"Model input does not support the exact camera INT8 path\n");goto done;
    }
    ty_trace_prefix=getenv("TINYYOLO_TRACE_PREFIX");
    if(ty_trace_prefix && !*ty_trace_prefix)ty_trace_prefix=NULL;
    if(streamed || shared) {
        code=g230_prepare_heads();if(code)goto done;
        printf("READY_TINYYOLO_INPUT {\"mode\":\"%s\",\"input_offset\":%u,\"input_bytes\":%u,\"dma_bytes\":%u,\"input_dtype\":\"%s\",\"pixel_xor\":%u,\"input_size\":%u,\"positions\":%u,\"output_offset\":%u,\"output_bytes\":%u,\"build_id\":%u}\n",
               ty_input_prequantized?"dma-int8":(shared?"dma":"pipe"),
               ty_offset(ty_input_prequantized?tensor(steps[0].out):(void*)g_frame_input),
               INPUT_VALUES*(ty_input_prequantized?1U:4U),TY_DMA_BYTES,
               ty_input_prequantized?"int8":"float32",ty_input_prequantized?128U:0U,
               INPUT_WIDTH,DETECTION_POSITIONS,ty_offset(shared?shared_output:tensor(FINAL_TENSOR)),FINAL_VALUES*4U,TY_BUILD);
        fflush(stdout);
    }
    for(frame=0;frame<repeat;frame++) {
        char path[4096];uint32_t li;FILE *metrics;
        if(streamed && ty_stream_read(g_frame_input,INPUT_VALUES*4U)){code=1;goto done;}
        if(shared){int command=ty_shared_input_wait();if(command==2){code=0;goto done;}if(command){code=1;goto done;}}
        g_frame_id=frame+1U;code=g222_frame_begin();if(!code)code=run_frame();
        if(code){fprintf(stderr,"Linux inference failed frame=%u step=%u code=%d; no retry\n",frame+1U,g_step,code);goto done;}
        for(li=0;li<24U;li++)if(!g_g222_layer_valid[li]){code=1;goto done;}
        if(!no_frame_files) {
        if(snprintf(path,sizeof(path),"%s.%04u.final.bin",argv[4],frame+1U)>=(int)sizeof(path)){code=1;goto done;}
        if(ty_file_write(path,g_final,sizeof(g_final))){code=1;goto done;}
        if(snprintf(path,sizeof(path),"%s.%04u.metrics.json",argv[4],frame+1U)>=(int)sizeof(path)){code=1;goto done;}
        {int fd=open(path,O_WRONLY|O_CREAT|O_EXCL,0644);if(fd<0){perror(path);code=1;goto done;}metrics=fdopen(fd,"w");if(!metrics){close(fd);code=1;goto done;}}
        fprintf(metrics,"{\"status\":\"PASS_LINUX_PL_FRAME\",\"frame\":%u,\"clock_MHz\":240,\"elapsed_ms\":%u,\"pl_calls\":24,\"dma_bytes_used\":%u,\"layers\":[",frame+1U,g_elapsed_ms,ty_used);
        for(li=0;li<24U;li++)fprintf(metrics,"%s{\"layer\":%u,\"options\":%u,\"skipped\":%u,\"cycles\":%llu,\"hp_idle\":%u}",li?",":"",li,g_layer_options[li],g_zero_skipped[li],(unsigned long long)((uint64_t)g_pl_stats[li][2]|((uint64_t)g_pl_stats[li][3]<<32)),g_hp_stats[li][5]);
        fprintf(metrics,"],\"fclk_hz\":%u,\"pl_hz\":%u,\"trace_enabled\":%s,\"streamed_input\":%s,\"shared_dma_input\":%s,\"cpu_lookup_cache\":\"%s\",\"cpu_lookup_cache_bytes\":%u,\"prequantized_int8_input\":%s}\n",
                info.fclk_hz,info.pl_hz,ty_trace_prefix?"true":"false",streamed?"true":"false",
                shared?"true":"false",
                ty_ocm_mapped?"ocm_device":"cached_ram",ty_hot.used,
                ty_input_prequantized?"true":"false");if(fclose(metrics)){code=1;goto done;}
        }
        /* The graph arena can reuse the camera input address for its final
         * tensor. Publish a dedicated output allocation for the DMA producer. */
        if(shared)memcpy(shared_output,g_final,sizeof(g_final));
        /* Publish the completed DMA output before the pipe acknowledgement.
         * The producer may reuse input only after this acknowledgement. */
        __sync_synchronize();
        printf("PASS_LINUX_PL_FRAME frame=%u elapsed_ms=%u PL_convolutions=24 HP_idle=1\n",frame+1U,g_elapsed_ms);
        fflush(stdout);
    }
    code=0;
done:
    if(ty_hot.memory) {
        if(ty_ocm_mapped)munmap(ty_hot.memory,TY_OCM_BYTES);
        else free(ty_hot.memory);
    }
    if(ty_dma)munmap(ty_dma,TY_DMA_BYTES);
    close(ty_fd);return code?1:0;
}
