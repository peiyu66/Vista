#ifndef VISTA_AUDIO_BOUNDARY_H
#define VISTA_AUDIO_BOUNDARY_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct libvlc_media_player_t libvlc_media_player_t;
#define VISTA_AUDIO_BOUNDARY_ABI 2u
#define VISTA_AUDIO_BOUNDARY_EPISODES 8u
/* Native VLC monotonic microseconds, NOT Date/Swift uptime. Zero means absent,
 * and validity bits are authoritative. No URI, filename, pointer, or media data. */
enum { VAB_OK=0, VAB_BUSY=1, VAB_UNAVAILABLE=2, VAB_INVALID=3 };
enum { VAB_COMMAND=1u, VAB_CHANGE=2u, VAB_BLOCK=4u, VAB_ENQUEUE=8u,
       VAB_REPORT=16u, VAB_REJECT=32u, VAB_ACCEPT=64u, VAB_WATCH=128u, VAB_WATCH_OFFSET=256u };
enum { VAB_OPEN=0, VAB_SUPERSEDED=1, VAB_PAUSE=2, VAB_SEEK=3,
       VAB_SOURCE=4, VAB_STOP=5, VAB_STREAM_END=6, VAB_TIMING_RESET=7 };
typedef struct {
    uint64_t instance_id, episode_id, session_id, command_id;
    uint32_t valid, end_reason;
    double requested_rate, audio_rate;
    int64_t command_us, change_us, block_us, boundary_system_us, boundary_audio_us;
    int64_t enqueue_us, enqueue_date_us, fifo_after_enqueue_us, block_length_us;
    int64_t first_report_us, first_report_system_us, first_report_audio_us;
    int64_t last_report_us, last_report_system_us, last_report_audio_us;
    int64_t first_reject_us, first_reject_system_us, last_reject_us, last_reject_system_us;
    int64_t accept_us, accept_system_us, accept_audio_us, accept_clock_audio_us;
    int64_t watch_us, watch_system_us, watch_audio_us, watch_accept_us;
    int64_t end_us;
    uint64_t report_count, reject_count, accept_count;
    /* watch_audio_us is player-normalized; this is the matched raw native PTS.
     * offset = native minus normalized, valid only with VAB_WATCH_OFFSET. */
    int64_t watch_native_audio_us, watch_pts_offset_us;
} vista_audio_boundary_episode;
typedef struct {
    uint32_t abi_version, status;
    uint64_t instance_id, episode_id;
    int64_t command_us;
} vista_audio_boundary_mark;
typedef struct {
    uint32_t abi_version, status, count, stream_closed;
    /* dropped_events == UINT64_MAX: per-instance loss is unlocalizable.
     * global_dropped_events is exact process-wide failed diagnostic acquisitions. */
    uint64_t instance_id, overwritten_episodes, dropped_events, global_dropped_events;
    uint64_t registration_failures;
    int64_t snapshot_us;
    vista_audio_boundary_episode episodes[VISTA_AUDIO_BOUNDARY_EPISODES];
} vista_audio_boundary_snapshot_data;
/* Call immediately BEFORE the normal setter, on a non-render/control thread.
 * session_id identifies the engine/source generation; IDs are anonymous.
 * No active native stream, ambiguity or contention is reported, never guessed.
 * Caller must retain player for this call, as with normal libvlc API calls. */
int vista_audio_boundary_mark_command(libvlc_media_player_t *player,
    uint64_t session_id, uint64_t command_id, double rate,
    vista_audio_boundary_mark *out);
/* Bounded nonblocking snapshot. Closed stream history remains until its registry
 * slot is reused; stale instance IDs then return UNAVAILABLE, never a new ID. */
int vista_audio_boundary_snapshot(uint64_t instance_id,
    vista_audio_boundary_snapshot_data *out);
/* Use native libvlc_clock() at official watch callback entry. Records only the
 * first exact instance/rate/system match to this episode's accepted timing
 * report. Watch PTS has a player-normalized origin, distinct from native PTS.
 * No player lookup or locks that wait. Safe from native callback. */
void vista_audio_boundary_watch(uint64_t instance_id, int64_t callback_us,
    double rate, int64_t audio_us, int64_t system_us);
/* Mark interruption BEFORE the existing pause/seek/stop/source action. No effect
 * on playback. Matching command only; 0 closes all open episodes for instance.
 * Returns BUSY if evidence marker could not be recorded. Bridge must also gate
 * watch attribution after interruption regardless of this return value. */
int vista_audio_boundary_finish(uint64_t instance_id, uint64_t command_id,
    uint32_t reason);
#ifdef __cplusplus
}
#endif
#endif
