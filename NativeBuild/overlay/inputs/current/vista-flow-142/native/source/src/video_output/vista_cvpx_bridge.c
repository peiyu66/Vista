#include "flow/vista_flow_trace.h"
#ifdef HAVE_CONFIG_H
# include "config.h"
#endif
#include <vlc_vista_cvpx.h>
#include <pthread.h>
#include <vlc_vista_recovery.h>

struct vista_cvpx_bridge {
    pthread_mutex_t mutex;
    pthread_cond_t drained;
    uint64_t generation, producer;
    bool attached, accepting;
    unsigned callbacks;
    vista_cvpx_frame *prepared, *ready, *leased;
    vista_cvpx_ready_cb notify;
    void *opaque;
    vista_cvpx_vt_diagnostics vt;
    vista_cvpx_vt_attempt_diagnostics vt_attempts;
    vista_cvpx_pipeline_diagnostics pipeline;
    vista_recovery_snapshot recovery;
    double drop_context_rate;
    uint64_t drop_reference_generation;
    bool drop_context_valid;
};

static void note_locked(vista_cvpx_bridge *b, vista_cvpx_pipeline_event event,
                        bool rejected, int32_t status, uint32_t detail, uint64_t value)
{
    if(event>=VISTA_PIPE_BRIDGE_PREPARE && event<=VISTA_PIPE_BRIDGE_TAKE)VFNew(VF_STATE,VF_POINT,VFParent(),event,detail,rejected);
    vista_cvpx_pipeline_bucket *v = &b->pipeline.events[event];
    if (v->count != UINT64_MAX) ++v->count;
    v->last_status = status; v->last_detail = detail; v->last_value = value;
    if (rejected) {
        if (!b->pipeline.first_rejected_event_plus1) {
            b->pipeline.first_rejected_event_plus1 = event + 1;
            b->pipeline.first_reject_status = status;
            b->pipeline.first_reject_detail = detail;
            b->pipeline.first_reject_value = value;
        }
        if (v->rejected != UINT64_MAX) ++v->rejected;
        v->last_reject_status = status; v->last_reject_detail = detail; v->last_reject_value = value;
    }
}

void vista_cvpx_note_pipeline(vista_cvpx_bridge *b, vista_cvpx_pipeline_event event,
                              bool rejected, int32_t status, uint32_t detail, uint64_t value)
{
    if (!b || event < 0 || event >= VISTA_PIPE_COUNT) return;
    pthread_mutex_lock(&b->mutex);
    note_locked(b, event, rejected, status, detail, value);
    pthread_mutex_unlock(&b->mutex);
}

void vista_cvpx_get_pipeline_diagnostics(vista_cvpx_bridge *b, vista_cvpx_pipeline_diagnostics *out)
{
    if (!out) return;
    if (!b) { memset(out, 0, sizeof(*out)); return; }
    pthread_mutex_lock(&b->mutex);
    *out = b->pipeline;
    pthread_mutex_unlock(&b->mutex);
}


static void recovery_inc(uint64_t *value) { if (*value != UINT64_MAX) ++*value; }
void vista_cvpx_note_recovery(vista_cvpx_bridge *b, vista_recovery_event event,
    vlc_tick_t pts, vlc_tick_t tick, vlc_tick_t delta, vlc_tick_t process,
    vlc_tick_t threshold, double rate, uint32_t clock_id)
{
    if (!b) return;
    pthread_mutex_lock(&b->mutex);
    vista_recovery_snapshot *s = &b->recovery;
    switch (event) {
    case VISTA_REC_QUEUE:
        recovery_inc(&s->queue_count); s->queue_tick = tick;
        if (pts == VLC_TICK_INVALID) recovery_inc(&s->queue_invalid);
        else {
            if (s->queue_valid && pts == s->queue_pts) recovery_inc(&s->queue_repeat);
            if (s->queue_valid && pts < s->queue_pts) recovery_inc(&s->queue_backward);
            recovery_inc(&s->queue_valid); s->queue_pts = pts;
        }
        break;
#define COUNT(event, field) case event: recovery_inc(&s->field); break
    COUNT(VISTA_REC_ADMITTED, delivery_admitted);
    COUNT(VISTA_REC_INVALID, delivery_invalid);
    COUNT(VISTA_REC_NO_VOUT, delivery_no_vout);
    COUNT(VISTA_REC_WAIT_ABORT, delivery_wait_abort);
    COUNT(VISTA_REC_FLUSH_ABORT, delivery_flush_abort);
    COUNT(VISTA_REC_PREROLL, delivery_preroll);
    COUNT(VISTA_REC_PREVFRAME, delivery_prevframe);
    COUNT(VISTA_REC_EMPTY, fifo_empty);
    COUNT(VISTA_REC_RENDER_NORMAL, render_normal);
    COUNT(VISTA_REC_RENDER_FORCED, render_forced);
    case VISTA_REC_RENDER_REDISPLAY:
        recovery_inc(&s->render_forced); recovery_inc(&s->render_redisplay); break;
    case VISTA_REC_POP: recovery_inc(&s->fifo_pop); s->popped_pts = pts; break;
    case VISTA_REC_LATE_DROP:
        b->drop_context_valid = false; /* old callers cannot imply v2 evidence */
        recovery_inc(&s->late_drop); s->drop_pts = pts; s->drop_tick = tick;
        s->drop_system_delta = delta; s->drop_process = process;
        s->drop_threshold = threshold; s->drop_rate = rate; s->drop_clock_id = clock_id;
        break;
#undef COUNT
    }
    pthread_mutex_unlock(&b->mutex);
}

