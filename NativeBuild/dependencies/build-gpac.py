from pathlib import Path
import os,json,subprocess,hashlib
R=Path(__file__).resolve().parent;B=R/'gpac-build';B.mkdir(exist_ok=True)
for name in ['tmp','module-cache','src/utils','src/isomedia','src/odf','src/media_tools','bin/gcc']:(B/name).mkdir(parents=True,exist_ok=True)
env=os.environ.copy()
for k in ['CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH','LIBRARY_PATH','SDKROOT','MACOSX_DEPLOYMENT_TARGET','IPHONEOS_DEPLOYMENT_TARGET','PKG_CONFIG_PATH','PKG_CONFIG_LIBDIR']:env.pop(k,None)
env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin',TMPDIR=str(B/'tmp'),CLANG_MODULE_CACHE_PATH=str(B/'module-cache'))
options=json.loads((R/'gpac-options.json').read_text())+['--cross-prefix='+str(R/'toolchain/xros-'),'--prefix='+str(R/'gpac-prefix')]
with (R/'logs/gpac-configure.log').open('w') as f:p=subprocess.run([str(R/'source/gpac-26.07.0/configure'),*options],cwd=B,env=env,stdout=f,stderr=subprocess.STDOUT)
assert p.returncode==0,'GPAC configure failed; inspect logs/gpac-configure.log'
with (R/'logs/gpac-build.log').open('w') as f:p=subprocess.run(['/usr/bin/make','-j3','-f',str(R/'GPACSubset.mk'),'probe'],cwd=B/'src',env=env,stdout=f,stderr=subprocess.STDOUT)
assert p.returncode==0,'GPAC build failed; inspect logs/gpac-build.log'
a=B/'bin/gcc/libgpac_static.a';j={'path':str(a.relative_to(R)),'sha256':hashlib.sha256(a.read_bytes()).hexdigest(),'bytes':a.stat().st_size,'builtFromSource':True,'platform':'arm64-apple-xros2.0','executedTargetBinaries':False};(R/'evidence/gpac-build.json').write_text(json.dumps(j,indent=2));print(json.dumps(j))
