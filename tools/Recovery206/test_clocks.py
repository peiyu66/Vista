from pathlib import Path
import re,subprocess,json,hashlib
from paths import ROOT,R,N,T
def fun(s,name):
 m=re.search(r'(?m)^(?:static\s+)?(?:bool|void|vlc_tick_t)\s*\n?'+name+r'\([^;{}]*\)\s*\{',s);assert m,name
 i=s.index('{',m.start())+1;depth=1
 while depth:depth+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[m.start():i]
ip=(N/'src/clock/input_clock.c').read_text();mc=(N/'src/clock/clock.c').read_text();inp=(N/'src/input/input.c').read_text()
pre=r'''
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <math.h>
#include <inttypes.h>
typedef int64_t vlc_tick_t;
#define VLC_TICK_INVALID 0
#define VLC_INPUT_CLOCK_RESUME 7
#define VLC_INPUT_CLOCK_GENERAL 1
#define VLC_TICK_FROM_MS(x) ((int64_t)(x)*1000)
#define CR_MAX_GAP 300000
#define CR_BUFFERING_RATE 48
#define CR_BUFFERING_TARGET 100000
#define INPUT_CLOCK_LATE_COUNT 3
#define __MAX(a,b) ((a)>(b)?(a):(b))
#define vlc_warning(...) ((void)0)
#define PLAYING_S 1
typedef struct{int64_t stream,system;}clock_point_t;
typedef struct{int value;}average_t;
static unsigned resets,drift_updates;
static void AvgReset(average_t*a){a->value=0;resets++;}
static void AvgUpdate(average_t*a,int64_t v){a->value=v;drift_updates++;}
static int64_t AvgGet(average_t*a){return a->value;}
static clock_point_t clock_point_Create(int64_t system,int64_t stream){return (clock_point_t){.system=system,.stream=stream};}
typedef struct{bool b_paused,b_has_reference,b_origin_changed;vlc_tick_t i_pause_date,i_next_drift_update,i_buffering_duration,i_pts_delay;clock_point_t ref,last;float rate;average_t drift;struct{int64_t pi_value[3];unsigned i_index;}late;}input_clock_t;
struct vlc_clock_context{double rate,coeff;vlc_tick_t offset;clock_point_t last,wait_sync_ref,start_time;};
typedef struct{int lock,cond;bool paused;vlc_tick_t pause_date;clock_point_t first_pcr;struct vlc_clock_context*context;}vlc_clock_main_t;
static int broadcasts,listeners,general_updates,events;static vlc_tick_t event_date;
static void vlc_mutex_assert(int*p){assert(*p==1);}
static void vlc_cond_broadcast(int*p){(void)p;broadcasts++;}
static void UpdateListener(input_clock_t*c,bool d,int reason){(void)c;assert(!d);if(reason==VLC_INPUT_CLOCK_RESUME)listeners++;else{assert(reason==VLC_INPUT_CLOCK_GENERAL);general_updates++;}}
typedef struct{int i_state;}input_thread_private_t;
typedef struct{input_thread_private_t priv;}input_thread_t;
static input_thread_private_t*input_priv(input_thread_t*p){return &p->priv;}
static void input_SendEventState(input_thread_t*p,int state,int64_t date){assert(p&&state==PLAYING_S);events++;event_date=date;}
'''
parts=[fun(ip,n) for n in ['ClockStreamToSystem','ClockSystemToStream','input_clock_Update','input_clock_ChangePause']]+[fun(mc,'vlc_clock_main_ChangePause'),fun(inp,'vista_hold189_resume_timer')]
main=r'''
int main(void){
 unsigned checks=0;
 for(int with_start=0;with_start<2;with_start++){
  input_clock_t input={.b_has_reference=true,.rate=3,.ref={460227001,1000000},.last={460277001,1016666}};
  struct vlc_clock_context ctx={.rate=3,.coeff=1,.offset=2000000,.last={460277001,1016666},.start_time={460227001,with_start?1000000:0},.wait_sync_ref={460227001,1000000}};
  vlc_clock_main_t main={.lock=1,.context=&ctx,.first_pcr={460227001,1000000}};
  const int64_t pts[]={460063001,460084001,460106001,460127001,460148001,460170001,460191001,460212001,460234001,460255001,460276001};
  for(int episode=0;episode<3;episode++){
   int64_t before[11];for(int i=0;i<11;i++)before[i]=ClockStreamToSystem(&input,pts[i]);
   int64_t initialRef=input.ref.system,initialLast=input.last.system,mainLast=ctx.last.system,offset=ctx.offset,start=ctx.start_time.system,pcr=main.first_pcr.system,sync=ctx.wait_sync_ref.system;
   int64_t paused=2000000+episode*1000000,duration=episode==0?77870:episode==1?838802:21000;
   input_clock_ChangePause(&input,true,paused);vlc_clock_main_ChangePause(&main,paused,true);
   assert(input.ref.system==initialRef&&main.paused&&input.b_paused);checks++;
   input_clock_ChangePause(&input,false,paused+duration);vlc_clock_main_ChangePause(&main,paused+duration,false);
   assert(input.ref.system==initialRef+duration&&input.last.system==initialLast+duration&&ctx.last.system==mainLast+duration&&main.first_pcr.system==pcr+duration&&ctx.wait_sync_ref.system==sync+duration);checks++;
   assert(with_start?ctx.start_time.system==start+duration:ctx.offset==offset+duration);checks++;
   for(int i=0;i<11;i++){int64_t after=ClockStreamToSystem(&input,pts[i]);assert(after==before[i]+duration);if(i)assert(after-ClockStreamToSystem(&input,pts[i-1])==before[i]-before[i-1]);checks++;}
  }
 }
 assert(listeners==6&&broadcasts==6);
 /* Advance PCR while wall clock is frozen, as es_out does during rebuffering.
    Include >300ms stream movement: it must not reset an established reference. */
 for(int extra=0;extra<2;extra++){
  input_clock_t input={.b_has_reference=true,.rate=3,.ref={.stream=460000001,.system=1000000},.last={.stream=460000001,.system=1000000}};
  const int64_t pts[]={460063001,460084001,460106001,460127001,460148001,460170001,460191001,460212001,460234001,460255001,460276001,461000001};
  int64_t expected[12];for(int i=0;i<12;i++)expected[i]=ClockStreamToSystem(&input,pts[i]);
  input_clock_ChangePause(&input,true,1000000);
  for(int i=0;i<12;i++){
   input_clock_Update(&input,false,true,extra,pts[i],1000000);
   assert(input.ref.system==1000000&&input.ref.stream==460000001);checks++;
   assert(input.last.system==1000000&&input.last.stream==pts[i]&&input.b_paused);checks++;
   assert(ClockStreamToSystem(&input,pts[i])==expected[i]);checks++;
   assert(resets==0&&drift_updates==0&&input.i_buffering_duration<=100000);checks++;
  }
  input_clock_ChangePause(&input,false,1838802);
  for(int i=0;i<12;i++){assert(ClockStreamToSystem(&input,pts[i])==expected[i]+838802);checks++;}
 }
 assert(general_updates==24);checks++;
 input_thread_t player={.priv={PLAYING_S}};assert(vista_hold189_resume_timer(&player,9000000,false));assert(events==1&&event_date==9000000);
 assert(!vista_hold189_resume_timer(&player,9000001,true));player.priv.i_state=2;assert(!vista_hold189_resume_timer(&player,9000002,false));assert(!vista_hold189_resume_timer(NULL,9000003,false));assert(events==1);checks+=5;
 printf("%u assertions PASS: actual input/main pause shifts preserve media spacing at rate3; PCR updates under frozen wall clock preserve reference; actual timer resume guard\n",checks);return 0;
}
'''
src=R/'tests/clocks.c';src.write_text(pre+'\n'+'\n'.join(parts)+'\n'+main);rows=[]
for name,flags in [('release',['-O2']),('asan-ubsan',['-O1','-g','-fsanitize=address,undefined'])]:
 exe=R/'tests'/('clocks-'+name);cmd=['xcrun','clang','-std=c11',*flags,str(src),'-o',str(exe)];p=subprocess.run(cmd,capture_output=True,text=True);assert p.returncode==0,p.stderr;p=subprocess.run([str(exe)],capture_output=True,text=True);assert p.returncode==0,p.stderr;rows.append({'mode':name,'stdout':p.stdout,'exit':p.returncode});print(p.stdout.strip())
(R/'validation/clocks.json').write_text(json.dumps({'rows':rows,'sources':{name:hashlib.sha256((N/name).read_bytes()).hexdigest() for name in ['src/clock/input_clock.c','src/clock/clock.c','src/input/input.c']},'limits':['Exact native pause/date and timer guard functions with scalar clock/event stubs.','PCR test executes actual Update and conversions; average helpers are scalar stubs, asserted no reset/drift-update on established-reference buffered path.', 'No PCM conversion, audio render callback or physical AV measurement; clock equality alone is not complete AV synchronization proof.']},indent=2))
