from pathlib import Path
import subprocess,json,hashlib,os
ROOT=Path(__file__).resolve().parents[2];T=ROOT/'.build/logging-runtime';T.mkdir(parents=True,exist_ok=True)
pkg=T/'package';pkg.mkdir(exist_ok=True)
for name,target in [('VistaCore',ROOT/'Sources/VistaCore'),('VistaMedia',ROOT/'Sources/VistaMedia')]:
 p=pkg/name
 if not p.exists():p.symlink_to(target,target_is_directory=True)
exe=pkg/'Runtime';exe.mkdir(exist_ok=True);(exe/'main.swift').write_text((Path(__file__).parent/'FullWriters.swift').read_text())
# No product source altered or stubbed. Diagnostic is optimized, not DEBUG.
(pkg/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package=Package(name:"VistaLogRuntime",platforms:[.macOS(.v14)],products:[.executable(name:"Runtime",targets:["Runtime"])],targets:[
.target(name:"VistaCore",path:"VistaCore",resources:[.copy("Resources")]),
.target(name:"VistaMedia",dependencies:["VistaCore"],path:"VistaMedia"),
.executableTarget(name:"Runtime",dependencies:["VistaCore","VistaMedia"],path:"Runtime")])
''')
def inventory(root):
 return {str(p.relative_to(root)):{'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(root.rglob('*')) if p.is_file()}
rows=[]
for mode,flags in [('Release',[]),('Diagnostic',['-Xswiftc','-DVISTA_DIAGNOSTICS'])]:
 scratch=T/('build-'+mode);cmd=['swift','build','-c','release','--package-path',str(pkg),'--scratch-path',str(scratch),*flags]
 with (T/(mode+'-build.log')).open('w') as log:p=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT)
 assert not p.returncode,mode+' compile failed'
 output=subprocess.check_output(cmd+['--show-bin-path'],text=True).strip();binary=Path(output)/'Runtime'
 # Exclusive fresh directory; refuse to silently reuse or clear an existing container.
 import tempfile
 root=Path(tempfile.mkdtemp(prefix=mode+'-clean-',dir=T));before=inventory(root)
 env=os.environ.copy();env['HOME']=str(root);env['CFFIXED_USER_HOME']=str(root);env['TMPDIR']=str(root)
 p=subprocess.run([str(binary),str(root)],capture_output=True,text=True,env=env);after=inventory(root)
 row={'mode':mode,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'before':before,'after':after,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'container':str(root.relative_to(ROOT))};rows.append(row);print(mode,p.returncode,p.stdout,flush=True)
 (T/'writers.json').write_text(json.dumps({'runs':rows,'scope':'Complete current VistaCore and VistaMedia product modules on macOS; exercise real lifecycle/playback/controller writers and encoders. No full visionOS UI, VLC playback, or physical AV execution.'},indent=2))
 assert not p.returncode,p.stderr
 assert bool(after)==(mode=='Diagnostic'),after
