from pathlib import Path
import subprocess,json,tempfile,hashlib,argparse
R=Path(__file__).resolve().parents[2];T=R/'.build/logging-runtime';T.mkdir(parents=True,exist_ok=True)
p=argparse.ArgumentParser();p.add_argument('--host-libs',type=Path,required=True);p.add_argument('--host-config',type=Path,required=True);a=p.parse_args()
# Current producer is always recompiled; only unchanged parser/GPAC dependencies are supplied.
obj=T/'MKVProducer-macos.o';cmd=['xcrun','clang++','-std=c++17','-O2','-Wno-deprecated-declarations','-DGPAC_HAVE_CONFIG_H','-I'+str(a.host_config),'-I'+str(R/'engine/vendor/gpac-26.07.0/include'),'-I'+str(R/'engine/vendor/libwebm'),'-I'+str(R/'engine/source/producer'),'-c',str(R/'engine/source/producer/MKVProducer.cpp'),'-o',str(obj)]
subprocess.run(cmd,check=True)
exe=T/'Producer';subprocess.run(['xcrun','clang++','-std=c++17','-O2','-I'+str(R/'engine/source/producer'),str(Path(__file__).parent/'Producer.cpp'),str(obj),*[str(a.host_libs/n) for n in ['parser.o','budget.o','libgpac_static.a']],'-lc++','-lz','-framework','CoreFoundation','-Wl,-dead_strip','-o',str(exe)],check=True)
rows=[]
for mode in ['Release','Diagnostic']:
 root=Path(tempfile.mkdtemp(prefix='Producer-'+mode+'-clean-',dir=T));p=subprocess.run([str(exe),str(root),mode,str(R/'Resources/LocalMKVDemo/MKVDemo12s_mono.mkv')],text=True,capture_output=True,timeout=70)
 files={str(f.relative_to(root)):{'bytes':f.stat().st_size,'sha256':hashlib.sha256(f.read_bytes()).hexdigest()} for f in root.rglob('*') if f.is_file()}
 rows.append({'mode':mode,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'before':{},'after':files,'container':str(root.relative_to(R))});(T/'producer.json').write_text(json.dumps({'runs':rows,'sourceSHA256':hashlib.sha256((R/'engine/source/producer/MKVProducer.cpp').read_bytes()).hexdigest(),'scope':'Real native producer normal and failed read paths; mode selects the same empty/nonempty receipt used by product SourceAdapterSession. No full Swift adapter or VLC playback execution.','dependencyHashes':{n:hashlib.sha256((a.host_libs/n).read_bytes()).hexdigest() for n in ['parser.o','budget.o','libgpac_static.a']}},indent=2));print(mode,p.returncode,p.stdout,flush=True);assert not p.returncode,p.stderr
 assert bool(files)==(mode=='Diagnostic'),files
