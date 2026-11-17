#ifndef VISTA_HOLD187_H
#define VISTA_HOLD187_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
/* Experimental, versioned scalar ABI. No reference-frame skipping. */
enum {VHR_QUEUED=1,VHR_HOLDING=2,VHR_READY=3,VHR_RESUMED=4,VHR_FAILED=5,VHR_CANCELLED=6};
enum {VHR_INPUT_BEGIN=0x565187,VHR_ES_BEGIN=0x565188,VHR_ES_TICK=0x565189,VHR_ES_CANCEL=0x56518a,VHR_ES_INPUT_REQUEST=0x56518b,VHR_ES_SOURCE_END=0x56518c};
typedef struct {uint64_t command;int64_t target_us,sample_us;double rate;} VHRInput;
typedef struct {uint32_t state,reason;uint64_t command,frames,discarded;int64_t target_us,started_us,ended_us,ready_pts,deadline_us;double rate;uint32_t pause_ack_mask,resume_requested,timer_resume_sent;} VHRResult;
typedef struct VHRRequest VHRRequest;
VHRRequest *vista_hold187_request(void *player,VHRInput input);
VHRResult vista_hold187_poll(VHRRequest *);
void vista_hold187_cancel(VHRRequest *);
void vista_hold187_cancel_paused(VHRRequest *);
void vista_hold187_release(VHRRequest *);
#endif
