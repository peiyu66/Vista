"""Read-only accepted Build105 input verification; no build or runtime tests."""
from pathlib import Path
import hashlib
import json
import os

root = Path(__file__).resolve().parents[1]
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
baseline = json.loads((root / 'tools/Build105AcceptedBaseline.json').read_text())
manifest_path = root / 'tools/Build105AcceptedInputs.json'
manifest = json.loads(manifest_path.read_text())
previous = json.loads((root / 'tools/Build104AcceptedInputs.json').read_text())
errors = []
if len(manifest) != 394 or sha(manifest_path) != baseline['inputManifestSHA256']:
    errors.append('input manifest differs')
changed = {p for p in manifest if manifest[p] != previous.get(p)}
if changed != set(baseline['changedProductTestFiles']):
    errors.append('unexpected product/test delta from accepted Build104')
exceptions = baseline['metadataExceptions']
if set(exceptions) != {'Dependencies/AMSMB2-provenance.json'}:
    errors.append('unexpected metadata exception')
for name, digest in manifest.items():
    expected = exceptions.get(name, {}).get('promotedSHA256', digest)
    path = root / name
    if not path.is_file() or sha(path) != expected:
        errors.append('input differs: ' + name)
for name, digest in baseline['supplementalFiles'].items():
    if not (root / name).is_file() or sha(root / name) != digest:
        errors.append('supplement differs: ' + name)
for name, target in baseline['symlinks'].items():
    path = root / name
    if not path.is_symlink() or os.readlink(path) != target or not path.resolve().is_dir():
        errors.append('symlink differs: ' + name)
view = (root / 'VistaApp/VRPresentation.swift').read_text()
controls = view.split('    @ViewBuilder private var playerControls:', 1)[1].split('    private var angleReadoutAvailable:', 1)[0]
for identifier in ['playbackSpeedLimit', 'playbackSpeedMessage', 'playbackPreparing',
                   'vrError', 'immersiveMessage', 'immersivePlaybackStatus']:
    if '"' + identifier + '"' in controls:
        errors.append('removed UI node returned: ' + identifier)
if controls.count('ProgressView(') != 1 or 'controllerVideoInfoBuffering' not in controls:
    errors.append('footer waiting indicator differs')
print(json.dumps({'applicationInputs': len(manifest), 'byteIdenticalInputs': 393,
                  'changedProductTestFiles': sorted(changed), 'errors': errors,
                  'passed': not errors}, indent=2, ensure_ascii=False))
raise SystemExit(bool(errors))
