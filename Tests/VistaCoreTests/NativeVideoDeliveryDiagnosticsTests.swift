import Foundation
import Testing
@testable import VistaMedia

struct NativeVideoDeliveryDiagnosticsTests {
 @Test func newSessionHasFiveNumericAggregatesAndNoInventedFrameAge() {
  let values=NativeVideoDeliveryDiagnostics().values(now:1_000)
  #expect(values.count==5 && values.values.allSatisfy{$0==0})
  #expect(values[.videoFrameAgeMS]==nil)
 }

 @Test func outputCountersDistinguishFalsePollNilCopyAndRejectedPTS() {
  var diagnostics=NativeVideoDeliveryDiagnostics()
  // One false poll, one nil copy, one nonfinite PTS and one accepted frame.
  for now in 1...4 {diagnostics.recordLoop(now:Double(now));diagnostics.recordOutputPoll()}
  diagnostics.recordOutputHasNew();diagnostics.recordOutputCopyNil()
  diagnostics.recordOutputHasNew();diagnostics.recordFrame(now:3,presentationTime:.nan)
  #expect(diagnostics.values(now:3)[.videoFrameAgeMS]==nil)
  diagnostics.recordOutputHasNew();diagnostics.recordFrame(now:4,presentationTime:20)
  let values=diagnostics.values(now:4.5)
  #expect(values[.videoLoopTicks]==4 && values[.videoOutputPolls]==4)
  #expect(values[.videoOutputHasNew]==3 && values[.videoOutputCopyNil]==1)
  #expect(values[.videoFrameAgeMS]==500)
  let falsePolls=diagnostics.outputPolls-diagnostics.outputHasNew
  let rejectedPTS=diagnostics.outputHasNew-diagnostics.outputCopyNil-1 // Existing frames count.
  #expect(falsePolls==1 && rejectedPTS==1)
 }

 @Test func maxGapIsSessionCumulativeIncludesUnfinishedGapAndSnapshotsNeverResetIt() {
  var diagnostics=NativeVideoDeliveryDiagnostics()
  diagnostics.recordLoop(now:10)
  #expect(diagnostics.values(now:10)[.videoLoopSessionMaxGapMS]==0)
  let unfinished=diagnostics.values(now:12)
  #expect(unfinished[.videoLoopSessionMaxGapMS]==2_000)
  #expect(diagnostics.values(now:12)==unfinished)
  diagnostics.recordLoop(now:13)
  diagnostics.recordLoop(now:13.25)
  #expect(diagnostics.values(now:13.5)[.videoLoopSessionMaxGapMS]==3_000)
  #expect(diagnostics.values(now:18)[.videoLoopSessionMaxGapMS]==4_750)
  diagnostics.recordLoop(now:18)
  #expect(diagnostics.values(now:18.25)[.videoLoopSessionMaxGapMS]==4_750)
 }

 @Test func onlyFinitePTSCopyUpdatesWallAgeEvenWhenMediaTimeMovesBackward() {
  var diagnostics=NativeVideoDeliveryDiagnostics()
  diagnostics.recordFrame(now:10,presentationTime:100)
  diagnostics.recordOutputPoll();diagnostics.recordOutputHasNew();diagnostics.recordOutputCopyNil()
  diagnostics.recordFrame(now:11,presentationTime:.infinity)
  diagnostics.recordFrame(now:12,presentationTime:.nan)
  #expect(diagnostics.values(now:15)[.videoFrameAgeMS]==5_000)
  // Seek can move media time backward; successful delivery still renews wall age.
  diagnostics.recordFrame(now:16,presentationTime:2)
  #expect(diagnostics.values(now:16.5)[.videoFrameAgeMS]==500)
 }

 @Test func invalidOrBackwardUptimeNeverMovesTheStoredTimestampsBackward() {
  var diagnostics=NativeVideoDeliveryDiagnostics()
  for now in [Double.nan,.infinity,-1] {
   diagnostics.recordLoop(now:now);diagnostics.recordFrame(now:now,presentationTime:0)
  }
  #expect(diagnostics.values(now:10)[.videoFrameAgeMS]==nil)
  #expect(diagnostics.values(now:10)[.videoLoopSessionMaxGapMS]==0)
  diagnostics.recordLoop(now:10);diagnostics.recordFrame(now:10,presentationTime:0)
  diagnostics.recordLoop(now:9);diagnostics.recordFrame(now:9,presentationTime:1)
  #expect(diagnostics.values(now:12)[.videoLoopSessionMaxGapMS]==2_000)
  #expect(diagnostics.values(now:12)[.videoFrameAgeMS]==2_000)
  for now in [Double.nan,.infinity,9] {
   let values=diagnostics.values(now:now)
   #expect(values[.videoFrameAgeMS]==nil && values.values.allSatisfy(\.isFinite))
  }
 }

