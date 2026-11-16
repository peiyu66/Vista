#include "vista_frame_stage_internal.h"
/* Bounded passive observation. No callback allocation, I/O or waiting. */
#include "vista_resume_observer_internal.h"
#include <stdatomic.h>
#include <string.h>
#include <limits.h>
#define N 16u
_Static_assert(ATOMIC_LLONG_LOCK_FREE==2,"diagnostic identity must be lock-free");
typedef struct { _Atomic uint64_t live; uint64_t id,serial; const void *aout,*main;
 vista_resume_snapshot_data data; } stream_slot;
typedef struct { _Atomic uint64_t live; uint64_t id,request;const void *main;
 _Atomic uint64_t version,decode; _Atomic int active; _Atomic int64_t entry,exit,pts; } decoder_slot;
static stream_slot streams[N];static decoder_slot decoders[N];
static atomic_flag gate=ATOMIC_FLAG_INIT;
static _Atomic uint64_t lost,registration_failures;
static _Atomic int any_active;
int vrr_active(void){return atomic_load_explicit(&any_active,memory_order_relaxed);}
static uint64_t generation,event_sequence;
static int enter(void){if(!atomic_flag_test_and_set_explicit(&gate,memory_order_acquire))return 1;atomic_fetch_add_explicit(&lost,1,memory_order_relaxed);return 0;}
static void leave(void){atomic_flag_clear_explicit(&gate,memory_order_release);}
static stream_slot *by_id(uint64_t id,int live){unsigned i=(unsigned)(id&255u);if(!i||i>N)return NULL;stream_slot*s=&streams[i-1];return s->id==id&&(!live||atomic_load(&s->live)==id)?s:NULL;}
static decoder_slot *decoder(uint64_t id){unsigned i=(unsigned)(id&255u);if(!i||i>N)return NULL;decoder_slot*d=&decoders[i-1];return d->id==id&&atomic_load(&d->live)==id?d:NULL;}
static stream_slot *by_key(const void *key,int aout){stream_slot*found=NULL;if(!key)return NULL;for(unsigned i=0;i<N;i++){stream_slot*s=&streams[i];if(atomic_load(&s->live)==s->id&&s->id&&(aout?s->aout:s->main)==key){if(found)return NULL;found=s;}}return found;}
static void refresh_active(void){int active=0;for(unsigned i=0;i<N;i++){stream_slot*s=&streams[i];if(s->id&&atomic_load(&s->live)==s->id&&s->data.episode_id&&!s->data.end_reason)active=1;}atomic_store_explicit(&any_active,active,memory_order_relaxed);}
static void capture_decode(stream_slot*s){decoder_slot*d=decoder(s->data.decoder_lifetime);s->data.decode_valid=0;if(!d){s->data.control_superseded=1;return;}
 uint64_t v=atomic_load(&d->version);if(v&1)return;
 uint64_t seq=atomic_load(&d->decode);int active=atomic_load(&d->active);int64_t entry=atomic_load(&d->entry),exit=atomic_load(&d->exit),pts=atomic_load(&d->pts);
 if(v!=atomic_load(&d->version)||atomic_load(&d->live)!=s->data.decoder_lifetime)return;
 s->data.decode_seq=seq;s->data.decode_active=active;s->data.decode_entry_us=entry;s->data.decode_exit_us=exit;s->data.decode_pts=pts;s->data.decode_valid=seq!=0;
}
static int open_at(stream_slot*s,int64_t now){if(!s||!s->data.episode_id||s->data.end_reason||now<s->data.armed_us)return 0;if(s->data.resume_us&&now-s->data.resume_us>VRR_WINDOW_US){capture_decode(s);s->data.end_reason=VRR_WINDOW_END;s->data.end_us=s->data.resume_us+VRR_WINDOW_US;refresh_active();return 0;}return 1;}
static void put(stream_slot*s,unsigned kind,const vista_resume_event*event){
 if(kind>=VRR_SLOT_COUNT||!open_at(s,event->tick_us))return;
 int post=kind>=VRR_REPORT;
 if(post&&(!s->data.resume_us||event->tick_us<s->data.resume_us))return;
 if(kind==VRR_REPORT)s->data.report_count++;
 if(kind==VRR_REJECT)s->data.reject_count++;
 if(kind==VRR_ACCEPT)s->data.accept_count++;
 if(kind==VRR_DROP_FIRST){
  s->data.drop_count++;
  if((s->data.valid_slots&(UINT64_C(1)<<VRR_MASTER_COMPLETE))&&!(s->data.valid_slots&(UINT64_C(1)<<VRR_DROP_AFTER_MASTER))){vista_resume_event e=*event;e.sequence=++event_sequence;s->data.slots[VRR_DROP_AFTER_MASTER]=e;s->data.valid_slots|=UINT64_C(1)<<VRR_DROP_AFTER_MASTER;}
  vista_resume_event e=*event;e.sequence=++event_sequence;s->data.slots[VRR_DROP_LAST]=e;s->data.valid_slots|=UINT64_C(1)<<VRR_DROP_LAST;
 }
 if(s->data.valid_slots&(UINT64_C(1)<<kind))return;
 s->data.slots[kind]=*event;s->data.slots[kind].sequence=++event_sequence;s->data.valid_slots|=UINT64_C(1)<<kind;
}
uint64_t vrr_register(const void*aout,const void*main){if(!aout||!main||!enter()){atomic_fetch_add(&registration_failures,1);return 0;}stream_slot*s=NULL;unsigned ix=0;for(unsigned i=0;i<N;i++)if(!atomic_load(&streams[i].live)&&(!s||streams[i].id<s->id)){s=&streams[i];ix=i;}if(!s||generation>=(UINT64_MAX>>8)-1){leave();atomic_fetch_add(&registration_failures,1);return 0;}s->id=(++generation<<8)|(ix+1);s->serial=0;s->aout=aout;s->main=main;memset(&s->data,0,sizeof(s->data));atomic_store(&s->live,s->id);uint64_t id=s->id;leave();return id;}
void vrr_retire(uint64_t id){unsigned i=(unsigned)(id&255u);if(i&&i<=N)atomic_compare_exchange_strong(&streams[i-1].live,&id,0);}
uint64_t vrr_decoder_register(const void*main){if(!main||!enter()){atomic_fetch_add(&registration_failures,1);return 0;}decoder_slot*d=NULL;unsigned ix=0;for(unsigned i=0;i<N;i++)if(!atomic_load(&decoders[i].live)&&(!d||decoders[i].id<d->id)){d=&decoders[i];ix=i;}if(!d||generation>=(UINT64_MAX>>8)-1){leave();atomic_fetch_add(&registration_failures,1);return 0;}d->id=(++generation<<8)|(ix+1);d->main=main;d->request=0;atomic_store(&d->version,0);atomic_store(&d->decode,0);atomic_store(&d->active,0);atomic_store(&d->entry,0);atomic_store(&d->exit,0);atomic_store(&d->pts,0);atomic_store(&d->live,d->id);uint64_t id=d->id;leave();return id;}
void vrr_decoder_retire(uint64_t id){unsigned i=(unsigned)(id&255u);if(i&&i<=N)atomic_compare_exchange_strong(&decoders[i-1].live,&id,0);}
int vrr_arm(const void*aout,uint64_t session,uint64_t command,uint64_t revision,uint64_t seek,int64_t now,vista_resume_mark*out){
 if(!out)return VRR_INVALID;memset(out,0,sizeof(*out));out->abi_version=VISTA_RESUME_OBSERVER_ABI;
 if(!session||!command||now<=0)return out->status=VRR_INVALID;if(!enter())return out->status=VRR_BUSY;
 stream_slot*s=by_key(aout,1);decoder_slot*d=NULL;int ambiguous=0;
 if(s)for(unsigned i=0;i<N;i++)if(decoders[i].id&&atomic_load(&decoders[i].live)==decoders[i].id&&decoders[i].main==s->main){if(d)ambiguous=1;d=&decoders[i];}
 if(!s||!d||ambiguous){leave();return out->status=VRR_UNAVAILABLE;}
 memset(&s->data,0,sizeof(s->data));s->data.abi_version=VISTA_RESUME_OBSERVER_ABI;s->data.instance_id=s->id;s->data.episode_id=++s->serial;s->data.session_id=session;s->data.command_id=command;s->data.revision=revision;s->data.seek_nonce=seek;s->data.armed_us=now;s->data.decoder_lifetime=d->id;
 capture_decode(s);atomic_store_explicit(&any_active,1,memory_order_relaxed);out->instance_id=s->id;out->episode_id=s->serial;out->armed_us=now;leave();return out->status=VRR_OK;
}
int vista_resume_observer_resume(uint64_t id,uint64_t ep,int dispatch){if(!id||!ep||(dispatch!=0&&dispatch!=1))return VRR_INVALID;if(!enter())return VRR_BUSY;stream_slot*s=by_id(id,1);int64_t now=vrr_now();if(!s||s->data.episode_id!=ep||!open_at(s,now)){leave();return VRR_UNAVAILABLE;}if(dispatch&&!s->data.resume_us)s->data.resume_us=now;if(!s->data.resume_us){leave();return VRR_INVALID;}vista_resume_event e={.tick_us=now};put(s,dispatch?VRR_RESUME_DISPATCH:VRR_RESUME_RETURN,&e);leave();return VRR_OK;}
int vista_resume_observer_end(uint64_t id,uint64_t ep,uint32_t reason){if(!id||!ep||reason<VRR_SUPERSEDED||reason>VRR_WINDOW_END)return VRR_INVALID;if(!enter())return VRR_BUSY;stream_slot*s=by_id(id,0);if(!s||s->data.episode_id!=ep){leave();return VRR_UNAVAILABLE;}if(!s->data.end_reason){capture_decode(s);s->data.end_reason=reason;s->data.end_us=vrr_now();refresh_active();}leave();return VRR_OK;}
int vista_resume_observer_snapshot(uint64_t id,uint64_t ep,vista_resume_snapshot_data*out){if(!out)return VRR_INVALID;memset(out,0,sizeof(*out));out->abi_version=VISTA_RESUME_OBSERVER_ABI;if(!enter())return out->status=VRR_BUSY;stream_slot*s=by_id(id,0);if(!s||s->data.episode_id!=ep){leave();return out->status=VRR_UNAVAILABLE;}int64_t now=vrr_now();open_at(s,now);if(!s->data.end_reason)capture_decode(s);*out=s->data;out->snapshot_us=now;out->global_lost=atomic_load(&lost);out->registration_failures=atomic_load(&registration_failures);out->stream_closed=atomic_load(&s->live)!=id;if(out->stream_closed&&!out->end_reason)out->end_reason=VRR_STREAM_END;refresh_active();leave();return out->status=VRR_OK;}
void vrr_emit_main(const void*main,unsigned kind,const vista_resume_event*e){if(!vrr_active()||!e||!enter())return;stream_slot*s=by_key(main,0);put(s,kind,e);leave();}
void vrr_emit_id(uint64_t id,unsigned kind,const vista_resume_event*e){if(!vrr_active()||!id||!e||!enter())return;put(by_id(id,1),kind,e);leave();}
void vrr_report(const void*aout,int64_t now,int64_t system,int64_t audio){if(!vrr_active()||!enter())return;vista_resume_event e={.tick_us=now,.present=3,.value={system,audio}};put(by_key(aout,1),VRR_REPORT,&e);leave();}
void vista_resume_observer_watch(uint64_t id,uint64_t ep,int64_t now,double rate,int64_t media,int64_t system,uint64_t seq){if(!vrr_active()||!id||!ep||!enter())return;stream_slot*s=by_id(id,1);if(s&&s->data.episode_id==ep&&system>0){vista_resume_event e={.tick_us=now,.present=7|VRR_HAS_RATE,.value={media,system,(int64_t)seq},.rate=rate};put(s,system==INT64_MAX?VRR_WATCH_MAX:VRR_WATCH_FINITE,&e);}leave();}
vrr_token vrr_control_request(uint64_t did,int64_t now,int paused,int64_t date){vrr_token token={0};if(!did||!enter())return token;decoder_slot*d=decoder(did);if(d){d->request++;stream_slot*s=by_key(d->main,0);if(s&&open_at(s,now)&&s->data.decoder_lifetime==did){if(s->data.control_request_seq&&s->data.control_ack_seq!=s->data.control_request_seq)s->data.control_superseded=1;if(!paused&&s->data.resume_us&&now>=s->data.resume_us){if(s->data.control_request_seq){s->data.control_superseded=1;leave();return token;}token=(vrr_token){s->id,s->data.episode_id,did,d->request};s->data.control_request_seq=d->request;vista_resume_event e={.tick_us=now,.present=15,.value={paused,date,(int64_t)d->request,(int64_t)did}};put(s,VRR_CONTROL_REQUEST,&e);}}}leave();return token;}
void vrr_control(vrr_token t,unsigned kind,int64_t now,int paused,int64_t date){if(!t.instance||!enter())return;stream_slot*s=by_id(t.instance,1);decoder_slot*d=decoder(t.decoder);if(s&&d&&s->data.episode_id==t.episode&&s->data.decoder_lifetime==t.decoder&&d->request==t.request){vista_resume_event e={.tick_us=now,.present=15,.value={paused,date,(int64_t)t.request,(int64_t)t.decoder}};put(s,kind,&e);if(kind==VRR_OUTPUT_ACK&&open_at(s,now))s->data.control_ack_seq=t.request;}leave();}
/* A decoder has one serialized ProcessInput writer. These atomic scalar
 * latches remain live before arm, so a pre-existing blocked decode is visible.
 * No shared collector gate is acquired while no episode is armed. */
