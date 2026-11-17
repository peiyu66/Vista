#ifndef VISTA_DECODE204_TRACE_H
#define VISTA_DECODE204_TRACE_H
#include "flow/vista_flow_trace.h"
/* Accepted decoder metrics use the existing bounded scalar Flow channel.
 * This adapter does not hash payloads or enable the experimental 197 writer.
 * Release never starts Flow; Diagnostic retains its existing lifecycle. */
static inline int VP197Enabled(void){return VFSession()!=0;}
static inline uint64_t VP197New(uint32_t stage,uint64_t parent,int64_t a,int64_t b,int64_t c){return VFNew(stage,VF_BEGIN,parent,a,b,c);}
static inline void VP197Emit(uint64_t id,uint32_t stage,uint32_t phase,int64_t a,int64_t b,int64_t c){VFEmit(id,stage,phase,0,a,b,c);}
static inline uint64_t VP197Packet(uint32_t stage,uint64_t parent,int64_t offset,int64_t flags,const void*bytes,size_t size,int64_t pts,int64_t dts){
 (void)offset;(void)flags;(void)bytes;return VFNew(stage,VF_POINT,parent,pts,dts,(int64_t)size);
}
#endif