 @Test func pauseSeekAndSceneGapsRemainWallTimeRatherThanFailureFlags() {
  var diagnostics=NativeVideoDeliveryDiagnostics()
  diagnostics.recordLoop(now:10);diagnostics.recordFrame(now:10,presentationTime:50)
  // An intentional pause/seek/inactive interval does not reset one related counter.
  diagnostics.recordLoop(now:40)
  let afterBoundary=diagnostics.values(now:40)
  #expect(afterBoundary[.videoLoopTicks]==2)
  #expect(afterBoundary[.videoLoopSessionMaxGapMS]==30_000)
  #expect(afterBoundary[.videoFrameAgeMS]==30_000)
  diagnostics.recordFrame(now:41,presentationTime:5)
  #expect(diagnostics.values(now:41)[.videoFrameAgeMS]==0)
  #expect(diagnostics.values(now:41)[.videoLoopSessionMaxGapMS]==30_000)
 }

 @Test func stoppingFreezesLoopGapButFrameAgeRemainsWallTime() {
  var diagnostics=NativeVideoDeliveryDiagnostics()
  diagnostics.recordLoop(now:10);diagnostics.recordOutputPoll();diagnostics.recordOutputHasNew()
  diagnostics.recordFrame(now:10,presentationTime:5)
  diagnostics.finishLoop(now:12)
  let stopped=diagnostics.values(now:100)
  #expect(stopped[.videoLoopSessionMaxGapMS]==2_000 && stopped[.videoFrameAgeMS]==90_000)
  #expect(stopped[.videoLoopTicks]==1 && stopped[.videoOutputPolls]==1 && stopped[.videoOutputHasNew]==1)
  diagnostics.finishLoop(now:200)
  let later=diagnostics.values(now:300)
  #expect(later[.videoFrameAgeMS]==290_000)
  #expect(later.filter{$0.key != .videoFrameAgeMS}==stopped.filter{$0.key != .videoFrameAgeMS})
 }

 @Test func sessionResetClearsEveryCounterTimestampAndHighWaterMarkTogether() {
  var diagnostics=NativeVideoDeliveryDiagnostics()
  diagnostics.recordLoop(now:10);diagnostics.recordLoop(now:20)
  diagnostics.recordOutputPoll();diagnostics.recordOutputHasNew();diagnostics.recordOutputCopyNil()
  diagnostics.recordFrame(now:20,presentationTime:1)
  diagnostics=NativeVideoDeliveryDiagnostics()
  #expect(diagnostics.values(now:100)==NativeVideoDeliveryDiagnostics().values(now:0))
  diagnostics.recordLoop(now:100)
  #expect(diagnostics.values(now:100)[.videoLoopSessionMaxGapMS]==0)
 }

 @Test func countersSaturateAtExactlyRepresentableLimitAndDurationsStayFinite() {
  var diagnostics=NativeVideoDeliveryDiagnostics()
  let maximum=NativeVideoDeliveryDiagnostics.maximumCounter
  diagnostics.loopTicks=maximum-1;diagnostics.outputPolls=maximum-1
  diagnostics.outputHasNew=maximum-1;diagnostics.outputCopyNil=maximum-1
  for _ in 0..<3 {
   diagnostics.recordLoop(now:0);diagnostics.recordOutputPoll()
   diagnostics.recordOutputHasNew();diagnostics.recordOutputCopyNil()
  }
  diagnostics.recordFrame(now:0,presentationTime:0)
  let values=diagnostics.values(now:Double.greatestFiniteMagnitude)
  for field in [PlaybackLogField.videoLoopTicks,.videoOutputPolls,.videoOutputHasNew,.videoOutputCopyNil] {
   #expect(values[field]==Double(maximum))
  }
  #expect(values[.videoLoopSessionMaxGapMS]==Double.greatestFiniteMagnitude)
  #expect(values[.videoFrameAgeMS]==Double.greatestFiniteMagnitude)
 }

