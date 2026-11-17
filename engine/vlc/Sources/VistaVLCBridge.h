#pragma once
#include "vista_flow_trace.h"
#include "VLCProbeBridge.h"
#include "../../source/producer/MKVProducer.h"
typedef ptrdiff_t (*VLCVistaReadAt)(void *, uint64_t, unsigned char *, size_t);
typedef int (*VLCVistaValidate)(void *);
VLCProbeEngine *VLCVistaCreate(void *, uint64_t, VLCVistaReadAt, VLCVistaValidate, VLCVistaValidate);
typedef struct {
 int64_t time_us, length_us; float rate; uint64_t watch_updates;
 bool paused, seekable, has_audio, unsupported_audio, unsupported_video;
 double watch_rate; int64_t watch_ts_us, watch_date_us, timer_time_us, timer_now_us;
 uint64_t watch_seeks;
 bool timer_valid, timer_paused, timer_seeking, buffering;
 uint32_t video_codec, audio_codec, width, height; uint64_t bitrate;
} VLCVistaState;
VLCVistaState VLCVistaGetState(VLCProbeEngine *);
int64_t VLCVistaClock(void);
void VLCVistaPause(VLCProbeEngine *, bool);
typedef struct { int status; uint64_t watch_floor; int64_t command_clock_us; } VLCVistaRateReceipt;
VLCVistaRateReceipt VLCVistaRate(VLCProbeEngine *, float);
int VLCVistaSeek(VLCProbeEngine *, int64_t);
/* Separate private observer ABI. No change to LibVLC/native archive or state ABI. */
typedef struct {
 uint64_t command_id;
 int64_t target_us, begin_clock_us, end_clock_us;
 uint64_t start_sequence, end_sequence;
 bool start_matched, ended, ambiguous;
} VLCVistaSeekObservation;
typedef struct { int status; uint64_t command_id; } VLCVistaSeekDispatch;
VLCVistaSeekDispatch VLCVistaSeekObserved(VLCProbeEngine *, int64_t);
VLCVistaSeekObservation VLCVistaGetSeekObservation(VLCProbeEngine *);

/* Optional low-frequency native media statistics; unavailable is not zero. */
typedef struct {
 bool available; uint64_t decoded_video, displayed_pictures, late_pictures, lost_pictures;
} VLCVistaMediaStats;
VLCVistaMediaStats VLCVistaGetMediaStats(VLCProbeEngine *);

/* v1/v2 recovery envelope; v2 clock evidence is paired under the native bridge mutex. */
typedef struct {
 bool available; uint32_t version;
 int64_t sample_clock_us, tick_zero, tick_invalid, ticks_per_second;
 uint64_t queue_count, queue_valid, queue_invalid, queue_repeat, queue_backward, delivery_admitted, delivery_invalid, delivery_no_vout, delivery_wait_abort, delivery_flush_abort, delivery_preroll, delivery_prevframe, fifo_pop, fifo_empty, late_drop, render_normal, render_forced, render_redisplay;
 int64_t queue_pts, queue_tick, popped_pts, drop_pts, drop_tick, drop_system_delta, drop_process, drop_threshold;
 double drop_rate; uint32_t drop_clock_id;
 bool drop_context_valid; double drop_context_rate; uint64_t drop_reference_generation;
} VLCVistaNativeDiagnostics;
VLCVistaNativeDiagnostics VLCVistaGetNativeDiagnostics(VLCProbeEngine *);

/* Passive per-command audio-boundary observations. Existing receipt ABI stays unchanged. */
#include <vista_audio_boundary.h>
typedef struct {
 VLCVistaRateReceipt rate;
 vista_audio_boundary_mark mark;
 vista_audio_boundary_snapshot_data previous;
 int finish_status;
} VLCVistaAudioRateReceipt;
VLCVistaAudioRateReceipt VLCVistaAudioRate(VLCProbeEngine *,float,uint64_t,uint64_t);
vista_audio_boundary_snapshot_data VLCVistaAudioSnapshot(VLCProbeEngine *);
vista_audio_boundary_snapshot_data VLCVistaAudioFinish(VLCProbeEngine *,uint32_t,int *);

/* Separate resume observer. Does not share the rate-boundary lifetime/gate. */
#include <vista_resume_observer.h>
#include <vista_frame_stage.h>
typedef struct {
 vista_frame_stage_mark mark;
 vista_frame_stage_snapshot_data previous;
 int finish_status;
} VLCVistaFrameReceipt;
vista_frame_stage_snapshot_data VLCVistaFrameSnapshot(VLCProbeEngine *);
vista_queue_pressure_snapshot_data VLCVistaQueuePressure(VLCProbeEngine *);
vista_frame_stage_snapshot_data VLCVistaFrameFinish(VLCProbeEngine *,uint32_t,int *);
typedef struct {
 VLCVistaAudioRateReceipt audio;
 VLCVistaFrameReceipt frame;
 vista_resume_mark mark;
 vista_resume_snapshot_data previous;
 int finish_status;
} VLCVistaResumeRateReceipt;
VLCVistaResumeRateReceipt VLCVistaResumeRate(VLCProbeEngine *,float,uint64_t,uint64_t,uint64_t,uint64_t,bool);
vista_resume_snapshot_data VLCVistaResumeSnapshot(VLCProbeEngine *);
vista_resume_snapshot_data VLCVistaResumeFinish(VLCProbeEngine *,uint32_t,int *);

#include "vista_hold187.h"
bool VLCVistaCatchupStart(VLCProbeEngine*,uint64_t,int64_t,int64_t,double);
VHRResult VLCVistaCatchupPoll(VLCProbeEngine*);
void VLCVistaCatchupCancel(VLCProbeEngine*,bool);
