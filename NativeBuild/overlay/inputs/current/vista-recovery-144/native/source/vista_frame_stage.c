#include "flow/vista_flow_trace.c"
/* Passive fixed-capacity collector. Try-only gate, no callback allocation/IO. */
#include "vista_frame_stage_internal.h"
#include <stdatomic.h>
#include <string.h>
#define STREAMS 8
#define DECODERS 16
#define FRAMES 128
static atomic_flag gate=ATOMIC_FLAG_INIT;
static _Atomic uint64_t lost;
static _Atomic uint64_t pressure_lost;
static void pressure_note_loss(void){
 uint64_t n=atomic_load_explicit(&pressure_lost,memory_order_relaxed);
 for(unsigned retry=0;retry<8 && n!=UINT64_MAX;retry++){
  if(atomic_compare_exchange_weak_explicit(&pressure_lost,&n,n+1,memory_order_relaxed,memory_order_relaxed))return;
 }
 /* Saturation is fail-closed; never spin on a decoder callback. */
 atomic_store_explicit(&pressure_lost,UINT64_MAX,memory_order_relaxed);
}
static _Atomic int active;
static uint64_t serial,frame_serial;
typedef struct{const void*main;uint64_t decoder;vista_frame_stage_snapshot_data d;} stream;
typedef struct{const void*key,*main;uint64_t gen;int64_t pts,entry;vista_queue_pressure_snapshot_data pressure;} decoder;
typedef struct{const void*ref,*pic;uint64_t instance,episode;vista_frame_stage_sample d;int complete;} frame;
/* ProcessInput -> VT is synchronous on the decoder thread. Reset even when
 * the collector gate is busy, so a repeated PTS can never inherit old context.
 * Only the first matching VT input in that ProcessInput scope consumes it. */
