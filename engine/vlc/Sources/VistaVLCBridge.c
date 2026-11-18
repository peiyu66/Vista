/* Isolated research adapter, not a public LibVLC ABI. */
#include "config.h"
#include "vista_seek_cost.h"
#include <vlc_vista_cvpx.h>
#include <vlc/libvlc_vista_cvpx_private.h>
#include "VistaVLCBridge.h"
#include "VLCSeekReceiptInternal.h"
#include <vlc/libvlc_media_track.h>
#include "VLCProbeSnapshotInternal.h"
#include "VLCProbePipelineInternal.h"
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>
#include <math.h>

struct VLCProbeEngine {
    VHRRequest *catchup187;
    uint64_t vsc_engine;
    atomic_uint_fast64_t vsc_input;
    vista_cvpx_bridge *bridge;
    libvlc_instance_t *vlc;
    libvlc_media_player_t *player;
    void *context; uint64_t size; VLCVistaReadAt read_at; VLCVistaValidate validate, verify_eof;
    atomic_uint active_input; bool watching;
    /* One fixed-size snapshot. No player API is called under this mutex or from
       a watch callback. unwatch_time joins callbacks before destruction. */
    pthread_mutex_t timing_lock;
    libvlc_media_player_time_point_t time_point;
    uint64_t watch_updates, watch_seeks;
    VLCSeekReceiptState seek_receipt;
    pthread_t seek_dispatch_thread;
    uint64_t audio_boundary_instance;
    atomic_uint_fast64_t audio_boundary_watch_instance;
    /* Control IDs retained for terminal snapshots. Callback gate is copied
       under the existing timing lock, then observed only after releasing it. */
    uint64_t resume_instance,resume_episode,resume_watch_instance,resume_watch_episode;
    uint64_t frame_instance,frame_episode;
    int64_t pause_date;
    bool point_valid, timer_paused, timer_seeking;
    atomic_bool buffering;
    atomic_int state;
    atomic_bool player_error, started, ended;
    atomic_uint opens, closes;
    atomic_uint audio_error_logs, audio_timing_logs, audio_log_emitted;
    atomic_bool audio_native_selected, audio_native_opened;
    uint64_t frames_taken;
};
typedef struct { VLCProbeEngine *owner; uint64_t offset,vsc_input; } Cursor;
static int input_open(void *opaque, void **out, uint64_t *size) {
    VLCProbeEngine *s=opaque; unsigned expected=0;
    if(!atomic_compare_exchange_strong(&s->active_input,&expected,1))return -1;
    if(s->validate(s->context)!=0){atomic_store(&s->active_input,0);return -1;}
    Cursor *c=calloc(1,sizeof(*c)); if(!c){atomic_store(&s->active_input,0);return -1;}
    c->owner=s; c->vsc_input=vsc_input_open(s->vsc_engine);atomic_store(&s->vsc_input,c->vsc_input); *out=c; *size=s->size; atomic_fetch_add(&s->opens,1); return 0;
}
static ptrdiff_t input_read(void *opaque,unsigned char *bytes,size_t count) {
 VF_SCOPE(flowRead,VF_INPUT_READ,VFParent(),count,0,0);
    Cursor *c=opaque; VLCProbeEngine *s=c->owner;
    if(c->offset>s->size)return -1;
    /* Exact caller demand only: no read-ahead or extra source bytes. */
#if !defined(VISTA_READ_PHASE216)
    if(count>524288)count=524288;
#endif
    /* The experimental Swift context clamps to its shared current phase. */
    if(count>s->size-c->offset)count=(size_t)(s->size-c->offset);
    if(!count)return s->verify_eof(s->context)==0?0:-1;

    ptrdiff_t n=s->read_at(s->context,c->offset,bytes,count);
    VFEmit(flowRead.id,VF_INPUT_READ,VF_POINT,0,c->offset,n,count);
    if(n<0 || (size_t)n>count)return -1;
    c->offset+=(uint64_t)n; return n;
}
static int input_seek(void *opaque,uint64_t offset) {
 VF_SCOPE(flowSeek,VF_INPUT_SEEK,VFParent(),offset,0,0);
    Cursor *c=opaque; VLCProbeEngine *s=c->owner;
    if(offset>s->size||s->validate(s->context)!=0)return -1;
    c->offset=offset; return 0;
}
static void input_close(void *opaque) {
    Cursor *c=opaque; VLCProbeEngine *s=c->owner;
    vsc_input_close(s->vsc_engine,c->vsc_input);uint64_t expectedInput=c->vsc_input;bool currentInput=atomic_compare_exchange_strong(&s->vsc_input,&expectedInput,0);
    atomic_fetch_add(&s->closes,1); if(currentInput)atomic_store(&s->active_input,0); free(c);
}
static void state_changed(void *opaque,libvlc_state_t state) {
    VLCProbeEngine *e=opaque;atomic_store(&e->state,state);
    if(state==libvlc_Opening||state==libvlc_Playing)atomic_store(&e->started,true);
    if(state==libvlc_Stopped&&atomic_load(&e->started))atomic_store(&e->ended,true);
    if(state==libvlc_Error)atomic_store(&e->player_error,true);
}
static void buffering_changed(void *opaque,float value) {
    atomic_store(&((VLCProbeEngine *)opaque)->buffering,isfinite(value) && value<1.0f);
}
static void media_stopping(void *opaque,libvlc_media_t *media,libvlc_stopping_reason_t reason) {
    (void)media;if(reason==libvlc_stopping_reason_error)atomic_store(&((VLCProbeEngine *)opaque)->player_error,true);
}
static unsigned bounded_increment(atomic_uint *value, unsigned limit) {
    unsigned old=atomic_load(value);
    while(old<limit && !atomic_compare_exchange_weak(value,&old,old+1)) {}
    return old;
}
/* Passive, bounded log evidence only. Never installs audio callbacks or changes volume. */
static void audio_log(void *opaque, int level, const libvlc_log_t *ctx, const char *fmt, va_list args) {
#if VISTA_DIAGNOSTICS
    VLCProbeEngine *e=opaque; const char *module=NULL, *object=NULL;
    libvlc_log_get_context(ctx,&module,NULL,NULL);
    libvlc_log_get_object(ctx,&object,NULL,NULL);
    char message[512]; vsnprintf(message,sizeof(message),fmt,args);
    bool selected=strstr(message,"using audio output module \"audiounit_ios\"")!=NULL;
    bool opened=module && !strcmp(module,"audiounit_ios") && strstr(message,"analog AudioUnit output successfully opened")!=NULL;
    bool relevant=selected || opened || (module && (strstr(module,"audio") || !strcmp(module,"avcodec")))
        || (object && !strcmp(object,"audio output"));
    if(!relevant)return;
    if(opened)atomic_store(&e->audio_native_opened,true);
    if(selected)atomic_store(&e->audio_native_selected,true);
    bool error=level>=LIBVLC_ERROR;
    bool timing=strstr(message,"drift") || strstr(message,"late") || strstr(message,"underrun") || strstr(message,"timing") || strstr(message,"latency") || strstr(message,"outputLatency") || strstr(message,"IOBufferDuration");
    if(error)bounded_increment(&e->audio_error_logs,1024);
    if(timing)bounded_increment(&e->audio_timing_logs,1024);
#else
    /* Keep a consuming callback: do not restore LibVLC's default stderr logger. */
    (void)opaque;(void)level;(void)ctx;(void)fmt;(void)args;
#endif

}
static void time_update(void *opaque,const libvlc_media_player_time_point_t *point) {
 VF_SCOPE(flowWatch,VF_WATCH,0,point->ts_us,point->system_date_us,isfinite(point->rate)?(int64_t)(point->rate*1000000):0);
 const int64_t callback_us=libvlc_clock();
 VLCProbeEngine *e=opaque;
 const uint64_t audio_instance=atomic_load(&e->audio_boundary_watch_instance);
 pthread_mutex_lock(&e->timing_lock);
 e->time_point=*point;e->point_valid=true;
 e->timer_paused=point->system_date_us==INT64_MAX;e->pause_date=0;
 if(e->watch_updates<9007199254740991ULL)e->watch_updates++;
 const uint64_t resume_instance=e->resume_watch_instance,resume_episode=e->resume_watch_episode;
 const uint64_t watch_sequence=e->watch_updates;
 VFEmit(flowWatch.id,VF_STATE,VF_POINT,0,watch_sequence,e->timer_paused,0);
 pthread_mutex_unlock(&e->timing_lock);
 /* Observe after the existing lock. A cleared/replaced gate cannot attach a
    later callback. A callback racing finish carries its earlier entry time;
    native matching also requires that time to follow the matched accept. */
 if(audio_instance && atomic_load(&e->audio_boundary_watch_instance)==audio_instance)
     vista_audio_boundary_watch(audio_instance,callback_us,point->rate,point->ts_us,point->system_date_us);
 if(resume_instance && resume_episode)
     vista_resume_observer_watch(resume_instance,resume_episode,callback_us,point->rate,point->ts_us,point->system_date_us,watch_sequence);
}
static void time_paused(void *opaque,libvlc_time_t date) {
 VLCProbeEngine *e=opaque;pthread_mutex_lock(&e->timing_lock);
 e->timer_paused=true;e->pause_date=date;
 pthread_mutex_unlock(&e->timing_lock);
}
static void time_seek(void *opaque,const libvlc_media_player_time_point_t *point) {
 const int64_t callback_us=libvlc_clock();
 VLCProbeEngine *e=opaque;pthread_mutex_lock(&e->timing_lock);
 const bool setter_thread=e->seek_receipt.dispatching&&pthread_equal(e->seek_dispatch_thread,pthread_self());
 VLCSeekReceiptCallback(&e->seek_receipt,point!=NULL,point ? point->ts_us:0,callback_us,setter_thread);
 e->timer_seeking=point!=NULL;
 /* A seek request point is not an observed output-rate acknowledgement. */
 e->point_valid=false;
 if(e->watch_seeks<9007199254740991ULL)e->watch_seeks++;
 pthread_mutex_unlock(&e->timing_lock);
}
VLCProbeEngine *VLCVistaCreate(void *context,uint64_t size,VLCVistaReadAt read_at,VLCVistaValidate validate,VLCVistaValidate verify_eof) {
 if(!context||!size||size>INT64_MAX||!read_at||!validate||!verify_eof)return NULL;
 VLCProbeEngine *e=calloc(1,sizeof(*e));if(!e)return NULL;
 if(pthread_mutex_init(&e->timing_lock,NULL)){free(e);return NULL;}
 e->context=context;e->size=size;e->read_at=read_at;e->validate=validate;e->verify_eof=verify_eof;
 e->bridge=vista_cvpx_create(NULL,NULL);
 e->vsc_engine=vsc_register(e->bridge);
#if VISTA_DIAGNOSTICS
 const char *options[]={"--aout=audiounit_ios","--no-spu","--no-osd","--verbose=2"};
#else
 /* Suppress logging during libvlc_new too, before our callback is installed. */
 const char *options[]={"--aout=audiounit_ios","--no-spu","--no-osd","--quiet"};
#endif
 e->vlc=libvlc_new(sizeof(options)/sizeof(options[0]),options);
 if(!e->bridge||!e->vlc)goto fail;
 /* Consume raw VLC messages only in this bounded matcher. Never persist paths/URLs. */
 libvlc_log_set(e->vlc,audio_log,e);
 static const struct libvlc_media_player_cbs callbacks={.version=0,.on_state_changed=state_changed,.on_media_stopping=media_stopping,.on_buffering_changed=buffering_changed};
 static const struct libvlc_media_player_watch_time_cbs clock={.version=0,.on_update=time_update,.on_paused=time_paused,.on_seek=time_seek};
 e->player=libvlc_media_player_new(e->vlc,&callbacks,e);
 if(!e->player||libvlc_vista_set_cvpx_bridge(e->player,e->bridge))goto fail;
 if(libvlc_media_player_watch_time(e->player,0,&clock,e))goto fail;e->watching=true;
 static const struct libvlc_media_open_cbs input={.version=0,.open=input_open,.read=input_read,.seek=input_seek,.close=input_close};
 libvlc_media_t *media=libvlc_media_new_callbacks(&input,e);if(!media)goto fail;
 libvlc_media_add_option(media,"demux=mkv");
 libvlc_media_player_set_media(e->player,media);libvlc_media_release(media);return e;
fail: VLCProbeEngineDestroy(e);return NULL;
}
VLCVistaState VLCVistaGetState(VLCProbeEngine *e) {
 VLCVistaState v={0};if(!e||!e->player)return v;
 v.time_us=libvlc_media_player_get_time(e->player);v.length_us=libvlc_media_player_get_length(e->player);
 v.rate=libvlc_media_player_get_rate(e->player);
 pthread_mutex_lock(&e->timing_lock);
 libvlc_media_player_time_point_t point=e->time_point;
 bool valid=e->point_valid;int64_t pause_date=e->pause_date;
 v.watch_updates=e->watch_updates;v.watch_seeks=e->watch_seeks;
 v.timer_paused=e->timer_paused;v.timer_seeking=e->timer_seeking;
 pthread_mutex_unlock(&e->timing_lock);
 v.watch_rate=point.rate;v.watch_ts_us=point.ts_us;v.watch_date_us=point.system_date_us;
 v.timer_time_us=-1;v.timer_now_us=libvlc_clock();
 /* Official clock domain and interpolation, including future/past points and
    paused points. No freshness timeout: update cadence may legitimately be 10s. */
 int64_t at=v.timer_paused ? (pause_date>0 ? pause_date:point.system_date_us):v.timer_now_us;
 if(valid && (!v.timer_paused || pause_date>0 || point.system_date_us==INT64_MAX))
     v.timer_valid=libvlc_media_player_time_point_interpolate(&point,at,&v.timer_time_us,NULL)==0;
 if(!v.timer_valid)v.timer_time_us=-1;
 v.buffering=atomic_load(&e->buffering);
 v.paused=atomic_load(&e->state)==libvlc_Paused;v.seekable=libvlc_media_player_is_seekable(e->player);
 libvlc_media_tracklist_t *list=libvlc_media_player_get_tracklist(e->player,libvlc_track_video,true);
 if(list){if(libvlc_media_tracklist_count(list)){libvlc_media_track_t *t=libvlc_media_tracklist_at(list,0);
 v.video_codec=t->i_codec;v.width=t->u.video->i_width;v.height=t->u.video->i_height;v.bitrate=t->i_bitrate;
 v.unsupported_video=t->i_codec!=VLC_CODEC_H264&&t->i_codec!=VLC_CODEC_HEVC&&t->i_codec!=VLC_CODEC_VP9;}
 libvlc_media_tracklist_delete(list);}
 list=libvlc_media_player_get_tracklist(e->player,libvlc_track_audio,false);
 if(list){size_t count=libvlc_media_tracklist_count(list);if(count){libvlc_media_track_t *t=libvlc_media_tracklist_at(list,0);
 for(size_t i=0;i<count;i++){libvlc_media_track_t *candidate=libvlc_media_tracklist_at(list,i);if(candidate->selected){t=candidate;break;}}
 v.has_audio=true;v.audio_codec=t->i_codec;v.unsupported_audio=t->i_codec!=VLC_CODEC_MP4A;}
 libvlc_media_tracklist_delete(list);}
 return v;
}
int64_t VLCVistaClock(void){return libvlc_clock();}
void VLCVistaPause(VLCProbeEngine *e,bool paused){if(e&&e->player){
 VLCVistaCatchupCancel(e,paused);
 VLCVistaAudioFinish(e,VAB_PAUSE,NULL);
 if(paused)VLCVistaFrameFinish(e,VFS_PAUSE,NULL);
 if(paused)VLCVistaResumeFinish(e,VRR_PAUSE,NULL);
 else if(e->resume_instance && e->resume_episode)
     vista_resume_observer_resume(e->resume_instance,e->resume_episode,1);
 libvlc_media_player_set_pause(e->player,paused);
 if(!paused && e->resume_instance && e->resume_episode)
     vista_resume_observer_resume(e->resume_instance,e->resume_episode,0);
}}
VLCVistaRateReceipt VLCVistaRate(VLCProbeEngine *e,float rate){
 VLCVistaRateReceipt result={.status=-1};if(!e||!e->player)return result;
 VLCVistaCatchupCancel(e,false);
 pthread_mutex_lock(&e->timing_lock);result.watch_floor=e->watch_updates;pthread_mutex_unlock(&e->timing_lock);
 result.status=libvlc_media_player_set_rate(e->player,rate);result.command_clock_us=libvlc_clock();return result;
}
int VLCVistaSeek(VLCProbeEngine *e,int64_t target){
 return VLCVistaSeekObserved(e,target).status;
}
VLCVistaSeekDispatch VLCVistaSeekObserved(VLCProbeEngine *e,int64_t target){
 VLCVistaSeekDispatch result={.status=-1};
 if(!e||!e->player||target<0)return result;
 VLCVistaCatchupCancel(e,false);
 /* Includes manual and automatic resync: diagnostics end before the same setter. */
 VLCVistaAudioFinish(e,VAB_SEEK,NULL);
 VLCVistaFrameFinish(e,VFS_SEEK,NULL);
 VLCVistaResumeFinish(e,VRR_SEEK,NULL);
 pthread_mutex_lock(&e->timing_lock);
 e->seek_dispatch_thread=pthread_self();
 result.command_id=VLCSeekReceiptBegin(&e->seek_receipt,target,libvlc_clock());
 pthread_mutex_unlock(&e->timing_lock);
 vsc_dispatch(e->vsc_engine,atomic_load(&e->vsc_input),target);
 result.status=libvlc_media_player_set_time(e->player,target,false);
 pthread_mutex_lock(&e->timing_lock);
 VLCSeekReceiptReturned(&e->seek_receipt,result.command_id,result.status);
 pthread_mutex_unlock(&e->timing_lock);
 return result;
}
VLCVistaSeekObservation VLCVistaGetSeekObservation(VLCProbeEngine *e){
 VLCVistaSeekObservation result={0};if(!e||!e->player)return result;
 pthread_mutex_lock(&e->timing_lock);result=e->seek_receipt.observation;pthread_mutex_unlock(&e->timing_lock);
 return result;
}
int VLCProbeEnginePlay(VLCProbeEngine *e){return libvlc_media_player_play(e->player);}
VLCProbeSnapshot *VLCProbeEngineTakeSnapshot(VLCProbeEngine *e) {
    VLCProbeSnapshot *s=VLCProbeTakeBridgeSnapshot(e->bridge);
    if(s)++e->frames_taken;
    return s;
}
VLCProbeDiagnostics VLCProbeEngineDiagnostics(VLCProbeEngine *e) {
    vista_cvpx_vt_diagnostics vt={0};vista_cvpx_get_vt_diagnostics(e->bridge,&vt);
    vista_cvpx_vt_attempt_diagnostics attempts={0};vista_cvpx_get_vt_attempt_diagnostics(e->bridge,&attempts);
    return (VLCProbeDiagnostics){.vt_create_attempts=attempts.create_attempts,
        .vt_create_failures=attempts.create_failures,.vt_failure_events=attempts.failure_events,
        .vt_last_create_status=attempts.last_create_status,.vt_last_create_profile=attempts.last_create_profile,
        .vt_last_create_codec=attempts.last_create_codec,.vt_last_failure_status=attempts.last_failure_status,
        .vt_last_failure_stage=attempts.last_failure_stage,.frames_taken=e->frames_taken,.vt_checks=vt.session_checks,
        .vt_hardware=vt.hardware_verified,.vt_rejected=vt.hardware_rejected,.last_vt_status=vt.last_status,
        .last_codec=vt.last_codec,.last_using_hardware=vt.last_using_hardware,
        .state=atomic_load(&e->state),.player_error=atomic_load(&e->player_error),.ended=atomic_load(&e->ended),
        .audio_native_selected=atomic_load(&e->audio_native_selected),.audio_native_opened=atomic_load(&e->audio_native_opened),
        .audio_error_logs=atomic_load(&e->audio_error_logs),.audio_timing_logs=atomic_load(&e->audio_timing_logs),
        .source_opens=atomic_load(&e->opens),.source_closes=atomic_load(&e->closes)};
}
VLCProbePipelineDiagnostics VLCProbeEnginePipelineDiagnostics(VLCProbeEngine *e) {
    vista_cvpx_pipeline_diagnostics pipeline={0};
    vista_cvpx_get_pipeline_diagnostics(e->bridge,&pipeline);
    return VLCProbeMapPipeline(&pipeline);
}
bool VLCProbeEngineDestroy(VLCProbeEngine *e) {
    if(e&&e->catchup187){vista_hold187_cancel(e->catchup187);vista_hold187_release(e->catchup187);e->catchup187=NULL;}
    if(!e)return true;
    VLCVistaFrameFinish(e,VFS_STOP,NULL);
    VLCVistaResumeFinish(e,VRR_STOP,NULL);
    pthread_mutex_lock(&e->timing_lock);VLCSeekReceiptInvalidate(&e->seek_receipt);pthread_mutex_unlock(&e->timing_lock);
    if(e->bridge)vista_cvpx_quiesce(e->bridge);
    if(e->player){if(e->watching){libvlc_media_player_unwatch_time(e->player);e->watching=false;}libvlc_media_player_stop_async(e->player);libvlc_media_player_release(e->player);e->player=NULL;}
    if(e->bridge)vista_cvpx_wait_drained(e->bridge);
    if(e->vlc){libvlc_log_unset(e->vlc);libvlc_release(e->vlc);e->vlc=NULL;}
    bool ok=vista_cvpx_destroy(e->bridge);
    if(ok){pthread_mutex_destroy(&e->timing_lock);vsc_unregister(e->vsc_engine);free(e);}return ok;
}