/* Same mutex and same event as the pre-existing late-drop counters. Control
 * evidence never comes from the lossy Flow recorder or a pointer lookup. */
void vista_cvpx_note_late_context(vista_cvpx_bridge *b,
    vlc_tick_t pts, vlc_tick_t tick, vlc_tick_t delta, vlc_tick_t process,
    vlc_tick_t threshold, double rate, uint32_t clock_id,
    double context_rate, uint64_t reference_generation)
{
    if (!b) return;
    pthread_mutex_lock(&b->mutex);
    vista_recovery_snapshot *s = &b->recovery;
    recovery_inc(&s->late_drop); s->drop_pts = pts; s->drop_tick = tick;
    s->drop_system_delta = delta; s->drop_process = process;
    s->drop_threshold = threshold; s->drop_rate = rate; s->drop_clock_id = clock_id;
    b->drop_context_rate = context_rate;
    b->drop_reference_generation = reference_generation;
    b->drop_context_valid = true;
    pthread_mutex_unlock(&b->mutex);
}

bool vista_cvpx_get_recovery(vista_cvpx_bridge *b, uint32_t version, void *out, size_t size)
{
    if (!b || !out || !((version == 1 && size == sizeof(vista_recovery_snapshot)) ||
                         (version == 2 && size == sizeof(vista_recovery_snapshot_v2)))) return false;
    pthread_mutex_lock(&b->mutex);
    if (version == 1) memcpy(out, &b->recovery, sizeof(b->recovery));
    else {
        vista_recovery_snapshot_v2 value = {
            .base = b->recovery,
            .drop_context_rate = b->drop_context_rate,
            .drop_reference_generation = b->drop_reference_generation,
            .drop_context_valid = b->drop_context_valid,
        };
        value.base.version = 2; value.base.size = sizeof(value);
        memcpy(out, &value, sizeof(value));
    }
    pthread_mutex_unlock(&b->mutex);
    return true;
}

static void drop(vista_cvpx_frame *f)
{
    if (!f) return;
    VFEmit(f->trace_frame_id,VF_MAILBOX_RELEASE,VF_POINT,0,0,0,0);
    CVPixelBufferRelease(f->pixel);
    video_format_Clean(&f->picture_format);
    video_format_Clean(&f->source_format);
    free(f);
}

vista_cvpx_bridge *vista_cvpx_create(vista_cvpx_ready_cb notify, void *opaque)
{
    vista_cvpx_bridge *b = calloc(1, sizeof(*b));
    if (!b) return NULL;
    if (pthread_mutex_init(&b->mutex, NULL)) { free(b); return NULL; }
    if (pthread_cond_init(&b->drained, NULL)) {
        pthread_mutex_destroy(&b->mutex); free(b); return NULL;
    }
    b->recovery.version = 1;
    b->recovery.size = sizeof(b->recovery);
    b->recovery.queue_pts = b->recovery.popped_pts = b->recovery.drop_pts = VLC_TICK_INVALID;
    b->generation = 1;
    b->notify = notify;
    b->opaque = opaque;
    return b;
}

bool vista_cvpx_destroy(vista_cvpx_bridge *b)
{
    if (!b) return true;
    pthread_mutex_lock(&b->mutex);
    bool safe = !b->attached && !b->callbacks && !b->leased;
    if (safe) { drop(b->prepared); drop(b->ready); }
    pthread_mutex_unlock(&b->mutex);
    if (!safe) return false;
    /* Owner guarantees no concurrent entry after player teardown. */
    pthread_cond_destroy(&b->drained);
    pthread_mutex_destroy(&b->mutex);
    free(b);
    return true;
}

bool vista_cvpx_attach(vista_cvpx_bridge *b, uint64_t *token)
{
    if (!b || !token) return false;
    pthread_mutex_lock(&b->mutex);
    bool ok = !b->attached && !b->callbacks && !b->leased
              && b->generation != UINT64_MAX;
    if (ok) {
        b->attached = b->accepting = true;
        *token = b->producer = b->generation;
    }
    pthread_mutex_unlock(&b->mutex);
    return ok;
}

