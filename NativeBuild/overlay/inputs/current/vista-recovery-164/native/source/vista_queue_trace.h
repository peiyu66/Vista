#ifndef VISTA_QUEUE_TRACE_H
#define VISTA_QUEUE_TRACE_H
#include "vista_frame_stage.h"
#include <string.h>
#define VFS_QUEUE_SLOTS 256
/* Bounded passive ownership ledger; no allocation, no diagnostic lock. */
typedef struct {const void *key;int64_t pts,dts;vfs_queue_info q;} vfs_queue_entry;
typedef struct {
 vfs_queue_entry entries[VFS_QUEUE_SLOTS],pending;
 uint64_t serial,epoch,lost;
 int64_t loop[4];
} vfs_queue_trace;
static inline void vfs_q_clear(vfs_queue_trace *q){
 memset(q->entries,0,sizeof(q->entries));memset(&q->pending,0,sizeof(q->pending));
 q->epoch++; /* serial/loss remain lifetime counters */
}
static inline void vfs_q_put(vfs_queue_trace*q,const void*k,int64_t pts,int64_t dts,int64_t now,uint64_t depth,uint64_t bytes){
 vfs_queue_entry *free_entry=NULL;
 for(unsigned i=0;i<VFS_QUEUE_SLOTS;i++){
  if(q->entries[i].key==k){memset(&q->entries[i],0,sizeof(q->entries[i]));q->lost++;}
  if(!q->entries[i].key&&!free_entry)free_entry=&q->entries[i];
 }
 uint64_t id=++q->serial;
 if(!free_entry){q->lost++;return;}
 *free_entry=(vfs_queue_entry){.key=k,.pts=pts,.dts=dts,.q={.id=id,.epoch=q->epoch,.enqueue_us=now,.enqueue_depth=depth,.enqueue_bytes=bytes,.mask=1}};
}
static inline void vfs_q_take(vfs_queue_trace*q,const void*k,int64_t pts,int64_t dts,int64_t now,uint64_t depth,uint64_t bytes){
 q->pending=(vfs_queue_entry){.key=k,.pts=pts,.dts=dts,.q={.epoch=q->epoch}};
 for(unsigned i=0;i<VFS_QUEUE_SLOTS;i++)if(q->entries[i].key==k){
  if(q->entries[i].pts==pts&&q->entries[i].dts==dts)q->pending=q->entries[i];
  else q->lost++;
  memset(&q->entries[i],0,sizeof(q->entries[i]));break;
 }
 q->pending.q.dequeue_us=now;q->pending.q.dequeue_depth=depth;q->pending.q.dequeue_bytes=bytes;
 q->pending.q.lost=q->lost;q->pending.q.mask|=2;
 memcpy(q->pending.q.loop,q->loop,sizeof(q->loop));if(q->loop[0])q->pending.q.mask|=4;
}
#endif
