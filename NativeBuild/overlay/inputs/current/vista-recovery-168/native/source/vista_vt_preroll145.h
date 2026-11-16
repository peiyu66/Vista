#ifndef VISTA_VT_PREROLL145_H
#define VISTA_VT_PREROLL145_H
#include <stdbool.h>
/* Zero means eligible. A nonzero bitmask records every exclusion, without
 * inferring preroll from elapsed time or a guessed seek target. */
static inline unsigned VistaVTPrerollReason(bool codec,bool preroll,bool pts,
 bool progressive,bool nonfield,bool noneos,bool format,bool unchanged) {
 return (!codec?1u:0u)|(!preroll?2u:0u)|(!pts?4u:0u)|
        (!progressive?8u:0u)|(!nonfield?16u:0u)|(!noneos?32u:0u)|
        (!format?64u:0u)|(!unchanged?128u:0u);
}
static inline bool VistaVP9PrerollSingle(bool shown,bool existing,bool pending,bool superframe) {
 return shown && !existing && !pending && !superframe;
}
enum {VVP_DECISION=250,VVP_SUBMIT=251,VVP_CALLBACK=252,VVP_DPB=253,VVP_FALLBACK=254};
#endif
