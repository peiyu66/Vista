"""Host/synthetic validation and unsigned xros builds only. No device commands."""
import argparse,hashlib,json,subprocess,time
from pathlib import Path
R=Path(__file__).resolve().parents[2];D=R/'.build/mp4-seek';D.mkdir(parents=True,exist_ok=True)
p=argparse.ArgumentParser();p.add_argument('baseline',type=Path);baseline=p.parse_args().baseline
inputs=sorted([*R.joinpath('Sources').rglob('*.swift'),*R.joinpath('Tests').rglob('*.swift'),R/'VistaBrowser.xcodeproj/project.pbxproj'])
hashes={str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs}
commands=[('source-equivalence',['python3','tools/MP4SeekDiagnostics/verify_release_source.py',str(baseline)]),
 ('analyzer',['python3','tools/MP4SeekDiagnostics/test_analyzer.py']),
 ('regression',['swift','test','--filter','MP4SeekDiagnosticsTests|NativePlaybackSessionTests|PlaybackPrefetchSourceTests|PlaybackRangeDiagnosticsTests|SMBPlaybackSourceTests|SMBRangeTests|NativeVideoDeliveryDiagnosticsTests|LifecycleDiagnosticsTests']),
 ('writers',['python3','tools/MP4SeekDiagnostics/test_writers.py'])]
for config in ['Diagnostic','Release']:
 commands.append(('xros-'+config,['xcodebuild','-project','VistaBrowser.xcodeproj','-scheme','VistaBrowser','-configuration',config,'-sdk','xros','-destination','generic/platform=visionOS','-derivedDataPath','.build/mp4-seek/xros','-clonedSourcePackagesDirPath','.build/mp4-seek/packages','-jobs','4','-disableAutomaticPackageResolution','-skipPackageUpdates','CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','build']))
results=[]
for name,cmd in commands:
 log=D/('final-'+name+'.log');start=time.monotonic()
 with log.open('w') as f:r=subprocess.run(cmd,cwd=R,stdout=f,stderr=subprocess.STDOUT)
 results.append({'check':name,'returncode':r.returncode,'seconds':time.monotonic()-start,'log':str(log.relative_to(R))})
 (D/'validation.json').write_text(json.dumps({'checks':results,'sourceHashes':hashes,'scope':'Isolated host/synthetic runtime and unsigned xros builds; no device, installation, signing or upload.'},indent=2)+'\n')
 print(name,r.returncode,flush=True)
 if r.returncode:raise SystemExit(r.returncode)
assert all(hashlib.sha256((R/f).read_bytes()).hexdigest()==h for f,h in hashes.items()),'Sources changed during validation'
for config in ['Release','Diagnostic']:
 app=D/'xros/Build/Products'/f'{config}-xros/Vista.app'
 strings=subprocess.check_output(['strings','-a',str(app/'Vista')],text=True)
 assert ('VistaMP4SeekDiagnostics' in strings)==(config=='Diagnostic'),config+' executable gate'
print('PASS stable sources and final app trace compile gates',flush=True)
