#include "vista_flow_trace.h"
#include <stdatomic.h>
#include <string.h>
_Static_assert(sizeof(VFRecord)==64,"scalar trace wire size");
extern int64_t vrr_now(void);
/* Producers never wait or perform IO. A utility consumer drains independently.
 * Each lane has a try-only producer gate and a release/acquire SPSC boundary. */
#define VF_LANES 8u
#define VF_LANE_CAPACITY (VF_CAPACITY/VF_LANES)
#define VF_MAP_BUCKETS 128u
#define VF_MAP_SLOTS 32u
static atomic_flag vf_lifecycle=ATOMIC_FLAG_INIT,vf_drain_gate=ATOMIC_FLAG_INIT;
static _Atomic uint64_t vf_serial,vf_sequence,vf_generation,vf_session;
static _Atomic uint64_t vf_lost,vf_attempts,vf_overflow,vf_stale,vf_map_miss,vf_map_busy,vf_map_evict,vf_map_invalidations,vf_written,vf_drained;
static _Atomic unsigned vf_writers,vf_lane_serial;
static _Atomic int vf_enabled;
static VFHeader vf_header; /* lifecycle/consumer only */
typedef struct {atomic_flag gate;_Atomic uint64_t head,tail;VFRecord records[VF_LANE_CAPACITY];} vf_lane;
static vf_lane vf_lanes[VF_LANES];
static _Thread_local uint64_t vf_parent;
static _Thread_local unsigned vf_preferred;
static _Thread_local int vf_has_lane;
typedef struct {const void *key;uint64_t id,epoch;} vf_mapping;
typedef struct {atomic_flag gate;_Atomic uint64_t epoch;vf_mapping slots[VF_MAP_SLOTS];} vf_bucket;
static vf_bucket vf_map[VF_MAP_BUCKETS];
static _Atomic uint64_t vf_triggers,vf_first_trigger_id;
static _Atomic int64_t vf_first_trigger_us,vf_last_trigger_us;
static _Atomic unsigned vf_first_trigger_reason;
int64_t VFClock(void){return vrr_now();}
static int vf_valid(uint64_t id){return id && (id>>32)==atomic_load_explicit(&vf_generation,memory_order_relaxed);}
static int vf_enter(void){atomic_fetch_add(&vf_writers,1);if(atomic_load(&vf_enabled))return 1;atomic_fetch_sub(&vf_writers,1);return 0;}
static void vf_leave(void){atomic_fetch_sub(&vf_writers,1);}
static void vf_put(uint64_t id,uint64_t parent,uint32_t stage,uint32_t phase,int64_t tick,int64_t a,int64_t b,int64_t c){
 uint64_t sequence=atomic_fetch_add_explicit(&vf_sequence,1,memory_order_relaxed)+1;
 if(!vf_has_lane){vf_preferred=atomic_fetch_add(&vf_lane_serial,1)%VF_LANES;vf_has_lane=1;}
 /* Try another lane if a producer is busy or its consumer has fallen behind. */
 for(unsigned n=0;n<VF_LANES;n++){
  vf_lane *l=&vf_lanes[(vf_preferred+n)%VF_LANES];
  if(atomic_flag_test_and_set_explicit(&l->gate,memory_order_acquire))continue;
  uint64_t tail=atomic_load_explicit(&l->tail,memory_order_relaxed),head=atomic_load_explicit(&l->head,memory_order_acquire);
  if(tail-head<VF_LANE_CAPACITY){
   l->records[tail%VF_LANE_CAPACITY]=(VFRecord){sequence,id,parent,tick,a,b,stage,phase,c};
   atomic_store_explicit(&l->tail,tail+1,memory_order_release);
   atomic_flag_clear_explicit(&l->gate,memory_order_release);atomic_fetch_add(&vf_written,1);return;
  }
  atomic_flag_clear_explicit(&l->gate,memory_order_release);
 }
 /* Separate actual full-lane pressure from transient producer contention. */
 unsigned full=0;for(unsigned n=0;n<VF_LANES;n++)if(atomic_load(&vf_lanes[n].tail)-atomic_load(&vf_lanes[n].head)>=VF_LANE_CAPACITY)full++;
 atomic_fetch_add(full==VF_LANES?&vf_overflow:&vf_lost,1);
}
int VFStart(uint64_t session){
 if(!session||atomic_flag_test_and_set(&vf_lifecycle))return 0;
 if(atomic_load(&vf_enabled)||atomic_load(&vf_writers)){atomic_flag_clear(&vf_lifecycle);return 0;}
 uint64_t generation=atomic_load(&vf_generation)+1;if(!generation||generation>=UINT32_MAX)generation=1;
 atomic_store(&vf_generation,generation);atomic_store(&vf_serial,0);atomic_store(&vf_sequence,0);
 atomic_store(&vf_lost,0);atomic_store(&vf_attempts,0);atomic_store(&vf_overflow,0);atomic_store(&vf_stale,0);
 atomic_store(&vf_map_miss,0);atomic_store(&vf_map_busy,0);atomic_store(&vf_map_evict,0);atomic_store(&vf_map_invalidations,0);atomic_store(&vf_written,0);atomic_store(&vf_drained,0);
 atomic_store(&vf_triggers,0);atomic_store(&vf_first_trigger_id,0);atomic_store(&vf_first_trigger_us,0);atomic_store(&vf_last_trigger_us,0);atomic_store(&vf_first_trigger_reason,0);
 for(unsigned n=0;n<VF_LANES;n++){atomic_flag_clear(&vf_lanes[n].gate);atomic_store(&vf_lanes[n].head,0);atomic_store(&vf_lanes[n].tail,0);}
 for(unsigned n=0;n<VF_MAP_BUCKETS;n++){atomic_flag_clear(&vf_map[n].gate);atomic_store(&vf_map[n].epoch,0);memset(vf_map[n].slots,0,sizeof(vf_map[n].slots));}
 vf_parent=0;vf_header=(VFHeader){.schema=VF_SCHEMA,.record_bytes=sizeof(VFRecord),.capacity=VF_CAPACITY,.session=session,.generation=generation,.opened_us=VFClock()};
 atomic_store(&vf_session,session);atomic_store(&vf_enabled,1);atomic_flag_clear(&vf_lifecycle);
 VFNew(VF_SESSION,VF_POINT,0,0,0,0);return 1;
}
uint64_t VFSession(void){return atomic_load(&vf_enabled)?atomic_load(&vf_session):0;}
uint64_t VFNew(uint32_t stage,uint32_t phase,uint64_t parent,int64_t a,int64_t b,int64_t c){
 if(!vf_enter())return 0;atomic_fetch_add(&vf_attempts,1);
 if(parent&&!vf_valid(parent)){atomic_fetch_add(&vf_stale,1);vf_leave();return 0;}
 /* Identity is independent of storage success. Lost events cannot erase the
  * identity subsequently carried by a frame, async task or mailbox lease. */
 uint64_t id=(atomic_load(&vf_generation)<<32)|(atomic_fetch_add(&vf_serial,1)+1);
 vf_put(id,parent,stage,phase,VFClock(),a,b,c);vf_leave();return id;
}
void VFEmit(uint64_t id,uint32_t stage,uint32_t phase,int64_t tick,int64_t a,int64_t b,int64_t c){
 if(!id||!vf_enter())return;atomic_fetch_add(&vf_attempts,1);
 if(!vf_valid(id)){atomic_fetch_add(&vf_stale,1);vf_leave();return;}
 vf_put(id,0,stage,phase,tick>0?tick:VFClock(),a,b,c);vf_leave();
}
uint64_t VFParent(void){return vf_parent;}
uint64_t VFSetParent(uint64_t id){uint64_t old=vf_parent;vf_parent=id;return old;}
static size_t vf_hash(const void *p){uint64_t x=(uintptr_t)p;x^=x>>33;x*=UINT64_C(0xff51afd7ed558ccd);x^=x>>33;return x%VF_MAP_BUCKETS;}
/* This map is only needed for opaque VLC block/picture objects. It is independent
 * of the event lanes. A missed mutation invalidates one bucket, never all frames. */
