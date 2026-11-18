from pathlib import Path
import subprocess,tempfile,json,hashlib
R=Path(__file__).resolve().parents[2];D=R/'.build/seek216-writers';D.mkdir(parents=True,exist_ok=True);P=D/'package';P.mkdir(exist_ok=True)
for name in ['VistaCore','VistaMedia']:
 p=P/name
 if not p.exists():p.symlink_to(R/'Sources'/name,target_is_directory=True)
(P/'Runtime').mkdir(exist_ok=True);(P/'Runtime/main.swift').write_text((R/'tools/MP4SeekDiagnostics/Runtime.swift').read_text())
(P/'Package.swift').write_text('''// swift-tools-version:6.0
import PackageDescription
let package=Package(name:"VistaSeekWriters",platforms:[.macOS(.v14)],targets:[.target(name:"VistaCore",path:"VistaCore",resources:[.copy("Resources")]),.target(name:"VistaMedia",dependencies:["VistaCore"],path:"VistaMedia"),.executableTarget(name:"Runtime",dependencies:["VistaCore","VistaMedia"],path:"Runtime")])
''')
rows=[]
for mode,flags in [('Release',[]),('Diagnostic',['-Xswiftc','-DVISTA_DIAGNOSTICS','-Xswiftc','-DVISTA_SEEK_CHUNK_1M','-Xswiftc','-DVISTA_EARLY_SEEK_PLAY','-Xswiftc','-DVISTA_READ_PHASE216'])]:
 cmd=['swift','build','-c','release','--package-path',str(P),'--scratch-path',str(D/mode),*flags]
 with (D/(mode+'-build.log')).open('w') as log:x=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT)
 assert x.returncode==0,mode+' build failed'
 binary=Path(subprocess.check_output(cmd+['--show-bin-path'],text=True).strip())/'Runtime'
 symbols=subprocess.check_output(['strings','-a',str(binary)],text=True)
 assert ('VistaMP4SeekDiagnostics' in symbols)==(mode=='Diagnostic'),mode+' seek trace compile gate'
 runtime=Path(tempfile.mkdtemp(prefix=mode+'-runtime-',dir=D));(runtime/'existing.jsonl').write_text('preserved\n');x=subprocess.run([str(binary),str(runtime)],capture_output=True,text=True);assert x.returncode==0,x.stderr
 files=[{'path':str(p.relative_to(runtime)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in runtime.rglob('*') if p.is_file()]
 assert (runtime/'existing.jsonl').read_text()=='preserved\n';assert bool([f for f in files if f['path']!='existing.jsonl'])==(mode=='Diagnostic');rows.append({'mode':mode,'stdout':x.stdout,'runtime':str(runtime.relative_to(R)),'files':files});print(x.stdout,flush=True)
 (D/'receipt.json').write_text(json.dumps({'runs':rows,'scope':'Complete actual current VistaCore/VistaMedia writer modules on macOS; not full visionOS UI or physical playback. No environment HOME override.'},indent=2)+'\n')