VLCVistaMediaStats VLCVistaGetMediaStats(VLCProbeEngine *e) {
 VLCVistaMediaStats result={0};if(!e||!e->player)return result;
 /* get_media returns a retained current-media reference (not a requested URL). */
 libvlc_media_t *media=libvlc_media_player_get_media(e->player);if(!media)return result;
 libvlc_media_stats_t stats={0};
 if(libvlc_media_get_stats(media,&stats)) {
  result.available=true;result.decoded_video=stats.i_decoded_video;
  result.displayed_pictures=stats.i_displayed_pictures;
  result.late_pictures=stats.i_late_pictures;result.lost_pictures=stats.i_lost_pictures;
 }
 libvlc_media_release(media);return result;
}

#include <vlc_vista_recovery.h>
VLCVistaNativeDiagnostics VLCVistaGetNativeDiagnostics(VLCProbeEngine *e) {
 VLCVistaNativeDiagnostics result={0};if(!e||!e->bridge)return result;
 vista_recovery_snapshot_v2 extended={0};
 vista_recovery_snapshot snapshot={0};
 if(vista_cvpx_get_recovery(e->bridge,2,&extended,sizeof(extended))) {
  snapshot=extended.base;
  result.drop_context_valid=extended.drop_context_valid != 0;
  result.drop_context_rate=extended.drop_context_rate;
  result.drop_reference_generation=extended.drop_reference_generation;
 } else if(!vista_cvpx_get_recovery(e->bridge,1,&snapshot,sizeof(snapshot)))return result;
 result.available=true;result.version=snapshot.version;
 result.sample_clock_us=libvlc_clock();result.tick_zero=VLC_TICK_0;
 result.tick_invalid=VLC_TICK_INVALID;result.ticks_per_second=CLOCK_FREQ;
 result.queue_count=snapshot.queue_count;
 result.queue_valid=snapshot.queue_valid;
 result.queue_invalid=snapshot.queue_invalid;
 result.queue_repeat=snapshot.queue_repeat;
 result.queue_backward=snapshot.queue_backward;
 result.delivery_admitted=snapshot.delivery_admitted;
 result.delivery_invalid=snapshot.delivery_invalid;
 result.delivery_no_vout=snapshot.delivery_no_vout;
 result.delivery_wait_abort=snapshot.delivery_wait_abort;
 result.delivery_flush_abort=snapshot.delivery_flush_abort;
 result.delivery_preroll=snapshot.delivery_preroll;
 result.delivery_prevframe=snapshot.delivery_prevframe;
 result.fifo_pop=snapshot.fifo_pop;
 result.fifo_empty=snapshot.fifo_empty;
 result.late_drop=snapshot.late_drop;
 result.render_normal=snapshot.render_normal;
 result.render_forced=snapshot.render_forced;
 result.render_redisplay=snapshot.render_redisplay;
 result.queue_pts=snapshot.queue_pts;
 result.queue_tick=snapshot.queue_tick;
 result.popped_pts=snapshot.popped_pts;
 result.drop_pts=snapshot.drop_pts;
 result.drop_tick=snapshot.drop_tick;
 result.drop_system_delta=snapshot.drop_system_delta;
 result.drop_process=snapshot.drop_process;
 result.drop_threshold=snapshot.drop_threshold;
 result.drop_rate=snapshot.drop_rate;
 result.drop_clock_id=snapshot.drop_clock_id;
 return result;
}

