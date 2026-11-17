from pathlib import Path
import json, shutil
ROOT=Path(__file__).resolve().parents[2]
R=ROOT/'.build/recovery206'
N=R/'native/source'
T=R/'tests'
T.mkdir(parents=True,exist_ok=True)
(R/'validation').mkdir(exist_ok=True)
for name,source in json.loads((Path(__file__).parent/'sources.json').read_text()).items():
 p=N/name;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/source,p)
