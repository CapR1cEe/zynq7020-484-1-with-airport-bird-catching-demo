#define TINYYOLO_VALIDATOR_HOST
#include "../linux/tinyyolo_validate.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(void)
{
    struct ty_submit s,t;
    unsigned i, rejected=0;
    memset(&s,0,sizeof(s));
    s.cfg[0]=0; s.cfg[1]=0x10000; s.cfg[2]=0x20000;
    s.cfg[3]=0x21000; s.cfg[4]=0x22000; s.cfg[5]=0x40000; s.cfg[6]=0x80000;
    s.cfg[7]=3; s.cfg[8]=16; s.cfg[9]=4; s.cfg[10]=6; s.cfg[11]=3; s.cfg[12]=1;
    s.cfg[13]=(unsigned)-128; s.cfg[14]=3; s.timeout_ms=1000;
    assert(ty_validate_request(&s,0x18000000U,TY_DMA_BYTES));
    for(i=0;i<7;i++) {
        t=s;t.cfg[i]++;assert(!ty_validate_request(&t,0x18000000U,TY_DMA_BYTES));rejected++;
        t=s;t.cfg[i]=TY_DMA_BYTES-8;assert(!ty_validate_request(&t,0x18000000U,TY_DMA_BYTES));rejected++;
    }
    t=s;t.cfg[6]=s.cfg[0];assert(!ty_validate_request(&t,0x18000000U,TY_DMA_BYTES));rejected++;
    t=s;t.cfg[6]=s.cfg[3];assert(!ty_validate_request(&t,0x18000000U,TY_DMA_BYTES));rejected++;
    t=s;t.cfg[7]=0xffffffffU;assert(!ty_validate_request(&t,0x18000000U,TY_DMA_BYTES));rejected++;
    t=s;t.options=64;assert(!ty_validate_request(&t,0x18000000U,TY_DMA_BYTES));rejected++;
    t=s;t.options=66;t.lut_offset=s.cfg[6];assert(!ty_validate_request(&t,0x18000000U,TY_DMA_BYTES));rejected++;
    t=s;t.options=66;t.lut_offset=0x30000;assert(ty_validate_request(&t,0x18000000U,TY_DMA_BYTES));
    t.cfg[9]=3;assert(!ty_validate_request(&t,0x18000000U,TY_DMA_BYTES));rejected++;
    assert(!ty_validate_request(&s,0xfffffff8U,TY_DMA_BYTES));rejected++;
    assert(!ty_validate_request(&s,0x1ffe0000U,TY_DMA_BYTES));rejected++;
    memset(&t,0,sizeof(t));t.options=4;t.timeout_ms=1000;t.cfg[0]=0;
    t.cfg[1]=0x40000;t.cfg[6]=0x100000;t.cfg[7]=256;t.cfg[8]=1;t.cfg[9]=13;t.cfg[10]=13;
    assert(ty_validate_request(&t,0x18000000U,TY_DMA_BYTES));
    t.cfg[6]=0x40000;assert(!ty_validate_request(&t,0x18000000U,TY_DMA_BYTES));rejected++;
    printf("PASS_LINUX_DMA_RANGE_VALIDATION rejected=%u hardware_access=0\n",rejected);
    return 0;
}