static void close_gate(vista_cvpx_bridge *b)
{
    b->accepting = false;
    if (b->generation != UINT64_MAX) ++b->generation;
    drop(b->prepared); b->prepared = NULL;
    drop(b->ready); b->ready = NULL;
}

static void drain_locked(vista_cvpx_bridge *b)
{
    while (b->callbacks || b->leased)
        pthread_cond_wait(&b->drained, &b->mutex);
}

void vista_cvpx_quiesce(vista_cvpx_bridge *b)
{
    pthread_mutex_lock(&b->mutex);
    close_gate(b);
    pthread_mutex_unlock(&b->mutex);
}

void vista_cvpx_wait_drained(vista_cvpx_bridge *b)
{
    pthread_mutex_lock(&b->mutex);
    drain_locked(b);
    pthread_mutex_unlock(&b->mutex);
}

void vista_cvpx_quiesce_and_drain(vista_cvpx_bridge *b)
{
    vista_cvpx_quiesce(b);
    vista_cvpx_wait_drained(b);
}

void vista_cvpx_detach(vista_cvpx_bridge *b, uint64_t token)
{
    pthread_mutex_lock(&b->mutex);
    if (b->attached && token == b->producer) {
        close_gate(b);
        drain_locked(b);
        b->attached = false;
    }
    pthread_mutex_unlock(&b->mutex);
}

static bool admitted(vista_cvpx_bridge *b, uint64_t token)
{
    return b->attached && b->accepting && token == b->producer
           && token == b->generation;
}

bool vista_cvpx_prepare(vista_cvpx_bridge *b, uint64_t token, uintptr_t identity,
                       CVPixelBufferRef pixel, const video_format_t *fmt,
                       const video_format_t *source, vlc_tick_t pts,
                       vlc_tick_t deadline, video_projection_mode_t projection,
                       vlc_stereoscopic_mode_t stereo, bool progressive,
                       bool left_eye, unsigned fields)
{
    const uint64_t flow=VFFind((void*)identity);
    VFNew(VF_LINK,VF_POINT,flow,1,flow!=0,pts);
    VF_SCOPE(flowPrepare,VF_MAILBOX_PREPARE,flow,pts,deadline,token);
    if (!b) return false;
    pthread_mutex_lock(&b->mutex);
    if (!admitted(b, token)) { note_locked(b, VISTA_PIPE_BRIDGE_PREPARE, true, 0, 1, 0); pthread_mutex_unlock(&b->mutex); return false; }
    drop(b->prepared); b->prepared = NULL;
    /* Validate before retention; an invalid prepare cannot display its predecessor. */
    if (!pixel || !fmt || !source || pts == VLC_TICK_INVALID) {
        note_locked(b, VISTA_PIPE_BRIDGE_PREPARE, true, 0, 2, 0);
        pthread_mutex_unlock(&b->mutex); return false;
    }
    vista_cvpx_frame *f = calloc(1, sizeof(*f));
    if (!f) { note_locked(b, VISTA_PIPE_BRIDGE_PREPARE, true, 0, 3, 0); pthread_mutex_unlock(&b->mutex); return false; }
    if (video_format_Copy(&f->picture_format, fmt) != VLC_SUCCESS ||
        video_format_Copy(&f->source_format, source) != VLC_SUCCESS) {
        /* calloc and Copy leave NULL on allocation failure. */
        video_format_Clean(&f->picture_format);
        video_format_Clean(&f->source_format);
        note_locked(b, VISTA_PIPE_BRIDGE_PREPARE, true, 0, 4, 0);
        free(f); pthread_mutex_unlock(&b->mutex); return false;
    }
    f->trace_frame_id=flow;
    f->pixel = CVPixelBufferRetain(pixel);
    f->media_pts = pts; f->initial_deadline = deadline;
    f->generation = token; f->picture_identity = identity;
    f->requested_projection = projection; f->requested_stereo = stereo;
    f->progressive = progressive; f->left_eye = left_eye; f->fields = fields;
    b->prepared = f;
    note_locked(b, VISTA_PIPE_BRIDGE_PREPARE, false, 0, CVPixelBufferGetPixelFormatType(pixel), fmt->i_chroma);
    pthread_mutex_unlock(&b->mutex);
    return true;
}

