from pathlib import Path
import json, hashlib
R = Path(__file__).resolve().parents[2]
b = json.loads((Path(__file__).parent / "baseline.json").read_text())
for group in ["productHashes", "unchangedNativeSourceHashes", "nativeArtifactHashes"]:
    for name, expected in b[group].items():
        assert hashlib.sha256((R / name).read_bytes()).hexdigest() == expected, name
print("PASS 211 source, preserved native inputs and native artifacts")
