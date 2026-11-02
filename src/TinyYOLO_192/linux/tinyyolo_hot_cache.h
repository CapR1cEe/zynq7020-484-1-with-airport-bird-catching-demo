#ifndef TINYYOLO_HOT_CACHE_H
#define TINYYOLO_HOT_CACHE_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#define TY_HOT_ENTRIES 64U
struct ty_hot_entry {uint32_t source,bytes,destination;};
struct ty_hot_cache {
    uint8_t *memory;
    uint32_t capacity,used,count;
    int device;
    struct ty_hot_entry entry[TY_HOT_ENTRIES];
};
/* Only immutable CPU lookup tables belong here. Model/feature tensors keep
 * their original coherent DMA offsets; this never creates a cacheable alias. */
static inline int ty_hot_add(struct ty_hot_cache *c,const uint8_t *parameters,
                            uint32_t parameter_bytes,uint32_t offset,uint32_t bytes)
{
    uint32_t i,destination;
    if(!bytes || bytes>parameter_bytes || offset>parameter_bytes-bytes)return -1;
    for(i=0;i<c->count;i++)
        if(c->entry[i].source==offset)return c->entry[i].bytes==bytes?0:-1;
    if(c->count==TY_HOT_ENTRIES || c->used>UINT32_MAX-63U)return -1;
    destination=(c->used+63U)&~63U;
    if(bytes>c->capacity || destination>c->capacity-bytes)return -1;
    if(c->device) {
        volatile uint8_t *target=c->memory+destination;
        for(i=0;i<bytes;i++)target[i]=parameters[offset+i];
        /* Device writes/reads are volatile. mmap attributes match the
         * kernel pool's shared Device mapping, with no cached alias. */
        for(i=0;i<bytes;i++)if(target[i]!=parameters[offset+i])return -1;
    } else memcpy(c->memory+destination,parameters+offset,bytes);
    c->entry[c->count].source=offset;
    c->entry[c->count].bytes=bytes;
    c->entry[c->count].destination=destination;
    c->count++;c->used=destination+bytes;
    return 0;
}
static inline const volatile void *ty_hot_find(const struct ty_hot_cache *c,
                                              uint32_t offset,uint32_t bytes)
{
    uint32_t i;
    for(i=0;i<c->count;i++)
        if(c->entry[i].source==offset && bytes<=c->entry[i].bytes)
            return c->memory+c->entry[i].destination;
    return NULL;
}
#endif
