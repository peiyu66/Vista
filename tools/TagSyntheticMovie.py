"""Add V2 360/top-bottom tags to our own tiny color-frame fixture; no video processing."""
from pathlib import Path
import struct


def box(kind, payload):
    return struct.pack('>I4s', len(payload) + 8, kind) + payload


def rewrite(data, path=()):
    result = bytearray()
    offset = 0
    while offset < len(data):
        size, kind = struct.unpack_from('>I4s', data, offset)
        header = 8
        if size == 1:
            size = struct.unpack_from('>Q', data, offset + 8)[0]
            header = 16
        assert size >= header and offset + size <= len(data)
        payload = data[offset + header:offset + size]
        if kind in (b'moov', b'trak', b'mdia', b'minf', b'stbl'):
            payload = rewrite(payload, path + (kind,))
        elif kind == b'stsd':
            payload = payload[:8] + rewrite(payload[8:], path + (kind,))
        elif kind == b'avc1':
            assert path == (b'moov', b'trak', b'mdia', b'minf', b'stbl', b'stsd')
            stereo = box(b'st3d', bytes(4) + bytes([1]))
            spherical = box(b'sv3d', box(b'svhd', bytes(4) + b'Vista synthetic fixture\0') +
                            box(b'proj', box(b'prhd', bytes(16)) + box(b'equi', bytes(20))))
            payload += stereo + spherical
        # Preserve original mdat header and offsets. The source moov must follow mdat.
        result += data[offset:offset + header] + payload if kind == b'mdat' else box(kind, payload)
        offset += size
    return bytes(result)


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    source = root / 'Sources/VistaCore/Resources/Synthetic.mp4'
    target = source.with_name('SyntheticVR.mp4')
    data = source.read_bytes()
    assert data.find(b'mdat') < data.find(b'moov')
    with target.open('xb') as output:
        output.write(rewrite(data))
    print('Created project-generated V2 metadata fixture.')
