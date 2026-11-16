/* Private bounded recovery evidence. v1 layout remains supported; v2 adds the
 * exact clock mapping used by the same late-drop event. */
#ifndef VLC_VISTA_RECOVERY_H
#define VLC_VISTA_RECOVERY_H
#include <vlc_common.h>
#include <vlc_tick.h>
typedef struct vista_cvpx_bridge vista_cvpx_bridge;
typedef struct {
    uint32_t version, size;
    uint64_t queue_count, queue_valid, queue_invalid, queue_repeat, queue_backward;
    uint64_t delivery_admitted, delivery_invalid, delivery_no_vout, delivery_wait_abort;
    uint64_t delivery_flush_abort, delivery_preroll, delivery_prevframe;
    uint64_t fifo_pop, fifo_empty, late_drop, render_normal, render_forced, render_redisplay;
    int64_t queue_pts, queue_tick, popped_pts, drop_pts, drop_tick;
    int64_t drop_system_delta, drop_process, drop_threshold;
    double drop_rate;
    uint32_t drop_clock_id, reserved;
} vista_recovery_snapshot;
typedef struct {
    vista_recovery_snapshot base;
    double drop_context_rate;
    uint64_t drop_reference_generation;
    uint32_t drop_context_valid, reserved;
} vista_recovery_snapshot_v2;
VLC_API void vista_cvpx_note_late_context(vista_cvpx_bridge *,
    vlc_tick_t pts, vlc_tick_t tick, vlc_tick_t delta, vlc_tick_t process,
    vlc_tick_t threshold, double rate, uint32_t clock_id,
    double context_rate, uint64_t reference_generation);
typedef enum {
    VISTA_REC_QUEUE, VISTA_REC_ADMITTED, VISTA_REC_INVALID, VISTA_REC_NO_VOUT,
    VISTA_REC_WAIT_ABORT, VISTA_REC_FLUSH_ABORT, VISTA_REC_PREROLL, VISTA_REC_PREVFRAME,
    VISTA_REC_POP, VISTA_REC_EMPTY, VISTA_REC_LATE_DROP,
    VISTA_REC_RENDER_NORMAL, VISTA_REC_RENDER_FORCED, VISTA_REC_RENDER_REDISPLAY
} vista_recovery_event;
VLC_API void vista_cvpx_note_recovery(vista_cvpx_bridge *, vista_recovery_event,
    vlc_tick_t pts, vlc_tick_t tick, vlc_tick_t delta, vlc_tick_t process,
    vlc_tick_t threshold, double rate, uint32_t clock_id);
/* Exact size/version protects callers from accidental incompatible layouts. */
VLC_API bool vista_cvpx_get_recovery(vista_cvpx_bridge *, uint32_t version,
    void *out, size_t size);
#endif
