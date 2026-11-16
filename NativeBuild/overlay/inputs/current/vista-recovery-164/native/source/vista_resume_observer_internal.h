#ifndef VISTA_RESUME_OBSERVER_INTERNAL_H
#define VISTA_RESUME_OBSERVER_INTERNAL_H
#include "vista_resume_observer.h"
#include <stddef.h>
/* Private opaque lookup keys never leave collector memory. */
typedef struct {uint64_t instance,episode,decoder,request;} vrr_token;
int vrr_active(void);
uint64_t vrr_register(const void *aout,const void *main_clock);
void vrr_retire(uint64_t);
int vrr_arm(const void *aout,uint64_t,uint64_t,uint64_t,uint64_t,int64_t,vista_resume_mark *);
void vrr_emit_main(const void *main_clock,unsigned slot,const vista_resume_event *);
void vrr_emit_id(uint64_t,unsigned slot,const vista_resume_event *);
void vrr_report(const void *aout,int64_t now,int64_t system,int64_t audio);
uint64_t vrr_decoder_register(const void *main_clock);
void vrr_decoder_retire(uint64_t);
vrr_token vrr_control_request(uint64_t decoder,int64_t now,int paused,int64_t date);
void vrr_control(vrr_token,unsigned slot,int64_t now,int paused,int64_t date);
uint64_t vrr_decode_enter(uint64_t decoder,int64_t now,int64_t pts);
void vrr_decode_exit(uint64_t decoder,uint64_t sequence,int64_t now);
int64_t vrr_now(void);
#endif
