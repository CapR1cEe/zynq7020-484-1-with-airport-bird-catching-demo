/* Fused exact head engine. The resident ARM creates immutable product tables
 * once per model; every per-frame convolution multiply/add executes in PL.
 * The output staging buffer avoids the graph arena's head/input aliasing. */
static int g230_prepare_heads(void) {
    uint32_t hi,c,i;
    if(g_head_tables_ready)return 0;
    for(hi=0;hi<2U;hi++) {
        const uint32_t li=hi?21U:17U;
        const Step *dequant=&steps[hi?42U:34U],*conv=&steps[hi?43U:35U];
        const Conv *head=&convs[li];
        const float *w,*lut,*bias;
        double *table=(double*)(g_head_tables[hi]+64U),b;
        /* Repacking weights changes all subsequent parameter offsets. Read
         * the dequantization LUT from this model's graph, never an old image. */
        if(dequant->kind!=2U || dequant->mode!=4U || conv->kind!=5U ||
           conv->layer!=li || conv->a!=dequant->out || dequant->channels!=256U ||
           head->ci!=256U || head->co!=1U || head->k!=1U ||
           dequant->h!=head->h || dequant->w!=head->w ||
           (dequant->p0&3U) || (head->weights&3U) || (head->bias&3U) ||
           dequant->p0>PARAM_BYTES || 1024U>PARAM_BYTES-dequant->p0 ||
           head->weights>PARAM_BYTES || 1024U>PARAM_BYTES-head->weights ||
           head->bias>PARAM_BYTES || 4U>PARAM_BYTES-head->bias)return 117;
        w=(const float*)(g_params+head->weights);
        lut=(const float*)(g_params+dequant->p0);
        bias=(const float*)(g_params+head->bias);b=(double)bias[0];
        if(!isfinite(b))return 117;
        memset(g_head_tables[hi],0,64U);memcpy(g_head_tables[hi],&b,8U);
        for(i=0;i<256U;i++) {
            if(!isfinite(lut[i]))return 117;
            if(lut[i]==0.0f)g_head_tables[hi][8U+i/8U]|=(uint8_t)(1U<<(i%8U));
        }
        for(c=0;c<256U;c++) {
            if(!isfinite(w[c]))return 117;
            for(i=0;i<256U;i++) {
                double p=(double)lut[i]*(double)w[c];uint64_t raw;
                memcpy(&raw,&p,8U);
                /* Binary32 x binary32 is exact in binary64. A nonzero result
                 * is far above binary64 gradual-underflow territory. */
                if((raw&UINT64_C(0x7ff0000000000000))==UINT64_C(0x7ff0000000000000) ||
                   ((raw&UINT64_C(0x7fffffffffffffff)) &&
                    (raw&UINT64_C(0x7ff0000000000000))<UINT64_C(0x0800000000000000)))return 117;
                table[c*256U+i]=p;
            }
        }
    }
    g_head_tables_ready=1U;return 0;
}
#ifndef TINYYOLO_LINUX
static int g230_head(const Step *s) {
    const uint32_t li=s==&steps[34]?17U:21U,hi=li==17U?0U:1U;
    const Conv *l=&convs[li];
    const uint32_t n=l->h*l->w;
    const int8_t *input=(const int8_t*)tensor(s->a);
    uint32_t config[15]={0},i,st,code;
    uint64_t begin,elapsed,drain_begin;
    int prep=g230_prepare_heads();if(prep)return g222_fail((uint32_t)prep,0U);
    if(s!=&steps[34] && s!=&steps[42])return g222_fail(116U,0U);
    if(s->mode!=4U || l->ci!=256U || l->co!=1U || s->channels!=256U ||
       s->h!=l->h || s->w!=l->w ||
       !g222_region((uintptr_t)input,(uint64_t)n*256U,(uintptr_t)g_arena,ARENA_BYTES) ||
       !g222_region((uintptr_t)g_head_tables[hi],524352U,(uintptr_t)g_head_tables,sizeof(g_head_tables)) ||
       !g222_region((uintptr_t)g_head_output[hi],(uint64_t)n*4U,(uintptr_t)g_head_output,sizeof(g_head_output)))
        return g222_fail(100U,0U);
    code=(uint32_t)g222_ready();if(code)return (int)code;
    g_g222_last_layer=li;
    config[0]=(uint32_t)(uintptr_t)input;
    config[1]=(uint32_t)(uintptr_t)g_head_tables[hi];
    config[6]=(uint32_t)(uintptr_t)g_head_output[hi];
    config[7]=256U;config[8]=1U;config[9]=l->h;config[10]=l->w;
    Xil_DCacheFlush();Xil_DCacheDisable();g222_dsb();g_g222_diag[7]=2U;
    Xil_Out32(G222_BASE,2U);g222_dsb();
    if(g222_read(4U)!=0U || g222_read(0x84U)!=1U){g222_diag();return g222_fail(102U,1U);}
    Xil_Out32(G222_BASE+0x44U,4U);g_layer_options[li]=4U;
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
    g_zero_skipped[li]=g222_read(0U);code=0U;
    if(g_pl_stats[li][0]!=2U || g_pl_stats[li][1])code=104U;
    else if(g_pl_stats[li][5]!=n || g_pl_stats[li][6]!=n*256U || g_pl_stats[li][7]!=n)code=105U;
    else if(g_hp_stats[li][5]!=1U || !g_hp_stats[li][0] ||
            (uint64_t)g_pl_stats[li][4]!=(uint64_t)g_hp_stats[li][2]+g_hp_stats[li][3]+g_hp_stats[li][4] ||
            g_hp_stats[li][4]!=g_hp_stats[li][0])code=112U;
    if(!code)code=g223_profile_validate(li);
    if(code){g222_restore_cache();return g222_fail(code,0U);}
    Xil_Out32(G222_BASE,2U);g222_dsb();
    if(g222_read(4U)!=0U || g222_read(0x84U)!=1U){g222_diag();return g222_fail(106U,1U);}
    g222_restore_cache();g_pl_calls++;g_g222_layer_valid[li]=1U;g_g222_last_code=0U;
    return 0;
}
#endif
