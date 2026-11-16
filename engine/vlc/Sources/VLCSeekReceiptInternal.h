#pragma once
/* Fixed scalar observer. Caller holds the bridge timing_lock for every operation.
 * It witnesses a synchronous requested-target start and subsequent NULL, not a
 * native per-command flush token, decoded-picture epoch or audio completion.
 * The consumer may use it only for a paused preview within the existing target
 * tolerance. A delayed prior NULL after a new start has no public identity.
 * Ambiguous callback chains stay quarantined for this engine lifetime; the
 * existing ordinary clock/watch gate remains available and unchanged. */
typedef struct {
    VLCVistaSeekObservation observation;
    uint64_t next_command, callback_sequence;
    bool dispatching, pending, quarantined;
} VLCSeekReceiptState;

static inline void VLCSeekReceiptInvalidate(VLCSeekReceiptState *s) {
    s->quarantined=true;s->observation.ambiguous=true;
}
static inline uint64_t VLCSeekReceiptBegin(VLCSeekReceiptState *s,int64_t target,int64_t now) {
    if(s->pending||s->dispatching)VLCSeekReceiptInvalidate(s);
    if(s->next_command==UINT64_MAX){VLCSeekReceiptInvalidate(s);return 0;}
    const uint64_t command=++s->next_command;
    s->observation=(VLCVistaSeekObservation){.command_id=command,.target_us=target,
        .begin_clock_us=now,.ambiguous=s->quarantined};
    s->dispatching=true;s->pending=true;
    return command;
}
static inline void VLCSeekReceiptCallback(VLCSeekReceiptState *s,bool has_point,int64_t target,int64_t now,bool setter_thread) {
    if(s->callback_sequence==UINT64_MAX){VLCSeekReceiptInvalidate(s);return;}
    const uint64_t sequence=++s->callback_sequence;
    VLCVistaSeekObservation *o=&s->observation;
    if(has_point) {
        /* VLC clamps a zero request to VLC_TICK_0 (1us); no other offset. */
        const int64_t expected=o->target_us==0 ? 1:o->target_us;
        const bool matched=s->dispatching&&setter_thread&&s->pending&&o->command_id>0&&
            o->start_sequence==0&&target==expected;
        if(!matched)VLCSeekReceiptInvalidate(s);
        o->start_matched=matched;o->start_sequence=sequence;
    } else {
        if(!s->pending||!o->start_matched||o->ended||now<o->begin_clock_us)
            VLCSeekReceiptInvalidate(s);
        o->end_sequence=sequence;o->end_clock_us=now;
        o->ended=o->start_matched&&!s->quarantined&&sequence>o->start_sequence;
        s->pending=false;
    }
    o->ambiguous=s->quarantined;
}
static inline void VLCSeekReceiptReturned(VLCSeekReceiptState *s,uint64_t command,int status) {
    if(command==0||command!=s->observation.command_id||status!=0||!s->observation.start_matched)
        VLCSeekReceiptInvalidate(s);
    s->dispatching=false;
}