void VFBind(const void *p,uint64_t id){
 if(!p||!vf_enter())return;vf_bucket *b=&vf_map[vf_hash(p)];
 if(atomic_flag_test_and_set_explicit(&b->gate,memory_order_acquire)){atomic_fetch_add(&b->epoch,1);atomic_fetch_add(&vf_map_invalidations,1);atomic_fetch_add(&vf_map_busy,1);vf_leave();return;}
 uint64_t epoch=atomic_load(&b->epoch);vf_mapping *slot=NULL;
 for(unsigned n=0;n<VF_MAP_SLOTS;n++){vf_mapping *m=&b->slots[n];if(m->key==p){slot=m;break;}if(!slot&&(!m->key||m->epoch!=epoch))slot=m;}
 if(!id||!vf_valid(id)){if(id)atomic_fetch_add(&vf_stale,1);if(slot&&slot->key==p)*slot=(vf_mapping){0};}
 else {
  if(!slot){atomic_fetch_add(&vf_map_evict,1);slot=&b->slots[0];for(unsigned n=1;n<VF_MAP_SLOTS;n++)if(b->slots[n].id<slot->id)slot=&b->slots[n];}
  *slot=(vf_mapping){p,id,epoch};
 }
 atomic_flag_clear_explicit(&b->gate,memory_order_release);vf_leave();
}
uint64_t VFFind(const void *p){
 if(!p||!vf_enter())return 0;vf_bucket *b=&vf_map[vf_hash(p)];uint64_t id=0;
 if(atomic_flag_test_and_set_explicit(&b->gate,memory_order_acquire)){atomic_fetch_add(&vf_map_busy,1);vf_leave();return 0;}
 uint64_t epoch=atomic_load(&b->epoch);
 for(unsigned n=0;n<VF_MAP_SLOTS;n++)if(b->slots[n].key==p){if(b->slots[n].epoch==epoch)id=b->slots[n].id;break;}
 if(atomic_load(&b->epoch)!=epoch)id=0;
 if(!id)atomic_fetch_add(&vf_map_miss,1);atomic_flag_clear_explicit(&b->gate,memory_order_release);vf_leave();return id;
}
void VFUnbind(const void *p){VFBind(p,0);}
int VFTrigger(uint32_t reason){
 if(!vf_enter())return 0;uint64_t id=VFNew(VF_TRIGGER,VF_POINT,0,reason,0,0);if(!id){vf_leave();return 0;}int64_t now=VFClock();
 if(atomic_fetch_add(&vf_triggers,1)==0){atomic_store(&vf_first_trigger_id,id);atomic_store(&vf_first_trigger_us,now);atomic_store(&vf_first_trigger_reason,reason);}atomic_store(&vf_last_trigger_us,now);vf_leave();return 1;
}
/* Only the utility writer calls drain/stop. Call stop after producer/renderer
 * lifecycle drain; a racing final producer yields busy rather than blocking. */
