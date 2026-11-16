#ifndef VISTA_VT_SAMPLE168_H
#define VISTA_VT_SAMPLE168_H
/* Decoder-thread-only diagnostics. Never retain a sample, pixel or callback refcon. */
#include <stdint.h>
#include <stdbool.h>
#include <limits.h>
#include <CoreMedia/CoreMedia.h>
#include "flow/vista_flow_trace.h"

typedef struct {
    uint64_t flow_session, owner, context, session_generation, format_generation, epoch;
    uint64_t seen, zero, positive, negative;
    int64_t min_length, max_length;
    unsigned selected, packets, epoch_seen, epoch_slow, errors, summaries, contexts;
    bool format_dirty, saw_preroll, normal_after_preroll, final_summary;
    uint32_t requested_pixel_format;
    unsigned coded_width, coded_height, destination_attribute_bits;
} vista_vt_sample168;

static inline void vvs168_inc(uint64_t *n) { if (*n < INT64_MAX) ++*n; }
static inline void vvs168_epoch(vista_vt_sample168 *s)
{
    vvs168_inc(&s->epoch);
    s->epoch_seen = s->epoch_slow = 0;
    s->saw_preroll = s->normal_after_preroll = false;
}
static inline void vvs168_format(vista_vt_sample168 *s)
{
    vvs168_inc(&s->format_generation);
    s->format_dirty = true;
    s->context = 0;
}
static inline void vvs168_session(vista_vt_sample168 *s)
{
    vvs168_inc(&s->session_generation);
    s->format_dirty = true;
    s->context = 0;
    vvs168_epoch(s);
}
/* Counts describe submitted samples, including frames outside diagnostic capture. */
static inline unsigned vvs168_select(vista_vt_sample168 *s, int64_t length,
                                    int64_t wall_us, int32_t status, bool preroll, bool recordable)
{
    if (s->seen == 0) s->min_length = s->max_length = length;
    if (length < s->min_length) s->min_length = length;
    if (length > s->max_length) s->max_length = length;
    vvs168_inc(&s->seen);
    vvs168_inc(length == 0 ? &s->zero : length > 0 ? &s->positive : &s->negative);
    if (preroll) s->saw_preroll = true;
    if (!recordable || s->selected >= 64) return 0;
    unsigned reason = 0;
    if (s->epoch_seen < 4) { ++s->epoch_seen; reason = 1; }
    else if (!preroll && s->saw_preroll && !s->normal_after_preroll) { reason = 4; }
    else if (status != 0 && s->errors < 4) { ++s->errors; reason = 2; }
    else if (wall_us >= 10000 && s->epoch_slow < 4) { ++s->epoch_slow; reason = 3; }
    if (reason) {
        ++s->selected;
        if (!preroll && s->saw_preroll) s->normal_after_preroll = true;
    }
    return reason;
}
static inline void vvs168_time(uint64_t id, uint32_t stage, CMTime t)
{
    VFEmit(id, stage, VF_POINT, 0, t.value, t.timescale, t.flags);
}
/* Called only after pure API/CPU/outer-submit end markers; sample is still owned
 * by DecodeBlock. The synchronous callback may already have freed p_info. */
