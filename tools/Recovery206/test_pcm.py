"""Exercise unchanged native PCM render/pause with synthetic identifiable samples."""
from pathlib import Path
import re,subprocess,json,hashlib
from paths import ROOT,R,N,T;s=(N/'coreaudio_common.c').read_text()
def fun(name):
 m=re.search(r'(?m)^(?:static\s+)?(?:void|vlc_tick_t)\s*\n?'+name+r'\([^;{}]*\)\s*\{',s);assert m,name
 i=s.index('{',m.start())+1;depth=1
 while depth:depth+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[m.start():i]
pre=r'''
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdio.h>
typedef int64_t vlc_tick_t;
typedef struct frame{uint8_t*p_buffer;size_t i_buffer;struct frame*p_next;}block_t,vlc_frame_t;
typedef struct{void*sys;}audio_output_t;
#include "vista_audio_boundary162.h"
#include "vista_audio_producer164.h"
#define VLC_TICK_INVALID 0
#define VLC_UNUSED(x) ((void)(x))
#define VLC_TICK_FROM_NS(x) ((x)/1000)
#define CLOCK_UPTIME_RAW 1
#define TIMING_REPORT_DELAY_TICKS 1000000
#define VF_POINT 0
#define VFNew(...) 0
#define VFEmit(...) ((void)0)
static int64_t now=1000000;
static int reports,releases;
static int64_t last_position,last_system;
struct aout_sys_common{
 bool b_paused,started,b_muted,reserve_observing192;
 uint64_t i_out_size,i_total_bytes,i_underrun_size,reserve_callback192,reserve_underruns192;
 int i_rate;unsigned i_bytes_per_frame;
 int64_t first_play_date,first_pts,au_latency_ticks,i_dev_latency_ticks;
 size_t timing_report_last_written_bytes,timing_report_delay_bytes;
 block_t*p_out_chain,**pp_out_last;
 int64_t(*get_latency)(audio_output_t*);
 struct vaq_state vista_boundaries;struct vap_state vista_producer;
 int locked;
};
static void lock_lock(struct aout_sys_common*s){assert(!s->locked);s->locked=1;}
static void lock_unlock(struct aout_sys_common*s){assert(s->locked);s->locked=0;}
static int64_t vlc_tick_now(void){return now;}
static uint64_t clock_gettime_nsec_np(int x){(void)x;return now*1000;}
static int64_t HostTimeToTick(struct aout_sys_common*s,int64_t t){(void)s;return t/1000;}
static int64_t BytesToTicks(struct aout_sys_common*s,size_t n){return (int64_t)(n/s->i_bytes_per_frame)*1000000/s->i_rate;}
static size_t TicksToBytes(struct aout_sys_common*s,int64_t t){return (t*s->i_rate/1000000)*s->i_bytes_per_frame;}
static void block_Release(block_t*b){assert(!b->i_buffer);releases++;}
static void vrr_report(audio_output_t*a,int64_t n,int64_t t,int64_t p){(void)a;(void)n;(void)t;(void)p;}
static void vab_report(audio_output_t*a,int64_t n,int64_t t,int64_t p){(void)a;(void)n;(void)t;(void)p;}
static void aout_TimingReport(audio_output_t*a,int64_t t,int64_t p){(void)a;reports++;last_position=p;last_system=t;}
'''
main=r'''
int main(void){
 unsigned checks=0;
 for(int split=4;split<256;split+=4){
  uint8_t pcm[512],got[512],silence[64];for(unsigned i=0;i<sizeof pcm;i++)pcm[i]=(i*37+11)&255;
  block_t b={pcm+256,256,NULL},a={pcm,256,&b};
  struct aout_sys_common s={.started=true,.i_rate=48000,.i_bytes_per_frame=4,.i_out_size=512,.first_pts=460000001,.first_play_date=1,.p_out_chain=&a,.pp_out_last=&b.p_next,.timing_report_delay_bytes=1,.reserve_observing192=true};
  audio_output_t out={&s};
  assert(vaq_enqueue(&s.vista_boundaries,0,0,1,7,false,4,true)==1);
  ca_Render(&out,0,got,split,NULL);
  uint64_t consumed=s.i_total_bytes,queued=s.i_out_size,underrun=s.i_underrun_size;uint8_t*cursor=a.p_buffer;
  ca_Pause(&out,true,now);assert(s.b_paused&&!s.started);checks++;
  for(int j=0;j<3;j++){
   memset(silence,0xff,sizeof silence);bool mute=false;now+=100000;
   ca_Render(&out,0,silence,sizeof silence,&mute);
   assert(mute);for(unsigned k=0;k<sizeof silence;k++)assert(!silence[k]);
   assert(s.i_total_bytes==consumed&&s.i_out_size==queued&&s.i_underrun_size==underrun&&a.p_buffer==cursor);checks++;
  }
  ca_Pause(&out,false,now);assert(!s.b_paused&&!s.started);checks++;
  /* Two calls ensure post-resume timing reports occur, spanning a block boundary. */
  ca_Render(&out,0,got+split,4,NULL);
  s.timing_report_delay_bytes=1; /* Force existing periodic report branch in this small fixture. */
  ca_Render(&out,0,got+split+4,512-split-4,NULL);
  assert(!memcmp(pcm,got,512));checks++;
  assert(s.i_total_bytes==512&&!s.i_out_size&&!s.p_out_chain&&s.pp_out_last==&s.p_out_chain);checks++;
  assert(!s.i_underrun_size&&!s.reserve_underruns192);checks++;
  assert(last_position==460000001+BytesToTicks(&s,512)&&last_system>=now);checks++;
  assert(!s.locked);checks++;
 }
 assert(releases==126&&reports>=63);checks++;
 printf("%u assertions PASS: extracted ca_Render/ca_Pause preserve partial PCM blocks across pause, no duplicate/drop, correct media-position counts\n",checks);
}
'''
p=R/'tests/pcm.c';p.write_text(pre+'\n'+fun('GetLatency')+'\n'+fun('ca_Render')+'\n'+fun('ca_Pause')+'\n'+main);rows=[]
for mode,flags in [('release',['-O2']),('asan-ubsan',['-O1','-g','-fsanitize=address,undefined'])]:
 exe=R/'tests'/('pcm-'+mode);r=subprocess.run(['xcrun','clang','-std=c11',*flags,'-I'+str(N),str(p),'-o',str(exe)],capture_output=True,text=True);assert not r.returncode,r.stderr
 r=subprocess.run([str(exe)],capture_output=True,text=True);assert not r.returncode,r.stderr;print(r.stdout.strip());rows.append({'mode':mode,'exit':r.returncode,'stdout':r.stdout})
(R/'validation/pcm.json').write_text(json.dumps({'rows':rows,'sourceSHA256':hashlib.sha256(s.encode()).hexdigest(),'limits':['Exact native render/pause functions and actual boundary/producer helpers; synthetic identifiable PCM, mocked hardware clock/lock/report sink and frame release.','No AudioUnit stop/start or real device output, no time-stretch conversion; proves queue continuity only, not end-to-end audiovisual alignment.']},indent=2))
