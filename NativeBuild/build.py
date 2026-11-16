#!/usr/bin/env python3
"""Build Vista178 native corresponding sources and/or relink the app; never sign or run."""
from pathlib import Path
import argparse,os,json,hashlib,tarfile,subprocess,shutil,datetime
N=Path(__file__).resolve().parent;ROOT=N.parent;D=N/'dependencies';O=N/'overlay';E=ROOT/'engine'
p=argparse.ArgumentParser();p.add_argument('stage',choices=['prepare','native','app','all'],nargs='?',default='all');p.add_argument('--allow-modified-sources',action='store_true');args=p.parse_args()
env=os.environ.copy();env['GIT_CEILING_DIRECTORIES']=str(ROOT)
if args.allow_modified_sources:env['VISTA_ALLOW_MODIFIED_SOURCES']='1'
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
def run(label,cmd,cwd=ROOT):
 print(label,flush=True);log=D/'logs'/(label+'.log')
 with log.open('w') as f:r=subprocess.run(cmd,cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT)
 if r.returncode:raise SystemExit(f'{label} failed ({r.returncode}); see {log}')
def extract(archive,target,strip=False):
 if target.exists():return
 target.mkdir(parents=True)
 with tarfile.open(archive) as t:
  for m in t:
   if strip:
    parts=m.name.split('/')[1:]
    if not parts:continue
    m.name='/'.join(parts)
   t.extract(m,target,filter='data')
def prepare():
 for x in json.loads((N/'archives.json').read_text()):
  a=N/'archives'/x['file'];assert sha(a)==x['sha256'],str(a)
 for x in ['logs','evidence','artifacts','build-xros']:(D/x).mkdir(parents=True,exist_ok=True)
 archives=N/'archives'
 mapping=[('ffmpeg-9.0.tar.xz',D/'source/ffmpeg-9.0'),('utfcpp-3.2.5.tar.gz',D/'contrib-src/utfcpp-3.2.5'),('libebml-1.4.6.tar.xz',D/'contrib-src/libebml-1.4.6'),('libmatroska-1.7.2.tar.xz',D/'contrib-src/libmatroska-1.7.2'),('gpac-26.07.0-vista-source.tar.xz',D/'source/gpac-26.07.0')]
 for a,target in mapping:extract(archives/a,target,True)
 vlc=D/'source/vlc'
 if not vlc.exists():
  extract(archives/'vlc-f7caf7922478f6cb7f1654b813d0c462d3e86f4a.tar.gz',vlc,True)
  run('vlc-patch-check',['git','apply','--check',str(N/'vlc-base-compat.patch')],vlc)
  run('vlc-patch',['git','apply',str(N/'vlc-base-compat.patch')],vlc)
  shutil.copy2(N/'vlc-revision.txt',vlc/'src/revision.txt')
def native():
 tool_paths=[env.get('VISTA_BUILD_TOOLS',''),'/opt/homebrew/opt/m4/bin','/opt/homebrew/opt/libtool/libexec/gnubin','/opt/homebrew/bin',env.get('PATH','')]
 env['PATH']=os.pathsep.join(p for p in tool_paths if p)
 required=['xcrun','python3','make','cmake','pkg-config','autoreconf','autoconf','automake','aclocal','m4']
 missing=[name for name in required if shutil.which(name,path=env['PATH']) is None]
 if missing:raise SystemExit('Missing build tools: '+', '.join(missing)+'. See NativeBuild/README.md; use PATH or VISTA_BUILD_TOOLS for an existing tools bin directory.')
 prepare()
 run('ffmpeg',['bash',str(D/'build-ffmpeg.sh'),'xros'])
 run('contrib',['bash',str(D/'build-contrib-xros.sh')])
 run('gpac',['python3',str(D/'build-gpac.py')])
 run('vlc-bootstrap',['bash',str(D/'bootstrap-vlc.sh')])
 run('vlc',['bash',str(D/'build-vlc.sh'),'xros'])
 run('vlc-archive',['bash',str(D/'archive-vlc.sh'),'xros'])
 run('overlay',['python3',str(O/'build.py')])
 target=E/'vlc/Vendor/libvlc-vista-cache-xros.a';shutil.copy2(D/'artifacts/libvlc-vista-audio-xros.a',target)
 objects=[O/'build'/x['object'] for x in json.loads((O/'recipes.json').read_text())]
 run('merge-overlay',['xcrun','ar','-r',str(target),*map(str,objects)])
 run('index-archive',['xcrun','ranlib',str(target)])
 for name in ['libs/xros','config/xros','vlc/Vendor/config']:(E/name).mkdir(parents=True,exist_ok=True)
 shutil.copy2(D/'gpac-build/bin/gcc/libgpac_static.a',E/'libs/xros/libgpac_static.a')
 shutil.copy2(D/'gpac-build/config.h',E/'config/xros/config.h')
 shutil.copytree(D/'source/gpac-26.07.0/include',E/'vendor/gpac-26.07.0/include',dirs_exist_ok=True)
 shutil.copy2(D/'vlc-build-xros/config.h',E/'vlc/Vendor/config/config.h')
 run('parser',['zsh',str(E/'build-parser.sh'),'xros'])
 run('producer',['zsh',str(E/'build-engine.sh'),'xros'])
 sdk=subprocess.check_output(['xcrun','--sdk','xros','--show-sdk-path'],text=True).strip()
 run('budget',['xcrun','clang++','-std=c++17','-O2','-Wall','-Wextra','-target','arm64-apple-xros2.0','-isysroot',sdk,'-I'+str(E/'source/producer'),'-c',str(E/'source/producer/ParserBudget.cpp'),'-o',str(E/'libs/xros/budget.o')])
 artifacts=[target,*[E/'libs/xros'/x for x in ['libgpac_static.a','parser.o','budget.o','MKVProducer.o']]]
 (N/'receipt.json').write_text(json.dumps({'nativeBuildPassed':True,'artifacts':{str(f.relative_to(ROOT)):sha(f) for f in artifacts},'allowModifiedSources':args.allow_modified_sources,'builtUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'signed':False,'launched':False},indent=2))
def app():
 (D/'logs').mkdir(parents=True,exist_ok=True)
 run('app',['xcodebuild','-project',str(ROOT/'VistaBrowser.xcodeproj'),'-scheme','VistaBrowser','-configuration','Release','-sdk','xros','-destination','generic/platform=visionOS','-derivedDataPath',str(ROOT/'.build/release'),'-clonedSourcePackagesDirPath',str(ROOT/'.build/SourcePackages'),'-jobs','4','-disableAutomaticPackageResolution','-skipPackageUpdates','CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','build'])
 print('Unsigned app: '+str(ROOT/'.build/release/Build/Products/Release-xros/Vista.app'),flush=True)
if args.stage=='prepare':prepare()
if args.stage in ('native','all'):native()
if args.stage in ('app','all'):app()
