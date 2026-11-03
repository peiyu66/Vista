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

sanitize = '--sanitize' in sys.argv[1:]
track = '--track' in sys.argv[1:]
if not set(sys.argv[1:]).issubset({'--sanitize', '--track'}): raise SystemExit('Only --sanitize and --track are supported')
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

# Generate a reviewable derived translation unit. Official source remains unchanged.
original = (vendor / 'mkvparser/mkvparser.cc').read_text()
assert original.count('new (std::nothrow)') == 44
patched = '#include "ParserBudget.hpp"\n' + original.replace('new (std::nothrow)', 'new (vista_parser::allocationTag, std::nothrow)')
assert 'new (std::nothrow)' not in patched
parser = output / 'budgeted-mkvparser.cc'; parser.write_text(patched)
cpp = ['-std=c++11', '-O2', '-I', vendor, '-I', experiment]
tracking = ['-DVISTA_TRACK_GLOBAL_ALLOCS', experiment / 'AllocationBudget.cpp'] if track else []
run(['clang++', *cpp, *(['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if sanitize else []),
     *tracking, experiment / 'Probe.cpp', parser, experiment / 'ParserBudget.cpp', '-o', output / 'probe'])
run(['clang++', *cpp, *(['-fsanitize=address,undefined'] if sanitize else []), experiment / 'ParserBudgetTests.cpp', experiment / 'ParserBudget.cpp', '-o', output / 'budget-tests'])
run([output / 'budget-tests'])
def clean(stderr):
    text = stderr.decode() if isinstance(stderr, bytes) else stderr
    return 'READER_HANDLES live=0' in text and (not track or 'ALLOCATION_STATS live=0 ' in text)
run(['swiftc', '-parse-as-library', experiment / 'HardwareProbe.swift', '-o', output / 'hardware'])
run(['swiftc', '-swift-version', '6', '-parse-as-library', experiment / 'BoundedRangeCache.swift', experiment / 'CacheTests.swift', '-o', output / 'cache-tests'])
run([output / 'cache-tests'])
for codec, fixture in [('h264', root / 'Sources/VistaCore/Resources/Synthetic.mp4'),
                       ('hevc', root / 'Tests/VistaCoreTests/Resources/SyntheticHEVC.mp4')]:
    movie = output / (codec + '.mkv')
    run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-n', '-i', fixture,
         '-map', '0:v:0', '-c', 'copy', '-map_metadata', '-1', movie])
    result = run([output / 'probe', movie], capture_output=True, text=True)
    assert clean(result.stderr)
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
        assert clean(rejected.stderr)
        if mode == 'alloc-budget': assert int(re.search(rb'PARSER_BUDGET charged=\d+ rejected=(\d+)', rejected.stderr)[1]) >= 1
    short = output / (codec + '-truncated.mkv')
    short.write_bytes(movie.read_bytes()[:10])
    rejected = subprocess.run([str(output / 'probe'), str(short)], capture_output=True)
    assert rejected.returncode == 1 and not rejected.stdout
    assert clean(rejected.stderr)
    print('REJECTION_VERIFIED', codec, 'cancel, midway-cancel, read-budget, allocation-budget, truncated-header', flush=True)

# Exercise the actual C++ parser through a dedicated-thread Swift async-source bridge.
bridge_objects = []
for name, source in [('parser', parser), ('budget', experiment / 'ParserBudget.cpp'), ('bridge', experiment / 'BridgeProbe.cpp')]:
    obj = output / (name + '-bridge.o')
    run(['clang++', *cpp, *(['-fsanitize=address'] if sanitize else []), '-c', source, '-o', obj])
    bridge_objects.append(obj)
run(['swiftc', '-swift-version', '6', '-parse-as-library', *(['-sanitize=address'] if sanitize else []),
     '-import-objc-header', experiment / 'BridgeProbe.h', experiment / 'BoundedRangeCache.swift',
     experiment / 'SyncRangeBridge.swift', experiment / 'BridgeTests.swift', *bridge_objects,
     '-Xlinker', '-lc++',
     '-o', output / 'bridge-tests'])
