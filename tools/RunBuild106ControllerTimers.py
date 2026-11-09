"""Run exact accepted controller task timers with local type substitutes, not UI."""
from pathlib import Path
import argparse, subprocess, re
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
r=Path(__file__).resolve().parents[1];a.output.mkdir(parents=True,exist_ok=True)
v=(r/'VistaApp/VRPresentation.swift').read_text()
start=v.index('@MainActor @Observable final class VRPresentation {');end=v.index('    var image:',start)
controller=v[start:end]+'}\n'
callbacks=re.findall(r'\.onChange\(of: presentation\.player\?\.speedStatus\.selected\) \{ _, _ in (.*?) \}',v)
assert callbacks==['presentation.scheduleHide()']
t=(r/'tools/Build106ControllerTimerTests.swift').read_text()
s=t.replace('// PRODUCTION_CONTROLLER',controller).replace('// PRODUCTION_RATE_OBSERVER','@MainActor func selectedRateDidChange(_ presentation: VRPresentation) { '+callbacks[0]+' }')
source=a.output/'ExtractedControllerTimerTests.swift';source.write_text(s)
subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(source),'-o',str(a.output/'timer-tests')],check=True)
subprocess.run([str(a.output/'timer-tests'),str(a.output/'timer-results.json')],check=True,timeout=30)
