/* G228 pipeline driver; legacy g222 helper/safety ABI is retained.
 * No CPU INT8 convolution/gather fallback. A fault is sticky until PS+PL reset.
 * The caller owns the device exclusively; IRQs/other cores must not start it.
 * g_pl_stats keeps the G221 10-word ABI. g_hp_stats is AR, R, input hits,
 * weight hits, misses, HP idle. layer_valid is set only for a successful layer.
 * Host tests replace MMIO/cache/timer/DSB, not this control flow. */
#define G222_BASE 0x40000000U
#define G222_BUILD 0x47325502U
#define G222_IDLE_TICKS ((uint64_t)COUNTS_PER_SECOND)
#define G222_RUN_TICKS ((uint64_t)COUNTS_PER_SECOND*600U)
volatile uint32_t g_pl_stats[24][10];
volatile uint32_t g_hp_stats[24][6];
/* 15 frozen uint64 counters/layer, represented as low/high uint32 pairs.
 * 0..7 exclusive phases; 8..14 overlapping bus events. Read after HP drain. */
volatile uint32_t g_phase_stats[24][30];
volatile uint32_t g_g222_layer_valid[24];
volatile uint32_t g_pl_calls;
volatile uint32_t g_zero_skipped[24],g_layer_options[24];
volatile uint32_t g_g222_lock,g_g222_unsafe,g_g222_last_code;
volatile uint32_t g_g222_last_layer=UINT32_MAX,g_g222_frame_sequence;
/* Latest observed ID, status, error, controller state, group, pixel, HP idle,
 * driver phase (1 preflight, 2 clear/config, 3 running, 4 drain, 5 validate). */
volatile uint32_t g_g222_diag[8];

static void g222_dsb(void) {
#ifdef TINYYOLO_DRIVER_TEST
    g222_test_barrier();
#else
    __asm__ volatile("dsb sy" ::: "memory");
#endif
}
static uint32_t g222_read(uint32_t off) {return Xil_In32(G222_BASE+off);}
static void g222_diag(void) {
    g_g222_diag[0]=g222_read(0x4cU);
    g_g222_diag[1]=g222_read(0x04U);
    g_g222_diag[2]=g222_read(0x44U);
    g_g222_diag[3]=g222_read(0x64U);
    g_g222_diag[4]=g222_read(0x68U);
    g_g222_diag[5]=g222_read(0x6cU);
    g_g222_diag[6]=g222_read(0x84U);
}
static int g222_fail(uint32_t code,uint32_t unsafe) {
    g_g222_last_code=code;g_g222_lock=code;
    if(unsafe)g_g222_unsafe=1U;
    return (int)code;
}
/* Returns no MMIO writes on ID mismatch, controller busy, or stalled sweep.
 * HP idle includes the initial tag sweep and any accepted transaction drain. */
static int g222_ready(void) {
    uint64_t begin;uint32_t st;
    if(g_g222_lock)return 107;
    g_g222_diag[7]=1U;g_g222_diag[0]=g222_read(0x4cU);
    if(g_g222_diag[0]!=G222_BUILD)return g222_fail(101U,1U);
    begin=ticks();
    for(;;) {
        st=g222_read(0x04U);g_g222_diag[1]=st;
        if(st!=0U && st!=2U && st!=4U){g222_diag();return g222_fail(108U,1U);}
        if(g222_read(0x84U)==1U)break;
        if(ticks()-begin>G222_IDLE_TICKS){g222_diag();return g222_fail(109U,1U);}
    }
    if(st==4U){g222_diag();return g222_fail(104U,0U);}
    return 0;
}
/* Called with D-cache disabled, before run_frame touches shared DDR buffers.
 * In particular, a build mismatch never initializes/overwrites the frame. */
