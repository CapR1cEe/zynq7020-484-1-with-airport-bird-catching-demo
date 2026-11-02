#ifndef TINYYOLO_VALIDATE_H
#define TINYYOLO_VALIDATE_H
#include "tinyyolo_uapi.h"
struct ty_span { __u64 off, bytes; };
static int ty_valid_span(__u64 off, __u64 bytes, __u64 size)
{
    return !(off & 7U) && bytes && bytes <= size && off <= size - bytes;
}
static int ty_overlap(struct ty_span a, struct ty_span b)
{
    return a.off < b.off + b.bytes && b.off < a.off + a.bytes;
}
/* Pure widened arithmetic; the kernel uses this before any MMIO write.
 * No userspace physical addresses are accepted, including in the LUT path.
 */
static int ty_validate_request(const struct ty_submit *s, __u64 dma, __u64 size)
{
    __u64 ci=s->cfg[7], co=s->cfg[8], h=s->cfg[9], w=s->cfg[10];
    __u64 k=s->cfg[11], pad=s->cfg[12], n, taps, plane;
    __u32 chunks;
    struct ty_span reads[6], writes[2];
    unsigned nr=0, nw=0, i, j;
    if (!size || dma < 0x00100000ULL || dma >= 0x1fff0000ULL ||
        size > 0x1fff0000ULL-dma || (dma&7U) || !s->timeout_ms || s->timeout_ms>600000U)
        return 0;
    if (s->options & ~127U) return 0;
    if (!ci || ci>1024U || !co || co>1024U || !h || h>416U || !w || w>845U)
        return 0;
    plane=h*w; n=plane*co;
    if (plane>173056U || n*4U>11075584U) return 0;
    if (s->options&4U) {
        if (s->options!=4U || ci!=256U || co!=1U || pad || k ||
            h!=w || h>26U) return 0;
        reads[nr++]=(struct ty_span){s->cfg[0],ci*plane};
        reads[nr++]=(struct ty_span){s->cfg[1],524352U};
        writes[nw++]=(struct ty_span){s->cfg[6],n*4U};
    } else {
        if (!((k==1U && pad==0U)||(k==3U && pad==1U)) ||
            (__s32)s->cfg[13]<-128 || (__s32)s->cfg[13]>127 ||
            (__s32)s->cfg[14]<-128 || (__s32)s->cfg[14]>127) return 0;
        taps=ci*k*k;
        if (taps>4608U) return 0;
        /* Bound taps before 32-bit division: avoid ARM kernel u64 helpers. */
        chunks=((__u32)taps+23U)/24U;
        if (n*chunks>0xffffffffULL) return 0;
        if ((s->options&64U) && (!(s->options&2U) || (h&1U) || (w&1U))) return 0;
        reads[nr++]=(struct ty_span){s->cfg[0],ci*plane};
        reads[nr++]=(struct ty_span){s->cfg[1],co*chunks*24U};
        reads[nr++]=(struct ty_span){s->cfg[2],co*4U};
        reads[nr++]=(struct ty_span){s->cfg[3],co*8U};
        reads[nr++]=(struct ty_span){s->cfg[4],co*4U};
        if (s->options&2U) reads[nr++]=(struct ty_span){s->lut_offset,256U};
        /* Even when stores are suppressed, validate the accumulator address. */
        if (!ty_valid_span(s->cfg[5],n*4U,size)) return 0;
        if (!(s->options&1U)) writes[nw++]=(struct ty_span){s->cfg[5],n*4U};
        writes[nw++]=(struct ty_span){s->cfg[6],(s->options&64U)?n/4U:n};
    }
    for (i=0;i<nr;i++) if (!ty_valid_span(reads[i].off,reads[i].bytes,size)) return 0;
    for (i=0;i<nw;i++) {
        if (!ty_valid_span(writes[i].off,writes[i].bytes,size)) return 0;
        for (j=0;j<nr;j++) if (ty_overlap(writes[i],reads[j])) return 0;
        for (j=0;j<i;j++) if (ty_overlap(writes[i],writes[j])) return 0;
    }
    return 1;
}
#endif
