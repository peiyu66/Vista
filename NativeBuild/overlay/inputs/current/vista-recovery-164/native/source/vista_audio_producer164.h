#ifndef VISTA_AUDIO_PRODUCER164_H
#define VISTA_AUDIO_PRODUCER164_H
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
/* Passive, under the existing CoreAudio lock. No scheduling or time mapping. */
enum { VAP_QUEUE=443,VAP_LOW=444,VAP_FORMAT=445,VAP_POSITION=446,VAP_WINDOW=447 };
struct vap_state { int64_t start; uint64_t low,high,underrun,blocks,max_block; bool active; };
static inline uint64_t vap_add(uint64_t a,uint64_t b) { return UINT64_MAX-a<b?UINT64_MAX:a+b; }
static inline void vap_reset(struct vap_state *p) { memset(p,0,sizeof(*p)); }
static inline void vap_begin(struct vap_state *p,int64_t now,uint64_t queue) {
    vap_reset(p);p->active=true;p->start=now;p->low=p->high=queue;
}
static inline void vap_render(struct vap_state *p,uint64_t remaining,uint64_t missing) {
    if(!p->active)return;
    if(remaining<p->low)p->low=remaining;
    p->underrun=vap_add(p->underrun,missing);
}
static inline bool vap_enqueue(struct vap_state *p,int64_t now,uint64_t before,uint64_t after,uint64_t bytes) {
    if(!p->active || now<p->start) { vap_begin(p,now,before); }
    if(before<p->low)p->low=before;
    if(after>p->high)p->high=after;
    p->blocks=vap_add(p->blocks,1);
    if(bytes>p->max_block)p->max_block=bytes;
    return now>=p->start && (uint64_t)now-(uint64_t)p->start>=200000;
}
#endif