static _Thread_local struct {const void *key,*pressure_key;int64_t pts,entry,pacer;int pressure_started,pressure_submitted,pressure_ok;vfs_queue_info queue;} input;
static stream streams[STREAMS];static decoder decoders[DECODERS];static frame frames[FRAMES];
static int enter(void){if(!atomic_flag_test_and_set_explicit(&gate,memory_order_acquire))return 1;atomic_fetch_add_explicit(&lost,1,memory_order_relaxed);return 0;}
static void leave(void){atomic_flag_clear_explicit(&gate,memory_order_release);}
static void refresh(void){int n=0;for(unsigned i=0;i<STREAMS;i++)if(streams[i].d.episode_id&&!streams[i].d.end_reason)n=1;atomic_store(&active,n);}
static int open(stream*s,int64_t now){if(!s||!s->d.episode_id||s->d.end_reason||now<s->d.armed_us)return 0;if(now-s->d.armed_us>VFS_WINDOW_US){s->d.end_reason=VFS_WINDOW_END;s->d.end_us=s->d.armed_us+VFS_WINDOW_US;refresh();return 0;}return 1;}
static decoder*dec(const void*k){for(unsigned i=0;i<DECODERS;i++)if(decoders[i].key==k&&k)return &decoders[i];return NULL;}
static stream*streamid(uint64_t id){for(unsigned i=0;i<STREAMS;i++)if(streams[i].d.instance_id==id&&id)return &streams[i];return NULL;}
static stream*owner(frame*f,int64_t now){stream*s=streamid(f->instance);if(!s)return NULL;if(s->d.episode_id!=f->episode||s->decoder!=f->d.decoder_generation){s->d.stale_events++;return NULL;}return open(s,now)?s:NULL;}
static frame*lookup(const void*k,int pic){frame*found=NULL;if(!k)return NULL;for(unsigned i=0;i<FRAMES;i++)if((pic?frames[i].pic:frames[i].ref)==k&&frames[i].d.frame_id){if(!found||frames[i].d.frame_id>found->d.frame_id)found=&frames[i];}return found;}
static void tick(frame*f,unsigned stage,int64_t now){if(stage<VFS_STAGE_COUNT&&!(f->d.stage_mask&(UINT64_C(1)<<stage))){f->d.stage_mask|=UINT64_C(1)<<stage;f->d.ticks[stage]=now;}}
void vfs_decoder_bind(const void*k,const void*main,uint64_t gen){if(!k||!main||!gen||!enter())return;decoder*d=dec(k);if(!d)for(unsigned i=0;i<DECODERS;i++)if(!decoders[i].key){d=&decoders[i];break;}if(d)*d=(decoder){.key=k,.main=main,.gen=gen};leave();}
void vfs_decoder_retire(const void*k){if(!enter())return;decoder*d=dec(k);if(d){for(unsigned i=0;i<STREAMS;i++)if(streams[i].decoder==d->gen&&streams[i].d.episode_id&&!streams[i].d.end_reason){streams[i].d.end_reason=VFS_STREAM_END;streams[i].d.end_us=vrr_now();}memset(d,0,sizeof(*d));refresh();}leave();}
void vfs_decode_enter(const void*k,int64_t pts,int64_t now){memset(&input,0,sizeof(input));input.key=k;input.pressure_key=k;input.pts=pts;input.entry=now;}
void vfs_decode_queue(const vfs_queue_info*q){if(q)input.queue=*q;}
void vfs_pressure_pacer(const void*k,int64_t elapsed){
 if(input.pressure_key==k && elapsed>=0 && elapsed<=INT64_MAX-input.pacer)input.pacer+=elapsed;
 else if(input.pressure_key==k)input.pressure_ok=0;
}
void vfs_pressure_submit(const void*k,int status){
 if(input.pressure_key==k){input.pressure_submitted++;if(status!=0)input.pressure_ok=0;}
}
void vfs_decode_exit(void){
 if(input.pressure_started && (input.pressure_submitted!=1 || !input.pressure_ok))pressure_note_loss();
 else if(input.pressure_started && !enter())pressure_note_loss();
 else if(input.pressure_started){
  decoder*d=dec(input.pressure_key);const vfs_queue_info*q=&input.queue;int64_t now=vrr_now();
  if(d && (q->mask&3)==3 && q->id && input.pts>0 && q->enqueue_us>0 &&
     q->enqueue_us<=q->dequeue_us && q->dequeue_us<=input.entry && input.entry<=now){
   vista_queue_pressure_snapshot_data*p=&d->pressure;
   if(p->decoder_generation!=d->gen || p->queue_epoch!=q->epoch)memset(p,0,sizeof(*p));
   if(p->completed<UINT64_MAX && (uint64_t)input.pacer<=UINT64_MAX-p->pacer_us){
    p->abi_version=VISTA_QUEUE_PRESSURE_ABI;p->status=VFS_OK;p->decoder_generation=d->gen;
    p->queue_epoch=q->epoch;p->queue_id=q->id;p->dequeue_depth=q->dequeue_depth;
    p->completed++;p->pacer_us+=(uint64_t)input.pacer;p->lost=q->lost;
    p->enqueue_us=q->enqueue_us;p->dequeue_us=q->dequeue_us;p->completed_us=now;p->pts=input.pts;
   }else {memset(p,0,sizeof(*p));pressure_note_loss();}
  }else pressure_note_loss();
  leave();
 }
 memset(&input,0,sizeof(input));
}
int vfs_pressure_snapshot_key(const void*main,int64_t now,vista_queue_pressure_snapshot_data*out){
 if(!out)return VFS_INVALID;memset(out,0,sizeof(*out));out->abi_version=VISTA_QUEUE_PRESSURE_ABI;
 if(!main || now<=0)return out->status=VFS_UNAVAILABLE;
 if(!enter())return out->status=VFS_BUSY;
 decoder*d=NULL;int ambiguous=0;
 for(unsigned i=0;i<DECODERS;i++)if(decoders[i].key && decoders[i].main==main){if(d)ambiguous=1;d=&decoders[i];}
 if(!d || ambiguous || !d->pressure.completed){leave();return out->status=VFS_UNAVAILABLE;}
 uint64_t telemetry_lost=atomic_load_explicit(&pressure_lost,memory_order_relaxed);
 if(telemetry_lost==UINT64_MAX || d->pressure.lost>UINT64_MAX-telemetry_lost){leave();return out->status=VFS_INVALID;}
 *out=d->pressure;out->lost+=telemetry_lost;out->snapshot_us=now;leave();return out->status=VFS_OK;
}
int vfs_arm_key(const void*main,uint64_t session,uint64_t command,uint64_t revision,uint64_t seek,int64_t now,vista_frame_stage_mark*out){if(!out)return VFS_INVALID;memset(out,0,sizeof(*out));out->abi_version=VISTA_FRAME_STAGE_ABI;if(!main||!session||!command||now<=0)return out->status=VFS_UNAVAILABLE;if(!enter())return out->status=VFS_BUSY;decoder*d=NULL;int ambiguous=0;for(unsigned i=0;i<DECODERS;i++)if(decoders[i].key&&decoders[i].main==main){if(d)ambiguous=1;d=&decoders[i];}if(!d||ambiguous){leave();return out->status=VFS_UNAVAILABLE;}
 stream*s=NULL;for(unsigned i=0;i<STREAMS;i++)if(streams[i].main==main){s=&streams[i];break;}if(!s)for(unsigned i=0;i<STREAMS;i++)if(!streams[i].d.episode_id||streams[i].d.end_reason){s=&streams[i];break;}if(!s){leave();return out->status=VFS_UNAVAILABLE;}
 uint64_t id=s->main==main?s->d.instance_id:++serial,ep=++serial;memset(&s->d,0,sizeof(s->d));s->main=main;s->decoder=d->gen;s->d=(vista_frame_stage_snapshot_data){.abi_version=VISTA_FRAME_STAGE_ABI,.instance_id=id,.episode_id=ep,.session_id=session,.command_id=command,.revision=revision,.seek_nonce=seek,.armed_us=now};out->instance_id=id;out->episode_id=ep;out->armed_us=now;atomic_store(&active,1);leave();return out->status=VFS_OK;
}
uint64_t vfs_begin(const void*k,const void*ref,int64_t pts,int64_t now){if(input.pressure_key==k){input.pressure_started++;input.pressure_ok=input.pressure_started==1 && input.pts==pts;}if(!atomic_load(&active)||!ref||!enter())return 0;decoder*d=dec(k);stream*s=NULL;if(d)for(unsigned i=0;i<STREAMS;i++)if(streams[i].main==d->main&&streams[i].decoder==d->gen&&open(&streams[i],now)){s=&streams[i];break;}if(!s){leave();return 0;}frame*f=NULL;for(unsigned i=0;i<FRAMES;i++){frame*x=&frames[i];stream*old=streamid(x->instance);if(!x->d.frame_id||x->complete||!old||old->d.episode_id!=x->episode||old->d.end_reason){if(!f||x->d.frame_id<f->d.frame_id)f=x;}}if(!f){s->d.capacity_lost++;leave();return 0;}*f=(frame){.ref=ref,.instance=s->d.instance_id,.episode=s->d.episode_id,.d={.frame_id=++frame_serial,.decoder_generation=d->gen,.pts=pts}};s->d.frames_started++;if(input.key==k&&input.pts==pts&&input.entry>=s->d.armed_us&&input.entry<=now){
 tick(f,VFS_DECODE_ENTER,input.entry);f->d.queue=input.queue;
 if(input.queue.mask&1)tick(f,VFS_COMPRESSED_ENQUEUE,input.queue.enqueue_us);
 if(input.queue.mask&2)tick(f,VFS_COMPRESSED_DEQUEUE,input.queue.dequeue_us);
 input.key=NULL;
}tick(f,VFS_PACER_BEGIN,now);uint64_t id=f->d.frame_id;leave();return id;}
void vfs_id(uint64_t id,unsigned stage,int64_t now,int64_t a,int64_t b){if(!id||!atomic_load(&active)||!enter())return;frame*f=NULL;for(unsigned i=0;i<FRAMES;i++)if(frames[i].d.frame_id==id){f=&frames[i];break;}if(f&&owner(f,now)){tick(f,stage,now);if(stage==VFS_SUBMIT_RETURN){f->d.submit_status=(int32_t)a;f->d.metadata_mask|=VFS_META_SUBMIT;}if(stage==VFS_CALLBACK_ENTER){f->d.callback_status=(int32_t)a;f->d.callback_flags=(uint32_t)b;f->d.metadata_mask|=VFS_META_CALLBACK;}stream*s=streamid(f->instance);if(s&&s->d.episode_id==f->episode)for(unsigned i=0;i<VFS_SAMPLE_COUNT;i++)if((s->d.sample_mask&(1u<<i))&&s->d.samples[i].frame_id==f->d.frame_id)s->d.samples[i]=f->d;}leave();}

