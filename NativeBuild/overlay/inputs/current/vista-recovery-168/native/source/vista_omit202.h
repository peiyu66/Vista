#ifndef VISTA_OMIT202_H
#define VISTA_OMIT202_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
/* A complete, single layer-0 / temporal-0 TRAIL_N slice. This is only a
 * structural prerequisite: the real VLC parser and active SPS must agree.
 * Parameter sets, SEI, multiple slices, dependent slices and malformed lengths
 * keep the original decoding path. No compressed reference picture is omitted. */
static inline bool vo202_single_trail_n(const uint8_t *p,size_t n,unsigned length_size)
{
    if(length_size!=4 || n<7)return false;
    uint32_t size=((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3];
    return size==n-4 && p[4]==0 && p[5]==1 && (p[6]&0x80)!=0;
}
/* The first SPS RBSP byte immediately follows its two-byte NAL header;
 * emulation-prevention cannot occur before it. max_sub_layers_minus1=0. */
static inline bool vo202_single_temporal_sps(const uint8_t *p,size_t n)
{
    return n>=3 && p[0]==(33<<1) && p[1]==1 && ((p[2]>>1)&7)==0;
}
static inline bool vo202_single_layer_vps(const uint8_t *p,size_t n)
{
    return n>=4 && p[0]==(32<<1) && p[1]==1 && (p[2]&3)==0 && (p[3]&0xfe)==0;
}
#endif
