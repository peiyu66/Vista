#ifndef VISTA_HOLD187_INTERNAL_H
#define VISTA_HOLD187_INTERNAL_H
#include "vista_hold187.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <limits.h>
struct VHRRequest {pthread_mutex_t lock;atomic_uint refs;atomic_bool cancel,preserve_pause;VHRInput input;VHRResult result;};
static inline VHRRequest *vhr_new(VHRInput x){
 if(!x.command||x.target_us<0||x.sample_us<=0||!isfinite(x.rate)||x.rate<2||x.rate>3)return NULL;
 VHRRequest *r=calloc(1,sizeof(*r));if(!r)return NULL;
 if(pthread_mutex_init(&r->lock,NULL)){free(r);return NULL;}
 atomic_init(&r->refs,1);atomic_init(&r->cancel,false);atomic_init(&r->preserve_pause,false);r->input=x;
 r->result=(VHRResult){.state=VHR_QUEUED,.command=x.command,.rate=x.rate};return r;
}
static inline void vhr_retain(VHRRequest*r){atomic_fetch_add_explicit(&r->refs,1,memory_order_relaxed);}
static inline void vhr_release(VHRRequest*r){if(r&&atomic_fetch_sub_explicit(&r->refs,1,memory_order_acq_rel)==1){pthread_mutex_destroy(&r->lock);free(r);}}
static inline VHRResult vhr_read(VHRRequest*r){VHRResult x={0};if(r){pthread_mutex_lock(&r->lock);x=r->result;pthread_mutex_unlock(&r->lock);}return x;}
static inline bool vhr_begin(VHRRequest*r,int64_t now){
 if(!r||atomic_load(&r->cancel)||now<r->input.sample_us)return false;
 int64_t age=now-r->input.sample_us;
 long double target=(long double)r->input.target_us+(long double)age*r->input.rate;
 if(age<0||age>100000||target<0||target>INT64_MAX-1000000)return false;
 pthread_mutex_lock(&r->lock);bool ok=r->result.state==VHR_QUEUED;
 if(ok){r->result.state=VHR_HOLDING;r->result.target_us=(int64_t)target;r->result.started_us=now;r->result.deadline_us=0 /* forward experiment: explicit control/source completion only */;}
 pthread_mutex_unlock(&r->lock);return ok;
}
static inline void vhr_finish(VHRRequest*r,unsigned state,unsigned reason,int64_t now){
 pthread_mutex_lock(&r->lock);if(r->result.state<VHR_RESUMED){r->result.state=state;r->result.reason=reason;r->result.ended_us=now;}pthread_mutex_unlock(&r->lock);
}
/* Called under decoder FIFO lock; a request lock is never held across FIFO/clock waits. */
static inline int vhr_picture(VHRRequest*r,int64_t pts,int64_t now){
 (void)now;if(!r)return 0;
 pthread_mutex_lock(&r->lock);VHRResult *x=&r->result;int action=1;
 x->frames++;
 if(x->state==VHR_HOLDING&&!atomic_load(&r->cancel)&&pts>0){
  if(pts-1>=x->target_us&&pts-1<=x->target_us+250000){x->ready_pts=pts;x->state=VHR_READY;action=2;}
 }
 if(action==1)x->discarded++;
 pthread_mutex_unlock(&r->lock);return action;
}
static inline bool vhr_running(VHRRequest*r,int64_t now){(void)now;VHRResult x=vhr_read(r);return r&&!atomic_load(&r->cancel)&&x.state==VHR_HOLDING;}
bool vista_hold189_resume_timer(void *input,int64_t date,bool still_paused);
/* Opaque owner; implementation lives in the matching decoder object. */
struct vlc_input_decoder_t;
bool vista_hold187_decoder_begin(struct vlc_input_decoder_t*,VHRRequest*);
void vista_hold187_decoder_end(struct vlc_input_decoder_t*,VHRRequest*);
bool vista_hold187_decoder_paused(struct vlc_input_decoder_t*);
int vista_hold_forward_input_state(struct vlc_input_decoder_t*,VHRRequest*);
#endif

