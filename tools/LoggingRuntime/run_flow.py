from pathlib import Path
import subprocess,tempfile,json,hashlib
R=Path(__file__).resolve().parents[2];T=R/'.build/logging-runtime';T.mkdir(parents=True,exist_ok=True)
C=R/'NativeBuild/overlay/inputs/current/vista-recovery-144/native/source/flow'
# Clock adapter only; real native lane/record and complete Swift writer are compiled unchanged.
clock=T/'clock.c';clock.write_text('#include <time.h>\n#include <stdint.h>\nint64_t vrr_now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (int64_t)t.tv_sec*1000000+t.tv_nsec/1000;}\n')
for src,obj in [(C/'vista_flow_trace.c',T/'flow.o'),(clock,T/'clock.o')]:subprocess.run(['xcrun','clang','-std=c11','-O2','-c',str(src),'-o',str(obj)],check=True)
rows=[]
for mode,flags in [('Release',[]),('Diagnostic',['-D','VISTA_DIAGNOSTICS','-D','VISTA_FLOW_TEST'])]:
 exe=T/('Flow-'+mode)
 subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-D','VISTA_VLC_CANDIDATE',*flags,'-import-objc-header',str(C/'vista_flow_trace.h'),str(R/'Sources/VistaCore/PlaybackFlowTrace.swift'),str(Path(__file__).parent/'Flow.swift'),str(T/'flow.o'),str(T/'clock.o'),'-o',str(exe)],check=True)
 root=Path(tempfile.mkdtemp(prefix='Flow-'+mode+'-clean-',dir=T));p=subprocess.run([str(exe),str(root)],capture_output=True,text=True,timeout=40)
 files={str(x.relative_to(root)):{'bytes':x.stat().st_size,'sha256':hashlib.sha256(x.read_bytes()).hexdigest()} for x in root.rglob('*') if x.is_file()}
 rows.append({'mode':mode,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'before':{},'after':files,'container':str(root.relative_to(R))});(T/'flow.json').write_text(json.dumps(rows,indent=2));print(mode,p.returncode,p.stdout,flush=True);assert not p.returncode,p.stderr
 assert bool(files)==(mode=='Diagnostic')
