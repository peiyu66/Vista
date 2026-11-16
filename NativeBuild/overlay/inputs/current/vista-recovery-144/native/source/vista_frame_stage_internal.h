#ifndef VISTA_FRAME_STAGE_INTERNAL_H
#define VISTA_FRAME_STAGE_INTERNAL_H
#include "vista_frame_stage.h"
#include <stddef.h>
const void *vrr_frame_main_key(const void *aout);
int64_t vrr_now(void);
int vfs_arm_key(const void *,uint64_t,uint64_t,uint64_t,uint64_t,int64_t,vista_frame_stage_mark *);
void vfs_decoder_bind(const void *,const void *,uint64_t);
void vfs_decoder_retire(const void *);
void vfs_decode_enter(const void *,int64_t,int64_t);
void vfs_decode_queue(const vfs_queue_info *);
void vfs_decode_exit(void);
void vfs_pressure_pacer(const void *,int64_t);
void vfs_pressure_submit(const void *,int);
int vfs_pressure_snapshot_key(const void *,int64_t,vista_queue_pressure_snapshot_data *);
uint64_t vfs_begin(const void *,const void *,int64_t,int64_t);
void vfs_id(uint64_t,unsigned,int64_t,int64_t,int64_t);
void vfs_ref(const void *,unsigned,int64_t,int64_t,int64_t);
void vfs_bind_picture(const void *,const void *,int64_t);
uint64_t vfs_picture_id(const void *);
void vfs_picture(const void *,unsigned,int64_t);
void vfs_prepare(const void *,int64_t,int64_t,uint32_t,double,uint64_t,int64_t,double);
void vfs_finish(const void *,int,int64_t,int64_t,int64_t);
#endif
