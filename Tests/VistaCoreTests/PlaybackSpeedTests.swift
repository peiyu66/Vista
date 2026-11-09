import Foundation
import Testing
import AVFoundation
@testable import VistaCore
@testable import VistaMedia

struct PlaybackSpeedTests {
 @Test func capabilityAndBounds() {
  for ready in [false,true] {for fast in [false,true] {
   let status=PlaybackSpeedStatus(ready:ready,supportsFastForward:fast)
   for rate in stride(from:-1.0,through:6.0,by:0.5) {#expect(status.accepts(rate)==(ready && rate>=1 && rate<=(fast ? 5:2)))}
   for invalid in [Double.nan,.infinity,-.infinity,1.25,2.75] {#expect(!status.accepts(invalid))}
  }}
  #expect(!PlaybackSpeedStatus(selected:1,ready:true).canReset)
  #expect(PlaybackSpeedStatus(selected:1,ready:true).canIncrease)
  #expect(!PlaybackSpeedStatus(selected:2,ready:true).canIncrease)
  #expect(PlaybackSpeedStatus(selected:2,ready:true,supportsFastForward:true).canIncrease)
  #expect(PlaybackSpeedStatus.upperLimit==5)
  #expect(PlaybackSpeedStatus(selected:3,ready:true,supportsFastForward:true).canIncrease)
  #expect(PlaybackSpeedStatus(selected:4,ready:true,supportsFastForward:true).canIncrease)
  #expect(!PlaybackSpeedStatus(selected:5,ready:true,supportsFastForward:true).canIncrease)
  #expect(PlaybackSpeedStatus(selected:5,ready:true,supportsFastForward:true).canReset)
 }
 @Test func labelsPreserveSelectionAndPause() {
  #expect(PlaybackSpeedStatus(selected:1.5,effectiveRate:1.5,ready:true).text=="1.5×")
  #expect(PlaybackSpeedStatus(selected:2.5,effectiveRate:0,ready:true,paused:true).text=="2.5× · 暫停")
  #expect(PlaybackSpeedStatus(selected:4.5,effectiveRate:0,ready:true,waiting:true).text=="4.5×")
  #expect(PlaybackSpeedStatus(selected:2,effectiveRate:2,ready:true).text=="2×")
  #expect(PlaybackSpeedStatus(selected:5,effectiveRate:5,ready:true).text=="5×")
  #expect(PlaybackSpeedStatus(selected:5,effectiveRate:0,ready:true,paused:true).text=="5× · 暫停")
  #expect(PlaybackSpeedStatus(selected:2,effectiveRate:0,ready:true,waiting:true).text=="2×")
  #expect(PlaybackSpeedStatus(selected:5,effectiveRate:2,ready:true).text=="5×")
 }
 @Test func transientTransportRatesNeverAddWaitingText() {
  for selected in [2.0,4.5] {
   for rate in [0.0,1.0,Double.nan,.infinity,-.infinity] {
    for waiting in [false,true] {
     let status=PlaybackSpeedStatus(selected:selected,effectiveRate:rate,ready:true,supportsFastForward:true,waiting:waiting)
     #expect(status.text=="\(PlaybackSpeedStatus.label(selected))×")
     #expect(status.showsBufferingIndicator==waiting)
    }
   }
  }
 }

}
private struct SpeedFixtureSource:MediaByteSource {
 let data:Data
 var readDelay:Duration = .zero
 func fileSize(for file:MediaFile)async throws->UInt64{UInt64(data.count)}
 func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data{try await Task.sleep(for:readDelay);return Data(data[Int(range.lowerBound)..<Int(range.upperBound)])}
}
@Suite(.serialized) struct NativePlaybackSpeedTests {
 @MainActor private func wait(_ check:()->Bool)async throws {
  let deadline=ContinuousClock.now.advanced(by:.seconds(8))
  while !check(),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
  #expect(check())
 }
 @Test @MainActor func startPausedStillTimesOutWhilePreparing()async throws {
  let source=SpeedFixtureSource(data:try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!),readDelay:.seconds(2))
  let session=NativePlaybackSession(stallLimit:0.1,muted:true)
  await #expect(throws:NativePlaybackSession.Failure.stalled) {
   try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,startPaused:true,onInfo:{_ in},onState:{_ in},onFrame:{_ in Issue.record("Unexpected frame")})
  }
 }
 @Test @MainActor func pauseSeekResumeAndCapability()async throws {
  let source=SpeedFixtureSource(data:try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!))
  let session=NativePlaybackSession(stallLimit:5,muted:true)
  let url=try #require(Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4"))
  let videoTracks=try await AVURLAsset(url:url).loadTracks(withMediaType:.video)
  let expectedBitrate=Double(try await videoTracks[0].load(.estimatedDataRate))
  var count=0,pts=0.0,hasAudio=false,bitrate:Double?
  // R4: retained test-only startup witness, not a product fix. Original 200ms conditions remain below.
  // No additional playback commands are issued during the follow-on observation.
  var witness=[[String:Double]](),frameWitness=0,speedWitness=0,stateWitness=0
  var taskFinished=false,commandSequence=0,duration=0.0
  let witnessStart=ProcessInfo.processInfo.systemUptime
  @MainActor func record(_ event:Int,checked:[String:Double]=[:]) {
   guard witness.count<128 else{return}
   let now=ProcessInfo.processInfo.systemUptime,status=session.speedStatus,m=session.requestMetrics
   var row:[String:Double]=["event":Double(event),"now":now,"sinceStart":now-witnessStart,
    "commandSequence":Double(commandSequence),"selected":status.selected,"reportedEffective":status.effectiveRate,
    "userPaused":session.isPlaybackPaused ? 1:0,"frames":Double(count),"lastPTS":pts,"duration":duration,
    "taskFinished":taskFinished ? 1:0,"reads":Double(m.reads),"bytes":Double(m.bytes),"sourceEpoch":Double(m.epoch),
    "stallResumes":Double(session.experimentStallResumes),"stallPending":session.experimentPendingDataStall ? 1:0]
   if let player=session.experimentPlayer {
    row["clock"]=player.currentTime().seconds;row["playerRate"]=Double(player.rate);row["defaultRate"]=Double(player.defaultRate)
    row["transport"]=Double(player.timeControlStatus.rawValue)
    row["waitingReason"]=player.reasonForWaitingToPlay == .evaluatingBufferingRate ? 1:player.reasonForWaitingToPlay == .toMinimizeStalls ? 2:player.reasonForWaitingToPlay == .noItemToPlay ? 3:0
    if let item=player.currentItem {
     row["itemStatus"]=Double(item.status.rawValue);row["empty"]=item.isPlaybackBufferEmpty ? 1:0
     row["full"]=item.isPlaybackBufferFull ? 1:0;row["likelyToKeepUp"]=item.isPlaybackLikelyToKeepUp ? 1:0
     row["timebasePresent"]=item.timebase == nil ? 0:1
     if let timebase=item.timebase {row["optionalEffective"]=CMTimebaseGetEffectiveRate(timebase)}
     let clock=player.currentTime().seconds
     row["loadedAhead"]=item.loadedTimeRanges.map(\.timeRangeValue).compactMap {range->Double? in
      let lower=range.start.seconds,upper=CMTimeRangeGetEnd(range).seconds
      return lower.isFinite && upper.isFinite && lower<=clock && upper>=clock ? upper-clock:nil
     }.max()
    }
   }
   if let r=session.experimentIntentLastRecord {
    row["lastLoggedCommand"]=Double(r.command);row["lastLoggedPhase"]=Double(r.phase.rawValue)
    row["lastLoggedKind"]=Double(r.kind.rawValue);row["lastLoggedAcceptedAt"]=r.acceptedAt
   }
   row.merge(checked){_,frozen in frozen}
   witness.append(row.filter{$0.value.isFinite})
  }
  defer {if let data=try? JSONSerialization.data(withJSONObject:witness,options:[.sortedKeys]),let text=String(data:data,encoding:.utf8) {print("SPEED_DIAG2_WITNESS",text)}}
  let task=Task {
   do {
    try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,onInfo:{hasAudio=$0.hasAudio;bitrate=$0.estimatedDataRate;duration=$0.duration},onState:{_ in if stateWitness<12 {stateWitness += 1;record(61)}},onFrame:{frame in
     count += 1;pts=frame.time
     if frameWitness<16 {frameWitness += 1;record(60)}
     if count==1 {commandSequence += 1;record(1);session.pause();record(2)}
    },onSpeed:{_ in if speedWitness<16 {speedWitness += 1;record(62)}})
    taskFinished=true;record(90)
   }catch {taskFinished=true;record(91);throw error}
  }
  do {
   try await wait{count>0}
   #expect(hasAudio)
   #expect(expectedBitrate>0 && bitrate==expectedBitrate)
   commandSequence += 1;record(3)
   #expect(session.setSpeed(2));#expect(session.speedStatus.selected==2 && session.speedStatus.effectiveRate==0)
   let pausedTime=try #require(session.experimentPlayerTime)
   try await Task.sleep(for:.milliseconds(150))
   #expect(abs((session.experimentPlayerTime ?? -1)-pausedTime)<0.03)
   commandSequence += 1;record(4)
   try await session.seek(to:1,maximumBackward:0)
   record(5)
   #expect(session.isPlaybackPaused && session.speedStatus.selected==2 && session.speedStatus.effectiveRate==0)
   let maximum=session.speedStatus.maximum
   for rate in stride(from:2.5,through:5.0,by:0.5) {
    commandSequence += 1;record(6)
    #expect(session.setSpeed(rate)==(maximum==5))
    record(7)
    #expect(session.speedStatus.selected==(maximum==5 ? rate:2))
    #expect(session.isPlaybackPaused && session.speedStatus.effectiveRate==0)
   }
   #expect(!session.setSpeed(6));#expect(!session.setSpeed(0))
   commandSequence += 1;record(8)
   // The seek target frame alone is not forward playback PTS evidence.
   let resumeAt=ProcessInfo.processInfo.systemUptime,resumePTS=max(pts,session.experimentPlayerTime ?? pts)
   session.resume()
   record(9)
   let before=try #require(session.experimentPlayerTime)
   try await Task.sleep(for:.milliseconds(200))
   // Freeze the original 200ms check before collecting the fuller witness.
   let checkedAt=ProcessInfo.processInfo.systemUptime,checkedClock=session.experimentPlayerTime ?? -1
   let checkedSpeed=session.speedStatus,checkedPTS=pts
   let delta=checkedClock-before
   #expect(checkedSpeed.effectiveRate==Double(checkedSpeed.selected))
   #expect(delta>0.2 && delta<1.6)
   record(10,checked:["checkedAt":checkedAt,"checkedClock":checkedClock,"checkedPTS":checkedPTS,
    "checkedEffective":checkedSpeed.effectiveRate,"checkedSelected":Double(checkedSpeed.selected),"checkedDelta":delta])
   // Preserve failure at 200ms, then distinguish late motion from continuing
   // stillness before the next original command. Stop at the original 5s bound.
   let observationDeadline=resumeAt+5
   var nextObservation=ProcessInfo.processInfo.systemUptime
   while !taskFinished,ProcessInfo.processInfo.systemUptime<observationDeadline,
    !((session.experimentPlayerTime ?? before)>before && pts>resumePTS) {
    try await Task.sleep(for:.milliseconds(10))
    if ProcessInfo.processInfo.systemUptime>=nextObservation {record(30);nextObservation += 0.1}
   }
   record((session.experimentPlayerTime ?? before)>before && pts>resumePTS ? 11:12)
   commandSequence += 1;record(13)
   #expect(session.setSpeed(1));#expect(session.speedStatus.selected==1)
   commandSequence += 1;record(14)
   let seek=Task {try await session.seek(to:2,maximumBackward:0)}
   await Task.yield();commandSequence += 1;record(15);session.pause();record(16)
   try await seek.value
   #expect(session.isPlaybackPaused && session.speedStatus.effectiveRate==0)
   record(17)
   let target=session.experimentPlayerTime ?? -1
   try await Task.sleep(for:.milliseconds(100))
   #expect(abs((session.experimentPlayerTime ?? -1)-target)<0.03)
   print("SPEED_NATIVE maximum",maximum,"rateDelta200ms",delta,"lastPTS",pts,"audioTrack",hasAudio,"audibleOutputTested",false)
  }catch {session.stop();task.cancel();_ = try? await task.value;throw error}
  session.stop();task.cancel();_ = try? await task.value
  #expect(!session.setSpeed(2))
 }
 @Test(arguments:[1.5,2.5,3.5,4.5,5.0]) @MainActor func higherRatesPreservePauseSeekAndResume(rate:Double)async throws {
  let source=SpeedFixtureSource(data:try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!))
  let session=NativePlaybackSession(stallLimit:5,muted:true);var frames=0
  let task=Task {try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,startPaused:true,onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1})}
  do {
   try await wait{frames>0}
   try #require(session.speedStatus.maximum==5,"Synthetic fixture must support fast forward to cover every half step through 5×")
   #expect(session.setSpeed(rate))
   try await session.seek(to:1,maximumBackward:0)
   #expect(session.isPlaybackPaused && session.selectedSpeed==rate && session.speedStatus.effectiveRate==0)
   let pausedLog=session.anonymousLogValues()
   #expect(pausedLog[.selectedSpeed]==Double(rate) && pausedLog[.effectiveRate]==0 && pausedLog[.maximumSpeed]==5)
   let paused=session.experimentPlayerTime ?? -1
   try await Task.sleep(for:.milliseconds(100))
   #expect(abs((session.experimentPlayerTime ?? -1)-paused)<0.03)
   session.resume()
   try await wait{session.speedStatus.effectiveRate==Double(rate) && (session.experimentPlayerTime ?? -1)>paused+0.1}
   try await session.seek(to:1,maximumBackward:0)
   #expect(!session.isPlaybackPaused && session.selectedSpeed==rate)
   try await wait{session.speedStatus.effectiveRate==Double(rate)}
   let runningLog=session.anonymousLogValues()
   #expect(runningLog[.selectedSpeed]==Double(rate) && runningLog[.effectiveRate]==Double(rate))
   let record=PlaybackLogRecord(event:.sample,values:runningLog,build:"69")
   #expect(record.values["selectedSpeed"]==Double(rate) && record.values["effectiveRate"]==Double(rate))
   session.pause()
   #expect(session.setSpeed(1) && session.isPlaybackPaused && session.selectedSpeed==1)
   #expect(!session.setSpeed(6) && session.selectedSpeed==1)
  }catch {session.stop();task.cancel();_ = try? await task.value;throw error}
  session.stop();task.cancel();_ = try? await task.value
  #expect(!session.setSpeed(rate))
 }
 @Test @MainActor func initialPausedSeekNeverResumes()async throws {
  let source=SpeedFixtureSource(data:try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!))
  let session=NativePlaybackSession(stallLimit:5,muted:true);var frames=0
  let task=Task {try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,startAt:2,startPaused:true,onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1})}
  do {
   try await wait{frames>0}
   #expect(session.speedStatus.selected==1 && session.speedStatus.effectiveRate==0 && session.isPlaybackPaused)
   let before=session.experimentPlayerTime ?? -1
   #expect(session.setSpeed(2));session.pause()
   try await Task.sleep(for:.milliseconds(100))
   #expect(abs((session.experimentPlayerTime ?? -1)-before)<0.03)
  }catch {session.stop();task.cancel();_ = try? await task.value;throw error}
  session.stop();task.cancel();_ = try? await task.value
 }
 #if VISTA_NATIVE_PLAYER_EXPERIMENT
 @Test @MainActor func controllerReplacesFileAtOneAndRejectsOldCallbacks()async throws {
  let source=SpeedFixtureSource(data:try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!))
  let controller=PlaybackController(),file=try MediaFile(components:["synthetic.mp4"])
  controller.play(file:file,source:source)
  do {
   try await wait{controller.canIncreaseSpeed}
   controller.togglePause()
   let maximum=controller.speedStatus.maximum
   for rate in stride(from:1.5,through:maximum,by:0.5) {
    controller.increaseSpeed()
    #expect(controller.speedStatus.selected==rate && controller.isPaused)
   }
   #expect(!controller.canIncreaseSpeed && controller.canResetSpeed)
   controller.increaseSpeed();controller.increaseSpeed()
   #expect(controller.speedStatus.selected==maximum && (maximum==5 ? controller.speedMessage==nil:controller.speedMessage != nil))
   controller.resetSpeed()
   #expect(controller.speedStatus.selected==1 && controller.isPaused && !controller.canResetSpeed)
   for _ in stride(from:1.5,through:maximum,by:0.5) {controller.increaseSpeed()}
   controller.seek(to:1)
   try await wait{!controller.isPreparing}
   #expect(controller.isPaused && controller.speedStatus.selected==maximum)
   let old=controller.playbackGeneration
   #expect(controller.trackInfo?.estimatedDataRate != nil)
   controller.stop(discardTrackInfo:true)
   #expect(controller.trackInfo==nil)
   try await Task.sleep(for:.milliseconds(100))
   #expect(controller.trackInfo==nil && !controller.isPlaying)
   controller.play(file:file,source:source)
   #expect(controller.playbackGeneration != old && controller.speedStatus.selected==1 && !controller.canResetSpeed && controller.trackInfo==nil)
   try await wait{controller.canIncreaseSpeed}
   #expect(controller.speedStatus.selected==1 && !controller.isPaused)
   controller.stop()
   try await Task.sleep(for:.milliseconds(100))
   #expect(!controller.canIncreaseSpeed && !controller.canResetSpeed && controller.speedStatus.selected==1)
  }catch {controller.stop();throw error}
 }
 #endif
}

struct VideoBitrateTests {
 private func info(_ rate:Double?)->VideoTrackInfo {
  VideoTrackInfo(codec:"test",width:16,height:16,duration:10,hasAudio:true,estimatedDataRate:rate)
 }
 @Test func estimatedAverageUsesDecimalBitUnitsAndUnknownNeverBecomesZero() {
  #expect(info(24_500_000).averageBitrateText=="≈24.5 Mbps")
  #expect(info(384_000).averageBitrateText=="≈0.38 Mbps")
  #expect(info(3_700).averageBitrateText=="≈0.004 Mbps")
  #expect(info(800).averageBitrateText=="<0.001 Mbps")
  #expect(info(0.25).averageBitrateText=="<0.001 Mbps")
  for invalid:Double? in [nil,0,-1,.nan,.infinity,-.infinity] {
   #expect(info(invalid).estimatedDataRate==nil)
   #expect(info(invalid).averageBitrateText=="— Mbps")
  }
 }
}