uint64_t vrr_decode_enter(uint64_t did,int64_t now,int64_t pts){
 decoder_slot*d=decoder(did);if(!d)return 0;
 atomic_fetch_add(&d->version,1);uint64_t seq=atomic_fetch_add(&d->decode,1)+1;
 atomic_store(&d->active,1);atomic_store(&d->exit,0);atomic_store(&d->entry,now);atomic_store(&d->pts,pts);atomic_fetch_add(&d->version,1);
 if(!vrr_active()||!enter())return seq;stream_slot*s=by_key(d->main,0);
 if(s&&s->data.decoder_lifetime==did){vista_resume_event e={.tick_us=now,.present=7,.value={pts,(int64_t)seq,(int64_t)did}};put(s,VRR_DECODE_ENTER,&e);}leave();return seq;
}
void vrr_decode_exit(uint64_t did,uint64_t seq,int64_t now){
 decoder_slot*d=decoder(did);if(!d||!seq||atomic_load(&d->decode)!=seq)return;
 atomic_fetch_add(&d->version,1);atomic_store(&d->active,0);atomic_store(&d->exit,now);atomic_fetch_add(&d->version,1);
 if(!vrr_active()||!enter())return;stream_slot*s=by_key(d->main,0);
 if(s&&s->data.decoder_lifetime==did){vista_resume_event e={.tick_us=now,.present=7,.value={atomic_load(&d->pts),(int64_t)seq,(int64_t)did}};put(s,VRR_DECODE_EXIT,&e);}leave();
}
#ifdef VRR_TEST
void vrr_test_hold(void){while(atomic_flag_test_and_set(&gate)){} }
void vrr_test_release(void){leave();}
#endif

/* Companion passive frame collector lookup; no native pointer leaves C. */
const void *vrr_frame_main_key(const void*aout){if(!enter())return NULL;stream_slot*s=by_key(aout,1);const void*main=s?s->main:NULL;leave();return main;}
