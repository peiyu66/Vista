from pathlib import Path
import shutil,json,hashlib
R=Path(__file__).resolve().parents[2];P=R/'.build/read216-harness';P.mkdir(parents=True,exist_ok=True)
(R/'validation216').mkdir(exist_ok=True)
(P/'Adapter').mkdir(exist_ok=True);(P/'Tests').mkdir(exist_ok=True)
if not (P/'VistaCore').exists():(P/'VistaCore').symlink_to(R/'Sources/VistaCore',target_is_directory=True)
files=['engine/source/source-adapter/AdapterContracts.swift','engine/source/source-adapter/LocalOperationSource.swift','engine/source/source-adapter/SMBOperationSource.swift','engine/vlc/Sources/AsyncInputContext.swift']
for f in files:(P/'Adapter'/Path(f).name).write_text('import VistaCore\n'+(R/f).read_text())
for f in (R/'tools/ReadPhase216/Tests').glob('*.swift'):shutil.copy2(f,P/'Tests'/f.name)
(P/'Package.swift').write_text('''// swift-tools-version:6.0
import PackageDescription
let package=Package(name:"ReadPhase216",platforms:[.macOS(.v14)],targets:[.target(name:"VistaCore",path:"VistaCore",resources:[.copy("Resources")]),.target(name:"Adapter",dependencies:["VistaCore"],path:"Adapter"),.testTarget(name:"ReadTests",dependencies:["VistaCore","Adapter"],path:"Tests")])
''')
(R/'validation216/read-harness-inputs.json').write_text(json.dumps({f:hashlib.sha256((R/f).read_bytes()).hexdigest() for f in files},indent=2)+'\n')