 @Test func serializedFieldsAreExactlySixAnonymousFiniteNumbersAndBounded()throws {
  var diagnostics=NativeVideoDeliveryDiagnostics()
  diagnostics.recordLoop(now:10);diagnostics.recordOutputPoll();diagnostics.recordOutputHasNew()
  diagnostics.recordFrame(now:10,presentationTime:2)
  let data=try JSONEncoder().encode(PlaybackLogRecord(event:.sample,values:diagnostics.values(now:11),build:"87"))
  let decoded=try JSONDecoder().decode(PlaybackLogRecord.self,from:data)
  let fields:Set<String>=["videoLoopTicks","videoLoopSessionMaxGapMS","videoOutputPolls","videoOutputHasNew","videoOutputCopyNil","videoFrameAgeMS"]
  #expect(Set(decoded.values.keys)==fields && decoded.values.values.allSatisfy(\.isFinite))
  #expect(data.count<512)
 }

 @Test func sourceContractKeepsExistingCallsCadenceAndSessionBoundaries()throws {
  let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let source=try String(contentsOf:root.appendingPathComponent("Sources/VistaMedia/NativePlaybackSession.swift"),encoding:.utf8)
  func occurrences(_ text:String)->Int {source.components(separatedBy:text).count-1}
  #expect(occurrences("output.hasNewPixelBuffer(")==1 && occurrences("output.copyPixelBuffer(")==1)
  #expect(source.contains("while true {\n    try check()\n    videoDeliveryDiagnostics.recordLoop(now:ProcessInfo.processInfo.systemUptime)"))
  // Build98 query-outcome bits remain beside the same real API boundaries.
  // Build92's observational flag and the existing counter cadence are retained.
  #expect(source.contains("var outputPolled=false,copiedFramePTS:Double?\n    if !seeking,let outputTime {\n     outputPolled=true;latestOutput.validity |= 64\n     videoDeliveryDiagnostics.recordOutputPoll()\n     if output.hasNewPixelBuffer(forItemTime:outputTime) {\n      latestOutput.validity |= 128\n      videoDeliveryDiagnostics.recordOutputHasNew()"))
  #expect(occurrences("outputPolled=true")==1 && occurrences("videoDeliveryDiagnostics.recordOutputPoll()")==1)
  #expect(source.contains("if let pixel=copiedPixel,display.seconds.isFinite {\n       copiedFramePTS=display.seconds"))
  #expect(occurrences("copiedFramePTS=display.seconds")==1)
  #expect(occurrences("updateBufferingSpeed(now:ProcessInfo.processInfo.systemUptime,duration:duration,outputPolled:outputPolled,copiedFramePTS:copiedFramePTS)")==1)
  #expect(source.contains("let copiedPixel=output.copyPixelBuffer(forItemTime:outputTime,itemTimeForDisplay:&display)\n      returnedFramePTS=display.seconds.isFinite ? display.seconds:nil\n      if copiedPixel == nil {latestOutput.validity |= 256;videoDeliveryDiagnostics.recordOutputCopyNil()}\n      if let pixel=copiedPixel,display.seconds.isFinite {"))
  #expect(source.contains("frames += 1\n       videoDeliveryDiagnostics.recordFrame(now:lastProgress,presentationTime:display.seconds)"))
  #expect(occurrences("videoDeliveryDiagnostics.recordFrame(")==1)
  #expect(source.contains("loader.onReadProgress={ [weak self] in\n    let now=ProcessInfo.processInfo.systemUptime;self?.lastProgress=now;self?.lastDeliveryAt=now\n   }"))
  #expect(source.contains("videoDeliveryDiagnostics=NativeVideoDeliveryDiagnostics()\n  lastProgress=ProcessInfo.processInfo.systemUptime;frames=0;waits=0;"))
  #expect(occurrences("videoDeliveryDiagnostics=NativeVideoDeliveryDiagnostics()")==2) // Property plus session start.
  #expect(occurrences("videoDeliveryDiagnostics.values(now:now)")==1)
  // Build97 adds diagnostic finalization before the existing teardown. Check
  // the real stop-method ordering rather than requiring adjacent source lines.
  let stopStart=try #require(source.range(of:"public func stop(){"))
  let stopEnd=try #require(source.range(of:" private func check()throws",range:stopStart.upperBound..<source.endIndex))
  var remaining=source[stopStart.upperBound..<stopEnd.lowerBound]
  for call in ["finishAutomaticRecovery()","abortWait(.stop)","videoDeliveryDiagnostics.finishLoop(now:ProcessInfo.processInfo.systemUptime)",
               "active=false","interruptBufferingWait()","automaticSpeedPolicy.reset()","stallRecovery.clear()","inactiveStallSuspension=nil","updatePrefetchActivity()"] {
   let boundary=try #require(remaining.range(of:call))
   remaining=remaining[boundary.upperBound...]
  }
  #expect(source.contains("try await Task.sleep(for:.milliseconds(8))"))
 }
}
