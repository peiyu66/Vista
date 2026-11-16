/* Vista134 bounded passive diagnostics. No callback allocation/I/O/wait. */
#include "vista_audio_boundary_internal.h"
#include <stdatomic.h>
#include <string.h>
#include <limits.h>
#define SLOTS 16u
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "64-bit diagnostic atomics must be lock-free");
typedef struct {
    _Atomic uint64_t live;
    uint64_t id, serial, overwritten;
    uintptr_t expected_block;
    const void *aout; /* Internal lookup only. Never copied to public output. */
    unsigned count, next, current;
    int has_current, match_ambiguous;
    int64_t match_accept_us, match_system, match_audio;
    vista_audio_boundary_episode episodes[VISTA_AUDIO_BOUNDARY_EPISODES];
} slot;
static slot slots[SLOTS];
static atomic_flag gate = ATOMIC_FLAG_INIT;
static _Atomic uint64_t global_lost, registration_failures;
static uint64_t generation; /* Protected by gate; zero is permanently invalid. */
static int enter(uint64_t id) {
    if (!atomic_flag_test_and_set_explicit(&gate, memory_order_acquire)) return 1;
    atomic_fetch_add_explicit(&global_lost, 1, memory_order_relaxed);
    (void)id; /* A failed acquisition cannot safely attribute a lost event. */
    return 0;
}
static void leave(void) { atomic_flag_clear_explicit(&gate,memory_order_release); }
static slot *by_id(uint64_t id, int active) {
    unsigned n=(unsigned)(id & 255u);
    if(!n || n>SLOTS) return NULL;
    slot *s=&slots[n-1];
    if(s->id!=id || (active && atomic_load_explicit(&s->live,memory_order_acquire)!=id)) return NULL;
    return s;
}
static slot *by_aout(const void *aout) {
    slot *found=NULL;
    for(unsigned i=0;i<SLOTS;i++)
        if(slots[i].aout==aout && slots[i].id &&
           atomic_load_explicit(&slots[i].live,memory_order_acquire)==slots[i].id) {
            if(found) return NULL; /* Ambiguous audio source: do not guess. */
            found=&slots[i];
        }
    return found;
}
static vista_audio_boundary_episode *current(slot *s) {
    if(!s || !s->has_current) return NULL;
    vista_audio_boundary_episode *e=&s->episodes[s->current];
    return e->end_reason==VAB_OPEN ? e : NULL;
}
static void end_open(slot *s, uint64_t command, uint32_t reason, int64_t now) {
    for(unsigned i=0;i<s->count;i++) {
        vista_audio_boundary_episode *e=&s->episodes[i];
        if(e->end_reason==VAB_OPEN && (!command || e->command_id==command)) {
            e->end_reason=reason;e->end_us=now;
        }
    }
    if(!current(s)) s->has_current=0;
}
static vista_audio_boundary_episode *append(slot *s, int64_t now) {
    unsigned i=s->next;s->next=(i+1)%VISTA_AUDIO_BOUNDARY_EPISODES;
    if(s->count<VISTA_AUDIO_BOUNDARY_EPISODES)s->count++;else s->overwritten++;
    vista_audio_boundary_episode *e=&s->episodes[i];memset(e,0,sizeof(*e));
    e->instance_id=s->id;e->episode_id=++s->serial;
    s->current=i;s->has_current=1;s->match_accept_us=0;s->match_ambiguous=0;s->expected_block=0;
    (void)now;return e;
}
uint64_t vab_register(const void *aout,int64_t now) {
    (void)now;
    if(!aout || !enter(0)) {atomic_fetch_add(&registration_failures,1);return 0;}
    slot *s=NULL;unsigned index=0;
    /* Prefer never-used then oldest inactive slot; preserve recent closed history. */
    for(unsigned i=0;i<SLOTS;i++) if(!atomic_load_explicit(&slots[i].live,memory_order_acquire))
        if(!s || slots[i].id<s->id) {s=&slots[i];index=i;}
    if(!s || generation>=((UINT64_MAX>>8)-1)) {leave();atomic_fetch_add(&registration_failures,1);return 0;}
    s->id=(++generation<<8)|(index+1);s->aout=aout;s->serial=0;s->overwritten=0;
    s->count=s->next=s->current=0;s->has_current=0;s->match_accept_us=0;
    memset(s->episodes,0,sizeof(s->episodes));
    atomic_store_explicit(&s->live,s->id,memory_order_release);
    uint64_t id=s->id;leave();return id;
}
void vab_retire(uint64_t id) {
    unsigned n=(unsigned)(id&255u);if(!n || n>SLOTS)return;
    /* Atomic token CAS works even if a snapshot holds the diagnostic gate.
     * No diagnostic data refers to stream memory, so teardown never waits. */
    atomic_compare_exchange_strong_explicit(&slots[n-1].live,&id,0,
                                           memory_order_acq_rel,memory_order_relaxed);
}
int vab_mark(const void *aout,uint64_t session,uint64_t command,double rate,
             int64_t now,vista_audio_boundary_mark *out) {
    if(!out)return VAB_INVALID;
    memset(out,0,sizeof(*out));out->abi_version=VISTA_AUDIO_BOUNDARY_ABI;
    if(!aout || !session || !command || !(rate>0 && rate<=32))return out->status=VAB_INVALID;
    if(!enter(0))return out->status=VAB_BUSY;
    slot *s=by_aout(aout);
    if(!s){leave();return out->status=VAB_UNAVAILABLE;}
    end_open(s,0,VAB_SUPERSEDED,now);
    vista_audio_boundary_episode *e=append(s,now);
    e->session_id=session;e->command_id=command;e->requested_rate=rate;
    e->command_us=now;e->valid=VAB_COMMAND;
    out->instance_id=s->id;out->episode_id=e->episode_id;out->command_us=now;
    leave();return out->status=VAB_OK;
}
void vab_change(uint64_t id,int64_t now,double rate) {
    if(!id || !enter(id))return;slot *s=by_id(id,1);
    if(s) {
        vista_audio_boundary_episode *e=current(s);
        if(!e || (e->valid&VAB_CHANGE) || (float)e->requested_rate!=(float)rate) {
            end_open(s,0,VAB_SUPERSEDED,now);e=append(s,now);
        }
        e->audio_rate=rate;e->change_us=now;e->valid|=VAB_CHANGE;
    }
    leave();
}
void vab_block(uint64_t id,int64_t now,double rate,int64_t system,int64_t audio,const void *block) {
    if(!id || !enter(id))return;slot *s=by_id(id,1);vista_audio_boundary_episode *e=current(s);
    if(e && (e->valid&VAB_CHANGE) && !(e->valid&VAB_BLOCK) && e->audio_rate==rate) {
        s->expected_block=(uintptr_t)block;
        e->block_us=now;e->boundary_system_us=system;e->boundary_audio_us=audio;e->valid|=VAB_BLOCK;
    }leave();
}
void vab_enqueue(const void *aout,const void *block,int64_t now,int64_t date,int64_t fifo,int64_t length) {
    if(!enter(0))return;slot *s=by_aout(aout);vista_audio_boundary_episode *e=current(s);
    if(e && (e->valid&VAB_BLOCK) && !(e->valid&VAB_ENQUEUE) && date==e->boundary_system_us && s->expected_block==(uintptr_t)block) {
        e->enqueue_us=now;e->enqueue_date_us=date;e->fifo_after_enqueue_us=fifo;
        e->block_length_us=length;e->valid|=VAB_ENQUEUE;
    }leave();
}
void vab_report(const void *aout,int64_t now,int64_t system,int64_t audio) {
    if(!enter(0))return;slot *s=by_aout(aout);vista_audio_boundary_episode *e=current(s);
    if(e && (e->valid&VAB_CHANGE)) {
        if(!(e->valid&VAB_REPORT)) {e->first_report_us=now;e->first_report_system_us=system;e->first_report_audio_us=audio;}
        e->last_report_us=now;e->last_report_system_us=system;e->last_report_audio_us=audio;
        e->report_count++;e->valid|=VAB_REPORT;
    }leave();
}
void vab_notify(uint64_t id,int64_t now,double rate,int64_t boundary,
                int64_t system,int64_t audio,int64_t corrected,int accepted) {
    if(!id || !enter(id))return;slot *s=by_id(id,1);vista_audio_boundary_episode *e=current(s);
    if(e && (e->valid&VAB_BLOCK) && e->audio_rate==rate && e->boundary_system_us==boundary) {
        if(accepted) {
            if(!(e->valid&VAB_ACCEPT)) {e->accept_us=now;e->accept_system_us=system;e->accept_audio_us=audio;e->accept_clock_audio_us=corrected;}
            e->valid|=VAB_ACCEPT;e->accept_count++;
            if(s->match_accept_us && s->match_system==system) {
                if(s->match_audio!=corrected)s->match_ambiguous=1;
            } else s->match_ambiguous=0;
            s->match_accept_us=now;s->match_system=system;s->match_audio=corrected;
        }else {
            if(!(e->valid&VAB_REJECT)){e->first_reject_us=now;e->first_reject_system_us=system;}
            e->last_reject_us=now;e->last_reject_system_us=system;e->reject_count++;e->valid|=VAB_REJECT;
        }
    }leave();
}
void vista_audio_boundary_watch(uint64_t id,int64_t now,double rate,int64_t audio,int64_t system) {
    if(!id || !enter(id))return;slot *s=by_id(id,1);vista_audio_boundary_episode *e=current(s);
    if(e && (e->valid&VAB_ACCEPT) && !(e->valid&VAB_WATCH) && e->audio_rate==rate &&
       !s->match_ambiguous && s->match_system==system && now>=s->match_accept_us) {
        e->watch_us=now;e->watch_system_us=system;e->watch_audio_us=audio;
        e->watch_accept_us=s->match_accept_us;e->watch_native_audio_us=s->match_audio;
        e->valid|=VAB_WATCH;
        if(!((audio>0 && s->match_audio<INT64_MIN+audio) ||
             (audio<0 && s->match_audio>INT64_MAX+audio))) {
            e->watch_pts_offset_us=s->match_audio-audio;e->valid|=VAB_WATCH_OFFSET;
        }
    }leave();
}
int vista_audio_boundary_finish(uint64_t id,uint64_t command,uint32_t reason) {
    if(!id || reason<VAB_SUPERSEDED || reason>VAB_TIMING_RESET)return VAB_INVALID;
    if(!enter(id))return VAB_BUSY;slot *s=by_id(id,0);
    if(s)end_open(s,command,reason,vab_now());leave();return s?VAB_OK:VAB_UNAVAILABLE;
}
void vab_reset(uint64_t id,int64_t now) {
    if(!id || !enter(id))return;slot *s=by_id(id,1);
    if(s)end_open(s,0,VAB_TIMING_RESET,now);leave();
}
int vista_audio_boundary_snapshot(uint64_t id,vista_audio_boundary_snapshot_data *out) {
    if(!out)return VAB_INVALID;memset(out,0,sizeof(*out));out->abi_version=VISTA_AUDIO_BOUNDARY_ABI;
    out->global_dropped_events=atomic_load_explicit(&global_lost,memory_order_relaxed);
    out->registration_failures=atomic_load_explicit(&registration_failures,memory_order_relaxed);
    if(!id)return out->status=VAB_UNAVAILABLE;
    if(!enter(id))return out->status=VAB_BUSY;
    slot *s=by_id(id,0);if(!s){leave();return out->status=VAB_UNAVAILABLE;}
    out->instance_id=id;out->count=s->count;out->overwritten_episodes=s->overwritten;
    out->dropped_events=UINT64_MAX; /* loss attribution unavailable; global total exact */
    out->stream_closed=atomic_load_explicit(&s->live,memory_order_acquire)!=id;
    out->snapshot_us=vab_now();
    unsigned oldest=s->count==VISTA_AUDIO_BOUNDARY_EPISODES?s->next:0;
    for(unsigned i=0;i<s->count;i++) {
        out->episodes[i]=s->episodes[(oldest+i)%VISTA_AUDIO_BOUNDARY_EPISODES];
        if(out->stream_closed && out->episodes[i].end_reason==VAB_OPEN)
            out->episodes[i].end_reason=VAB_STREAM_END; /* End timestamp unavailable. */
    }
    leave();return out->status=VAB_OK;
}
#ifdef VAB_TEST
void vab_test_hold(void){while(atomic_flag_test_and_set(&gate)){} }
void vab_test_release(void){leave();}
#endif
