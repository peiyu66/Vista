#!/bin/bash
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd); F="$D"; P=${1:?macos or xros}; B="$D/vlc-build-$P"
case "$P" in
macos) SDKNAME=macosx; TARGET=arm64-apple-macos14.0; CONTRIB="$F/contrib-prefix";;
xros) SDKNAME=xros; TARGET=arm64-apple-xros2.0; CONTRIB="$F/contrib-prefix-xros";;
*) exit 2;; esac
python3 - "$D" "$P" "$CONTRIB" <<'PY'
from pathlib import Path
import subprocess,sys,json
r=Path(sys.argv[1]);p=sys.argv[2];c=Path(sys.argv[3]);b=r/f'vlc-build-{p}';libs=[];names=[]
for target in (r/f'evidence/vlc-{p}-module-targets.txt').read_text().splitlines():
 lib=b/'modules/.libs'/target.replace('.la','.a');libs.append(lib)
 out=subprocess.check_output(['/usr/bin/nm','-g',str(lib)],text=True)
 sym=[s.split()[-1][1:] for s in out.splitlines() if ' T _vlc_entry__' in s];assert len(sym)==1,(lib,sym);names+=sym
code='#include <stddef.h>\n#include <vlc_plugin.h>\n'+'\n'.join('VLC_ENTRY_FUNC('+n+');' for n in names)+'\nconst vlc_plugin_cb vlc_static_modules[] = {\n'+''.join('    '+n+',\n' for n in names)+'    NULL\n};\n'
(r/f'artifacts/static-module-list-{p}.c').write_text(code)
libs.extend([b/'lib/.libs/libvlc.a',b/'src/.libs/libvlccore.a',b/'compat/.libs/libcompat.a'])
libs.extend(sorted((c/'lib').glob('*.a')))
libs.extend([r/f'prefix-{p}/lib/libavcodec.a',r/f'prefix-{p}/lib/libavutil.a',r/f'artifacts/static-module-list-{p}.o'])
(r/f'evidence/static-libs-list-{p}.txt').write_text('\n'.join(map(str,libs))+'\n')
(r/f'evidence/static-module-symbols-{p}.json').write_text(json.dumps(names,indent=2)+'\n')
PY
xcrun --sdk "$SDKNAME" clang -c -target "$TARGET" -isysroot "$(xcrun --sdk "$SDKNAME" --show-sdk-path)" -DHAVE_CONFIG_H -I"$B" -I"$D/source/vlc/include" "$D/artifacts/static-module-list-$P.c" -o "$D/artifacts/static-module-list-$P.o"
/usr/bin/libtool -static -no_warning_for_no_symbols -filelist "$D/evidence/static-libs-list-$P.txt" -o "$D/artifacts/libvlc-vista-audio-$P.a"