void vfs_ref(const void*k,unsigned stage,int64_t now,int64_t a,int64_t b){
if(!atomic_load(&active)||!enter())return;frame*f=lookup(k,0);if(f&&owner(f,now)){tick(f,stage,now);if(stage==VFS_SUBMIT_RETURN){f->d.submit_status=(int32_t)a;f->d.metadata_mask|=VFS_META_SUBMIT;}if(stage==VFS_CALLBACK_ENTER){f->d.callback_status=(int32_t)a;f->d.callback_flags=(uint32_t)b;f->d.metadata_mask|=VFS_META_CALLBACK;}}leave();}
void vfs_bind_picture(const void*ref,const void*pic,int64_t now){if(!atomic_load(&active)||!enter())return;frame*f=lookup(ref,0);if(f&&owner(f,now)){tick(f,VFS_PICTURE_END,now);f->pic=pic;}leave();}
uint64_t vfs_picture_id(const void*k){if(!atomic_load(&active)||!enter())return 0;frame*f=lookup(k,1);uint64_t id=f?f->d.frame_id:0;leave();return id;}

void vfs_picture(const void*k,unsigned stage,int64_t now){VFEmit(VFFind(k),stage==VFS_DPB_EXIT?VF_DPB_EXIT:VF_QUEUE_VIDEO,stage==VFS_QUEUE_ENTER?VF_BEGIN:stage==VFS_QUEUE_LOCKED?VF_END:VF_POINT,now,stage,0,0);if(!atomic_load(&active)||!enter())return;frame*f=lookup(k,1);if(f&&owner(f,now))tick(f,stage,now);leave();}
void vfs_prepare(const void*k,int64_t now,int64_t deadline,uint32_t context,double rate,uint64_t reference,int64_t output_pts,double context_rate){uint64_t flow=VFFind(k);VFEmit(flow,VF_PREPARE,VF_POINT,now,deadline,(int64_t)(rate*1000000),context);VFEmit(flow,VF_CLOCK_CONVERT,VF_POINT,now,output_pts,(int64_t)(context_rate*1000000),reference);if(!atomic_load(&active)||!enter())return;frame*f=lookup(k,1);if(f&&owner(f,now)){tick(f,VFS_PREPARE,now);f->d.output_pts=output_pts;f->d.deadline_us=deadline;f->d.context_id=context;f->d.reference_generation=reference;f->d.video_rate=rate;f->d.context_rate=context_rate;f->d.metadata_mask|=VFS_META_DEADLINE|VFS_META_CONTEXT|VFS_META_RATE|VFS_META_REFERENCE|VFS_META_OUTPUT_PTS|VFS_META_CONTEXT_RATE;}leave();}
static int64_t span(const vista_frame_stage_sample*d){unsigned first=(d->stage_mask&(UINT64_C(1)<<VFS_DECODE_ENTER))?VFS_DECODE_ENTER:VFS_PACER_BEGIN;return d->ticks[VFS_PREPARE]-d->ticks[first];}
void vfs_finish(const void*k,int drop,int64_t now,int64_t threshold,int64_t process){VFEmit(VFFind(k),VF_DROP,VF_POINT,now,drop,threshold,process);if(!atomic_load(&active)||!enter())return;frame*f=lookup(k,1);stream*s=f?owner(f,now):NULL;if(s&&!f->complete){f->complete=1;f->d.outcome=drop?VFS_DROPPED:VFS_PREPARED;if(drop){tick(f,VFS_DROP,now);f->d.threshold_us=threshold;f->d.processing_us=process;f->d.metadata_mask|=VFS_META_DROP;s->d.frames_dropped++;if(!(s->d.sample_mask&2)){s->d.samples[1]=f->d;s->d.sample_mask|=2;}s->d.samples[2]=f->d;s->d.sample_mask|=4;}if(f->d.stage_mask&(UINT64_C(1)<<VFS_PREPARE)){s->d.frames_prepared++;if(!(s->d.sample_mask&1)){s->d.samples[0]=f->d;s->d.sample_mask|=1;}if(!(s->d.sample_mask&8)||span(&f->d)>span(&s->d.samples[3])){s->d.samples[3]=f->d;s->d.sample_mask|=8;}}}leave();}
int vista_frame_stage_snapshot(uint64_t id,uint64_t ep,vista_frame_stage_snapshot_data*out){if(!out)return VFS_INVALID;memset(out,0,sizeof(*out));out->abi_version=VISTA_FRAME_STAGE_ABI;if(!enter())return out->status=VFS_BUSY;stream*s=streamid(id);if(!s||s->d.episode_id!=ep){leave();return out->status=VFS_UNAVAILABLE;}int64_t now=vrr_now();open(s,now);*out=s->d;
 int64_t cutoff=now;if(cutoff>s->d.armed_us+VFS_WINDOW_US)cutoff=s->d.armed_us+VFS_WINDOW_US;if(s->d.end_us&&cutoff>s->d.end_us)cutoff=s->d.end_us;
 int64_t best=(out->sample_mask&8)?span(&out->samples[3]):-1;
 for(unsigned i=0;i<FRAMES;i++){frame*f=&frames[i];if(f->instance==id&&f->episode==ep&&!f->complete&&f->d.frame_id){int64_t elapsed=cutoff-f->d.ticks[VFS_PACER_BEGIN];if(elapsed>best){best=elapsed;out->samples[3]=f->d;out->sample_mask|=8;}}}

 out->snapshot_us=now;out->contention_lost=atomic_load(&lost);leave();return out->status=VFS_OK;}
int vista_frame_stage_end(uint64_t id,uint64_t ep,uint32_t reason){if(reason<VFS_SUPERSEDED||reason>VFS_WINDOW_END)return VFS_INVALID;if(!enter())return VFS_BUSY;stream*s=streamid(id);if(!s||s->d.episode_id!=ep){leave();return VFS_UNAVAILABLE;}if(!s->d.end_reason){s->d.end_reason=reason;s->d.end_us=vrr_now();}refresh();leave();return VFS_OK;}
