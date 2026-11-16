#ifndef VISTA_FLOW_TRACE_H
#define VISTA_FLOW_TRACE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
#define VF_CAPACITY 65536u
#define VF_PREHISTORY 16384u
#define VF_SCHEMA 2u
/* No pointers, payload, media names or source identity leave this scalar ABI. */
typedef struct {uint64_t sequence,id,parent;int64_t tick_us,a,b;uint32_t stage,phase;int64_t c;} VFRecord;
typedef struct {
 uint32_t schema,record_bytes,capacity,count;
 uint64_t session,generation,trigger_id;
 int64_t opened_us,trigger_us,cutoff_us,exported_us;
 uint64_t attempts,contention_lost,capacity_lost,map_lost,stale_lost,prehistory_discarded,after_cutoff;
 uint32_t trigger_reason,cutoff_reason;
 uint64_t map_busy,map_miss,map_evictions,map_invalidations,written,drained,trigger_count;
 int64_t last_trigger_us;
} VFHeader;
enum { VF_BEGIN=1,VF_END=2,VF_POINT=3 };
enum {
 VF_SESSION=1,VF_TRIGGER=2,VF_ANCHOR=3,VF_CONTROL=4,VF_WATCH=5,
 VF_INPUT_READ=10,VF_INPUT_SEEK=11,VF_DEMUX=12,VF_DECODER_ENQUEUE=13,
 VF_BLOCK=14,VF_FIFO_ENQUEUE=15,VF_FIFO_DEQUEUE=16,VF_PROCESS_INPUT=17,
 VF_PACKETIZER=18,VF_DECODER_CALL=19,VF_FIFO_LOCK=20,VF_INPUT_PACE=21,
 VF_LOOP_CONTROL=22,VF_LOOP_EMPTY=23,VF_LOOP_PAUSE=24,VF_FRAME=30,
 VF_PACER=31,VF_SUBMIT=32,VF_CALLBACK=33,VF_CALLBACK_LOCK=34,VF_PICTURE=35,
 VF_DPB_INSERT=36,VF_DPB_EXIT=37,VF_QUEUE_VIDEO=38,VF_PREPARE=39,VF_DROP=40,
 VF_RENDER=41,VF_RENDER_WAIT=42,VF_VOUT_PREPARE=43,VF_VOUT_DISPLAY=44,
 VF_MAILBOX_PREPARE=45,VF_MAILBOX_DISPLAY=46,VF_MAILBOX_TAKE=47,VF_MAILBOX_RELEASE=48,
 VF_VT_SESSION=49,VF_VT_DRAIN=50,VF_CLOCK_CONVERT=51,
 VF_ASYNC_READ=100,VF_CONDITION=101,VF_TASK_START=102,VF_PREVIOUS_JOIN=103,
 VF_WINDOW_READ=104,VF_CALLBACK_COPY=105,VF_SOURCE_REQUEST=110,
 VF_SOURCE_QUEUED=111,VF_SOURCE_WORK=112,VF_SOURCE_CALL=113,VF_SOURCE_ACCEPT=114,
 VF_POLL=120,VF_POLL_ACTOR=121,VF_FRAME_COPY=122,VF_PIXEL_PREPARE=123,VF_APP_GATE=124,
 VF_PUBLISH=125,VF_CONTROLLER=126,VF_PROPERTY=127,VF_UI_TASK=128,VF_ROUTE=129,
 VF_PRESENT_SUBMIT=130,VF_COALESCE=131,VF_WORKER=132,VF_FLUSH=133,VF_READY_WAIT=134,
 VF_SAMPLE=135,VF_ENQUEUE=136,VF_MATERIAL=137,VF_BIND=138,VF_ENTITY=139,
 VF_DISCARD=140,VF_FAILURE=141,VF_GPU_EPOCH=142,VF_GPU_ENCODE=143,VF_GPU_COMMIT=144,
 VF_GPU_COMPLETE=145,VF_GPU_RESUME=146,VF_GPU_TIMES=147,VF_IMAGE=148,
 VF_TEXTURE_LEFT=149,VF_TEXTURE_RIGHT=150,VF_PREVIEW=151,VF_CLEANUP=152,
 VF_CONTROL_INTENT=160,VF_CONTROL_ACTOR=161,VF_OBSERVER_END=162,VF_STATE=163,VF_LINK=164,
 VF_AUDIO_RATE_CHANGE=180,VF_AUDIO_SEGMENT=181,VF_AUDIO_SEGMENT_META=182,
 VF_AUDIO_MAP_REPORT=183,VF_AUDIO_MAP_SYSTEM=184,VF_AUDIO_MAP_RESET=185,
 VF_AUDIO_MAP_FAILURE=186,VF_AUDIO_PLAY=187,VF_AUDIO_FILTER=188,VF_AUDIO_SYNC=189,
 VF_QUEUE_PRESSURE_SAMPLE=240,VF_QUEUE_PRESSURE_TIMING=241,VF_QUEUE_PRESSURE_PROGRESS=242,
 VF_QUEUE_PRESSURE_RESULT=243,VF_QUEUE_PRESSURE_DECISION=244,
 VF_CONTROL_SOURCE_VALIDATION=246,
 VF_CONTROL_PRESENTATION_DRAIN=247,
 VF_VT_PREROLL_DECISION=250,
 VF_VT_PREROLL_SUBMIT=251,
 VF_VT_PREROLL_CALLBACK=252,
 VF_VT_PREROLL_DPB=253,
 VF_VT_PREROLL_FALLBACK=254,
 VF_BUFFER_EPISODE=300,
 VF_BUFFER_STATE=301,
 VF_BUFFER_THRESHOLD=302,
 VF_BUFFER_COMPONENTS=303,
 VF_BUFFER_DECODER=304,
 VF_BUFFER_CLOCK=305,
 VF_PREROLL_TARGET=306,
 VF_DECODER_IDENTITY=307,
 VF_DECODER_START_WAIT=308,
 VF_DECODER_READY=309,
 VF_DECODER_WAIT=310,
 VF_DECODER_STOP_WAIT=311,
 VF_DECODER_PREROLL=312,
 VF_DECODER_PREROLL_COUNTS=313,
 VF_DECODER_FORCED=314,
 VF_DECODER_OUTPUT_WAIT=315,
 VF_DECODER_WAIT_FLAGS=316,
 VF_BUFFER_PREROLL_MARK=317,
 VF_INPUT_SEEK_QUEUED=318,
 VF_INPUT_CONTROL_EXEC=319,
 VF_INPUT_CONTROL_REPLACED=320,
 VF_VOUT_FORCED_HANDOFF=330,
 VF_VOUT_FORCED_HANDOFF_STATE=331,
 VF_VT_SAMPLE_CONTEXT=484,
 VF_VT_INPUT_TIMING=485,
 VF_VT_SAMPLE_DURATION=486,
 VF_VT_SAMPLE_PTS=487,
 VF_VT_SAMPLE_DTS=488,
 VF_VT_SAMPLE_SHAPE=489,
 VF_VT_SAMPLE_SUMMARY=490,
 VF_VT_FORMAT_IDENTITY=491,
 VF_VT_SAMPLE_EPOCHS=492,
 VF_VOUT_RENDER_DEFERRED=332
};
int VFStart(uint64_t session);
uint64_t VFSession(void);
uint64_t VFNew(uint32_t stage,uint32_t phase,uint64_t parent,int64_t a,int64_t b,int64_t c);
void VFEmit(uint64_t id,uint32_t stage,uint32_t phase,int64_t tick,int64_t a,int64_t b,int64_t c);
uint64_t VFParent(void);
uint64_t VFSetParent(uint64_t id);
void VFBind(const void *object,uint64_t id);
uint64_t VFFind(const void *object);
void VFUnbind(const void *object);
int VFTrigger(uint32_t reason);
int VFStop(uint64_t session);
/* capacity=0/records=NULL refreshes cumulative header without consuming records. */
size_t VFDrain(VFHeader *header,VFRecord *records,size_t capacity);
size_t VFExport(VFHeader *header,VFRecord *records,size_t capacity);
int64_t VFClock(void);
/* Scopes restore parent even on early return; no waits or heap allocation. */
typedef struct {uint64_t id,previous;uint32_t stage;} VFScope;
static inline VFScope VFOpen(uint32_t stage,uint64_t parent,int64_t a,int64_t b,int64_t c){uint64_t id=VFNew(stage,VF_BEGIN,parent,a,b,c);uint64_t previous=VFSetParent(id);return (VFScope){id,previous,stage};}
static inline void VFClose(VFScope *s){VFEmit(s->id,s->stage,VF_END,0,0,0,0);VFSetParent(s->previous);}
#define VF_SCOPE(name,stage,parent,a,b,c) VFScope name __attribute__((cleanup(VFClose)))=VFOpen(stage,parent,a,b,c)
#define VF_CALL(stage,expr) ({VF_SCOPE(vf_call_scope,stage,VFParent(),0,0,0); __auto_type vf_result=(expr); vf_result;})
#define VF_VOID(stage,expr) do {VF_SCOPE(vf_void_scope,stage,VFParent(),0,0,0);expr;} while(0)
#ifdef __cplusplus
}
#endif
#endif
