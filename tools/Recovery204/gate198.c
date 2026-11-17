#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include "vista_inflight198.h"
typedef int64_t vlc_tick_t;
typedef pthread_mutex_t vlc_mutex_t;
typedef pthread_cond_t vlc_cond_t;
#define VLC_TICK_FROM_MS(x) ((int64_t)(x)*1000)
#define vlc_mutex_lock pthread_mutex_lock
#define vlc_mutex_unlock pthread_mutex_unlock
static int64_t vlc_tick_now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (int64_t)t.tv_sec*1000000+t.tv_nsec/1000;}
static int vlc_cond_timedwait(vlc_cond_t*c,vlc_mutex_t*m,int64_t end){struct timespec t;clock_gettime(CLOCK_REALTIME,&t);int64_t delta=end-vlc_tick_now();if(delta<0)delta=0;t.tv_nsec+=delta*1000;t.tv_sec+=t.tv_nsec/1000000000;t.tv_nsec%=1000000000;return pthread_cond_timedwait(c,m,&t);}
typedef struct {bool b_progressive,b_field;} frame_info_t;
typedef struct {vlc_mutex_t inflight_lock198;vlc_cond_t inflight_cond198;vi198_state inflight198;bool inflight_enabled198;uint64_t inflight_trace198;int codec;} decoder_sys_t;
typedef struct {decoder_sys_t*p_sys;} decoder_t;
static _Atomic unsigned control;
unsigned VistaDecoderControl198(decoder_t*d){(void)d;return atomic_load(&control);}
static void VP197Emit(uint64_t id,int stage,int phase,int64_t a,int64_t b,int64_t c){(void)id;(void)stage;(void)phase;(void)a;(void)b;(void)c;}
static uint64_t VP197New(int stage,int parent,int64_t a,int64_t b,int64_t c){(void)stage;(void)parent;(void)a;(void)b;(void)c;return 1;}
#include "admission-extracted198.inc"
static void init(decoder_sys_t*s){*s=(decoder_sys_t){0};pthread_mutex_init(&s->inflight_lock198,NULL);pthread_cond_init(&s->inflight_cond198,NULL);vi198_init(&s->inflight198);s->inflight_enabled198=true;atomic_store(&control,0);}
static void clean(decoder_sys_t*s){assert(vi198_quiet(&s->inflight198));pthread_mutex_destroy(&s->inflight_lock198);pthread_cond_destroy(&s->inflight_cond198);}

