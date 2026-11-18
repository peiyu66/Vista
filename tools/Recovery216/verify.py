from pathlib import Path
import hashlib,json
R=Path(__file__).resolve().parents[2]
b=json.loads((Path(__file__).parent/'baseline.json').read_text())
for name,digest in b['sourceHashes'].items():
 assert hashlib.sha256((R/name).read_bytes()).hexdigest()==digest,name
for name,digest in b['preservedProductHashes'].items():
 assert hashlib.sha256((R/name).read_bytes()).hexdigest()==digest,name
print('PASS accepted 216 exact source and preserved product resources')
