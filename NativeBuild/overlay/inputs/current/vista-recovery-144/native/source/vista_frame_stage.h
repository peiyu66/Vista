#ifndef VISTA_FRAME_STAGE_H
#define VISTA_FRAME_STAGE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct libvlc_media_player_t libvlc_media_player_t;
#define VISTA_FRAME_STAGE_ABI 2u
#define VFS_WINDOW_US INT64_C(3500000)
#define VFS_SAMPLE_COUNT 4u
enum { VFS_OK=0,VFS_BUSY=1,VFS_UNAVAILABLE=2,VFS_INVALID=3 };
enum { VFS_OPEN=0,VFS_SUPERSEDED=1,VFS_PAUSE=2,VFS_SEEK=3,VFS_SOURCE=4,VFS_STOP=5,VFS_STREAM_END=6,VFS_WINDOW_END=7 };
enum { VFS_DECODE_ENTER,VFS_PACER_BEGIN,VFS_PACER_END,VFS_SUBMIT_BEGIN,VFS_SUBMIT_RETURN,VFS_CALLBACK_ENTER,VFS_CALLBACK_LOCKED,VFS_PICTURE_BEGIN,VFS_PICTURE_END,VFS_DPB_INSERT,VFS_DPB_EXIT,VFS_QUEUE_ENTER,VFS_QUEUE_LOCKED,VFS_FIFO_PUSH_RETURN,VFS_PREPARE,VFS_DROP,VFS_COMPRESSED_ENQUEUE,VFS_COMPRESSED_DEQUEUE,VFS_STAGE_COUNT };
/* sample slots: first prepared, first dropped, latest dropped, slowest observed (may be pending).
 * Same frame can occupy multiple slots. stage_mask alone establishes presence.
 * Native monotonic microseconds; pts is native media ticks, NOT wall time.
 * FIFO_PUSH_RETURN is picture_fifo_Push return while the FIFO lock remains
 * held, before unlock. The same-FIFO consumer cannot Prepare before this hook.
 * It is not outer vout_PutPicture return. VT callback may precede submit return.
 * Missing/uncompleted stage is absent, never infer success from a zero value.
 * frame_id is immutable within (instance_id,episode_id,decoder_generation).
 * No pointers, paths or user content exported. */
enum { VFS_META_DEADLINE=1u, VFS_META_DROP=2u, VFS_META_SUBMIT=4u, VFS_META_CALLBACK=8u, VFS_META_CONTEXT=16u, VFS_META_RATE=32u, VFS_META_REFERENCE=64u, VFS_META_OUTPUT_PTS=128u, VFS_META_CONTEXT_RATE=256u };
enum { VFS_PENDING=0, VFS_PREPARED=1, VFS_DROPPED=2 };
/* queue mask: 1 matched enqueue; 2 dequeue; 4 complete preceding loop interval.
 * Counts/bytes at enqueue are BEFORE adding this chain; dequeue AFTER removal.
 * loop[] = previous ProcessInput return, control, empty FIFO wait, paused wait (us).
 * Loop measures the immediately preceding decoder iteration, NOT queue residence.
 * queue ID is lifetime-unique for this decoder; epoch advances on FIFO flush. */
typedef struct {
 uint64_t id,epoch,enqueue_depth,dequeue_depth,enqueue_bytes,dequeue_bytes,lost;
 int64_t enqueue_us,dequeue_us,loop[4];
 uint32_t mask;
} vfs_queue_info;
typedef struct {
 uint64_t frame_id,decoder_generation,stage_mask;
 int64_t pts,ticks[VFS_STAGE_COUNT];
 int64_t deadline_us,threshold_us,processing_us;
 int64_t output_pts; /* actual decoded->date at Prepare, may differ from input pts */
 uint64_t reference_generation; /* actual observed Convert reference */
 uint32_t outcome,metadata_mask;
 int32_t submit_status,callback_status;
 uint32_t callback_flags,context_id;
 double video_rate,context_rate;
 vfs_queue_info queue;
} vista_frame_stage_sample;
typedef struct {uint32_t abi_version,status;uint64_t instance_id,episode_id;int64_t armed_us;} vista_frame_stage_mark;
typedef struct {
 uint32_t abi_version,status,end_reason,sample_mask;
 uint64_t instance_id,episode_id,session_id,command_id,revision,seek_nonce;
 int64_t armed_us,end_us,snapshot_us;
 uint64_t frames_started,frames_prepared,frames_dropped,capacity_lost,contention_lost,stale_events;
 vista_frame_stage_sample samples[VFS_SAMPLE_COUNT];
} vista_frame_stage_snapshot_data;
/* 144: independent, tiny current compressed-input pressure snapshot. Not tied
 * to the 3.5s frame-stage episode. Complete successful VT inputs only; native
 * monotonic microseconds and native media PTS. Snapshot never waits on decode.
 * completed/pacer_us are cumulative within decoder_generation + queue_epoch;
 * queue_id identifies the input, not an output/display count. */
#define VISTA_QUEUE_PRESSURE_ABI 1u
typedef struct {
 uint32_t abi_version,status;
 uint64_t decoder_generation,queue_epoch,queue_id,dequeue_depth,completed,pacer_us,lost;
 int64_t snapshot_us,enqueue_us,dequeue_us,completed_us,pts;
} vista_queue_pressure_snapshot_data;
int vista_queue_pressure_snapshot(libvlc_media_player_t *,vista_queue_pressure_snapshot_data *);
/* Arm immediately before an existing rate command. Separate window from audio
 * and paused-resume diagnostics; audio completion MUST NOT end this window.
 * No playback action. Snapshot auto-expires at armed+3.5s; explicit pause/seek/
 * source/stop ends it. New arm supersedes, old IDs cannot annotate new window. */
int vista_frame_stage_arm(libvlc_media_player_t *,uint64_t session,uint64_t command,uint64_t revision,uint64_t seek_nonce,vista_frame_stage_mark *);
int vista_frame_stage_snapshot(uint64_t instance,uint64_t episode,vista_frame_stage_snapshot_data *);
int vista_frame_stage_end(uint64_t instance,uint64_t episode,uint32_t reason);
#ifdef __cplusplus
}
#endif
#endif
