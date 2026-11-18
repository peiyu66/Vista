"""Compare runtime sources with only Diagnostic branches removed; no file writes."""
import argparse,re,json
from pathlib import Path
FILES=['Sources/VistaMedia/NativePlaybackSession.swift','Sources/VistaMedia/HardwarePlayback.swift','Sources/VistaCore/PlaybackPrefetchSource.swift','Sources/VistaSMB/SMBMediaReader.swift','Sources/VistaCore/MediaReadPlan.swift','engine/vlc/Sources/AsyncInputContext.swift','engine/vlc/Sources/VLCPlaybackDriver.swift','engine/source/source-adapter/SMBOperationSource.swift','engine/source/source-adapter/LocalOperationSource.swift']
def release_text(source):
    out=[];stack=[];skip=False
    for line in source.splitlines():
        clean=line.strip()
        if clean.startswith('#if '):
            stack.append((skip,clean in ['#if DEBUG || VISTA_DIAGNOSTICS', '#if VISTA_SEEK_CHUNK_1M', '#if VISTA_EARLY_SEEK_PLAY', '#if VISTA_READ_PHASE216']))
            if stack[-1][1]:skip=True
            elif not skip:out.append(line)
        elif clean=='#else' and stack:
            old,ours=stack[-1]
            if ours:skip=old
            elif not skip:out.append(line)
        elif clean=='#endif' and stack:
            old,ours=stack.pop()
            if not ours and not skip:out.append(line)
            skip=old
        elif not skip:out.append(line)
    assert not stack
    return re.sub(r'\s+','', '\n'.join(out).replace('Int(MediaReadPlan.nativeChunkBytes)', '2 * 1_048_576'))
def main():
    args=argparse.ArgumentParser();args.add_argument('baseline',type=Path);base=args.parse_args().baseline
    root=Path(__file__).resolve().parents[2]
    result={f:release_text((root/f).read_text())==release_text((base/f).read_text()) for f in FILES}
    print(json.dumps(result,indent=2));assert all(result.values())
if __name__=='__main__':main()
