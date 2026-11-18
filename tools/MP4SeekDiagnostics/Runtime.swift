import Foundation
import VistaCore
import VistaMedia

@main struct Runtime {
 static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
  #if DEBUG || VISTA_DIAGNOSTICS
  let seekWriter=LifecycleDiagnostics(directory:root.appendingPathComponent("VistaMP4SeekDiagnostics"),mirror:false,criticalDurability:false)
  let seek=MP4SeekDiagnostics(epoch:1,target:42,sourceKind:2,writer:seekWriter)
  seek.record(.seekIssued,boundary:true)
  seek.record(.bridgeStarted,fields:[.rangeLower:1024,.rangeUpper:2048],correlation:.init(bridge:1,request:1,chunk:1,seek:1))
  seek.record(.seekAwaitReturned,fields:[.outcome:1],boundary:true)
  seek.record(.frameDelivered,fields:[.framePTS:42],boundary:true);seek.close(1)
  #endif
  let lifecycle=LifecycleDiagnostics(directory:root.appendingPathComponent("VistaLifecycleDiagnostics"),mirror:false)
  let token=lifecycle.begin(.connect)
  lifecycle.record(.requestError,[.errorCode:5]);lifecycle.finish(token,failure:LifecycleFailure(URLError(.networkConnectionLost)))
  lifecycle.record(.scenePhase,[.phase:1]);lifecycle.record(.viewDisappear)
  let playback=PlaybackLogStore(directory:root.appendingPathComponent("VistaDiagnostics"))
  // Actual product record encoding and complete writer implementation, no record substitute.
  for event in [PlaybackLogEvent.sample,.failed,.automaticSpeed,.automaticRecovery,.automaticRecoverySummary,.waitEpisode] {
   playback.enqueue(PlaybackLogRecord(event:event,values:[.selectedSpeed:3]))
  }
  playback.drainForTesting()
  let controller=ControllerCheckpointStore(directory:root.appendingPathComponent("VistaControllerCheckpoints"))
  controller.enqueue(records:(1...3).map { PlaybackLogRecord(event:.controllerPose,values:[.cpPoseCause:1,.cpPoseEpoch:1,.cpPoseRequest:1,.cpPoseRole:Double($0)]) },controllerInstance:UUID(),playerGeneration:nil,referenceRevision:1)
  controller.drainForTesting()
  try await Task.sleep(for:.seconds(1))
  precondition(lifecycle.status.writerFailures==0 && playback.status.failures==0 && controller.status.writeFailures==0)
  let files=(FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey])?.allObjects as? [URL] ?? []).filter{(try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true}
  if VistaDiagnostics.enabled {
   precondition(files.contains{$0.deletingLastPathComponent().lastPathComponent=="VistaMP4SeekDiagnostics"})
  } else {precondition(files.allSatisfy{$0.lastPathComponent=="existing.jsonl"})}
  let existing=try String(contentsOf:root.appendingPathComponent("existing.jsonl"),encoding:.utf8);precondition(existing=="preserved\n")
  print("PASS actual complete VistaCore/VistaMedia writers; enabled=\(VistaDiagnostics.enabled); files=\(files.count)")
 }
}
