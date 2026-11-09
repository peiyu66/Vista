import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import VistaCore
@testable import VistaMedia

struct PlaybackBufferingSpeedTests {
 private func status(_ speed:Double=5,waiting:Bool=true,paused:Bool=false,ready:Bool=true)->PlaybackSpeedStatus {
  .init(selected:speed,ready:ready,supportsFastForward:true,paused:paused,waiting:waiting)
 }
 @Test func indicatorKeepsSpeedWithoutBufferingText() {
  #expect(status().text=="5×" && status().showsBufferingIndicator)
  #expect(!status(paused:true).showsBufferingIndicator)
  #expect(!status(ready:false).showsBufferingIndicator)
  #expect(!status(waiting:false).showsBufferingIndicator)
 }
 @Test func oneHalfStepAtHalfSecondPerRecoveredEpisodeThroughFloor() {
  #expect(PlaybackBufferingSpeedPolicy.interval==0.5)
  var policy=PlaybackBufferingSpeedPolicy(),speed=5.0
  for _ in 1...6 {
   #expect(policy.reducedSpeed(now:0,status:status(speed),eligible:true)==nil)
   #expect(policy.reducedSpeed(now:0.499,status:status(speed),eligible:true)==nil)
   #expect(policy.reducedSpeed(now:0.5,status:status(speed),eligible:true)==speed-0.5)
   speed -= 0.5
   for time in [3.0,30,300] {#expect(policy.reducedSpeed(now:time,status:status(speed),eligible:true)==nil)}
   policy.playbackDidAdvance()
  }
  #expect(speed==2)
  #expect(policy.reducedSpeed(now:0,status:status(speed),eligible:true)==nil)
  #expect(policy.reducedSpeed(now:100,status:status(speed),eligible:true)==nil)
 }
 @Test(arguments:[1.0,1.5,2.0]) func lowerManualRatesNeverIncreaseOrReduce(speed:Double) {
  var policy=PlaybackBufferingSpeedPolicy()
  #expect(policy.reducedSpeed(now:0,status:status(speed),eligible:true)==nil)
  #expect(policy.reducedSpeed(now:30,status:status(speed),eligible:true)==nil)
 }
 @Test func interruptedUnspentTimerRestartsButSpentEpisodeNeverRearmsWithoutProgress() {
  for reduced in [false,true] {for action in 0..<7 {
   var policy=PlaybackBufferingSpeedPolicy()
   #expect(policy.reducedSpeed(now:0,status:status(),eligible:true)==nil)
   if reduced {#expect(policy.reducedSpeed(now:0.5,status:status(),eligible:true)==4.5)}
   switch action {
   case 0:#expect(policy.reducedSpeed(now:2,status:status(waiting:false),eligible:true)==nil)
   case 1:#expect(policy.reducedSpeed(now:2,status:status(paused:true),eligible:true)==nil)
   case 2:#expect(policy.reducedSpeed(now:2,status:status(ready:false),eligible:true)==nil)
   case 3:#expect(policy.reducedSpeed(now:2,status:status(),eligible:false)==nil)
   case 4:policy.interruptWaiting()
   case 5:#expect(policy.reducedSpeed(now:.nan,status:status(),eligible:true)==nil)
   default:#expect(policy.reducedSpeed(now:2,status:status(1),eligible:true)==nil)
   }
   #expect(policy.reducedSpeed(now:3,status:status(),eligible:true)==nil)
   #expect(policy.reducedSpeed(now:3.499,status:status(),eligible:true)==nil)
   #expect(policy.reducedSpeed(now:3.5,status:status(),eligible:true)==(reduced ? nil:4.5))
  }}
 }
 @Test func clockRollbackRestartsHalfSecondWithoutRearmingConsumedEpisode() {
  var policy=PlaybackBufferingSpeedPolicy()
  #expect(policy.reducedSpeed(now:10,status:status(),eligible:true)==nil)
  #expect(policy.reducedSpeed(now:9,status:status(),eligible:true)==nil)
  #expect(policy.reducedSpeed(now:9.499,status:status(),eligible:true)==nil)
  #expect(policy.reducedSpeed(now:9.5,status:status(),eligible:true)==4.5)
  #expect(policy.reducedSpeed(now:8,status:status(4.5),eligible:true)==nil)
  #expect(policy.reducedSpeed(now:100,status:status(4.5),eligible:true)==nil)
 }
 @Test func clockRollbackManualChangeAndLongGapNeverCauseBurstOrSecondStep() {
  var policy=PlaybackBufferingSpeedPolicy()
  #expect(policy.reducedSpeed(now:10,status:status(),eligible:true)==nil)
  #expect(policy.reducedSpeed(now:9,status:status(),eligible:true)==nil)
  #expect(policy.reducedSpeed(now:10,status:status(4),eligible:true)==nil)
  #expect(policy.reducedSpeed(now:10.499,status:status(4),eligible:true)==nil)
  #expect(policy.reducedSpeed(now:100,status:status(4),eligible:true)==3.5)
  #expect(policy.reducedSpeed(now:300,status:status(5),eligible:true)==nil)
  policy.reset() // A new playback session may start a new episode.
  #expect(policy.reducedSpeed(now:300,status:status(5),eligible:true)==nil)
  #expect(policy.reducedSpeed(now:300.5,status:status(5),eligible:true)==4.5)
 }
}

struct NativePlaybackProgressGateTests {
 @Test func requiresTwoAdvancingClockAndVideoSamplesWhileEligible() {
  var gate=NativePlaybackProgressGate()
  #expect(gate.record(position:1,framePTS:1,eligible:true)==false)
  #expect(gate.record(position:2,framePTS:1,eligible:true)==false)
  #expect(gate.record(position:2,framePTS:2,eligible:true)==false)
  #expect(gate.record(position:3,framePTS:3,eligible:true)==true)
  #expect(gate.record(position:4,framePTS:4,eligible:false)==false)
  #expect(gate.record(position:5,framePTS:5,eligible:true)==false)
  #expect(gate.record(position:6,framePTS:6,eligible:true)==true)
  gate.reset() // Pause, seek, scene change or manual selection.
  #expect(gate.record(position:100,framePTS:100,eligible:true)==false)
  #expect(gate.record(position:.nan,framePTS:101,eligible:true)==false)
  #expect(gate.record(position:101,framePTS:101,eligible:true)==false)
  #expect(gate.record(position:102,framePTS:102,eligible:true)==true)
 }
}

private struct BufferingSpeedFixtureSource:MediaByteSource {
 let data:Data
 func fileSize(for file:MediaFile)async throws->UInt64 {UInt64(data.count)}
 func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data {
  try Task.checkCancellation();return data.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))
 }
}
@MainActor private final class RecoveryBufferingSpeedFixtureSource:PlaybackRecoveryControlling {
 let data:Data
 var isPlaybackRecovering=false
 var recoveryActiveStartedAt:TimeInterval? {nil}
 var recoveryActiveElapsed:TimeInterval {0}
 init(data:Data){self.data=data}
 func fileSize(for file:MediaFile)async throws->UInt64 {UInt64(data.count)}
 func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data {try Task.checkCancellation();return data.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))}
 func setPlaybackSceneActive(_ active:Bool){}
 func cancelPlayback(){}
 func awaitPlaybackCleanup()async throws{}
}
@Suite(.serialized) @MainActor struct NativeBufferingSpeedTests {
 private enum Failure:Error {case timeout}
 private func wait(seconds:Double=8,_ check:()->Bool)async throws {
  let end=ProcessInfo.processInfo.systemUptime+seconds
  while !check() {guard ProcessInfo.processInfo.systemUptime<end else{throw Failure.timeout};try await Task.sleep(for:.milliseconds(10))}
 }
 @Test func realTimerReducesWaitingIntentWithoutInventedResumeAndAppliesRateAfterRefill()async throws {
  let source=BufferingSpeedFixtureSource(data:try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!))
  let session=NativePlaybackSession(stallLimit:30,muted:true);var frames=0
  let task=Task {try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,startPaused:true,onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1})}
  do {
   try await wait{frames>0}
   let player=try #require(session.experimentPlayer),item=try #require(player.currentItem)
   #expect(session.setSpeed(5))
   session.resume();player.pause() // Transport pause is not a user's pause.
   let began=ProcessInfo.processInfo.systemUptime
   try await Task.sleep(for:.milliseconds(200))
   #expect(session.selectedSpeed==5 && player.rate==0)
   try await wait{session.selectedSpeed==4.5}
   #expect(ProcessInfo.processInfo.systemUptime-began>=0.5)
   #expect(player.defaultRate==4.5 && player.rate==0 && !session.isPlaybackPaused)
   #expect(session.experimentStallResumes==0 && session.speedStatus.showsBufferingIndicator)
   try await Task.sleep(for:.milliseconds(1800))
   #expect(session.selectedSpeed==4.5 && player.rate==0)
   let framesBefore=frames
   // Current-item data-stall recovery must honor the reduced selected/default rate.
   NotificationCenter.default.post(name:AVPlayerItem.playbackStalledNotification,object:item)
   try await wait{session.experimentStallResumes==1 && session.speedStatus.effectiveRate==4.5 && frames>framesBefore+2}
   #expect(player.defaultRate==4.5)
   player.pause() // A new stall after confirmed clock/video progress may reduce once.
   try await wait{session.selectedSpeed==4}
   #expect(player.defaultRate==4 && player.rate==0)
   session.pause()
   #expect(session.setSpeed(1))
   try await Task.sleep(for:.milliseconds(1600))
   #expect(session.isPlaybackPaused && session.selectedSpeed==1 && player.rate==0)
   session.resume();player.pause()
   try await Task.sleep(for:.milliseconds(1600))
   #expect(session.selectedSpeed==1 && player.defaultRate==1 && player.rate==0)
  }catch {session.stop();task.cancel();_ = try? await task.value;throw error}
  session.stop();task.cancel();_ = try? await task.value
 }
 @Test func sparseDecisionChangesRunningRateAndLogsExactReason() async throws {
  var policy=PlaybackAutomaticSpeedPolicy(),decision:PlaybackAutomaticSpeedPolicy.Decision?
  let status=PlaybackSpeedStatus(selected:5,effectiveRate:5,ready:true,supportsFastForward:true,paused:false,waiting:false)
  for i in 0...120 {let now=Double(i)/100;_=policy.update(now:now,status:status,eligible:true,playing:true,clock:now*5,outputPolled:true,copiedFramePTS:now*5)}
  for i in 121...650 {
   let now=Double(i)/100
   if let next=policy.update(now:now,status:status,eligible:true,playing:true,clock:now*5,outputPolled:true,copiedFramePTS:nil) {decision=next;break}
  }
  let step=try #require(decision);#expect(step.reason == .sparseOutput)
  let source=BufferingSpeedFixtureSource(data:try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!))
  let session=NativePlaybackSession(stallLimit:30,muted:true);var frames=0
  let task=Task {try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,startPaused:true,onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1})}
  do {
   try await wait{frames>0}
   let player=try #require(session.experimentPlayer)
   #expect(session.setSpeed(5));session.resume()
   try await wait{player.timeControlStatus == .playing && player.rate==5}
   session.applyAutomaticSpeedDecision(step)
   #expect(session.experimentAutomaticRecoveryIsObserving)
   #expect(session.selectedSpeed==4.5 && player.defaultRate==4.5 && player.rate==4.5 && !session.isPlaybackPaused)
   try await wait{session.speedStatus.effectiveRate==4.5}
   let record=PlaybackLogRecord(automaticSpeed:step,session:1,previous:5)
   #expect(record.event == .automaticSpeed && record.values["autoSpeedReason"]==2)
   #expect(record.values["autoSpeedFrom"]==5 && record.values["autoSpeedTo"]==4.5 && record.values["autoSpeedCooldownSeconds"]==3)
   #expect(record.values["autoSpeedWaitingCooldownSeconds"]==3)
   #expect(record.values["autoSpeedSparseRearmOnRateStart"]==1 && record.values["autoSpeedSparseWindowSeconds"]==PlaybackAutomaticSpeedPolicy.sparseInterval)
   #expect(try JSONEncoder().encode(record).count<4096)
   session.pause()
   #expect(!session.experimentAutomaticRecoveryIsObserving && player.rate==0)
  }catch {session.stop();task.cancel();_ = try? await task.value;throw error}
  session.stop();task.cancel();_ = try? await task.value
 }
 @Test func sourceRecoveryCannotAccumulateAutomaticWaitEvidence() async throws {
  let source=RecoveryBufferingSpeedFixtureSource(data:try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!))
  let session=NativePlaybackSession(stallLimit:30,muted:true);var frames=0
  let task=Task {try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,startPaused:true,onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1})}
  do {
   try await wait{frames>0}
   let player=try #require(session.experimentPlayer)
   #expect(session.setSpeed(5));session.resume();player.pause()
   let now=ProcessInfo.processInfo.systemUptime
   source.isPlaybackRecovering=true
   session.updateBufferingSpeed(now:now,duration:10);session.updateBufferingSpeed(now:now+2,duration:10)
   #expect(session.selectedSpeed==5 && player.rate==0 && session.experimentLastAutomaticSpeedDecision==nil)
   source.isPlaybackRecovering=false
   session.updateBufferingSpeed(now:now+3,duration:10)
   #expect(session.selectedSpeed==5)
   session.updateBufferingSpeed(now:now+3.5,duration:10)
   #expect(session.selectedSpeed==4.5 && player.rate==0 && session.experimentLastAutomaticSpeedDecision?.reason == .buffering)
  }catch {session.stop();task.cancel();_ = try? await task.value;throw error}
  session.stop();task.cancel();_ = try? await task.value
 }
 @Test(arguments:0..<5) func lifecycleAndManualActionsKeepCooldownButAllowFreshRepeat(action:Int)async throws {
  let source=BufferingSpeedFixtureSource(data:try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!))
  let session=NativePlaybackSession(stallLimit:30,muted:true);var frames=0
  let task=Task {try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,startPaused:true,onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1})}
  do {
   try await wait{frames>0}
   let player=try #require(session.experimentPlayer)
   #expect(session.setSpeed(5));session.resume();player.pause()
   let now=ProcessInfo.processInfo.systemUptime
   session.updateBufferingSpeed(now:now,duration:10)
   session.updateBufferingSpeed(now:now+0.499,duration:10)
   #expect(session.selectedSpeed==5 && player.rate==0)
   session.updateBufferingSpeed(now:now+0.5,duration:10)
   #expect(session.selectedSpeed==4.5)
   switch action {
   case 0:session.pause();session.resume()
   case 1:session.setPlaybackSceneActive(false);session.setPlaybackSceneActive(true)
   case 2:#expect(session.setSpeed(5))
   case 3:try await session.seek(to:0,maximumBackward:0)
   default:session.updateBufferingSpeed(now:now+2,duration:0)
   }
   player.pause()
   let selected=session.selectedSpeed
   for offset in [2.1,3,3.499] {session.updateBufferingSpeed(now:now+offset,duration:10)}
   #expect(session.selectedSpeed==selected && player.defaultRate==Float(selected) && player.rate==0)
   session.updateBufferingSpeed(now:now+3.5,duration:10) // Cooldown ends; starts fresh wait evidence.
   session.updateBufferingSpeed(now:now+3.999,duration:10)
   #expect(session.selectedSpeed==selected)
   session.updateBufferingSpeed(now:now+4,duration:10)
   #expect(session.selectedSpeed==selected-0.5 && player.defaultRate==Float(selected-0.5) && player.rate==0)
   #expect(session.experimentLastAutomaticSpeedDecision?.reason == .buffering && session.experimentLastAutomaticSpeedDecision?.sequence == 2)
   session.stop();session.updateBufferingSpeed(now:now+200,duration:10)
   #expect(player.rate==0 && !session.setSpeed(5))
  }catch {session.stop();task.cancel();_ = try? await task.value;throw error}
  session.stop();task.cancel();_ = try? await task.value
 }
}