run([output / 'bridge-tests', output / 'h264.mkv', output / 'hevc.mkv'], timeout=15)

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
    assert rejected.returncode == 1 and not rejected.stdout and clean(rejected.stderr)
    if name == 'oversized-codec-private':
        assert int(re.search(rb'PARSER_BUDGET charged=\d+ rejected=(\d+)', rejected.stderr)[1]) >= 1
    print('MALFORMED_REJECTED', name, rejected.stderr.decode().strip().splitlines()[-1], flush=True)
rng = random.Random(20261103)
seed = (output / 'h264.mkv').read_bytes()
for index in range(128):
    changed = bytearray(seed)
    position = rng.randrange(len(changed))
    changed[position] ^= 1 << rng.randrange(8)
    path = output / 'mutation.mkv'; path.write_bytes(changed)
    result = subprocess.run([str(output / 'probe'), str(path)], capture_output=True, timeout=5)
    assert result.returncode in (0, 1) and clean(result.stderr), (index, result.returncode, result.stderr)
print('MUTATIONS_BOUNDED_AND_RELEASED', 128, flush=True)

# Static archives only: compilation does not install or launch anything on a device.
for sdk, target in [('macosx', 'arm64-apple-macos14.0'), ('xrsimulator', 'arm64-apple-xros2.0-simulator'),
                    ('xros', 'arm64-apple-xros2.0')]:
    sdkpath = run(['xcrun', '--sdk', sdk, '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
    obj = output / (sdk + '.o')
    archive = output / (sdk + '.a')
    run(['xcrun', '--sdk', sdk, 'clang++', *cpp, '-target', target, '-isysroot', sdkpath,
         '-c', parser, '-o', obj])
    budget_obj = output / (sdk + '-budget.o')
    run(['xcrun', '--sdk', sdk, 'clang++', *cpp, '-target', target, '-isysroot', sdkpath, '-c', experiment / 'ParserBudget.cpp', '-o', budget_obj])
    run(['xcrun', 'libtool', '-static', '-o', archive, obj, budget_obj])
    symbols = run(['nm', '-gU', archive], capture_output=True, text=True).stdout
    assert not re.search(r'\b(__Znwm|__Znam|__ZdlPv|__ZdaPv|__ZnwmRKSt9nothrow_t|__ZnamRKSt9nothrow_t)$', symbols, re.M)
    bridge_obj = output / (sdk + '-bridge.o')
    run(['xcrun', '--sdk', sdk, 'clang++', *cpp, '-target', target, '-isysroot', sdkpath, '-c', experiment / 'BridgeProbe.cpp', '-o', bridge_obj])
    run(['xcrun', 'swiftc', '-swift-version', '6', '-typecheck', '-parse-as-library', '-target', target, '-sdk', sdkpath,
         '-import-objc-header', experiment / 'BridgeProbe.h', experiment / 'BoundedRangeCache.swift',
         experiment / 'SyncRangeBridge.swift', experiment / 'BridgeTests.swift'])
    run(['xcrun', 'swiftc', '-typecheck', '-parse-as-library', '-target', target, '-sdk', sdkpath,
         experiment / 'HardwareProbe.swift'])
    run(['xcrun', 'swiftc', '-swift-version', '6', '-typecheck', '-parse-as-library', '-target', target, '-sdk', sdkpath,
         experiment / 'BoundedRangeCache.swift', experiment / 'CacheTests.swift'])
    print('PLATFORM_COMPILE_VERIFIED_NO_GLOBAL_ALLOCATOR_OVERRIDE', sdk, 'archive_bytes', archive.stat().st_size, flush=True)
print('EXPERIMENT_COMPLETE: app unchanged; not an SMB or device playback test', flush=True)
