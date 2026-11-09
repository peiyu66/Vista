"""Read-only Build104 source equivalence check; does not build or execute tests."""
from pathlib import Path
import hashlib
import json
import os

root = Path(__file__).resolve().parents[1]
baseline = json.loads((root / 'tools/Build104AcceptedBaseline.json').read_text())
manifest_path = root / 'tools/Build104AcceptedInputs.json'
manifest = json.loads(manifest_path.read_text())
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
errors = []
if sha(manifest_path) != baseline['inputManifestSHA256']:
    errors.append('input manifest digest differs')
if len(manifest) != 394:
    errors.append('input manifest count differs')
exceptions = baseline['metadataExceptions']
if set(exceptions) != {'Dependencies/AMSMB2-provenance.json'}:
    errors.append('unexpected metadata exception')
for name, original in manifest.items():
    expected = exceptions.get(name, {}).get('promotedSHA256', original)
    path = root / name
    if not path.is_file() or sha(path) != expected:
        errors.append('input differs: ' + name)
for name, expected in baseline['supplementalFiles'].items():
    path = root / name
    if not path.is_file() or sha(path) != expected:
        errors.append('supplement differs: ' + name)
for name, target in baseline['symlinks'].items():
    path = root / name
    if not path.is_symlink() or os.readlink(path) != target:
        errors.append('symlink differs: ' + name)
    elif not path.resolve().is_dir():
        errors.append('symlink target missing: ' + name)
provenance = json.loads((root / 'Dependencies/AMSMB2-provenance.json').read_text())
for patch in provenance['patches']:
    if sha(root / patch['path']) != patch['sha256']:
        errors.append('patch digest differs: ' + patch['path'])
print(json.dumps({'inputs': len(manifest), 'byteIdenticalInputs': len(manifest)-len(exceptions),
                  'metadataExceptions': list(exceptions), 'errors': errors,
                  'passed': not errors}, indent=2, ensure_ascii=False))
raise SystemExit(bool(errors))
