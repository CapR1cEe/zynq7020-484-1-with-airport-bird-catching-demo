#ifndef TINYYOLO_INTEGER_OPS_H
#define TINYYOLO_INTEGER_OPS_H
#include <stddef.h>
#include <stdint.h>

/* Preconditions: 1 <= shift <= 62; multiplier > 0; product fits INT64 and is
 * not INT64_MIN. Those conditions are audited for every exported channel.
 * This shared routine is used by the native checker and ARM test application.
 */
static inline int8_t tinyyolo_requant_integer(int32_t accumulator,
                                             uint64_t multiplier,
                                             uint32_t shift,
                                             int32_t zero_point)
{
    int64_t product = (int64_t)accumulator * (int64_t)multiplier;
    uint64_t magnitude = product < 0 ? (uint64_t)(-product) : (uint64_t)product;
    uint64_t quotient = magnitude >> shift;
    uint64_t remainder = magnitude & ((UINT64_C(1) << shift) - UINT64_C(1));
    uint64_t half = UINT64_C(1) << (shift - 1U);
    if (remainder > half || (remainder == half && (quotient & UINT64_C(1)) != 0U))
        ++quotient;
    int64_t rounded = product < 0 ? -(int64_t)quotient : (int64_t)quotient;
    rounded += zero_point;
    if (rounded < -128) rounded = -128;
    if (rounded > 127) rounded = 127;
    return (int8_t)rounded;
}

/* Quantized SiLU is applied BEFORE the signed maximum, not after max(qx).
 * The 256 entries include the next input scale/zero point. No FLOAT operations
 * are needed. Input/output must not overlap; height and width must be even.
 */
static inline void tinyyolo_bridge_2x2(const int8_t *input, int8_t *output,
                                      const int8_t lut[256],
                                      uint32_t channels, uint32_t height,
                                      uint32_t width)
{
    uint32_t oc, y, x, ky, kx;
    uint32_t oh = height / 2U;
    uint32_t ow = width / 2U;
    for (oc = 0U; oc < channels; ++oc)
        for (y = 0U; y < oh; ++y)
            for (x = 0U; x < ow; ++x) {
                int8_t maximum = INT8_MIN;
                for (ky = 0U; ky < 2U; ++ky)
                    for (kx = 0U; kx < 2U; ++kx) {
                        size_t index = (size_t)oc * height * width
                                     + (size_t)(2U * y + ky) * width + 2U * x + kx;
                        int8_t activated = lut[(int32_t)input[index] + 128];
                        if (activated > maximum) maximum = activated;
                    }
                output[(size_t)oc * oh * ow + (size_t)y * ow + x] = maximum;
            }
}
#endif