/* Control-thread only. Never invokes playback APIs from a diagnostic callback. */
vista_audio_boundary_snapshot_data VLCVistaAudioSnapshot(VLCProbeEngine *e) {
 vista_audio_boundary_snapshot_data out={.abi_version=VISTA_AUDIO_BOUNDARY_ABI,.status=VAB_UNAVAILABLE};
 if(e&&e->audio_boundary_instance)vista_audio_boundary_snapshot(e->audio_boundary_instance,&out);
 return out;
}
vista_audio_boundary_snapshot_data VLCVistaAudioFinish(VLCProbeEngine *e,uint32_t reason,int *status) {
 if(status)*status=VAB_UNAVAILABLE;
 if(e) {
  atomic_store(&e->audio_boundary_watch_instance,0);
  if(e->audio_boundary_instance) {
   int result=vista_audio_boundary_finish(e->audio_boundary_instance,0,reason);
   if(status)*status=result;
  }
 }
 return VLCVistaAudioSnapshot(e);
}
VLCVistaAudioRateReceipt VLCVistaAudioRate(VLCProbeEngine *e,float rate,uint64_t session,uint64_t command) {
 VLCVistaAudioRateReceipt out={.rate={.status=-1},.mark={.abi_version=VISTA_AUDIO_BOUNDARY_ABI,.status=VAB_UNAVAILABLE}};
 out.previous=VLCVistaAudioFinish(e,VAB_SUPERSEDED,&out.finish_status);
 if(!e||!e->player)return out;
 vista_audio_boundary_mark_command(e->player,session,command,rate,&out.mark);
 e->audio_boundary_instance=out.mark.status==VAB_OK?out.mark.instance_id:0;
 atomic_store(&e->audio_boundary_watch_instance,e->audio_boundary_instance);
 out.rate=VLCVistaRate(e,rate);
 if(out.rate.status!=0)VLCVistaAudioFinish(e,VAB_SUPERSEDED,NULL);
 return out;
}

