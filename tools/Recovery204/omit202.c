#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include "vista_vt_preroll145.h"
#include "vista_omit202.h"
typedef int64_t vlc_tick_t;
typedef pthread_mutex_t vlc_mutex_t;
typedef pthread_cond_t vlc_cond_t;
#define VLC_TICK_FROM_MS(x) ((int64_t)(x)*1000)
#define vlc_mutex_lock pthread_mutex_lock
#define vlc_mutex_unlock pthread_mutex_unlock
#define vlc_mutex_init(m) pthread_mutex_init(m,NULL)
#define vlc_cond_init(c) pthread_cond_init(c,NULL)
#define vlc_cond_signal pthread_cond_signal
#define vlc_cond_broadcast pthread_cond_broadcast
#define vlc_cond_wait pthread_cond_wait
static int64_t vlc_tick_now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (int64_t)t.tv_sec*1000000+t.tv_nsec/1000;}
static int vlc_cond_timedwait(vlc_cond_t*c,vlc_mutex_t*m,int64_t end){struct timespec t;clock_gettime(CLOCK_REALTIME,&t);int64_t delta=end-vlc_tick_now();if(delta<0)delta=0;t.tv_nsec+=delta*1000;t.tv_sec+=t.tv_nsec/1000000000;t.tv_nsec%=1000000000;return pthread_cond_timedwait(c,m,&t);}
#include "pacer-extracted202.inc"
typedef struct {int i_poc;vlc_tick_t pts;} frame_info_t;
typedef struct {vlc_mutex_t lock;vlc_cond_t metadata_cond202;unsigned pending_metadata202;bool omit_enabled202,b_discard_decoder_output;int vtsession_status;unsigned commits,last_poc;struct pic_pacer pacer;} decoder_sys_t;
typedef struct {decoder_sys_t*p_sys;} decoder_t;
#define VTSESSION_STATUS_OK 0
static _Atomic unsigned control;
unsigned VistaDecoderControl198(decoder_t*d){(void)d;return atomic_load(&control);}
static void VP197Emit(uint64_t id,int stage,int phase,int64_t a,int64_t b,int64_t c){(void)id;(void)stage;(void)phase;(void)a;(void)b;(void)c;}
static void OnDecodedFrame(decoder_t*d,frame_info_t*f){assert(d->p_sys->pending_metadata202==0);++d->p_sys->commits;d->p_sys->last_poc=f->i_poc;pic_pacer_UpdateMaxBuffering(&d->p_sys->pacer,5);free(f);}
#include "metadata-extracted202.inc"
static frame_info_t*frame(int i){frame_info_t*f=calloc(1,sizeof(*f));f->i_poc=i;f->pts=i*16683+1;return f;}
static void init(decoder_sys_t*s){memset(s,0,sizeof(*s));vlc_mutex_init(&s->lock);vlc_cond_init(&s->metadata_cond202);pic_pacer_Init(&s->pacer);s->omit_enabled202=true;atomic_store(&control,0);}
static void clean(decoder_sys_t*s){assert(!s->pending_metadata202&&!s->pacer.queued_fields_for_decode&&!s->pacer.nb_fields_out);pthread_mutex_destroy(&s->lock);pthread_cond_destroy(&s->metadata_cond202);pthread_mutex_destroy(&s->pacer.lock);pthread_cond_destroy(&s->pacer.wait);}
static void napMS(long ms){struct timespec t={ms/1000,(ms%1000)*1000000};nanosleep(&t,NULL);}
typedef struct{decoder_t*d;frame_info_t*f;int result;_Atomic bool done;}work;
static void*omit(void*x){work*w=x;w->result=VistaTryOmit202(w->d,w->f,1);atomic_store(&w->done,true);return NULL;}
static void finish(decoder_t*d){pic_pacer_AccountFinishedDecode(&d->p_sys->pacer,false);VistaMetadataFinished202(d);}
int main(void){unsigned cases=0;
 for(int field=0;field<8;++field){bool v[8]={true,true,true,true,true,true,true,true};v[field]=false;assert(VistaVTPrerollReason(v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7])==(1u<<field));cases++;}
 for(int mode=0;mode<5;++mode){decoder_sys_t s;init(&s);decoder_t d={&s};VistaMetadataScheduled202(&d);pic_pacer_AccountScheduledDecode(&s.pacer,false);work w={.d=&d,.f=frame(7)};pthread_t t;pthread_create(&t,NULL,omit,&w);napMS(20);assert(!atomic_load(&w.done));
  // Success/drop/error callback all complete actual scheduled work; the gate
  // being released at callback entry is insufficient for metadata ordering.
  if(mode<3){if(mode==2){pthread_mutex_lock(&s.lock);s.vtsession_status=1;pthread_mutex_unlock(&s.lock);}finish(&d);pthread_join(t,NULL);assert(w.result==(mode==2?0:1));if(mode==2)free(w.f);}
  else {atomic_store(&control,mode==3?1:2);pthread_join(t,NULL);assert(w.result==2&&!s.commits&&s.pending_metadata202==1);free(w.f);finish(&d);atomic_store(&control,0);}
  clean(&s);cases++;
 }
 {decoder_sys_t s;init(&s);decoder_t d={&s};VistaMetadataScheduled202(&d);pic_pacer_AccountScheduledDecode(&s.pacer,false);atomic_store(&control,4);work w={.d=&d,.f=frame(9)};pthread_t t;pthread_create(&t,NULL,omit,&w);napMS(300);assert(!atomic_load(&w.done));finish(&d);pthread_join(t,NULL);assert(w.result==1&&s.commits==1);clean(&s);cases++;}
 // Two callbacks may overlap their post-entry work. Metadata must wait for
 // BOTH, including when they finish in reverse order; no in-flight credit is
 // consumed for omission itself.
 for(int reverse=0;reverse<2;++reverse){decoder_sys_t s;init(&s);decoder_t d={&s};
  for(int i=0;i<2;++i){VistaMetadataScheduled202(&d);pic_pacer_AccountScheduledDecode(&s.pacer,false);}
  work w={.d=&d,.f=frame(8)};pthread_t t;pthread_create(&t,NULL,omit,&w);napMS(20);assert(!atomic_load(&w.done));
  finish(&d);napMS(20);assert(!atomic_load(&w.done));pthread_mutex_lock(&s.lock);assert(s.pending_metadata202==1);pthread_mutex_unlock(&s.lock);
  finish(&d);pthread_join(t,NULL);assert(w.result==1&&s.commits==1);clean(&s);cases++;
 }
 for(int generation=0;generation<100;++generation){decoder_sys_t s;init(&s);decoder_t d={&s};
  // API error without callback and synchronous callback both finish exactly
  // once via existing ticket ownership. No decode credit for omitted inputs.
  for(int i=0;i<50;++i){pic_pacer_WaitAllocatableSlot(&s.pacer,false);VistaMetadataScheduled202(&d);pic_pacer_AccountScheduledDecode(&s.pacer,false);finish(&d);assert(VistaTryOmit202(&d,frame(i),i+1)==1);}
  assert(s.commits==50&&s.pacer.queued_fields_for_decode==0);clean(&s);cases++;
 }
 {decoder_sys_t s;init(&s);decoder_t d={&s};s.omit_enabled202=false;VistaMetadataScheduled202(&d);VistaMetadataFinished202(&d);assert(!s.pending_metadata202);clean(&s);cases++;}
 {decoder_sys_t s;init(&s);decoder_t d={&s};s.b_discard_decoder_output=true;frame_info_t*f=frame(1);assert(VistaTryOmit202(&d,f,1)==0);free(f);clean(&s);cases++;}
 printf("{\"passed\":true,\"cases\":%u,\"metadataCommits\":5000,\"pauseWaitMS\":300,\"exactHelpers\":true,\"actualPacer\":true}\n",cases);
}
