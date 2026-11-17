#!/usr/bin/env python3
"""Recheck unchanged accepted recovery policy without rewriting its old project baseline."""
from pathlib import Path
import hashlib,json,subprocess,tempfile
R=Path(__file__).resolve().parents[2]
b=json.loads((R/'tools/DirectRecovery194/baseline.json').read_text())
for f,h in b['productHashes'].items():
    if f.endswith('.swift'):
        assert hashlib.sha256((R/f).read_bytes()).hexdigest()==h,f
with tempfile.TemporaryDirectory(prefix='vista-204-direct-') as tmp:
    t=Path(tmp)
    for mode in ['-Onone','-O']:
        exe=t/mode
        subprocess.run(['xcrun','swiftc','-swift-version','6',mode,'-module-cache-path',str(t/'cache'),str(R/'engine/vlc/Sources/VLCClockResyncPolicy.swift'),str(R/'tools/DirectRecovery194/PolicyTests.swift'),'-o',str(exe)],check=True)
        subprocess.run([str(exe)],check=True)
