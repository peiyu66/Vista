from pathlib import Path
import subprocess,json,re,hashlib,tempfile
R=Path(__file__).resolve().parents[2];D=R/'.build/store213/input-log-tests';D.mkdir(parents=True,exist_ok=True)
s=(R/'VistaApp/ShortcutBrowser.swift').read_text();core=(R/'tools/Store213/InputMemoryProbe.swift').read_text();adapter=(R/'tools/Store213/InputProbeLog.swift').read_text()
assert s.split('// INPUT_PROBE_CORE_BEGIN\n')[1].split('// INPUT_PROBE_CORE_END')[0]==core
assert adapter in s
assert 'VISTA_SHORTCUT_INPUT_PROBE' not in s and 'ShortcutInputProbeView' not in s
assert 'UIPasteboard' not in core+adapter
(D/'ExactProbe.swift').write_text('import CoreGraphics\n#if DEBUG || VISTA_DIAGNOSTICS\n'+core+adapter+'\n#endif\n')
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
results={}
for config,flags in [('Diagnostic',['-D','VISTA_DIAGNOSTICS']),('Release',[])]:
 exe=D/config
 cmd=['xcrun','--sdk','macosx','swiftc','-swift-version','6','-target','arm64-apple-macosx14.0','-sdk',sdk,'-O','-parse-as-library','-module-cache-path',str(D/'module-cache'),*flags,'-o',str(exe),str(R/'Sources/VistaCore/LifecycleDiagnostics.swift'),str(D/'ExactProbe.swift'),str(R/'tools/Store213/InputLogTests.swift')]
 c=subprocess.run(cmd,capture_output=True,text=True);(D/(config+'-compile.log')).write_text(c.stdout+c.stderr);assert c.returncode==0,c.stderr
 runtime=Path(tempfile.mkdtemp(prefix=config+'-',dir=D));x=subprocess.run([str(exe),str(runtime)],capture_output=True,text=True);assert x.returncode==0,x.stdout+x.stderr
 files=[{'path':str(p.relative_to(runtime)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in runtime.rglob('*') if p.is_file()]
 assert (bool(files) if config=='Diagnostic' else [f['path'] for f in files]==['existing-logs/current.jsonl'])
 results[config]={'output':x.stdout.strip(),'files':files,'runtime':str(runtime.relative_to(R))};print(x.stdout.strip())
results['scope']='Exact embedded recorder/adapter and shared writer, actual host execution; not complete visionOS app runtime or gesture validation.'
(D/'receipt.json').write_text(json.dumps(results,indent=2)+'\n')