bool vista_cvpx_display(vista_cvpx_bridge *b, uint64_t token,
                       uintptr_t identity, vlc_tick_t display_tick)
{
    pthread_mutex_lock(&b->mutex);
    vista_cvpx_frame *f = b->prepared;
    if (!admitted(b, token)) { note_locked(b, VISTA_PIPE_BRIDGE_DISPLAY, true, 0, 1, 0); pthread_mutex_unlock(&b->mutex); return false; }
    b->prepared = NULL;
    if (!f || f->generation != token || f->picture_identity != identity) {
        note_locked(b, VISTA_PIPE_BRIDGE_DISPLAY, true, 0, 2, 0);
        drop(f); pthread_mutex_unlock(&b->mutex); return false;
    }
    VFEmit(f->trace_frame_id,VF_MAILBOX_DISPLAY,VF_POINT,0,display_tick,token,0);
    f->display_tick = display_tick;
    drop(b->ready);
    b->ready = f;
    note_locked(b, VISTA_PIPE_BRIDGE_DISPLAY, false, 0, 0, 0);
    vista_cvpx_ready_cb notify = b->notify;
    if (notify) ++b->callbacks;
    pthread_mutex_unlock(&b->mutex);
    if (notify) {
        notify(b->opaque);
        pthread_mutex_lock(&b->mutex);
        --b->callbacks;
        pthread_cond_broadcast(&b->drained);
        pthread_mutex_unlock(&b->mutex);
    }
    return true;
}

const vista_cvpx_frame *vista_cvpx_take_latest(vista_cvpx_bridge *b)
{
    pthread_mutex_lock(&b->mutex);
    const vista_cvpx_frame *f = NULL;
    if (b->accepting && b->attached && !b->leased && b->ready) {
        f = b->leased = b->ready; b->ready = NULL;
        note_locked(b, VISTA_PIPE_BRIDGE_TAKE, false, 0, 0, 0);
    }
    pthread_mutex_unlock(&b->mutex);
    if(f)VFEmit(f->trace_frame_id,VF_MAILBOX_TAKE,VF_POINT,0,f->media_pts,f->generation,0);
    return f;
}

bool vista_cvpx_is_current(vista_cvpx_bridge *b, const vista_cvpx_frame *f)
{
    pthread_mutex_lock(&b->mutex);
    bool current = f && b->leased == f && admitted(b, f->generation);
    pthread_mutex_unlock(&b->mutex);
    return current;
}

bool vista_cvpx_release(vista_cvpx_bridge *b, const vista_cvpx_frame *f)
{
    pthread_mutex_lock(&b->mutex);
    bool valid = f && b->leased == f;
    if (valid) {
        drop(b->leased); b->leased = NULL;
        pthread_cond_broadcast(&b->drained);
    }
    pthread_mutex_unlock(&b->mutex);
    return valid;
}

void vista_cvpx_note_vt(vista_cvpx_bridge *b, int32_t status, bool hardware, uint32_t codec)
{
    pthread_mutex_lock(&b->mutex);
    ++b->vt.session_checks;
    if (status == 0 && hardware) ++b->vt.hardware_verified;
    else ++b->vt.hardware_rejected;
    b->vt.last_status = status;
    b->vt.last_codec = codec;
    b->vt.last_using_hardware = hardware;
    pthread_mutex_unlock(&b->mutex);
}

void vista_cvpx_get_vt_diagnostics(vista_cvpx_bridge *b, vista_cvpx_vt_diagnostics *out)
{
    pthread_mutex_lock(&b->mutex);
    *out = b->vt;
    pthread_mutex_unlock(&b->mutex);
}

void vista_cvpx_note_vt_create(vista_cvpx_bridge *b, int32_t status,
                              uint32_t codec, int32_t profile)
{
    if (!b) return;
    pthread_mutex_lock(&b->mutex);
    if (b->vt_attempts.create_attempts != UINT64_MAX) ++b->vt_attempts.create_attempts;
    if (status != 0 && b->vt_attempts.create_failures != UINT64_MAX)
        ++b->vt_attempts.create_failures;
    b->vt_attempts.last_create_status = status;
    b->vt_attempts.last_create_codec = codec;
    b->vt_attempts.last_create_profile = profile;
    pthread_mutex_unlock(&b->mutex);
}

void vista_cvpx_note_vt_failure(vista_cvpx_bridge *b, int32_t status, uint32_t stage)
{
    if (!b || status == 0) return;
    pthread_mutex_lock(&b->mutex);
    if (b->vt_attempts.failure_events != UINT64_MAX) ++b->vt_attempts.failure_events;
    b->vt_attempts.last_failure_status = status;
    b->vt_attempts.last_failure_stage = stage;
    pthread_mutex_unlock(&b->mutex);
}

void vista_cvpx_get_vt_attempt_diagnostics(vista_cvpx_bridge *b, vista_cvpx_vt_attempt_diagnostics *out)
{
    pthread_mutex_lock(&b->mutex);
    *out = b->vt_attempts;
    pthread_mutex_unlock(&b->mutex);
}
