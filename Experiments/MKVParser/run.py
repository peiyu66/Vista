#!/usr/bin/env python3
"""Trusted synthetic-fixture experiment. No downloads, installs, private input or App changes."""
import hashlib
import json
import re
import random
import os
import sys
from pathlib import Path
import subprocess
import tempfile

sanitize = sys.argv[1:] == ['--sanitize']
if sys.argv[1:] and not sanitize: raise SystemExit('Only --sanitize is supported')
if sanitize:
    os.environ['UBSAN_OPTIONS'] = 'halt_on_error=1:print_stacktrace=1'
    os.environ['ASAN_OPTIONS'] = 'abort_on_error=1'
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
run(['clang++', *cpp, *(['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if sanitize else []), experiment / 'Probe.cpp', experiment / 'AllocationBudget.cpp', vendor / 'mkvparser/mkvparser.cc', '-o', output / 'probe'])
run(['swiftc', '-parse-as-library', experiment / 'HardwareProbe.swift', '-o', output / 'hardware'])
run(['swiftc', '-swift-version', '6', '-parse-as-library', experiment / 'BoundedRangeCache.swift', experiment / 'CacheTests.swift', '-o', output / 'cache-tests'])
run([output / 'cache-tests'])
for codec, fixture in [('h264', root / 'Sources/VistaCore/Resources/Synthetic.mp4'),
                       ('hevc', root / 'Tests/VistaCoreTests/Resources/SyntheticHEVC.mp4')]:
    movie = output / (codec + '.mkv')
    run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-n', '-i', fixture,
         '-map', '0:v:0', '-c', 'copy', '-map_metadata', '-1', movie])
    result = run([output / 'probe', movie], capture_output=True, text=True)
    assert 'ALLOCATION_STATS live=0 ' in result.stderr and 'READER_HANDLES live=0' in result.stderr
    print(result.stderr.strip(), flush=True)
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
    for mode in ['cancel', 'cancel-midway', 'budget', 'alloc-budget']:
        rejected = subprocess.run([str(output / 'probe'), str(movie), mode], capture_output=True)
        assert rejected.returncode == 1 and not rejected.stdout and b'PROTOTYPE_REJECTED' in rejected.stderr
        assert b'ALLOCATION_STATS live=0 ' in rejected.stderr and b'READER_HANDLES live=0' in rejected.stderr
        if mode == 'alloc-budget': assert int(re.search(rb'rejected=(\d+)', rejected.stderr)[1]) >= 1
    short = output / (codec + '-truncated.mkv')
    short.write_bytes(movie.read_bytes()[:10])
    rejected = subprocess.run([str(output / 'probe'), str(short)], capture_output=True)
    assert rejected.returncode == 1 and not rejected.stdout
    assert b'ALLOCATION_STATS live=0 ' in rejected.stderr and b'READER_HANDLES live=0' in rejected.stderr
    print('REJECTION_VERIFIED', codec, 'cancel, midway-cancel, read-budget, allocation-budget, truncated-header', flush=True)

# Malformed structures and deterministic mutations stay in the isolated executable.
def element(identifier, payload):
    length = len(payload)
    width = next(n for n in range(1, 9) if length < (1 << (7 * n)) - 1)
    return bytes.fromhex(identifier) + ((1 << (7 * width)) | length).to_bytes(width, 'big') + payload
header = element('1a45dfa3', element('4286', b'\x01') + element('42f7', b'\x01') +
                 element('42f2', b'\x04') + element('42f3', b'\x08') + element('4282', b'matroska') +
                 element('4287', b'\x04') + element('4285', b'\x02'))
entry = element('ae', element('d7', b'\x01') + element('73c5', b'\x01') + element('83', b'\x01') +
                element('86', b'V_MPEG4/ISO/AVC') + element('63a2', b'\x01' * 300000) +
                element('e0', element('b0', b'\x40') + element('ba', b'\x40')))
attack = header + element('18538067', element('1549a966', element('2ad7b1', b'\x0f\x42\x40')) + element('1654ae6b', entry))
for name, data in [('oversized-codec-private', attack), ('invalid-vint', b'\x00' * 32),
                   ('unknown-header-size', bytes.fromhex('1a45dfa3ff'))]:
    path = output / (name + '.mkv'); path.write_bytes(data)
    rejected = subprocess.run([str(output / 'probe'), str(path)], capture_output=True, timeout=5)
    assert rejected.returncode == 1 and not rejected.stdout and b'ALLOCATION_STATS live=0 ' in rejected.stderr and b'READER_HANDLES live=0' in rejected.stderr
    if name == 'oversized-codec-private':
        assert int(re.search(rb'rejected=(\d+)', rejected.stderr)[1]) >= 1
    print('MALFORMED_REJECTED', name, rejected.stderr.decode().strip().splitlines()[-1], flush=True)
rng = random.Random(20261103)
seed = (output / 'h264.mkv').read_bytes()
for index in range(128):
    changed = bytearray(seed)
    position = rng.randrange(len(changed))
    changed[position] ^= 1 << rng.randrange(8)
    path = output / 'mutation.mkv'; path.write_bytes(changed)
    result = subprocess.run([str(output / 'probe'), str(path)], capture_output=True, timeout=5)
    assert result.returncode in (0, 1) and b'ALLOCATION_STATS live=0 ' in result.stderr and b'READER_HANDLES live=0' in result.stderr, (index, result.returncode, result.stderr)
print('MUTATIONS_BOUNDED_AND_RELEASED', 128, flush=True)

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
    run(['xcrun', 'swiftc', '-swift-version', '6', '-typecheck', '-parse-as-library', '-target', target, '-sdk', sdkpath,
         experiment / 'BoundedRangeCache.swift', experiment / 'CacheTests.swift'])
    print('PLATFORM_COMPILE_VERIFIED', sdk, 'archive_bytes', archive.stat().st_size, flush=True)
print('EXPERIMENT_COMPLETE: app unchanged; not an SMB or device playback test', flush=True)
