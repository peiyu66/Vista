from pathlib import Path
import subprocess
R=Path(__file__).resolve().parents[2];T=R/'.build/recovery206/tests';T.mkdir(parents=True,exist_ok=True)
for case in ['tools/DirectRecovery194/PolicyTests.swift','tools/Recovery206/WatchTests.swift']:
 for mode in ['-Onone','-O']:
  exe=T/(Path(case).stem+mode)
  subprocess.run(['xcrun','swiftc','-swift-version','6',mode,'-module-cache-path',str(T/'cache'),str(R/'engine/vlc/Sources/VLCClockResyncPolicy.swift'),str(R/case),'-o',str(exe)],check=True)
  subprocess.run([str(exe)],check=True)
