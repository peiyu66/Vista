import Foundation
import Testing
import simd
@testable import VistaMedia

struct ControllerResetLogTests {
 @Test func resetPhasesAreOneShotAndSupersededOrCancelledRequestsDoNotLeak() {
  var trace=ControllerResetTrace()
  let first=trace.begin()
  #expect(trace.awaitingApply==first && trace.awaitingFrame==nil)
  // No attachment/placeControls means no invented applied or next-frame record.
  let missingApplyFrame=trace.nextFrame(ticket:first);#expect(!missingApplyFrame)
  let second=trace.begin(),secondApply=trace.applied()
  #expect(second != first && secondApply==second)
  let duplicateApply=trace.applied(),staleFrame=trace.nextFrame(ticket:first)
  #expect(duplicateApply==nil && !staleFrame)
  let validFrame=trace.nextFrame(ticket:second),duplicateFrame=trace.nextFrame(ticket:second)
  #expect(validFrame && !duplicateFrame)
  let third=trace.begin(),thirdApply=trace.applied();#expect(thirdApply==third)
  trace.cancel();let cancelledFrame=trace.nextFrame(ticket:third),cancelledApply=trace.applied()
  #expect(!cancelledFrame && cancelledApply==nil)
 }
 @Test func matrixSnapshotsAreNumericBoundedAndExcludeAbsoluteTranslation()throws {
  var matrix=matrix_identity_float4x4
  matrix.columns.3=[123456,234567,345678,1]
  matrix.columns.1.x=0.25
  let q=simd_quatf(angle:0.4,axis:[0,1,0])
  var values=ControllerResetLog.values(sequence:1,phase:.applied,world:matrix,parent:matrix,local:matrix,
      intended:q,frame:q,cachedHead:q,video:q,localPosition:[1,-0.18,-1],cachedViewer:[0,0.1,0],offset:.zero)
  #expect(values[.cw01]==0.25 && values[.cw10]==0)
  #expect(!values.values.contains(123456) && !values.values.contains(234567) && !values.values.contains(345678))
  for key in [PlaybackLogField.crElapsedMS,.crPoseSource,.crPoseAgeMS,.crExpectedParent,.crHasScene,.crPreservePlacement,.crVisible,.crMoving,.crScrubbing,.crCalibration,.crAutoPitch,.crManualYaw,.crManualPitch,.crManualRoll,.projection,.layout,.route,.logFailures,.logDropped] {values[key]=1}
  for phase in [ControllerResetLogPhase.before,.applied,.nextSceneUpdate] {
   values[.crPhase]=Double(phase.rawValue)
   let record=PlaybackLogRecord(event:.controllerReset,values:values,build:"55")
   let encoded=try JSONEncoder().encode(record)
   #expect(encoded.count<4096)
   #expect(try JSONDecoder().decode(PlaybackLogRecord.self,from:encoded).event == .controllerReset)
  }
  // Longest practical finite Double encodings, including all fields used by this event.
  let worst=values.mapValues {_ in -Double.greatestFiniteMagnitude}
  let encoded=try JSONEncoder().encode(PlaybackLogRecord(event:.controllerReset,values:worst,build:"999999999999"))
  #expect(encoded.count<4096)
  print("CONTROLLER_RESET_LOG maximum_test_bytes",encoded.count,"fields",worst.count)
  values[.cqX] = .nan;values[.cqY] = .infinity
  let sanitized=PlaybackLogRecord(event:.controllerReset,values:values,build:"private.mp4")
  #expect(sanitized.build=="0" && sanitized.values["cqX"]==nil && sanitized.values["cqY"]==nil)
  let absent=ControllerResetLog.values(sequence:2,phase:.before,world:nil,parent:nil,local:nil,intended:q,frame:q,cachedHead:nil,video:nil,localPosition:nil,cachedViewer:.zero,offset:.zero)
  #expect(absent[.crHasEntity]==0 && absent[.crHasParent]==0 && absent[.crHeadCached]==0 && absent[.cw00]==nil)
 }
 @Test func threeSnapshotsUseExistingSandboxLogStore()throws {
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:directory)}
  let store=PlaybackLogStore(directory:directory)
  for phase in [ControllerResetLogPhase.before,.applied,.nextSceneUpdate] {
   store.enqueue(.init(event:.controllerReset,values:[.crSequence:1,.crPhase:Double(phase.rawValue)],build:"55"))
  }
  store.drainForTesting()
  let lines=try String(contentsOf:directory.appendingPathComponent("current.jsonl"),encoding:.utf8).split(separator:"\n")
  let records=try lines.map {try JSONDecoder().decode(PlaybackLogRecord.self,from:Data($0.utf8))}
  #expect(records.count==3 && records.map {$0.values["crPhase"]} == [0,1,2])
  #expect(store.status.failures==0 && store.status.dropped==0)
 }
}