static int g222_frame_begin(void) {
    uint32_t i,j;int code=g222_ready();if(code)return code;
    g_g222_frame_sequence++;g_g222_last_layer=UINT32_MAX;g_g222_last_code=0U;
    for(i=0;i<24U;i++) {
        g_g222_layer_valid[i]=0U;
        for(j=0;j<10U;j++)g_pl_stats[i][j]=0U;
        for(j=0;j<6U;j++)g_hp_stats[i][j]=0U;
        for(j=0;j<30U;j++)g_phase_stats[i][j]=0U;
    }
    return 0;
}
static int g222_region(uintptr_t p,uint64_t bytes,uintptr_t low,uint64_t size) {
    return !(p&7U) && bytes && p>=low && bytes<=size && (uint64_t)(p-low)<=size-bytes;
}
static void g222_snapshot(uint32_t li,uint64_t elapsed) {
    uint32_t i;
    g_pl_stats[li][0]=g222_read(0x04U);g_pl_stats[li][1]=g222_read(0x44U);
    g_pl_stats[li][2]=g222_read(0x48U);g_pl_stats[li][3]=g222_read(0x50U);
    for(i=0;i<4U;i++)g_pl_stats[li][4U+i]=g222_read(0x54U+4U*i);
    g_pl_stats[li][8]=(uint32_t)elapsed;g_pl_stats[li][9]=(uint32_t)(elapsed>>32);
    for(i=0;i<6U;i++)g_hp_stats[li][i]=g222_read(0x70U+4U*i);
    for(i=0;i<30U;i++)g_phase_stats[li][i]=g222_read(0x88U+4U*i);
    g222_diag();
}
static uint64_t g223_counter(uint32_t li,uint32_t index) {
    return (uint64_t)g_phase_stats[li][2U*index] |
           ((uint64_t)g_phase_stats[li][2U*index+1U]<<32);
}
static uint32_t g223_profile_validate(uint32_t li) {
    uint32_t j;uint64_t sum=0U;
    uint64_t total=(uint64_t)g_pl_stats[li][2]|((uint64_t)g_pl_stats[li][3]<<32);
    for(j=0;j<8U;j++) {
        uint64_t value=g223_counter(li,j);
        if(value>total || sum>total-value)return 113U;
        sum+=value;
    }
    if(sum!=total || !total)return 113U;
    if(g223_counter(li,11U)!=g_hp_stats[li][1] ||
       g223_counter(li,14U)!=g_pl_stats[li][5])return 114U;
    for(j=8U;j<15U;j++)if(g223_counter(li,j)>total)return 115U;
    return 0U;
}
/* Cache-enabled entry is guaranteed by ARM main. Only re-enable after a
 * terminal controller state AND HP idle. Never read/copy output on failure. */
