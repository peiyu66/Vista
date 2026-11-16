#include "vista_seek_cost.h"
#include "flow/vista_flow_trace.h"
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <limits.h>
#include <vlc/vlc.h>
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
static atomic_uint_fast64_t ids=0;
typedef struct {void *bridge;vsc_lease lease;int valid;vsc_snapshot snapshot;} slot;
static slot slots[4];
uint64_t vsc_identity(void){uint64_t n=atomic_load(&ids);while(n!=UINT64_MAX){if(atomic_compare_exchange_weak(&ids,&n,n+1))return n+1;}return 0;}
static slot *find(uint64_t e){for(unsigned i=0;i<4;i++)if(e&&slots[i].lease.engine==e)return &slots[i];return NULL;}
static int matches(slot*s,vsc_lease l){return s&&l.input&&l.owner&&s->lease.input==l.input&&s->lease.owner==l.owner;}
static void life(vsc_lease l,int action){VFNew(420,VF_POINT,VFParent(),l.engine,l.input,action);}
uint64_t vsc_register(void*b){if(!b)return 0;pthread_mutex_lock(&mutex);uint64_t e=0;for(unsigned i=0;i<4;i++)if(slots[i].bridge==b)goto out;for(unsigned i=0;i<4;i++)if(!slots[i].lease.engine){e=vsc_identity();if(e){slots[i]=(slot){.bridge=b,.lease={e,0,0}};}break;}out:pthread_mutex_unlock(&mutex);return e;}
void vsc_unregister(uint64_t e){pthread_mutex_lock(&mutex);slot*s=find(e);if(s)*s=(slot){0};pthread_mutex_unlock(&mutex);}
uint64_t vsc_input_open(uint64_t e){pthread_mutex_lock(&mutex);slot*s=find(e);uint64_t n=s&&!s->lease.input?vsc_identity():0;if(n){s->lease.input=n;s->valid=0;}vsc_lease l=s?s->lease:(vsc_lease){0};pthread_mutex_unlock(&mutex);if(n)life(l,1);return n;}
void vsc_input_close(uint64_t e,uint64_t i){pthread_mutex_lock(&mutex);slot*s=find(e);vsc_lease l=s?s->lease:(vsc_lease){0};int ok=s&&i&&s->lease.input==i;if(ok){s->lease.input=s->lease.owner=0;s->valid=0;}pthread_mutex_unlock(&mutex);if(ok)life(l,2);}
vsc_lease vsc_bind(void*b){pthread_mutex_lock(&mutex);vsc_lease l={0};for(unsigned i=0;i<4;i++){slot*s=&slots[i];if(s->bridge==b&&s->lease.input&&!s->lease.owner){s->lease.owner=vsc_identity();l=s->lease;break;}}pthread_mutex_unlock(&mutex);if(l.owner)life(l,3);return l;}
void vsc_unbind(vsc_lease l){pthread_mutex_lock(&mutex);slot*s=find(l.engine);int ok=matches(s,l);if(ok){s->lease.owner=0;s->valid=0;}pthread_mutex_unlock(&mutex);if(ok)life(l,4);}
static void packet(uint64_t id,const vsc_snapshot*s){VFEmit(id,421,VF_POINT,0,s->engine,s->input,s->owner);VFEmit(id,422,VF_POINT,0,s->sampled,s->serial,s->scope);VFEmit(id,423,VF_POINT,0,s->anchor,s->offset,s->status);VFEmit(id,427,VF_POINT,0,s->track,s->uid,s->selected_hash);VFEmit(id,428,VF_POINT,0,s->chapter_begin,s->chapter_end,((uint64_t)s->selected_total<<32)|s->selected_video);for(uint32_t i=0;i<s->count&&i<4;i++){VFEmit(id,429,VF_POINT,0,s->points[i].pts,s->points[i].fpos,((uint64_t)i<<32)|((uint32_t)s->points[i].trust));}}
void vsc_publish(vsc_lease l,vsc_snapshot*s){if(pthread_mutex_trylock(&mutex))return;slot*x=find(l.engine);int ok=matches(x,l);if(ok){s->engine=l.engine;s->input=l.input;s->owner=l.owner;s->serial=vsc_identity();x->snapshot=*s;x->valid=1;}pthread_mutex_unlock(&mutex);if(ok){uint64_t id=VFNew(421,VF_BEGIN,VFParent(),s->status,s->count,s->scope);packet(id,s);VFEmit(id,421,VF_END,0,0,0,0);}}
int vsc_copy(uint64_t e,uint64_t i,vsc_snapshot*out){memset(out,0,sizeof(*out));if(pthread_mutex_trylock(&mutex))return 2;slot*s=find(e);int ok=s&&i&&s->lease.input==i&&s->lease.owner&&s->valid;if(ok)*out=s->snapshot;pthread_mutex_unlock(&mutex);return ok?0:1;}
void vsc_dispatch(uint64_t e,uint64_t i,int64_t target){vsc_snapshot s;int status=vsc_copy(e,i,&s);int64_t now=libvlc_clock();int copied=status==0;if(copied&&(s.sampled>now||now-s.sampled>250000))status=3;uint64_t id=VFNew(425,VF_BEGIN,VFParent(),target,status,now);if(copied)packet(id,&s);VFEmit(id,425,VF_END,0,e,i,0);}
uint64_t vsc_actual_begin(vsc_lease l,int64_t t,int64_t o){uint64_t id=VFNew(424,VF_BEGIN,VFParent(),t,o,l.owner);VFEmit(id,426,VF_POINT,0,l.engine,l.input,l.owner);return id;}
void vsc_actual(uint64_t id,vsc_lease l,int64_t t,int64_t o,uint32_t track,vsc_point p,int end){(void)l;(void)t;(void)o;VFEmit(id,end?424:426,end?VF_END:VF_POINT,0,track,p.pts,p.fpos);if(!end)VFEmit(id,427,VF_POINT,0,track,p.trust,p.origin);}

void vsc_actual_count(uint64_t id,uint32_t total,uint32_t emitted){VFEmit(id,428,VF_POINT,0,total,emitted,total>=emitted?total-emitted:0);}