static inline void vvs168_sample(vista_vt_sample168 *s, uint64_t frame,
                                CMSampleBufferRef sample, int64_t length,
                                int64_t pts, int64_t dts, size_t block_bytes,
                                int64_t wall_us, int32_t status, bool preroll)
{
    uint64_t flow_session = VFSession();
    if (s->flow_session != flow_session) {
        s->flow_session = flow_session;
        s->owner = 0;
        s->format_dirty = true;
        s->context = 0;
    }
    unsigned reason = vvs168_select(s, length, wall_us, status, preroll,
                                    frame != 0 && flow_session != 0);
    if (!reason) return;
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    if ((!s->owner || s->format_dirty) && s->contexts < 16) {
        CMVideoDimensions dimensions = format ? CMVideoFormatDescriptionGetDimensions(format)
                                              : (CMVideoDimensions){0, 0};
        uint32_t codec = format ? CMFormatDescriptionGetMediaSubType(format) : 0;
        if (!s->owner)
            s->owner = VFNew(VF_VT_FORMAT_IDENTITY, VF_POINT, frame,
                             6, flow_session, 0);
        if (!s->owner) return;
        s->context = VFNew(VF_VT_FORMAT_IDENTITY, VF_POINT, s->owner,
                           0, codec, s->requested_pixel_format);
        if (!s->context) return;
        VFEmit(s->context, VF_VT_FORMAT_IDENTITY, VF_POINT, 0, 1, s->coded_width, s->coded_height);
        VFEmit(s->context, VF_VT_FORMAT_IDENTITY, VF_POINT, 0, 2, dimensions.width, dimensions.height);
        VFEmit(s->context, VF_VT_FORMAT_IDENTITY, VF_POINT, 0, 3, s->session_generation, s->format_generation);
        VFEmit(s->context, VF_VT_FORMAT_IDENTITY, VF_POINT, 0, 4, s->destination_attribute_bits, 16);
        ++s->contexts;
        s->format_dirty = false;
    }
    if (!s->owner) return;
    uint64_t id = VFNew(VF_VT_SAMPLE_CONTEXT, VF_POINT, frame,
                        s->context, s->session_generation, s->format_generation);
    if (!id) return;
    ++s->packets;
    VFEmit(id, VF_VT_FORMAT_IDENTITY, VF_POINT, 0, 5, s->epoch,
           ((int64_t)reason << 32) | s->selected);
    VFEmit(id, VF_VT_INPUT_TIMING, VF_POINT, 0, length, pts, dts);
    CMTime duration = CMSampleBufferGetDuration(sample);
    CMTime presentation = CMSampleBufferGetPresentationTimeStamp(sample);
    CMTime decode = CMSampleBufferGetDecodeTimeStamp(sample);
    vvs168_time(id, VF_VT_SAMPLE_DURATION, duration);
    vvs168_time(id, VF_VT_SAMPLE_PTS, presentation);
    vvs168_time(id, VF_VT_SAMPLE_DTS, decode);
    VFEmit(id, VF_VT_SAMPLE_EPOCHS, VF_POINT, 0, duration.epoch, presentation.epoch, decode.epoch);
    size_t total = CMSampleBufferGetTotalSampleSize(sample);
    VFEmit(id, VF_VT_SAMPLE_SHAPE, VF_POINT, 0,
           total <= INT64_MAX ? (int64_t)total : -1,
           CMSampleBufferGetNumSamples(sample),
           block_bytes <= INT64_MAX ? (int64_t)block_bytes : -1);
}
/* At most 16 intermediate summaries plus one final CloseDecoder summary. */
static inline void vvs168_summary(vista_vt_sample168 *s, unsigned reason)
{
    if (!s->owner || s->flow_session != VFSession()) return;
    if (reason == 3) {
        if (s->final_summary) return;
        s->final_summary = true;
    } else if (s->summaries >= 16) return;
    ++s->summaries;
    VFEmit(s->owner, VF_VT_SAMPLE_SUMMARY, VF_POINT, 0, 1, s->seen, s->selected);
    VFEmit(s->owner, VF_VT_SAMPLE_SUMMARY, VF_POINT, 0, 2, s->zero, s->positive);
    VFEmit(s->owner, VF_VT_SAMPLE_SUMMARY, VF_POINT, 0, 3, s->negative, s->min_length);
    VFEmit(s->owner, VF_VT_SAMPLE_SUMMARY, VF_POINT, 0, 4, s->max_length, s->epoch);
    VFEmit(s->owner, VF_VT_SAMPLE_SUMMARY, VF_POINT, 0, 5, reason, s->summaries);
    VFEmit(s->owner, VF_VT_SAMPLE_SUMMARY, VF_POINT, 0, 6, s->packets, s->seen - s->packets);
}
#endif
