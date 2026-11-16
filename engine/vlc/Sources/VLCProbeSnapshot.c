#include "vista_flow_trace.h"
#ifdef HAVE_CONFIG_H
#include "config.h"
#endif
#include <vlc_vista_cvpx.h>
#include "VLCProbeBridge.h"
#include "VLCProbeSnapshotInternal.h"
struct VLCProbeSnapshot {
    CVPixelBufferRef pixel;
    video_format_t source, picture; /* deep copies also preserve optional palette */
    VLCProbeMetadata metadata;
};
static VLCProbeFormat format_copy(const video_format_t *f) {
    VLCProbeFormat m={0};
    m.chroma=f->i_chroma;m.coded_width=f->i_width;m.coded_height=f->i_height;
    m.visible_width=f->i_visible_width;m.visible_height=f->i_visible_height;
    m.x_offset=f->i_x_offset;m.y_offset=f->i_y_offset;m.sar_num=f->i_sar_num;m.sar_den=f->i_sar_den;
    m.frame_rate=f->i_frame_rate;m.frame_rate_base=f->i_frame_rate_base;
    m.orientation=f->orientation;m.primaries=f->primaries;m.transfer=f->transfer;m.matrix=f->space;
    m.range=f->color_range;m.chroma_location=f->chroma_location;
    m.projection=f->projection_mode;m.multiview=f->multiview_mode;m.right_eye_first=f->b_multiview_right_eye_first;
    m.pose_yaw=f->pose.yaw;m.pose_pitch=f->pose.pitch;m.pose_roll=f->pose.roll;m.pose_fov=f->pose.fov;
    memcpy(m.mastering_primaries,f->mastering.primaries,sizeof(m.mastering_primaries));
    memcpy(m.mastering_white,f->mastering.white_point,sizeof(m.mastering_white));
    m.mastering_max_luminance=f->mastering.max_luminance;m.mastering_min_luminance=f->mastering.min_luminance;
    m.max_cll=f->lighting.MaxCLL;m.max_fall=f->lighting.MaxFALL;
    m.dovi_major=f->dovi.version_major;m.dovi_minor=f->dovi.version_minor;m.dovi_profile=f->dovi.profile;
    m.dovi_level=f->dovi.level;m.dovi_rpu=f->dovi.rpu_present;m.dovi_el=f->dovi.el_present;m.dovi_bl=f->dovi.bl_present;
    m.dovi_compatibility=f->dovi.bl_signal_compatibility_id;m.dovi_compression=f->dovi.md_compression;
    m.cubemap_padding=f->i_cubemap_padding;return m;
}
VLCProbeSnapshot *VLCProbeTakeBridgeSnapshot(vista_cvpx_bridge *bridge) {
    const vista_cvpx_frame *f=vista_cvpx_take_latest(bridge);if(!f)return NULL;
    VLCProbeSnapshot *s=NULL;
    if(!vista_cvpx_is_current(bridge,f))goto finish;
    s=calloc(1,sizeof(*s));if(!s)goto finish;
    if(video_format_Copy(&s->source,&f->source_format)!=VLC_SUCCESS||
       video_format_Copy(&s->picture,&f->picture_format)!=VLC_SUCCESS) {
        VLCProbeSnapshotRelease(s);s=NULL;goto finish;
    }
    /* Ownership transfer: independent +1 BEFORE returning the sole mailbox lease.
     * No pixel writes, CPU locks, picture_t retention, or custom recycling pool.
     * VT/CoreVideo must keep this image unavailable for reuse until every owner releases.
     * This lifetime is distinct from the bridge's 3 references and VLC picture pacer. */
    VFNew(VF_LINK,VF_POINT,f->trace_frame_id,2,f->trace_frame_id!=0,f->media_pts);
    s->pixel=CVPixelBufferRetain(f->pixel);
    s->metadata=(VLCProbeMetadata){.source=format_copy(&s->source),.picture=format_copy(&s->picture),
        .raw_pts=f->media_pts,.tick_zero=VLC_TICK_0,.ticks_per_second=CLOCK_FREQ,
        .initial_deadline=f->initial_deadline,.display_tick=f->display_tick,
        .producer_generation=f->generation,.trace_frame_id=f->trace_frame_id,.requested_projection=f->requested_projection,
        .requested_stereo=f->requested_stereo,.progressive=f->progressive,.left_eye=f->left_eye,.fields=f->fields};
finish:
    if(!vista_cvpx_release(bridge,f))abort();
    return s;
}
VLCProbeMetadata VLCProbeSnapshotMetadata(const VLCProbeSnapshot *s){return s->metadata;}
CVPixelBufferRef VLCProbeSnapshotCopyPixel(const VLCProbeSnapshot *s){return CVPixelBufferRetain(s->pixel);}
void VLCProbeSnapshotRelease(VLCProbeSnapshot *s) {
    if(!s)return;if(s->pixel)CVPixelBufferRelease(s->pixel);
    video_format_Clean(&s->source);video_format_Clean(&s->picture);free(s);
}