/* Serialized control-thread entry points. No new playback call or setter order. */
vista_resume_snapshot_data VLCVistaResumeSnapshot(VLCProbeEngine *e) {
 vista_resume_snapshot_data out={.abi_version=VISTA_RESUME_OBSERVER_ABI,.status=VRR_UNAVAILABLE};
 if(e && e->resume_instance && e->resume_episode) {
  vista_resume_observer_snapshot(e->resume_instance,e->resume_episode,&out);
  if(out.status==VRR_OK && out.end_reason!=VRR_OPEN) {
   pthread_mutex_lock(&e->timing_lock);
   e->resume_watch_instance=0;e->resume_watch_episode=0;
   pthread_mutex_unlock(&e->timing_lock);
  }
 }
 return out;
}
vista_resume_snapshot_data VLCVistaResumeFinish(VLCProbeEngine *e,uint32_t reason,int *status) {
 if(status)*status=VRR_UNAVAILABLE;
 if(e) {
  pthread_mutex_lock(&e->timing_lock);
  e->resume_watch_instance=0;e->resume_watch_episode=0;
  pthread_mutex_unlock(&e->timing_lock);
  if(e->resume_instance && e->resume_episode) {
   int result=vista_resume_observer_end(e->resume_instance,e->resume_episode,reason);
   if(status)*status=result;
  }
 }
 return VLCVistaResumeSnapshot(e);
}
VLCVistaResumeRateReceipt VLCVistaResumeRate(VLCProbeEngine *e,float rate,uint64_t session,
 uint64_t command,uint64_t revision,uint64_t seek_nonce,bool paused) {
 VLCVistaResumeRateReceipt out={.mark={.abi_version=VISTA_RESUME_OBSERVER_ABI,.status=VRR_UNAVAILABLE}};
 out.previous=VLCVistaResumeFinish(e,VRR_SUPERSEDED,&out.finish_status);
 out.frame.mark=(vista_frame_stage_mark){.abi_version=VISTA_FRAME_STAGE_ABI,.status=VFS_UNAVAILABLE};
 out.frame.previous=VLCVistaFrameFinish(e,VFS_SUPERSEDED,&out.frame.finish_status);
 if(e && e->player) {
  e->frame_instance=0;e->frame_episode=0;
  if(!paused) {
   vista_frame_stage_arm(e->player,session,command,revision,seek_nonce,&out.frame.mark);
   if(out.frame.mark.status==VFS_OK && out.frame.mark.abi_version==VISTA_FRAME_STAGE_ABI) {
    e->frame_instance=out.frame.mark.instance_id;e->frame_episode=out.frame.mark.episode_id;
   }
  }
 }
 if(e && e->player) {
  e->resume_instance=0;e->resume_episode=0;
  if(paused) {
   vista_resume_observer_arm(e->player,session,command,revision,seek_nonce,&out.mark);
   if(out.mark.status==VRR_OK && out.mark.abi_version==VISTA_RESUME_OBSERVER_ABI) {
    e->resume_instance=out.mark.instance_id;e->resume_episode=out.mark.episode_id;
    pthread_mutex_lock(&e->timing_lock);
    e->resume_watch_instance=e->resume_instance;e->resume_watch_episode=e->resume_episode;
    pthread_mutex_unlock(&e->timing_lock);
   }
  }
 }
 out.audio=VLCVistaAudioRate(e,rate,session,command);
 if(out.audio.rate.status!=0){VLCVistaFrameFinish(e,VFS_SUPERSEDED,NULL);VLCVistaResumeFinish(e,VRR_SUPERSEDED,NULL);}
 return out;
}

