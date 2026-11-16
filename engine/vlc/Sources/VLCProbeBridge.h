#ifndef VISTA_VLC_PROBE_BRIDGE_H
#define VISTA_VLC_PROBE_BRIDGE_H
#include <CoreVideo/CoreVideo.h>
#include <stdint.h>
#include <stdbool.h>

/* Swift-facing envelope only. No VLC structs or pointer identity escape. */
typedef struct VLCProbeEngine VLCProbeEngine;
typedef struct VLCProbeSnapshot VLCProbeSnapshot;
typedef struct {
    uint32_t chroma, coded_width, coded_height, visible_width, visible_height;
    uint32_t x_offset, y_offset, sar_num, sar_den, frame_rate, frame_rate_base;
    int32_t orientation, primaries, transfer, matrix, range, chroma_location;
    int32_t projection, multiview;
    bool right_eye_first;
    float pose_yaw, pose_pitch, pose_roll, pose_fov;
    uint16_t mastering_primaries[6], mastering_white[2];
    uint32_t mastering_max_luminance, mastering_min_luminance;
    uint16_t max_cll, max_fall;
    uint8_t dovi_major, dovi_minor, dovi_profile, dovi_level;
    uint8_t dovi_rpu, dovi_el, dovi_bl, dovi_compatibility, dovi_compression;
    uint32_t cubemap_padding;
} VLCProbeFormat;
typedef struct {
    VLCProbeFormat source, picture;
    int64_t raw_pts, tick_zero, ticks_per_second, initial_deadline, display_tick;
    uint64_t producer_generation, trace_frame_id;
    int32_t requested_projection, requested_stereo;
    bool progressive, left_eye;
    uint32_t fields;
} VLCProbeMetadata;
typedef struct {
    uint64_t frames_taken, vt_checks, vt_hardware, vt_rejected;
    int32_t last_vt_status, state;
    uint32_t last_codec, source_opens, source_closes;
    bool last_using_hardware, player_error, ended;
    /* Additive diagnostics: these do not change the hardware-query fields above. */
    uint64_t vt_create_attempts, vt_create_failures, vt_failure_events;
    int32_t vt_last_create_status, vt_last_create_profile, vt_last_failure_status;
    uint32_t vt_last_create_codec, vt_last_failure_stage;
    bool audio_native_selected, audio_native_opened;
    uint32_t audio_error_logs, audio_timing_logs;
} VLCProbeDiagnostics;

/* Independent fixed-size scalar ABI; original hardware/attempt envelope is unchanged. */
enum { VLCProbePipelineEventCount = 20 };
typedef struct {
    uint64_t count, rejected;
    int32_t last_status, last_reject_status;
    uint32_t last_detail, last_reject_detail;
    uint64_t last_value, last_reject_value;
} VLCProbePipelineBucket;
typedef struct {
    VLCProbePipelineBucket events[VLCProbePipelineEventCount];
    uint32_t first_rejected_event_plus1;
    int32_t first_reject_status;
    uint32_t first_reject_detail;
    uint64_t first_reject_value;
} VLCProbePipelineDiagnostics;
VLCProbePipelineDiagnostics VLCProbeEnginePipelineDiagnostics(VLCProbeEngine *);

/* All operations must be serialized off MainActor, except snapshot access/release.
 * Only the caller-selected bundled synthetic file is supplied. No URL/network API. */
VLCProbeEngine *VLCProbeEngineCreate(const char *path);
VLCProbeEngine *VLCProbeEngineCreateWithAudio(const char *path, bool audio);
int VLCProbeEnginePlay(VLCProbeEngine *);
VLCProbeSnapshot *VLCProbeEngineTakeSnapshot(VLCProbeEngine *);
VLCProbeDiagnostics VLCProbeEngineDiagnostics(VLCProbeEngine *);
/* Closes admission, synchronously stops/releases player, drains leases, destroys bridge.
 * This does NOT wait for independently retained CVPixelBuffers to become unused. */
bool VLCProbeEngineDestroy(VLCProbeEngine *);
VLCProbeMetadata VLCProbeSnapshotMetadata(const VLCProbeSnapshot *);
CVPixelBufferRef VLCProbeSnapshotCopyPixel(const VLCProbeSnapshot *) CF_RETURNS_RETAINED;
void VLCProbeSnapshotRelease(VLCProbeSnapshot *);
#endif
