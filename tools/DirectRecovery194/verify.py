#!/usr/bin/env python3
"""Verify accepted direct-recovery source and run actual policy; no device/network."""
from pathlib import Path
import hashlib,json,subprocess,tempfile
R=Path(__file__).resolve().parents[2];B=Path(__file__).with_name('baseline.json');b=json.loads(B.read_text())
for f,h in b['productHashes'].items():assert hashlib.sha256((R/f).read_bytes()).hexdigest()==h,f
s=(R/'engine/vlc/Sources/VLCPlaybackDriver.swift').read_text()
start=s.index('        if directRecovery194.take(');end=s.index('        let beforeFrame=',start);direct=s[start:end]
assert not any(x in direct for x in ['await ','lastFrameAt','lateDrop','costGuard'])
a=s.index('    func seekCurrentTime(');z=s.index('    func close()',a);actor=s[a:z]
assert actor.index('await permits()==0')<actor.index('let state=VLCVistaGetState')<actor.index('if !direct {')<actor.index('VLCVistaSeek(pointer,target)')
assert 'next.sourceEpoch==currentSourceEpoch' in s
for token in ['self.engine===core','self.currentSeek?.nonce==next.nonce','self.pendingSeek==nil','next.intentRevision==self.automatic.revision','next.sourceEpoch==self.currentSourceEpoch','!self.sourceRecovering']:
 assert token in actor+s[s.index('direct194:next.direct194,permits:'):],token
assert 'VLCVistaCatchupStart' not in s and 'VLCVistaEnableAudioReserve192' not in s
assert 'VISTA_DIRECT_RECOVERY194' not in (R/'engine/vlc/Sources/VLCClockResyncPolicy.swift').read_text()
with tempfile.TemporaryDirectory(prefix='vista-direct194-') as d:
 for mode in ['-Onone','-O']:
  exe=Path(d)/mode
  subprocess.run(['xcrun','swiftc','-swift-version','6',mode,'-module-cache-path',str(Path(d)/'cache'),str(R/'engine/vlc/Sources/VLCClockResyncPolicy.swift'),str(Path(__file__).with_name('PolicyTests.swift')),'-o',str(exe)],check=True)
  subprocess.run([str(exe)],check=True)
print('PASS source hashes, direct admission/dispatch safety boundaries and Release-independent actual policy')