int VFStop(uint64_t session){
 if(session!=atomic_load(&vf_session))return 0;
 atomic_store(&vf_enabled,0);if(atomic_load(&vf_writers))return 0;
 if(!vf_header.cutoff_us){vf_header.cutoff_us=VFClock();vf_header.cutoff_reason=3;}return 1;
}
size_t VFDrain(VFHeader *h,VFRecord *out,size_t capacity){
 if(!h||(capacity&&!out)||atomic_flag_test_and_set(&vf_drain_gate))return 0;
 size_t count=0;
 for(unsigned n=0;n<VF_LANES&&count<capacity;n++){
  vf_lane *l=&vf_lanes[n];uint64_t head=atomic_load_explicit(&l->head,memory_order_relaxed),tail=atomic_load_explicit(&l->tail,memory_order_acquire);
  while(head<tail&&count<capacity)out[count++]=l->records[(head++)%VF_LANE_CAPACITY];
  atomic_store_explicit(&l->head,head,memory_order_release);
 }
 atomic_fetch_add(&vf_drained,count);*h=vf_header;h->count=(uint32_t)count;h->exported_us=VFClock();h->attempts=atomic_load(&vf_attempts);h->contention_lost=atomic_load(&vf_lost);h->capacity_lost=atomic_load(&vf_overflow);h->stale_lost=atomic_load(&vf_stale);
 h->map_busy=atomic_load(&vf_map_busy);h->map_miss=atomic_load(&vf_map_miss);h->map_evictions=atomic_load(&vf_map_evict);h->map_invalidations=atomic_load(&vf_map_invalidations);h->map_lost=h->map_busy+h->map_miss+h->map_evictions;
 h->written=atomic_load(&vf_written);h->drained=atomic_load(&vf_drained);h->trigger_count=atomic_load(&vf_triggers);h->trigger_id=atomic_load(&vf_first_trigger_id);h->trigger_us=atomic_load(&vf_first_trigger_us);h->last_trigger_us=atomic_load(&vf_last_trigger_us);h->trigger_reason=atomic_load(&vf_first_trigger_reason);
 atomic_flag_clear(&vf_drain_gate);return count;
}
size_t VFExport(VFHeader *h,VFRecord *out,size_t capacity){if(!VFStop(atomic_load(&vf_session)))return 0;return VFDrain(h,out,capacity);}
