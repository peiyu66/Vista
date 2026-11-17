#!/usr/bin/env python3
"""Optimized host tests of actual persistence classes in both build modes.
Record fixture substitutes playback dependencies; this is not device playback.
"""
from pathlib import Path
import subprocess,tempfile,json
R=Path(__file__).resolve().parents[2]
def block(s,mark):
 a=s.index(mark);b=s.index('{',a);i=b+1;depth=1
 while depth:depth+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[a:i]
s=(R/'Sources/VistaMedia/PlaybackMetrics.swift').read_text()
pre='''import Foundation
public struct PlaybackLogRecord:Codable,Sendable {
 var event:PlaybackLogEvent;var values:[String:Double]=[:];var build="0";var waitEpisode:Int?=nil
 func withWaitLosses(dropped:UInt64,rejected:UInt64,failures:UInt64,missingPayload:UInt64,oversize:UInt64,encoding:UInt64,rotatedFiles:UInt64,expiredFiles:UInt64)->Self {self}
 func withRecoveryLogLosses(dropped:Int,failures:Int)->Self{self}
}
enum PlaybackWaitEpisodeDiagnostics {static func increment(_ n:inout UInt64){if n<UInt64.max{n+=1}}}
'''
parts=[block(s,'public enum PlaybackLogEvent:'),block(s,'public enum PlaybackLogField:'),block((R/'Sources/VistaMedia/PlaybackWaitEpisodeDiagnostics.swift').read_text(),'struct PlaybackWaitEpisodeLogBuffer {'),block(s,'public final class PlaybackLogStore:'),block(s,'public final class ControllerCheckpointStore:')]
main='''
@main struct Test {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);let fm=FileManager.default
  try fm.createDirectory(at:root,withIntermediateDirectories:true)
  let sentinel=root.appendingPathComponent("old.jsonl");try Data("keep".utf8).write(to:sentinel)
  let lifecycle=LifecycleDiagnostics(directory:root.appendingPathComponent("life"),mirror:false)
  lifecycle.record(.processStart);lifecycle.record(.requestError,[.errorCode:5])
  let token=lifecycle.begin(.connect);lifecycle.finish(token);Thread.sleep(forTimeInterval:1)
  let play=PlaybackLogStore(directory:root.appendingPathComponent("play"))
  for e in [PlaybackLogEvent.sample,.failed,.automaticSpeed,.waitEpisode] {play.enqueue(PlaybackLogRecord(event:e,waitEpisode:1))};play.drainForTesting()
  let pose=ControllerCheckpointStore(directory:root.appendingPathComponent("pose"))
  pose.enqueue(records:(1...3).map{PlaybackLogRecord(event:.controllerPose,values:["cpPoseCause":1,"cpPoseEpoch":1,"cpPoseRequest":1,"cpPoseRole":Double($0)])},controllerInstance:UUID(),playerGeneration:nil,referenceRevision:1);pose.drainForTesting()
  for d in ["life","play","pose"] {precondition(fm.fileExists(atPath:root.appendingPathComponent(d).path)==VistaDiagnostics.enabled)}
  precondition(try! Data(contentsOf:sentinel)==Data("keep".utf8))
  precondition(lifecycle.status.writerFailures==0 && play.status.failures==0 && pose.status.writeFailures==0)
  print("PASS enabled=\\(VistaDiagnostics.enabled): lifecycle/playback/controller files, historical preservation")
 }
}
'''
presenter=(R/'Sources/VistaMedia/SystemVideoPresenter.swift').read_text()
assert 'blockedHoldFlow=blockedInput.flow.id == 0 ? nil:blockedInput.flow.id' in presenter
predicate='(blockedHoldFlow.map{$0==frame.flow.id} ?? (blockedHoldInput==ObjectIdentifier(frame)))'
assert predicate in presenter
fallback='import Foundation\nfinal class Frame { let flow:Flow;init(_ id:UInt64){flow=Flow(id:id)} };struct Flow{let id:UInt64}\nfunc blocked(_ frame:Frame,_ blockedHoldInput:ObjectIdentifier?,_ blockedHoldFlow:UInt64?)->Bool {PREDICATE}\nlet old=Frame(0),new=Frame(0)\nprecondition(blocked(old,ObjectIdentifier(old),nil))\nprecondition(!blocked(new,ObjectIdentifier(old),nil))\nlet diagnostic=Frame(42)\nprecondition(blocked(diagnostic,nil,42));precondition(!blocked(diagnostic,nil,43))\nprint("PASS actual renderer blocked-frame predicate, zero-flow identity fallback")\n'.replace('PREDICATE',predicate)
with tempfile.TemporaryDirectory(prefix='vista-logging-') as tmp:
 t=Path(tmp);f=t/'Stores.swift';f.write_text(pre+'\n'+'\n'.join(parts)+main)
 for name,flags in [('Release',[]),('Diagnostic',['-D','VISTA_DIAGNOSTICS'])]:
  exe=t/name
  cmd=['xcrun','swiftc','-O','-swift-version','6','-parse-as-library',*flags,str(R/'Sources/VistaCore/LifecycleDiagnostics.swift'),str(f),'-o',str(exe)]
  subprocess.run(cmd,check=True)
  subprocess.run([str(exe),str(t/(name+'-files'))],check=True)

with tempfile.TemporaryDirectory(prefix='vista-identity-') as tmp:
 t=Path(tmp);f=t/'main.swift';f.write_text(fallback)
 subprocess.run(['xcrun','swiftc','-O',str(f),'-o',str(t/'check')],check=True)
 subprocess.run([str(t/'check')],check=True)
