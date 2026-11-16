/* Private Apple research ABI, NOT an upstream/public LibVLC API. */
#ifdef HAVE_CONFIG_H
# include "config.h"
#endif
#ifndef VISTA_CVPX_BRIDGE_H
#define VISTA_CVPX_BRIDGE_H
#include <vlc_common.h>
#include <vlc_es.h>
#include <vlc_vout.h>
#include <vlc_tick.h>
#include <CoreVideo/CoreVideo.h>

typedef struct vista_cvpx_bridge vista_cvpx_bridge;
typedef struct vista_cvpx_frame {
    CVPixelBufferRef pixel;             /* owned by this lease; never release separately */
    video_format_t picture_format;     /* deep copied including optional palette */
    video_format_t source_format;      /* original crop/SAR/projection/packing */
    vlc_tick_t media_pts;
    vlc_tick_t initial_deadline;        /* Prepare's system-clock deadline, NOT final recomputed deadline */
    vlc_tick_t display_tick;            /* sampled when Display actually publishes */
    uint64_t generation;
    video_projection_mode_t requested_projection;
    vlc_stereoscopic_mode_t requested_stereo;
    bool progressive;
    bool left_eye;
    unsigned fields;
    uintptr_t picture_identity;        /* equality only; never dereference or retain picture_t */
    uint64_t trace_frame_id; /* immutable diagnostic identity; appended, prefix ABI unchanged */
} vista_cvpx_frame;

/* Called on Display only. Signal/coalesce consumer work, do not block or close here.
 * A callback may call TakeLatest; GPU completion must return the lease. */
typedef void (*vista_cvpx_ready_cb)(void *);
typedef struct {
    uint64_t session_checks, hardware_verified, hardware_rejected;
    int32_t last_status;
    uint32_t last_codec;
    bool last_using_hardware;
} vista_cvpx_vt_diagnostics;
VLC_API void vista_cvpx_note_vt(vista_cvpx_bridge *, int32_t status, bool using_hw, uint32_t codec);
VLC_API void vista_cvpx_get_vt_diagnostics(vista_cvpx_bridge *, vista_cvpx_vt_diagnostics *);
/* Separate fixed-size ABI; preserves the original successful-session counters.
 * Values are meaningful only after the corresponding count is nonzero.
 * Failure stages: 1 session creation, 2 decode submission, 3 decode callback.
 * All statuses are actual OSStatus returns, never invented failure codes. */
typedef struct {
    uint64_t create_attempts, create_failures, failure_events;
    int32_t last_create_status, last_create_profile, last_failure_status;
    uint32_t last_create_codec, last_failure_stage;
} vista_cvpx_vt_attempt_diagnostics;
VLC_API void vista_cvpx_note_vt_create(vista_cvpx_bridge *, int32_t status,
                                      uint32_t codec, int32_t profile);
VLC_API void vista_cvpx_note_vt_failure(vista_cvpx_bridge *, int32_t status, uint32_t stage);
VLC_API void vista_cvpx_get_vt_attempt_diagnostics(vista_cvpx_bridge *, vista_cvpx_vt_attempt_diagnostics *);

/* Independent bounded pipeline ABI. Counts saturate, never retain media/paths.
 * rejected is a local branch outcome; status is an actual return, or 0 when none.
 * Each bucket preserves the last observation AND last rejection, so later success
 * cannot erase the reason for a lost frame. No per-frame logs or behavior changes. */
