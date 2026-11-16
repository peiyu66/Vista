#ifndef VLC_PROBE_PIPELINE_INTERNAL_H
#define VLC_PROBE_PIPELINE_INTERNAL_H
#include <vlc_vista_cvpx.h>
#include "VLCProbeBridge.h"
_Static_assert((int)VISTA_PIPE_COUNT == VLCProbePipelineEventCount, "pipeline event count changed");
_Static_assert(VISTA_PIPE_SUBMIT == 0, "pipeline event SUBMIT index changed");
_Static_assert(VISTA_PIPE_CALLBACK == 1, "pipeline event CALLBACK index changed");
_Static_assert(VISTA_PIPE_CALLBACK_DISCARD == 2, "pipeline event CALLBACK_DISCARD index changed");
_Static_assert(VISTA_PIPE_CALLBACK_NULL == 3, "pipeline event CALLBACK_NULL index changed");
_Static_assert(VISTA_PIPE_CALLBACK_ABORT == 4, "pipeline event CALLBACK_ABORT index changed");
_Static_assert(VISTA_PIPE_FORMAT == 5, "pipeline event FORMAT index changed");
_Static_assert(VISTA_PIPE_CALLBACK_BAD_PTS == 6, "pipeline event CALLBACK_BAD_PTS index changed");
_Static_assert(VISTA_PIPE_CALLBACK_ZERO_SIZE == 7, "pipeline event CALLBACK_ZERO_SIZE index changed");
_Static_assert(VISTA_PIPE_NEW_PICTURE == 8, "pipeline event NEW_PICTURE index changed");
_Static_assert(VISTA_PIPE_ATTACH == 9, "pipeline event ATTACH index changed");
_Static_assert(VISTA_PIPE_DPB_INSERT == 10, "pipeline event DPB_INSERT index changed");
_Static_assert(VISTA_PIPE_QUEUE_VIDEO == 11, "pipeline event QUEUE_VIDEO index changed");
_Static_assert(VISTA_PIPE_VOUT_OPEN == 12, "pipeline event VOUT_OPEN index changed");
_Static_assert(VISTA_PIPE_VOUT_UPDATE == 13, "pipeline event VOUT_UPDATE index changed");
_Static_assert(VISTA_PIPE_VOUT_PREPARE == 14, "pipeline event VOUT_PREPARE index changed");
_Static_assert(VISTA_PIPE_VOUT_DISPLAY == 15, "pipeline event VOUT_DISPLAY index changed");
_Static_assert(VISTA_PIPE_BRIDGE_PREPARE == 16, "pipeline event BRIDGE_PREPARE index changed");
_Static_assert(VISTA_PIPE_BRIDGE_DISPLAY == 17, "pipeline event BRIDGE_DISPLAY index changed");
_Static_assert(VISTA_PIPE_BRIDGE_TAKE == 18, "pipeline event BRIDGE_TAKE index changed");
_Static_assert(VISTA_PIPE_CALLBACK_DROPPED == 19, "pipeline event CALLBACK_DROPPED index changed");
static inline VLCProbePipelineDiagnostics VLCProbeMapPipeline(const vista_cvpx_pipeline_diagnostics *source) {
    VLCProbePipelineDiagnostics output = {0};
    for (unsigned i = 0; i < VLCProbePipelineEventCount; ++i) {
        const vista_cvpx_pipeline_bucket *s = &source->events[i];
        output.events[i] = (VLCProbePipelineBucket){
            .count=s->count, .rejected=s->rejected,
            .last_status=s->last_status, .last_reject_status=s->last_reject_status,
            .last_detail=s->last_detail, .last_reject_detail=s->last_reject_detail,
            .last_value=s->last_value, .last_reject_value=s->last_reject_value};
    }
    output.first_rejected_event_plus1=source->first_rejected_event_plus1;
    output.first_reject_status=source->first_reject_status;
    output.first_reject_detail=source->first_reject_detail;
    output.first_reject_value=source->first_reject_value;
    return output;
}
#endif
