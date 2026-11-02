#ifndef TINYYOLO_UAPI_H
#define TINYYOLO_UAPI_H
#ifdef TINYYOLO_VALIDATOR_HOST
#include <stdint.h>
typedef uint32_t __u32;
typedef uint64_t __u64;
typedef int32_t __s32;
#else
#include <linux/types.h>
#include <linux/ioctl.h>
#endif
#define TY_ABI 2U
#define TY_BUILD 0x47325502U
#define TY_DMA_BYTES (32U * 1024U * 1024U)
#define TY_OCM_BYTES (32U * 1024U)
#define TY_OCM_MMAP_OFFSET TY_DMA_BYTES
#define TY_OCM_DEVICE_MAPPING 1U
/* Integer reference-clock rounding can report 99,999,999 Hz for 100 MHz.
 * Accept at most 100 ppm; return the measured clock unchanged through INFO. */
static inline int ty_clock_matches(__u64 hz, __u32 target)
{
    return hz >= target-target/10000U && hz <= target+target/10000U;
}
struct ty_info {
    __u32 abi, build_id, pl_hz, fclk_hz, dma_bytes, faulted, ocm_bytes, ocm_flags;
};
/* Address fields cfg[0..6] and lut_offset are offsets inside the DMA mmap.
 * Scalar fields cfg[7..14] match the hardware's 15-word configuration ABI.
 * A submit is synchronous. Do not touch the mmap until it returns.
 */
struct ty_submit {
    __u32 cfg[15], options, lut_offset, timeout_ms;
    __u32 status, error, skipped, elapsed_ns_lo, elapsed_ns_hi;
    __u32 pl[10], hp[6], phase[30];
};
#define TY_IOC_INFO _IOR('Y', 0x28, struct ty_info)
#define TY_IOC_SUBMIT _IOWR('Y', 0x29, struct ty_submit)
/* Producer release barrier for a shared-mmap input; no hardware is started. */
#define TY_IOC_INPUT_PUBLISH _IO('Y', 0x2a)
#endif
