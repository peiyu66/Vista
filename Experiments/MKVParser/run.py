#!/usr/bin/env python3
"""Trusted synthetic-fixture experiment. No downloads, installs, private input or App changes."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
experiment = root / 'Experiments/MKVParser'
vendor = experiment / 'vendor/libwebm'
output = Path(tempfile.mkdtemp(prefix='vista-mkv-experiment-'))

def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)

# Confirm the exact vendored bytes before compiling.
for line in (vendor / 'SHA256SUMS').read_text().splitlines():
    digest, name = line.split('  ', 1)
    assert hashlib.sha256((vendor / name).read_bytes()).hexdigest() == digest

cpp = ['-std=c++11', '-O2', '-I', vendor]
run(['clang++', *cpp, experiment / 'Probe.cpp', vendor / 'mkvparser/mkvparser.cc', '-o', output / 'probe'])
run(['swiftc', '-parse-as-library', experiment / 'HardwareProbe.swift', '-o', output / 'hardware'])
for codec, fixture in [('h264', root / 'Sources/VistaCore/Resources/Synthetic.mp4'),
                       ('hevc', root / 'Tests/VistaCoreTests/Resources/SyntheticHEVC.mp4')]:
    movie = output / (codec + '.mkv')
    run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-n', '-i', fixture,
         '-map', '0:v:0', '-c', 'copy', '-map_metadata', '-1', movie])
    result = run([output / 'probe', movie], capture_output=True, text=True)
    info = json.loads(result.stdout)
    assert len(info['samples']) == 24 and info['largestRead'] <= 65536 and info['bytes'] <= 1048576
    parsed = output / (codec + '.json')
    parsed.write_text(result.stdout)
    print('DEMUX_VERIFIED', codec, 'samples', len(info['samples']), 'reads', info['calls'],
          'bytes', info['bytes'], 'max_read', info['largestRead'], flush=True)
    run([output / 'hardware', parsed])
    run([output / 'probe', movie, 'bounds'])
    gap_result = run([output / 'probe', movie, 'gap'], capture_output=True, text=True)
    gap_info = json.loads(gap_result.stdout)
    assert gap_info['samples'] == info['samples'] and gap_info['privateHex'] == info['privateHex']
    assert gap_info['bytes'] < 4096
    print('VIRTUAL_4GIB_SKIP_VERIFIED', codec, 'bytes', gap_info['bytes'], flush=True)
    for mode in ['cancel', 'cancel-midway', 'budget']:
        rejected = subprocess.run([str(output / 'probe'), str(movie), mode], capture_output=True)
        assert rejected.returncode == 1 and not rejected.stdout and b'PROTOTYPE_REJECTED' in rejected.stderr
    short = output / (codec + '-truncated.mkv')
    short.write_bytes(movie.read_bytes()[:10])
    rejected = subprocess.run([str(output / 'probe'), str(short)], capture_output=True)
    assert rejected.returncode == 1 and not rejected.stdout
    print('REJECTION_VERIFIED', codec, 'cancel, midway-cancel, budget, truncated-header', flush=True)

# Static archives only: compilation does not install or launch anything on a device.
for sdk, target in [('macosx', 'arm64-apple-macos14.0'), ('xrsimulator', 'arm64-apple-xros2.0-simulator'),
                    ('xros', 'arm64-apple-xros2.0')]:
    sdkpath = run(['xcrun', '--sdk', sdk, '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
    obj = output / (sdk + '.o')
    archive = output / (sdk + '.a')
    run(['xcrun', '--sdk', sdk, 'clang++', *cpp, '-target', target, '-isysroot', sdkpath,
         '-c', vendor / 'mkvparser/mkvparser.cc', '-o', obj])
    run(['xcrun', 'libtool', '-static', '-o', archive, obj])
    run(['xcrun', 'swiftc', '-typecheck', '-parse-as-library', '-target', target, '-sdk', sdkpath,
         experiment / 'HardwareProbe.swift'])
    print('PLATFORM_COMPILE_VERIFIED', sdk, 'archive_bytes', archive.stat().st_size, flush=True)
print('EXPERIMENT_COMPLETE: app unchanged; not an SMB or device playback test', flush=True)
