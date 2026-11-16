#pragma once
#include <cstdint>

// Pure, allocation-free admission/mapping used by the producer and scoped tests.
// Values are H.273 CICP, except VP9 colour_space and Matroska range/siting.
// See engine/COLOUR-MAPPING.md for the deliberately restricted SDR subset.
namespace vista_colour {
constexpr int64_t Absent = -1;
constexpr uint64_t MaxDimension = 8192, MaxPixels = uint64_t(4096) * 4096;
constexpr bool GeometrySupported(uint64_t width, uint64_t height) {
 return width > 0 && height > 0 && width <= MaxDimension && height <= MaxDimension &&
        width * height <= MaxPixels; // multiplication only after per-axis bound
}
struct Container {
 int64_t matrix=Absent,transfer=Absent,primaries=Absent,range=Absent,bits=Absent;
 int64_t subH=Absent,subV=Absent,cbH=Absent,cbV=Absent,sitingH=Absent,sitingV=Absent;
 uint32_t hdrMask=0;
};
struct Resolved {
 uint8_t matrix=2,transfer=2,primaries=2,chroma=1;
 bool operator==(const Resolved& other)const {
  return matrix==other.matrix&&transfer==other.transfer&&primaries==other.primaries&&chroma==other.chroma;
 }
};
constexpr bool Unspecified(int64_t value) { return value==Absent||value==2; }
constexpr bool MatrixSupported(int64_t v) { return Unspecified(v)||v==1||v==5||v==6||v==7||v==9||v==10; }
constexpr bool PrimariesSupported(int64_t v) { return Unspecified(v)||v==1||v==5||v==6||v==7||v==9; }
constexpr bool TransferSupported(int64_t v) { return Unspecified(v)||v==1||v==4||v==5||v==6||v==7||v==13||v==14||v==15; }
inline uint32_t ValidateContainer(const Container& c) {
 if(c.hdrMask||c.transfer==16||c.transfer==18)return 216;
 if(!MatrixSupported(c.matrix)||!PrimariesSupported(c.primaries)||!TransferSupported(c.transfer))return 284;
 if(c.bits!=Absent&&c.bits!=0&&c.bits!=8)return 218;
 // Profile 0 is 4:2:0, with no extra decimation of Cb relative to Cr.
 if((c.subH!=Absent&&c.subH!=1)||(c.subV!=Absent&&c.subV!=1)||
    (c.cbH!=Absent&&c.cbH!=0)||(c.cbV!=Absent&&c.cbV!=0))return 219;
 // vpcC has no centre-horizontal 4:2:0 representation. Reject, never relabel.
 if((c.sitingH!=Absent&&c.sitingH!=0&&c.sitingH!=1)||
    (c.sitingV!=Absent&&c.sitingV!=0&&c.sitingV!=1&&c.sitingV!=2))return 219;
 if(c.range!=Absent&&c.range!=0&&c.range!=1&&c.range!=2)return 220;
 return 0;
}
inline uint32_t Resolve(const Container& c,unsigned colourSpace,bool full,Resolved& result) {
 if(auto error=ValidateContainer(c))return error;
 if(colourSpace>5)return 285; // 6 reserved; RGB 7 cannot occur in profile 0.
 if((c.range==1&&full)||(c.range==2&&!full))return 243;
 Resolved r;
 r.matrix=Unspecified(c.matrix)?2:uint8_t(c.matrix);
 r.transfer=Unspecified(c.transfer)?2:uint8_t(c.transfer);
 r.primaries=Unspecified(c.primaries)?2:uint8_t(c.primaries);
 // VP9 defaults to chroma colocated with luma. Container may explicitly override.
 r.chroma=c.sitingV==2?0:1;
 if(colourSpace==1) {
  // BT.601 covers both 525- and 625-line primaries. Do not invent which one.
  if(r.matrix!=2&&r.matrix!=5&&r.matrix!=6)return 286;
  if(r.primaries!=2&&r.primaries!=5&&r.primaries!=6)return 287;
  if(r.transfer!=2&&r.transfer!=1&&r.transfer!=6)return 288;
  if(r.matrix==2)r.matrix=6; // 5 and 6 have the same YCbCr coefficients.
  if(r.transfer==2)r.transfer=6;
 } else if(colourSpace>=2) {
  // Explicit SDR standards. BT.2020 permits CL or NCL signaled by the container.
  const uint8_t matrices[]={2,2,1,6,7,9};
  const uint8_t primaries[]={2,2,1,6,7,9};
  const uint8_t transfers[]={2,2,1,6,7,14};
  const auto m=matrices[colourSpace],p=primaries[colourSpace],t=transfers[colourSpace];
  if(r.matrix!=2&&r.matrix!=m&&!(colourSpace==5&&r.matrix==10))return 286;
  if(r.primaries!=2&&r.primaries!=p)return 287;
  if(r.transfer!=2&&r.transfer!=t&&!(colourSpace==5&&r.transfer==15))return 288;
  if(r.matrix==2)r.matrix=m;
  if(r.primaries==2)r.primaries=p;
  if(r.transfer==2)r.transfer=t;
 }
 result=r;return 0;
}
} // namespace vista_colour