static void finish(decoder_sys_t*s,uint64_t id){uint64_t p;pthread_mutex_lock(&s->inflight_lock198);assert(vi198_callback(&s->inflight198,id,&p));vi198_return(&s->inflight198,id,false);pthread_cond_broadcast(&s->inflight_cond198);pthread_mutex_unlock(&s->inflight_lock198);}
typedef struct {decoder_t*d;frame_info_t*f;bool cancel;uint64_t token;int64_t elapsed;_Atomic bool done;} work;
static void*admit(void*x){work*w=x;int64_t begin=vlc_tick_now();w->token=VistaAdmission198(w->d,w->f,99,&w->cancel);w->elapsed=vlc_tick_now()-begin;atomic_store(&w->done,true);return NULL;}
static void napMS(long ms){struct timespec t={ms/1000,(ms%1000)*1000000};nanosleep(&t,NULL);}
typedef struct {decoder_sys_t*s;uint64_t id;bool returning;} racing;
static void*race(void*arg){racing*r=arg;pthread_mutex_lock(&r->s->inflight_lock198);if(r->returning)vi198_return(&r->s->inflight198,r->id,false);else {uint64_t p;assert(vi198_callback(&r->s->inflight198,r->id,&p));}pthread_mutex_unlock(&r->s->inflight_lock198);return NULL;}
int main(void){assert(VI198_CAP==3);int cases=0;frame_info_t frames[128];for(int i=0;i<128;++i)frames[i]=(frame_info_t){true,false};
 for(int status=-1;status<=1;++status)for(int before=0;before<2;++before){decoder_sys_t s;init(&s);uint64_t p;uint64_t id=vi198_reserve(&s.inflight198,&frames[0],55);if(!before)vi198_return(&s.inflight198,id,false);assert(vi198_callback(&s.inflight198,id,&p)==&frames[0]&&p==55);assert(s.inflight198.outstanding==0);assert(!vi198_callback(&s.inflight198,id,&p));if(before)vi198_return(&s.inflight198,id,false);clean(&s);++cases;}
 {decoder_sys_t s;init(&s);uint64_t p;uint64_t id=vi198_reserve(&s.inflight198,&frames[0],55);assert(vi198_return(&s.inflight198,id,true)==&frames[0]);assert(!vi198_return(&s.inflight198,id,true)&&!vi198_callback(&s.inflight198,id,&p));clean(&s);++cases;}
 // Reused credit is not released by the previous synchronous call's return.
 {decoder_sys_t s;init(&s);uint64_t p;uint64_t a=vi198_reserve(&s.inflight198,&frames[0],1);assert(vi198_callback(&s.inflight198,a,&p));uint64_t b=vi198_reserve(&s.inflight198,&frames[1],2);vi198_return(&s.inflight198,a,false);assert(s.inflight198.outstanding==1);assert(!vi198_callback(&s.inflight198,a,&p));finish(&s,b);clean(&s);++cases;}
 // 300ms with no callback: remain at3; no time-based permission or bypass.
 // A pause request likewise does not release a credit. Normal/error/drop
 // callbacks all use the same claim path; the next ordered submission continues.
 for(unsigned pause=0;pause<2;++pause){decoder_sys_t s;init(&s);decoder_t d={&s};uint64_t ids[VI198_CAP];bool cancel;for(int i=0;i<VI198_CAP;++i){ids[i]=VistaAdmission198(&d,&frames[i],i+1,&cancel);vi198_return(&s.inflight198,ids[i],false);}work w={.d=&d,.f=&frames[VI198_CAP]};pthread_t th;pthread_create(&th,NULL,admit,&w);if(pause)atomic_store(&control,4);napMS(300);assert(!atomic_load(&w.done));pthread_mutex_lock(&s.inflight_lock198);assert(s.inflight198.outstanding==VI198_CAP&&s.inflight198.peak==VI198_CAP);pthread_mutex_unlock(&s.inflight_lock198);finish(&s,ids[VI198_CAP-1]);pthread_join(th,NULL);assert(w.token&&!w.cancel&&w.elapsed>=250000);for(int i=0;i<VI198_CAP-1;++i)finish(&s,ids[i]);finish(&s,w.token);clean(&s);++cases;}
 // Actual flush or abort cancels UNSUBMITTED input; no invented completion.
 for(unsigned mode=1;mode<=2;++mode){decoder_sys_t s;init(&s);decoder_t d={&s};uint64_t ids[VI198_CAP];bool cancel;for(int i=0;i<VI198_CAP;++i){ids[i]=VistaAdmission198(&d,&frames[i],i+1,&cancel);vi198_return(&s.inflight198,ids[i],false);}work w={.d=&d,.f=&frames[VI198_CAP]};pthread_t th;pthread_create(&th,NULL,admit,&w);napMS(20);atomic_store(&control,mode);pthread_join(th,NULL);assert(!w.token&&w.cancel&&s.inflight198.outstanding==VI198_CAP);for(int i=0;i<VI198_CAP;++i)finish(&s,ids[i]);atomic_store(&control,0);VistaDrain198(&d);assert(s.inflight198.epoch==2);clean(&s);++cases;}
 {decoder_sys_t s;init(&s);decoder_t d={&s};uint64_t id=vi198_reserve(&s.inflight198,&frames[0],1),p;assert(!vi198_epoch(&s.inflight198)&&s.inflight198.epoch==1);finish(&s,id);VistaDrain198(&d);assert(s.inflight198.epoch==2);uint64_t fresh=vi198_reserve(&s.inflight198,&frames[0],1);assert(fresh!=id&&!vi198_callback(&s.inflight198,id,&p)&&s.inflight198.outstanding==1);finish(&s,fresh);clean(&s);++cases;}
 // A completed callback owns frame_info independently of the three credit slots.
 // 100 claims before output bodies finish cannot exhaust an unrelated64 table.
 {decoder_sys_t s;init(&s);uint64_t p;for(int i=0;i<100;++i){uint64_t id=vi198_reserve(&s.inflight198,&frames[i],i+1);assert(id);assert(vi198_callback(&s.inflight198,id,&p)==&frames[i]);vi198_return(&s.inflight198,id,false);}clean(&s);++cases;}
 {decoder_sys_t s;init(&s);for(int trial=0;trial<10000;++trial){uint64_t id[VI198_CAP],p;for(int i=0;i<VI198_CAP;++i){id[i]=vi198_reserve(&s.inflight198,&frames[i],i+1);vi198_return(&s.inflight198,id[i],false);}assert(!vi198_reserve(&s.inflight198,&frames[VI198_CAP],4));for(int j=VI198_CAP-1;j>=0;--j)assert(vi198_callback(&s.inflight198,id[j],&p)==&frames[j]);assert(vi198_quiet(&s.inflight198));}clean(&s);++cases;}
 for(int t=0;t<100;++t){decoder_sys_t s;init(&s);racing work[2*VI198_CAP];pthread_t threads[2*VI198_CAP];for(int i=0;i<VI198_CAP;++i){uint64_t id=vi198_reserve(&s.inflight198,&frames[i],i+1);work[2*i]=(racing){&s,id,true};work[2*i+1]=(racing){&s,id,false};}for(int i=0;i<2*VI198_CAP;++i)pthread_create(&threads[i],NULL,race,&work[i]);for(int i=0;i<2*VI198_CAP;++i)pthread_join(threads[i],NULL);clean(&s);++cases;}
 printf("{\"passed\":true,\"cap\":3,\"cases\":%d,\"ringWrapCalls\":30000,\"noTimeoutObservedMS\":300,\"exactAdmissionHelper\":true}\n",cases);
}