static void g222_restore_cache(void) {
    g222_dsb();Xil_DCacheInvalidate();Xil_DCacheEnable();g222_dsb();
}
static int conv_int(uint32_t li,const int8_t *input,int8_t *out) {
    const Conv *l;uint64_t plane,n,src,taps,weights,macs,begin,elapsed,drain_begin;
    uint32_t config[15],i,st,code,options,expected_writes,qp,oc;
    uint32_t *acc=(uint32_t*)(g_acc_buffer+GUARD);
    if(g_g222_lock)return 107;
    g_g222_last_layer=li;
    /* Bounds must precede convs[li], and all arithmetic is widened first. */
    if(li>=24U)return g222_fail(100U,0U);
    l=&convs[li];plane=(uint64_t)l->h*l->w;n=plane*l->co;
    src=plane*l->ci;taps=(uint64_t)l->ci*l->k*l->k;
    weights=(uint64_t)l->co*l->chunks*MAC_LANES;macs=n*l->chunks;
    if(!l->chunks || !l->ci || l->ci>1024U || !l->co || l->co>1024U ||
       !l->h || l->h>416U || !l->w || l->w>845U || plane>173056U ||
       !((l->k==1U && l->pad==0U)||(l->k==3U && l->pad==1U)) ||
       taps>4608U || l->chunks!=(taps+MAC_LANES-1U)/MAC_LANES || n*4U>ACC_BYTES || macs>UINT32_MAX ||
       l->zx< -128 || l->zx>127 || l->zy< -128 || l->zy>127 ||
       !g222_region((uintptr_t)input,src,(uintptr_t)g_arena,ARENA_BYTES) ||
       !g222_region((uintptr_t)out,n,(uintptr_t)g_arena,ARENA_BYTES) ||
       !((uintptr_t)input+src<=(uintptr_t)out || (uintptr_t)out+n<=(uintptr_t)input) ||
       !g222_region((uintptr_t)g_params+l->weights,weights,(uintptr_t)g_params,PARAM_BYTES) ||
       !g222_region((uintptr_t)g_params+l->bias,(uint64_t)l->co*4U,(uintptr_t)g_params,PARAM_BYTES) ||
       !g222_region((uintptr_t)g_params+l->mul,(uint64_t)l->co*8U,(uintptr_t)g_params,PARAM_BYTES) ||
       !g222_region((uintptr_t)g_params+l->shift,(uint64_t)l->co*4U,(uintptr_t)g_params,PARAM_BYTES) ||
       l->acc_trace>TRACE_BYTES || n*4U>TRACE_BYTES-l->acc_trace)return g222_fail(100U,0U);
    options=g_pl_feature_mask&56U;g230_fused_step=UINT32_MAX;
    if(!g_trace_enabled) {
        const Step *current=&steps[g_step];
        options|=1U;
        if(g_step+1U<STEP_COUNT) {
            const Step *next=&steps[g_step+1U];
            if(next->kind==2U && next->a==current->out && next->mode<=2U &&
               tensors[current->out].last==g_step+1U) {
                options|=2U;g230_fused_step=g_step+1U;g230_fused_mode=next->mode;
                if(next->mode==2U)options|=64U;
            }
        }
    }
    qp=(options&64U)?(uint32_t)(plane/4U):(uint32_t)plane;
    expected_writes=(options&1U)?0U:(uint32_t)n;
    if(options&32U)for(oc=0;oc<l->co;oc++)expected_writes+=((oc+1U)*qp-1U)/8U-(oc*qp)/8U+1U;
    else expected_writes+=qp*l->co;
    code=(uint32_t)g222_ready();if(code)return (int)code;
    config[0]=(uint32_t)(uintptr_t)input;
    config[1]=(uint32_t)(uintptr_t)(g_params+l->weights);
    config[2]=(uint32_t)(uintptr_t)(g_params+l->bias);
    config[3]=(uint32_t)(uintptr_t)(g_params+l->mul);
    config[4]=(uint32_t)(uintptr_t)(g_params+l->shift);
    config[5]=(uint32_t)(uintptr_t)acc;config[6]=(uint32_t)(uintptr_t)out;
    config[7]=l->ci;config[8]=l->co;config[9]=l->h;config[10]=l->w;
    config[11]=l->k;config[12]=l->pad;config[13]=(uint32_t)l->zx;config[14]=(uint32_t)l->zy;
    Xil_DCacheFlush();Xil_DCacheDisable();g222_dsb();g_g222_diag[7]=2U;
    Xil_Out32(G222_BASE,2U);g222_dsb();
    if(g222_read(4U)!=0U || g222_read(0x84U)!=1U) {
        g222_diag();return g222_fail(102U,1U);
    }
    Xil_Out32(G222_BASE+0x44U,options);
    Xil_Out32(G222_BASE+0x4cU,(options&2U)?(uint32_t)(uintptr_t)(g_params+steps[g_step+1U].p0):0U);
    g_layer_options[li]=options;
    for(i=0;i<15U;i++)Xil_Out32(G222_BASE+8U+4U*i,config[i]);
    g222_dsb();begin=ticks();Xil_Out32(G222_BASE,1U);g222_dsb();g_g222_diag[7]=3U;
    for(;;) {
        st=g222_read(4U);elapsed=ticks()-begin;
        if(st==2U || st==4U)break;
        if(st&~1U){g222_snapshot(li,elapsed);return g222_fail(110U,1U);}
        if(elapsed>G222_RUN_TICKS){g222_snapshot(li,elapsed);return g222_fail(103U,1U);}
    }
    g_g222_diag[7]=4U;drain_begin=ticks();
    while(g222_read(0x84U)!=1U) {
        if(ticks()-drain_begin>G222_IDLE_TICKS) {
            g222_snapshot(li,ticks()-begin);return g222_fail(111U,1U);
        }
    }
    g222_dsb();g222_snapshot(li,ticks()-begin);g_g222_diag[7]=5U;
    code=0U;
    if(g_pl_stats[li][0]!=2U || g_pl_stats[li][1])code=104U;
    else if(g_pl_stats[li][5]!=expected_writes || g_pl_stats[li][6]!=macs || g_pl_stats[li][7]!=n)code=105U;
    else if(g_hp_stats[li][5]!=1U || !g_hp_stats[li][0] ||
            (uint64_t)g_pl_stats[li][4]!=(uint64_t)g_hp_stats[li][2]+g_hp_stats[li][3]+g_hp_stats[li][4] ||
            g_hp_stats[li][4]!=g_hp_stats[li][0] || g_hp_stats[li][1]<g_hp_stats[li][0] ||
            (uint64_t)g_hp_stats[li][1]>(uint64_t)g_hp_stats[li][0]*8U)code=112U;
    g_zero_skipped[li]=g222_read(0U);
    if(!code)code=g223_profile_validate(li);
    if(code){g222_restore_cache();return g222_fail(code,0U);}
    /* Snapshots precede clear. HP counters are not reset by controller clear. */
    Xil_Out32(G222_BASE,2U);g222_dsb();
    if(g222_read(4U)!=0U || g222_read(0x84U)!=1U) {
        g222_diag();return g222_fail(106U,1U);
    }
    g222_restore_cache();g_mac_chunks+=(uint32_t)macs;g_pl_calls++;
    g_g222_layer_valid[li]=1U;g_g222_last_code=0U;
    if(g_trace_enabled)memcpy(g_trace+l->acc_trace,acc,(size_t)n*4U);
    return 0;
}
