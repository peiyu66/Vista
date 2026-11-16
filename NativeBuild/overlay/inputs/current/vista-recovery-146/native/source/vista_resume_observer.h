#ifndef VISTA_RESUME_OBSERVER_H
#define VISTA_RESUME_OBSERVER_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct libvlc_media_player_t libvlc_media_player_t;
#define VISTA_RESUME_OBSERVER_ABI 1u
#define VRR_WINDOW_US INT64_C(3500000)
enum { VRR_OK=0, VRR_BUSY=1, VRR_UNAVAILABLE=2, VRR_INVALID=3 };
enum { VRR_OPEN=0, VRR_SUPERSEDED=1, VRR_PAUSE=2, VRR_SEEK=3, VRR_SOURCE=4, VRR_STOP=5, VRR_STREAM_END=6, VRR_WINDOW_END=7 };
enum { VRR_ROLE_UNKNOWN=0, VRR_ROLE_INPUT_SLAVE=1, VRR_ROLE_INPUT_MASTER=2, VRR_ROLE_OUTPUT_MASTER=3, VRR_ROLE_OUTPUT_SLAVE=4 };
enum vista_resume_slot {
 VRR_INPUT_BEFORE, VRR_INPUT_AFTER, VRR_RESUME_DISPATCH, VRR_RESUME_RETURN,
 VRR_CONTROL_REQUEST, VRR_CONTROL_LOOP, VRR_OUTPUT_DISPATCH, VRR_HOLD_BEFORE,
 VRR_HOLD_AFTER, VRR_OUTPUT_ACK, VRR_DECODE_ENTER, VRR_DECODE_EXIT,
 VRR_REPORT, VRR_REJECT, VRR_ACCEPT, VRR_MASTER_COMPLETE,
 VRR_WATCH_MAX, VRR_WATCH_FINITE, VRR_CONVERT, VRR_DROP_FIRST,
 VRR_DROP_AFTER_MASTER, VRR_DROP_LAST, VRR_FINAL_PLAY, VRR_SLOT_COUNT
};
/* All ticks/system dates are VLC monotonic microseconds. Media/raw audio PTS
 * are native VLC ticks; official watch media is player-normalized microseconds.
 * Presence is explicit: a missing slot/value is NOT a measured zero.
 * present bits0..9 map value[0..9], bit10=rate,11=context_rate,12=role,
 * 13=reason,14=reference_generation. Absent metadata must also stay absent.
 * sequence/tick are valid whenever the slot bit is set.
 * No pointer, URI, filename or audio/video content is exported.
 * value layouts by slot (indices 0..9):
 * INPUT_BEFORE/AFTER, MASTER_COMPLETE:
 *   system,media,paused,pause_date,last.system,last.stream,wait_ref.system,
 *   wait_ref.stream,wait_priority,context_id; rates=caller,ctx. reason=update reason.
 * CONVERT: now,media,deadline,last.system,last.stream,wait_ref.system,
 *   wait_ref.stream,wait_priority,context_id,uses_master; rates=caller,ctx.
 * REPORT: report.system,raw_audio. REJECT/ACCEPT: system,raw_audio,corrected_audio,
 *   rate_system_anchor,rate_audio_anchor; rate=timing; context_rate absent (sync.rate belongs to another lock/thread);
 *   sync rate is recorded at FINAL_PLAY. reason=reject reason.
 * WATCH_MAX/FINITE: normalized_media,system_date,watch_sequence; rate=watch.
 * DROP_*: PTS,now,deadline,threshold,process,context_id; rate=video.
 * FINAL_PLAY: PTS,play_date; rate=sync.
 * CONTROL/OUTPUT: target_paused,date,request_seq,decoder_lifetime.
 * DECODE: PTS,decode_seq,decoder_lifetime. Control/decode stage pairing uses
 * immutable request/decode identities, never the latest command relabeled.
 * RESUME_DISPATCH/RETURN: no values; event tick is authoritative.
 * DROP_AFTER_MASTER means master completion was observed before drop recording;
 * compare reference_generation to establish whether conversion used it.
 * decode_valid gates the decode fields; decode_seq>0 does not by itself imply a
 * completed exit. decode_exit_us==0 is absent until that sequence completes.
 */
enum { VRR_HAS_RATE=1u<<10, VRR_HAS_CONTEXT_RATE=1u<<11, VRR_HAS_ROLE=1u<<12,
       VRR_HAS_REASON=1u<<13, VRR_HAS_REFERENCE=1u<<14 };
typedef struct {
 uint64_t sequence, present;
 int64_t tick_us;
 uint32_t role, reason;
 uint64_t reference_generation;
 int64_t value[10];
 double rate, context_rate;
} vista_resume_event;
typedef struct {
 uint32_t abi_version,status;
 uint64_t instance_id,episode_id;
 int64_t armed_us;
} vista_resume_mark;
typedef struct {
 uint32_t abi_version,status,end_reason,stream_closed;
 uint64_t instance_id,episode_id,session_id,command_id,revision,seek_nonce;
 int64_t armed_us,resume_us,end_us,snapshot_us;
 uint64_t valid_slots,global_lost,registration_failures;
 uint64_t report_count,reject_count,accept_count,drop_count;
 uint64_t decoder_lifetime,control_request_seq,control_ack_seq,decode_seq;
 int64_t decode_entry_us,decode_exit_us,decode_pts;
 uint32_t decode_active,control_superseded,decode_valid;
 vista_resume_event slots[VRR_SLOT_COUNT];
} vista_resume_snapshot_data;
/* Non-render/control thread; arm immediately before an already-requested paused
 * rate setter. Unique live audio stream required. No playback API is called.
 * A new arm supersedes the old episode. No implicit observer on ordinary rate. */
int vista_resume_observer_arm(libvlc_media_player_t *,uint64_t session,
 uint64_t command,uint64_t revision,uint64_t seek_nonce,vista_resume_mark *);
/* Immediately before/after normal set_pause(false). Exact IDs required.
 * dispatch=1 starts the postresume window, dispatch=0 records setter return.
 * Return means dispatch only, not decoder/vout completion. */
int vista_resume_observer_resume(uint64_t instance,uint64_t episode,int dispatch);
int vista_resume_observer_snapshot(uint64_t instance,uint64_t episode,vista_resume_snapshot_data *);
int vista_resume_observer_end(uint64_t instance,uint64_t episode,uint32_t reason);
/* Independent official time-point observer, not gated by old rate VAB flags.
 * callback_us must be read at callback entry; watch sequence is caller's value. */
void vista_resume_observer_watch(uint64_t instance,uint64_t episode,
 int64_t callback_us,double rate,int64_t media_us,int64_t system_us,uint64_t watch_sequence);
#ifdef __cplusplus
}
#endif
#endif
