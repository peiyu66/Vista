#!/usr/bin/env python3
"""Exercise accepted cap-3 admission and omitted-input metadata dependencies.
Uses actual source helpers, pthread locks and fake decoder callbacks; no device.
"""
from pathlib import Path
import subprocess,tempfile,json,shutil,hashlib
R=Path(__file__).resolve().parents[2];T=Path(__file__).parent
N=R/'NativeBuild/overlay/inputs/current/vista-recovery-168/native/source'
s=(N/'modules/codec/videotoolbox/decoder.c').read_text()
assert '#define VI198_CAP 3' in (N/'vista_inflight198.h').read_text()
assert 'VistaInflight198Enabled' not in s and 'vsp_api' not in s
assert 'pending_metadata202' in s and 'VTDecompressionSessionWaitForAsynchronousFrames' in s
assert 'deadline' not in s[s.index('static uint64_t VistaAdmission198('):s.index('static void VistaDrain198(')]
assert 'VLCVistaCatchupStart' not in (R/'engine/vlc/Sources/VLCPlaybackDriver.swift').read_text()
rows=[]
with tempfile.TemporaryDirectory(prefix='vista-accepted204-') as tmp:
 t=Path(tmp)
 for n in ['gate198.c','omit202.c','pacer-extracted202.inc']:shutil.copy2(T/n,t/n)
 a=s.index('static uint64_t VistaAdmission198(');b=s.index('#pragma mark - start & stop',a);(t/'admission-extracted198.inc').write_text(s[a:b])
 a=s.index('static int VistaTryOmit202(');b=s.index('static CMVideoCodecType CodecPrecheck',a);(t/'metadata-extracted202.inc').write_text(s[a:b])
 for name in ['gate198','omit202']:
  for mode,flags in [('release',['-O2']),('asan-ubsan',['-O1','-g','-fsanitize=address,undefined']),('tsan',['-O1','-g','-fsanitize=thread'])]:
   exe=t/(name+'-'+mode);cmd=['xcrun','clang','-std=c11','-Wall','-Wextra','-I'+str(N),str(t/(name+'.c')),'-o',str(exe),*flags]
   p=subprocess.run(cmd,capture_output=True,text=True);assert p.returncode==0,p.stderr
   p=subprocess.run([str(exe)],capture_output=True,text=True,timeout=40);assert p.returncode==0,p.stderr
   row={'test':name,'mode':mode,**json.loads(p.stdout)};rows.append(row);print(json.dumps(row),flush=True)
o=R/'.build/accepted204';o.mkdir(parents=True,exist_ok=True)
(o/'host-results.json').write_text(json.dumps({'results':rows,'decoderSHA256':hashlib.sha256(s.encode()).hexdigest(),'limits':'Real admission/metadata helpers and pacer; fake callback, FIFO-control and DPB provider. Not physical audio/video verification.'},indent=2))