typedef enum {
    VISTA_PIPE_SUBMIT = 0,
    VISTA_PIPE_CALLBACK = 1,
    VISTA_PIPE_CALLBACK_DISCARD = 2,
    VISTA_PIPE_CALLBACK_NULL = 3,
    VISTA_PIPE_CALLBACK_ABORT = 4,
    VISTA_PIPE_FORMAT = 5,
    VISTA_PIPE_CALLBACK_BAD_PTS = 6,
    VISTA_PIPE_CALLBACK_ZERO_SIZE = 7,
    VISTA_PIPE_NEW_PICTURE = 8,
    VISTA_PIPE_ATTACH = 9,
    VISTA_PIPE_DPB_INSERT = 10,
    VISTA_PIPE_QUEUE_VIDEO = 11,
    VISTA_PIPE_VOUT_OPEN = 12,
    VISTA_PIPE_VOUT_UPDATE = 13,
    VISTA_PIPE_VOUT_PREPARE = 14,
    VISTA_PIPE_VOUT_DISPLAY = 15,
    VISTA_PIPE_BRIDGE_PREPARE = 16,
    VISTA_PIPE_BRIDGE_DISPLAY = 17,
    VISTA_PIPE_BRIDGE_TAKE = 18,
    VISTA_PIPE_CALLBACK_DROPPED = 19,
    VISTA_PIPE_COUNT = 20
} vista_cvpx_pipeline_event;
typedef struct {
    uint64_t count, rejected;
    int32_t last_status, last_reject_status;
    uint32_t last_detail, last_reject_detail;
    uint64_t last_value, last_reject_value;
} vista_cvpx_pipeline_bucket;
typedef struct {
    vista_cvpx_pipeline_bucket events[VISTA_PIPE_COUNT];
    uint32_t first_rejected_event_plus1; /* 0 means none; otherwise event index + 1 */
    int32_t first_reject_status;
    uint32_t first_reject_detail;
    uint64_t first_reject_value;
} vista_cvpx_pipeline_diagnostics;
VLC_API void vista_cvpx_note_pipeline(vista_cvpx_bridge *, vista_cvpx_pipeline_event,
                                      bool rejected, int32_t status, uint32_t detail, uint64_t value);
VLC_API void vista_cvpx_get_pipeline_diagnostics(vista_cvpx_bridge *, vista_cvpx_pipeline_diagnostics *);

VLC_API vista_cvpx_bridge *vista_cvpx_create(vista_cvpx_ready_cb, void *);
/* Requires a fully stopped player, closed producer, and returned leases. */
VLC_API bool vista_cvpx_destroy(vista_cvpx_bridge *);

/* Exactly one producer lifetime. The token NEVER changes within that vout.
 * Reopening after seek requires stopping/closing the old producer first.
 * No API here can relabel old queued pictures as belonging to a new generation. */
VLC_API bool vista_cvpx_attach(vista_cvpx_bridge *, uint64_t *producer_generation);
VLC_API void vista_cvpx_detach(vista_cvpx_bridge *, uint64_t producer_generation);
/* Two-phase stop: close admission, flush/cancel renderer, then wait off its queue. */
VLC_API void vista_cvpx_quiesce(vista_cvpx_bridge *);
VLC_API void vista_cvpx_wait_drained(vista_cvpx_bridge *);
/* Close admission, drop pending slots and wait for callback + leased/GPU frame.
 * Call from a control queue, never the consumer/GPU-completion executor.
 * Does not detach/rearm producer. Existing producer tokens remain stale. */
VLC_API void vista_cvpx_quiesce_and_drain(vista_cvpx_bridge *);

VLC_API bool vista_cvpx_prepare(vista_cvpx_bridge *, uint64_t, uintptr_t identity,
                       CVPixelBufferRef, const video_format_t *, const video_format_t *,
                       vlc_tick_t pts, vlc_tick_t deadline,
                       video_projection_mode_t, vlc_stereoscopic_mode_t,
                       bool progressive, bool left_eye, unsigned fields);
VLC_API bool vista_cvpx_display(vista_cvpx_bridge *, uint64_t, uintptr_t identity,
                       vlc_tick_t display_tick);
/* At most one checked-out lease. If busy, leave newest ready frame in its slot. */
VLC_API const vista_cvpx_frame *vista_cvpx_take_latest(vista_cvpx_bridge *);
VLC_API bool vista_cvpx_is_current(vista_cvpx_bridge *, const vista_cvpx_frame *);
/* Must be called exactly once, after all renderer/GPU uses have completed. */
VLC_API bool vista_cvpx_release(vista_cvpx_bridge *, const vista_cvpx_frame *);

#endif
