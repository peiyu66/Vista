from pathlib import Path
import re,subprocess,json,hashlib
from paths import ROOT,R,N,T
def fun(s,name):
 m=re.search(r'(?m)^(?:static\s+)?(?:bool|int|void)\s*\n?'+name+r'\([^;{}]*\)\s*\{',s);assert m,name
 b=s.index('{',m.start());j=b+1;depth=1
 while depth:depth+=(s[j]=='{')-(s[j]=='}');j+=1
 return s[m.start():j]
e=(N/'src/input/es_out.c').read_text();d=(N/'src/input/decoder.c').read_text()
pre=r'''
#include <assert.h>
#include <stdio.h>
#include <pthread.h>
#include "vista_hold187_internal.h"
typedef int64_t vlc_tick_t;
#define VLC_SUCCESS 0
#define VLC_EGENERIC -1
#define VIDEO_ES 1
#define AUDIO_ES 2
#define VLC_CODEC_HEVC 77
#define VF_BEGIN 1
#define VF_END 2
#define VF_POINT 3
struct format{int i_codec,i_cat;};
struct vlc_input_decoder_t {int cat;struct{struct format *fmt_in;}dec;bool paused,output_paused,flushing,aborting,b_waiting;int64_t pause_date,output_pause_date;struct{bool started;void*vout;}video;VHRRequest*vista_hold187;int *p_fifo;bool sync,b_idle,b_draining;};
typedef struct vlc_input_decoder_t vlc_input_decoder_t;
typedef struct{vlc_input_decoder_t*p_dec;struct format fmt;}es_out_id_t;
typedef struct {bool b_paused,b_buffering,b_rebuffering,vista_hold187_attempted;bool vista_forward_source_buffering,vista_forward_source_ended;uint64_t vista_forward_input_requests,vista_forward_source_waits;void*p_next_frame_es,*p_sout_record,*p_pgrm;double rate;VHRRequest*vista_hold187;uint64_t vista_hold187_flow;es_out_id_t es[2];}es_out_sys_t;
static int64_t now=1000000;static unsigned pauses,resumes,logs,checks,queued,released;static int lockdepth;
static int64_t vlc_tick_now(void){return now;}
static void vlc_fifo_Lock(int*x){(void)x;assert(!lockdepth);lockdepth++;}
static void vlc_fifo_Unlock(int*x){(void)x;assert(lockdepth==1);lockdepth--;}
static void vlc_fifo_Signal(int*x){(void)x;}
static bool vlc_fifo_IsEmpty(int*x){return *x==0;}
static bool vlc_input_decoder_IsSynchronous(vlc_input_decoder_t*o){return o->sync;}
#define foreach_es_then_es_slaves(es) for((es)=p_sys->es;(es)!=p_sys->es+2;(es)++)
static bool EsOutIsPaused(es_out_sys_t*s){return s->b_paused||s->b_rebuffering;}
static void EsOutChangeOutputPause(es_out_sys_t*s,bool pause,int64_t date){if(pause)pauses++;else resumes++;for(unsigned i=0;i<2;i++){vlc_input_decoder_t*d=s->es[i].p_dec;if(d){d->paused=d->output_paused=pause;d->pause_date=d->output_pause_date=date;}}}
static void input_SendEventCache(void*x,double y){(void)x;(void)y;}
#define p_input p_pgrm
static uint64_t VFParent(void){return 0;}
static uint64_t VFNew(int a,int b,uint64_t c,int64_t d,int64_t e,int64_t f){(void)a;(void)b;(void)c;(void)d;(void)e;(void)f;return ++logs;}
static void VFEmit(uint64_t a,int b,int c,uint64_t d,int64_t e,int64_t f,int64_t g){(void)a;(void)b;(void)c;(void)d;(void)e;(void)f;(void)g;logs++;}
static void VistaHoldEnd(es_out_sys_t*,unsigned,unsigned,bool,bool);
bool vista_hold189_resume_timer(void *input,int64_t date,bool still_paused){(void)input;(void)date;return !still_paused;}
struct picture{int64_t date;};typedef struct picture picture_t;
static void vout_PutPicture(void*v,picture_t*p){(void)v;queued++;free(p);}
static void picture_Release(picture_t*p){released++;free(p);}
'''
parts=[fun(d,x) for x in ['vista_hold187_decoder_begin','vista_hold187_decoder_end','vista_hold187_decoder_paused','vista_hold_forward_input_state']]
parts+=[fun(e,x) for x in ['EsOutChangePause','EsOutChangeRebuffer','VistaSourceRebuffer','VistaHoldEnd','VistaHoldBegin','VistaHoldTick']]
# Exact product picture admission block, with a mock queue sink only.
a=d.index('    if(p_owner->vista_hold187 && p_owner->paused && p_owner->output_paused)');b=d.index('    bool prerolled',a)
parts+=['static int play(vlc_input_decoder_t*p_owner,picture_t*p_picture){void*p_vout=p_owner->video.vout;\n'+d[a:b]+'picture_Release(p_picture);return -1;}']
i=(N/'src/input/input.c').read_text()
parts += [r'''
#include <stdarg.h>
#define PLAYING_S 1
#define PAUSE_S 2
#define ERROR_S 3
#define DEMUX_SET_PAUSE_STATE 1
#define msg_Warn(...) ((void)0)
#define msg_Err(...) ((void)0)
typedef struct {bool paused;int fail;} demux_t;
struct master {bool b_can_pause;demux_t*p_demux;};
typedef struct{es_out_sys_t*p_es_out_display,*p_es_out;int i_state;bool b_pause_after_buffering;struct master*master;} input_thread_private_t;
typedef struct{input_thread_private_t priv;}input_thread_t;
static input_thread_private_t*input_priv(input_thread_t*p){return &p->priv;}
static int demux_Control(demux_t*d,int ignored,bool pause){(void)ignored;if(d->fail)return -1;d->paused=pause;return 0;}
static bool es_out_GetBuffering(es_out_sys_t*s){return s->b_buffering||s->b_rebuffering;}
static int es_out_SetPauseState(es_out_sys_t*s,bool can,bool pause,int64_t date){(void)can;EsOutChangePause(s,pause,date);return 0;}
static void input_ChangeState(input_thread_t*p,int state,int64_t date){(void)date;p->priv.i_state=state;}
static int es_out_PrivControl(es_out_sys_t*s,int query,...){
 if(query==VHR_ES_TICK)return VistaHoldTick(s);
 assert(query==VHR_ES_CANCEL);va_list ap;va_start(ap,query);int keep=va_arg(ap,int);va_end(ap);
 VistaHoldEnd(s,VHR_CANCELLED,4,keep==1,keep==2);return 0;
}
''']+[fun(i,x)for x in ['ControlPause','ControlUnpause','VistaHoldInputTick']]
main=r'''
#define C(x) do{checks++;if(!(x)){fprintf(stderr,"%d %s\n",__LINE__,#x);abort();}}while(0)
static es_out_sys_t sys;static vlc_input_decoder_t video,audio;static struct format vf={VLC_CODEC_HEVC,VIDEO_ES},af={1,AUDIO_ES};static int depth=100;
static void setup(void){C(!sys.vista_hold187);memset(&sys,0,sizeof(sys));memset(&video,0,sizeof(video));memset(&audio,0,sizeof(audio));video=(vlc_input_decoder_t){.cat=VIDEO_ES,.dec={&vf},.video={true,(void*)1},.p_fifo=&depth};audio=(vlc_input_decoder_t){.cat=AUDIO_ES,.dec={&af},.p_fifo=&depth};sys=(es_out_sys_t){.rate=3,.p_pgrm=(void*)1,.es={{&video,{VLC_CODEC_HEVC,VIDEO_ES}},{&audio,{1,AUDIO_ES}}}};now=1000000;depth=100;pauses=resumes=logs=queued=released=0;}
static VHRRequest*request(void){VHRRequest*r=vhr_new((VHRInput){1,3000000,now,3});C(r);return r;}
static void picture(int64_t pts){picture_t*p=malloc(sizeof(*p));p->date=pts;vlc_fifo_Lock(video.p_fifo);C(play(&video,p)==0);vlc_fifo_Unlock(video.p_fifo);}
static void*racer(void*opaque){VHRRequest*r=opaque;for(int i=0;i<20000;i++){VHRResult s=vhr_read(r);assert(s.command==1);if(i==10000)atomic_store(&r->cancel,true);}return NULL;}
int main(void){
 setup();VHRRequest*r=request();C(VistaHoldBegin(&sys,r)==0);C(pauses==1&&resumes==0&&sys.b_rebuffering);C(atomic_load(&r->refs)==3);C(vhr_running(r,now));
 picture(2900001);C(queued==0&&released==1);picture(3000001);C(queued==1);picture(3016668);C(queued==1&&released==2);C(!vhr_running(r,now));
 audio.output_paused=false;C(VistaHoldTick(&sys)==1&&resumes==0);audio.output_paused=true;now+=180000;C(VistaHoldTick(&sys)==0);C(vhr_read(r).state==VHR_RESUMED&&resumes==1&&!sys.b_rebuffering);C(atomic_load(&r->refs)==1);C(!video.vista_hold187);C(logs==5);C(vhr_read(r).pause_ack_mask==3);C(vhr_read(r).resume_requested&&vhr_read(r).timer_resume_sent);
 VHRRequest*second=request();C(VistaHoldBegin(&sys,second)==0);C(pauses==2);VistaHoldEnd(&sys,VHR_CANCELLED,4,false,false);vhr_release(second);vhr_release(r);
 setup();r=request();C(VistaHoldBegin(&sys,r)==0);now+=600000;C(VistaHoldTick(&sys)==1&&vhr_read(r).state==VHR_HOLDING&&resumes==0);sys.vista_forward_source_ended=true;depth=0;video.b_idle=true;C(VistaHoldTick(&sys)==0);C(vhr_read(r).state==VHR_FAILED&&vhr_read(r).reason==5&&resumes==1);vhr_release(r);
 setup();r=request();C(VistaHoldBegin(&sys,r)==0);atomic_store(&r->preserve_pause,true);atomic_store(&r->cancel,true);C(VistaHoldTick(&sys)==2);demux_t dm={0};struct master ma={true,&dm};input_thread_t input={.priv={&sys,&sys,PLAYING_S,false,&ma}};C(VistaHoldInputTick(&input)==0);C(input.priv.i_state==PAUSE_S&&dm.paused);C(sys.b_paused&&!sys.b_rebuffering&&resumes==0&&audio.paused);ControlUnpause(&input,now);C(input.priv.i_state==PLAYING_S&&!dm.paused);C(resumes==1);vhr_release(r);
 setup();r=request();C(VistaHoldBegin(&sys,r)==0);VistaHoldEnd(&sys,VHR_CANCELLED,4,false,false);C(resumes==1&&vhr_read(r).state==VHR_CANCELLED);vhr_release(r);
 setup();r=request();C(VistaHoldBegin(&sys,r)==0);VistaHoldEnd(&sys,VHR_CANCELLED,4,false,true);C(resumes==0&&atomic_load(&r->refs)==1);vhr_release(r);
 setup();r=request();now+=100001;C(VistaHoldBegin(&sys,r)!=0&&pauses==0);vhr_release(r);
 setup();r=request();atomic_store(&r->cancel,true);C(VistaHoldBegin(&sys,r)!=0&&pauses==0);vhr_release(r);
 setup();r=request();depth=0;C(VistaHoldBegin(&sys,r)==0&&pauses==1&&video.vista_hold187);C(VistaHoldTick(&sys)==3);VistaHoldEnd(&sys,VHR_CANCELLED,4,false,false);C(atomic_load(&r->refs)==1);vhr_release(r);
 setup();r=request();video.sync=true;C(VistaHoldBegin(&sys,r)!=0&&pauses==0);vhr_release(r);
 setup();r=request();sys.b_buffering=true;C(VistaHoldBegin(&sys,r)!=0&&pauses==0);vhr_release(r);
 setup();r=request();sys.es[1].p_dec=NULL;C(VistaHoldBegin(&sys,r)!=0&&pauses==0);vhr_release(r);
 setup();r=request();sys.rate=2.5;C(VistaHoldBegin(&sys,r)!=0&&pauses==0);vhr_release(r);
 setup();r=request();now+=100000;C(VistaHoldBegin(&sys,r)==0);C(vhr_read(r).target_us==3300000);picture(3550002);C(queued==0&&released==1);now+=600000;C(VistaHoldTick(&sys)==1);VistaHoldEnd(&sys,VHR_CANCELLED,4,false,false);vhr_release(r);
 C(!vhr_new((VHRInput){1,0,1,NAN}));C(!vhr_new((VHRInput){1,0,1,INFINITY}));C(!vhr_new((VHRInput){0,0,1,3}));
 r=vhr_new((VHRInput){1,INT64_MAX,1000000,3});C(r&&!vhr_begin(r,1000001));vhr_release(r);
 r=vhr_new((VHRInput){1,0,1000000,3});C(!vhr_begin(r,INT64_MIN));C(!vhr_begin(r,999999));vhr_release(r);
 // Output resume is not timer resume while another buffering reason survives.
 setup();r=request();C(VistaHoldBegin(&sys,r)==0);sys.b_buffering=true;VistaHoldEnd(&sys,VHR_CANCELLED,4,false,false);C(!vhr_read(r).resume_requested&&!vhr_read(r).timer_resume_sent);vhr_release(r);
 setup();r=request();C(VistaHoldBegin(&sys,r)==0);VistaHoldEnd(&sys,VHR_CANCELLED,4,true,false);C(!vhr_read(r).resume_requested&&!vhr_read(r).timer_resume_sent);vhr_release(r);

 // Actual coordinator: supply needs both pause acknowledgements and FIFO demand.
 setup();r=request();C(VistaHoldBegin(&sys,r)==0);depth=0;
 audio.output_paused=false;C(VistaHoldTick(&sys)==1);audio.output_paused=true;
 C(VistaHoldTick(&sys)==3);depth=1;C(VistaHoldTick(&sys)==1);
 VistaSourceRebuffer(&sys,false,now);C(sys.b_rebuffering&&resumes==0&&audio.paused);
 VistaSourceRebuffer(&sys,true,now);C(VistaHoldTick(&sys)==4&&sys.vista_forward_source_waits==1);
 picture(3000001);C(vhr_read(r).state==VHR_READY);C(VistaHoldTick(&sys)==4&&resumes==0);
 VistaSourceRebuffer(&sys,false,now);C(resumes==0);C(VistaHoldTick(&sys)==0&&resumes==1);vhr_release(r);
 // External source wait must survive explicit recovery cancellation.
 setup();r=request();C(VistaHoldBegin(&sys,r)==0);VistaSourceRebuffer(&sys,true,now);
 atomic_store(&r->cancel,true);C(VistaHoldTick(&sys)==0);C(sys.b_rebuffering&&resumes==0&&audio.paused);
 VistaSourceRebuffer(&sys,false,now);C(!sys.b_rebuffering&&resumes==1);vhr_release(r);
 // EOF waits for actual decoder drain, never merely an empty FIFO.
 setup();r=request();C(VistaHoldBegin(&sys,r)==0);sys.vista_forward_source_ended=true;depth=0;video.b_idle=true;video.b_draining=true;
 C(VistaHoldTick(&sys)==1&&vhr_read(r).state==VHR_HOLDING);video.b_draining=false;
 C(VistaHoldTick(&sys)==0&&vhr_read(r).reason==5);vhr_release(r);
 // Owner mismatch/flush cannot issue data demand for an obsolete request.
 setup();r=request();C(VistaHoldBegin(&sys,r)==0);depth=0;video.flushing=true;
 C(vista_hold_forward_input_state(&video,r)==0);video.flushing=false;VHRRequest*foreign=request();C(vista_hold_forward_input_state(&video,foreign)==0);vhr_release(foreign);
 atomic_store(&r->cancel,true);C(VistaHoldTick(&sys)==0);vhr_release(r);

 // Real atomic/refcount and mutex handoff under concurrent polling/cancel.
 setup();r=request();C(VistaHoldBegin(&sys,r)==0);pthread_t t;C(!pthread_create(&t,NULL,racer,r));for(int i=0;i<20000;i++)vhr_picture(r,2000000,now);C(!pthread_join(t,NULL));VistaHoldTick(&sys);C(vhr_read(r).state==VHR_CANCELLED&&atomic_load(&r->refs)==1);vhr_release(r);
 printf("%u assertions PASS; exact native coordinator/decoder helpers and request synchronization; no device/decode replay\n",checks);return 0;
}
'''
f=T/'hold187.c';f.write_text(pre+'\n'+'\n'.join(parts)+'\n'+main)
cmd=['clang','-std=gnu11','-g','-O1','-fsanitize=address,undefined','-fno-omit-frame-pointer','-I'+str(N),str(f),'-o',str(T/'hold187')]
p=subprocess.run(cmd,capture_output=True,text=True);(T/'compile.log').write_text(p.stdout+p.stderr);assert p.returncode==0,p.stderr
p=subprocess.run([str(T/'hold187')],capture_output=True,text=True);print(p.stdout,p.stderr)
(R/'validation/forward-tests.json').write_text(json.dumps({'command':cmd,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'sources':{str(x.relative_to(R)):hashlib.sha256(x.read_bytes()).hexdigest() for x in [N/'src/input/es_out.c',N/'src/input/decoder.c',N/'vista_hold187_internal.h',f]},'limits':'Actual extracted helpers with mocked FIFO/output/device coordination; real request pthread mutex and atomic refs, no real decoder or device AV quality verification.'},indent=2)+'\n');assert p.returncode==0
