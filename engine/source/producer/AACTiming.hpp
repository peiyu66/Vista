#pragma once
#include <stdint.h>

// Integer-only AAC timeline arithmetic. Callers enforce admitted input bounds:
// timestamps 0..24h, rate 8..96kHz, and nonnegative CodecDelay <=1s.
namespace vista_aac {
constexpr int64_t NS=1000000000;
struct Origin { int64_t deltaNS,cutSample,residual; bool exact; };
inline Origin OriginCut(int64_t originNS,int64_t anchorNS,unsigned rate,int64_t delaySamples) {
 const int64_t delta=originNS-anchorNS;
 const __int128 numerator=__int128(delta)*rate;
 const int64_t remainder=int64_t(numerator%NS);
 return {delta,int64_t(numerator/NS)+delaySamples,remainder,remainder==0};
}
struct Packet { int64_t index,residual; };
inline Packet PacketClock(int64_t ptsNS,int64_t anchorNS,unsigned rate) {
 const __int128 numerator=__int128(ptsNS-anchorNS)*rate;
 constexpr int64_t frame=1024*NS;
 const int64_t index=int64_t(numerator>=0?(numerator+frame/2)/frame:-((-numerator+frame/2)/frame));
 return {index,int64_t(numerator-__int128(index)*frame)};
}
inline bool WithinTick(int64_t residual,int64_t tickNS,unsigned rate) {
 return residual<=__int128(tickNS)*rate&&residual>=-__int128(tickNS)*rate;
}
// Approved v8 policy: bounded retiming of source markers to the existing
// fixed source-first clock. Quantization is included, never added per packet,
// GOP or seek. Strictly under half a frame keeps nearest time slots unambiguous.
inline bool WithinBoundedRetiming(int64_t residual,unsigned rate) {
 const __int128 timeCap=__int128(10000000)*rate;
 const __int128 frameCap=__int128(511)*NS;
 const __int128 cap=timeCap<frameCap?timeCap:frameCap;
 return residual<=cap&&residual>=-cap;
}
inline int64_t RoundedNS(int64_t samples,unsigned rate) {
 const __int128 numerator=__int128(samples)*NS;
 return int64_t(numerator>=0?(numerator+rate/2)/rate:-((-numerator+rate/2)/rate));
}
}
