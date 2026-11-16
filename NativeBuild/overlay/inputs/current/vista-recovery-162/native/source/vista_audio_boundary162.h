#ifndef VISTA_AUDIO_BOUNDARY162_H
#define VISTA_AUDIO_BOUNDARY162_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <limits.h>
/* Only the existing CoreAudio output lock serializes this fixed metadata ring.
 * Bytes are actual output bytes, never media timestamps or predicted dates. */
#define VAQ_CAPACITY 64
struct vaq_marker { uint64_t boundary,serial,command; bool silence; };
struct vaq_state {
 struct vaq_marker entries[VAQ_CAPACITY],pending;
 size_t head,count;
 uint64_t generation,last_serial,last_command,last_boundary,reported_serial;
 bool initialized,last_silence,disabled,has_pending,pending_noted;
};
static inline void vaq_reset(struct vaq_state *q) {
 uint64_t generation=q->generation+1;memset(q,0,sizeof(*q));q->generation=generation;
}
static inline void vaq_disable(struct vaq_state *q) {
 q->disabled=true;q->count=0;q->has_pending=false;q->pending_noted=false;
}
/* 1 marker, 0 unchanged, -1 fail closed. No allocation, locks, clocks or IO. */
static inline int vaq_enqueue(struct vaq_state *q,uint64_t consumed,uint64_t queued,
 uint64_t serial,uint64_t command,bool silence,unsigned frame_bytes,bool valid) {
 if(q->disabled)return 0;
 if(!valid || !frame_bytes || queued>UINT64_MAX-consumed) {vaq_disable(q);return -1;}
 uint64_t boundary=consumed+queued;
 if(boundary>UINT64_MAX-frame_bytes) {vaq_disable(q);return -1;}
 if(q->initialized && q->last_serial==serial && q->last_command==command && q->last_silence==silence)return 0;
 if(q->count==VAQ_CAPACITY) {vaq_disable(q);return -1;}
 struct vaq_marker m={boundary,serial,command,silence};
 q->entries[(q->head+q->count)%VAQ_CAPACITY]=m;q->count++;
 q->last_serial=serial;q->last_command=command;q->last_silence=silence;q->last_boundary=boundary;q->initialized=true;
 return 1;
}
/* Require one whole PCM frame past a boundary. At most CAPACITY work per
 * callback, coalesce to the actual latest consumed segment. Silence cannot
 * manufacture confirmation. A partial callback keeps pending until valid. */
static inline unsigned vaq_consume(struct vaq_state *q,uint64_t consumed,unsigned frame_bytes) {
 unsigned crossed=0;if(q->disabled || !frame_bytes)return 0;
 while(q->count) {
  struct vaq_marker m=q->entries[q->head];
  if(consumed<m.boundary || consumed-m.boundary<frame_bytes)break;
  q->head=(q->head+1)%VAQ_CAPACITY;q->count--;q->pending=m;
  q->has_pending=m.serial>q->reported_serial && !m.silence;q->pending_noted=false;crossed++;
 }
 return crossed;
}
/* At an unconsumed next boundary the existing map selects that next segment
 * at equality. Do not use a prior pending marker to force that new report. */
static inline bool vaq_reportable(const struct vaq_state *q,uint64_t consumed) {
 return q->has_pending && !q->disabled &&
   (!q->count || q->entries[q->head].boundary>consumed);
}
/* This TLS context is producer-only and defined once in coreaudio_common.c.
 * Render never touches TLS. Non-CoreAudio outputs take the unchanged call. */
struct vaq_context {const void *aout;uint64_t serial,command;bool silence,valid;};
void vista_audio_play162(audio_output_t *,block_t *,vlc_tick_t,uint64_t,uint64_t,bool,bool);
void vista_audio_command162(audio_output_t *,uint64_t,uint64_t);
enum { VAF_COMMAND_QUEUE=435,VAF_QUEUE_BOUNDS=436,VAF_RATE_MARKER=437,
 VAF_RATE_RENDER=438,VAF_BOUNDARY_REPORT=439,VAF_BOUNDARY_STATE=440,
 VAF_LATENCY=441,VAF_BOUNDARY_SCOPE=442 };
#endif