/* Independent bounded frame-stage lifetime; audio acceptance never ends it. */
vista_frame_stage_snapshot_data VLCVistaFrameSnapshot(VLCProbeEngine *e) {
 vista_frame_stage_snapshot_data out={.abi_version=VISTA_FRAME_STAGE_ABI,.status=VFS_UNAVAILABLE};
 if(e && e->frame_instance && e->frame_episode)
  vista_frame_stage_snapshot(e->frame_instance,e->frame_episode,&out);
 return out;
}
vista_frame_stage_snapshot_data VLCVistaFrameFinish(VLCProbeEngine *e,uint32_t reason,int *status) {
 if(status)*status=VFS_UNAVAILABLE;
 if(e && e->frame_instance && e->frame_episode) {
  int result=vista_frame_stage_end(e->frame_instance,e->frame_episode,reason);
  if(status)*status=result;
 }
 return VLCVistaFrameSnapshot(e);
}

/* Tiny current decoder telemetry; no additional playback or clock operation. */
vista_queue_pressure_snapshot_data VLCVistaQueuePressure(VLCProbeEngine *e) {
 vista_queue_pressure_snapshot_data out={.abi_version=VISTA_QUEUE_PRESSURE_ABI,.status=VFS_UNAVAILABLE};
 if(e && e->player)vista_queue_pressure_snapshot(e->player,&out);
 return out;
}

bool VLCVistaCatchupStart(VLCProbeEngine*e,uint64_t command,int64_t target,int64_t sample,double rate){
 if(!e||!e->player)return false;
 if(e->catchup187){VHRResult x=vista_hold187_poll(e->catchup187);if(x.state<VHR_RESUMED)return false;vista_hold187_release(e->catchup187);e->catchup187=NULL;}
 e->catchup187=vista_hold187_request(e->player,(VHRInput){command,target,sample,rate});return e->catchup187!=NULL;
}
VHRResult VLCVistaCatchupPoll(VLCProbeEngine*e){return e?vista_hold187_poll(e->catchup187):(VHRResult){0};}
void VLCVistaCatchupCancel(VLCProbeEngine*e,bool paused){if(e){if(paused)vista_hold187_cancel_paused(e->catchup187);else vista_hold187_cancel(e->catchup187);}}
