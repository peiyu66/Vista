#ifndef VISTA_SEEK_COST_H
#define VISTA_SEEK_COST_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {uint64_t engine,input,owner;} vsc_lease;
typedef struct {int64_t pts;uint64_t fpos;int32_t trust;uint32_t origin;} vsc_point;
typedef struct {
 uint64_t engine,input,owner,serial,scope,track,uid,selected_hash;
 int64_t sampled,anchor,offset,chapter_begin,chapter_end;
 uint32_t count,status,selected_video,selected_total;
 vsc_point points[4];
} vsc_snapshot;
uint64_t vsc_register(void *bridge);
void vsc_unregister(uint64_t engine);
uint64_t vsc_input_open(uint64_t engine);
void vsc_input_close(uint64_t engine,uint64_t input);
vsc_lease vsc_bind(void *bridge);
void vsc_unbind(vsc_lease);
uint64_t vsc_identity(void);
void vsc_publish(vsc_lease,vsc_snapshot *);
int vsc_copy(uint64_t engine,uint64_t input,vsc_snapshot *);
void vsc_dispatch(uint64_t engine,uint64_t input,int64_t target);
void vsc_actual(uint64_t token,vsc_lease,int64_t target,int64_t offset,uint32_t track,vsc_point,int end);
void vsc_actual_count(uint64_t,uint32_t,uint32_t);
uint64_t vsc_actual_begin(vsc_lease,int64_t target,int64_t offset);
#ifdef __cplusplus
}
#endif
#endif
