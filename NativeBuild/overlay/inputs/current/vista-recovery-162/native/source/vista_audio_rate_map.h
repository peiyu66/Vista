#ifndef VISTA_AUDIO_RATE_MAP_H
#define VISTA_AUDIO_RATE_MAP_H
/* Output-position mapping. No wall clock, allocation, atomics or I/O.
 * Callers serialize with the existing stream timing lock. Media anchors retain
 * VLC's filtered-block PTS semantics, not a claim about scaletempo PCM content. */
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <limits.h>
#include <math.h>
#define VAM_CAPACITY 256
enum { VAM_OK=1,VAM_EMPTY=2,VAM_BEFORE=3,VAM_BACKWARD=4,VAM_SILENCE=5,
       VAM_OVERFLOW_GAP=6,VAM_INVALID=7 };
typedef struct {int64_t raw,media,scheduled,anchor_raw,command_boundary;double rate;uint64_t id,command,serial;bool silence;unsigned reason;} VAMSegment;
typedef struct {
 VAMSegment entries[VAM_CAPACITY],tail;
 size_t count;
 uint64_t frames,generation;
 unsigned frequency;
 int64_t origin,last_raw,last_media,overflow_from;
 bool initialized,poisoned,overflow,has_report;
} VAM;
static inline void vam_reset(VAM *m) {
 uint64_t generation=m->generation+1;memset(m,0,sizeof(*m));m->generation=generation;
}
static inline bool vam_position(const VAM *m,int64_t *out) {
 if(!m->frequency || m->frames>INT64_MAX/1000000)return false;
 int64_t delta=(int64_t)(m->frames*1000000/m->frequency);
 if(m->origin>INT64_MAX-delta)return false;
 *out=m->origin+delta;return true;
}
static inline bool vam_value(const VAMSegment *s,int64_t raw,int64_t *out) {
 if(raw<s->raw || s->silence || !(s->rate>0 && s->rate<=32))return false;
 long double v=(long double)s->media+((long double)raw-s->anchor_raw)*s->rate;
 if(!(v>=0 && v<9223372036854775808.0L))return false;
 *out=(int64_t)v;return true;
}
/* Must run once for every actual PCM enqueue, including silence and drain. */
static inline int vam_enqueue(VAM *m,int64_t pts,uint64_t frames,unsigned frequency,
 double rate,bool silence,int64_t scheduled,uint64_t serial,int64_t command_boundary,VAMSegment *created,int64_t *continuity) {
 if(created)memset(created,0,sizeof(*created));if(continuity)*continuity=0;
 if(m->poisoned)return VAM_INVALID;
 if(pts<0 || !frames || !frequency || !(rate>0 && rate<=32) || frames>INT64_MAX/1000000) {
  m->poisoned=true;return VAM_INVALID;
 }
 if(!m->initialized){m->origin=pts;m->frequency=frequency;m->initialized=true;}
 if(m->frequency!=frequency || UINT64_MAX-m->frames<frames){m->poisoned=true;return VAM_INVALID;}
 int64_t raw;if(!vam_position(m,&raw)){m->poisoned=true;return VAM_INVALID;}
 VAMSegment *last=m->overflow?&m->tail:(m->count?&m->entries[m->count-1]:NULL);
 int64_t predicted=0,error=0;
 bool has_prediction=last && vam_value(last,raw,&predicted);
 if(has_prediction)error=pts-predicted;
 /* A quantization tolerance, not a claim about filter-content accuracy. */
 int64_t quantum=(int64_t)ceil(rate*1000000/frequency)+1;
 bool reanchor=last && !silence && !last->silence && last->rate==rate &&
     has_prediction && (error>quantum || error < -quantum);
 bool math_boundary=!last || last->rate!=rate || last->silence!=silence || reanchor;
 bool new_segment=math_boundary || last->serial!=serial;
 if(new_segment) {
  /* An identity-only cut retains the exact previous affine anchor. It must
   * not turn a repeated same-rate command into a media-clock correction. */
  VAMSegment s={.raw=raw,.media=math_boundary?pts:last->media,.scheduled=math_boundary?scheduled:last->scheduled,
   .anchor_raw=math_boundary?raw:last->anchor_raw,
   .command_boundary=command_boundary!=INT64_MIN?command_boundary:
       (last && last->serial==serial?last->command_boundary:INT64_MIN),
   .rate=rate,.silence=silence,.serial=serial,.reason=!math_boundary?3:(reanchor?2:1)};
  if(continuity && has_prediction)*continuity=error;
  if(m->overflow || m->count==VAM_CAPACITY) {
   if(!m->overflow)m->overflow_from=raw;
   m->overflow=true;m->tail=s;
  } else m->entries[m->count++]=s;
  if(created)*created=s;
 }
 m->frames+=frames;
 return new_segment?VAM_OK:0;
}
static inline void vam_identify_last(VAM *m,uint64_t id,uint64_t command) {
 VAMSegment *s=m->overflow?&m->tail:(m->count?&m->entries[m->count-1]:NULL);
 if(s){s->id=id;s->command=command;}
}
static inline int vam_report(VAM *m,int64_t raw,VAMSegment *selected,int64_t *media) {
 if(m->poisoned)return VAM_INVALID;
 if(!m->count)return VAM_EMPTY;
 if(raw<0 || (m->has_report && raw<m->last_raw))return VAM_BACKWARD;
 int64_t end;if(!vam_position(m,&end) || raw>end)return VAM_INVALID;
 if(m->overflow && raw>=m->overflow_from) {
  if(raw<m->tail.raw)return VAM_OVERFLOW_GAP;
  m->entries[0]=m->tail;m->count=1;m->overflow=false;
 }
 size_t i=0;while(i+1<m->count && raw>=m->entries[i+1].raw)++i;
 VAMSegment s=m->entries[i];if(selected)*selected=s;
 if(raw<s.raw)return VAM_BEFORE;
 if(s.silence)return VAM_SILENCE;
 int64_t mapped;if(!vam_value(&s,raw,&mapped))return VAM_INVALID;
 if(m->has_report && mapped<m->last_media)return VAM_BACKWARD;
 m->last_raw=raw;m->last_media=mapped;m->has_report=true;*media=mapped;
 if(i){memmove(m->entries,m->entries+i,(m->count-i)*sizeof(s));m->count-=i;}
 return VAM_OK;
}
#endif
