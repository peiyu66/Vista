import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

struct PlaybackSpeedTests {
 @Test func capabilityAndBounds() {
  for ready in [false,true] {for fast in [false,true] {
   let status=PlaybackSpeedStatus(ready:ready,supportsFastForward:fast)
   for rate in -1...5 {#expect(status.accepts(rate)==(ready && rate>=1 && rate<=(fast ? 3:2)))}
  }}
  #expect(!PlaybackSpeedStatus(selected:1,ready:true).canReset)
  #expect(PlaybackSpeedStatus(selected:1,ready:true).canIncrease)
  #expect(!PlaybackSpeedStatus(selected:2,ready:true).canIncrease)
  #expect(PlaybackSpeedStatus(selected:2,ready:true,supportsFastForward:true).canIncrease)
  #expect(!PlaybackSpeedStatus(selected:3,ready:true,supportsFastForward:true).canIncrease)
  #expect(PlaybackSpeedStatus(selected:3,ready:true,supportsFastForward:true).canReset)
 }
 @Test func labelsDistinguishSelectionFromTransport() {
  #expect(PlaybackSpeedStatus(selected:2,effectiveRate:2,ready:true).text=="2×")
  #expect(PlaybackSpeedStatus(selected:3,effectiveRate:0,ready:true,paused:true).text=="3× · 暫停")
  #expect(PlaybackSpeedStatus(selected:2,effectiveRate:0,ready:true,waiting:true).text=="設定 2× · 緩衝中")
  #expect(PlaybackSpeedStatus(selected:3,effectiveRate:2,ready:true).text=="設定 3× · 等待播放")
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
  var count=0,pts=0.0,hasAudio=false
  let task=Task {try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,onInfo:{hasAudio=$0.hasAudio},onState:{_ in},onFrame:{frame in count += 1;pts=frame.time;if count==1 {session.pause()}})}
  do {
   try await wait{count>0}
   #expect(hasAudio)
   #expect(session.setSpeed(2));#expect(session.speedStatus.selected==2 && session.speedStatus.effectiveRate==0)
   let pausedTime=try #require(session.experimentPlayerTime)
   try await Task.sleep(for:.milliseconds(150))
   #expect(abs((session.experimentPlayerTime ?? -1)-pausedTime)<0.03)
   try await session.seek(to:1,maximumBackward:0)
   #expect(session.isPlaybackPaused && session.speedStatus.selected==2 && session.speedStatus.effectiveRate==0)
   let maximum=session.speedStatus.maximum
   #expect(session.setSpeed(3)==(maximum==3))
   #expect(session.speedStatus.selected==(maximum==3 ? 3:2))
   #expect(!session.setSpeed(4));#expect(!session.setSpeed(0))
   session.resume()
   let before=try #require(session.experimentPlayerTime)
   try await Task.sleep(for:.milliseconds(200))
   let delta=(session.experimentPlayerTime ?? -1)-before
   #expect(session.speedStatus.effectiveRate==Double(session.speedStatus.selected))
   #expect(delta>0.2 && delta<0.95)
   #expect(session.setSpeed(1));#expect(session.speedStatus.selected==1)
   let seek=Task {try await session.seek(to:2,maximumBackward:0)}
   await Task.yield();session.pause()
   try await seek.value
   #expect(session.isPlaybackPaused && session.speedStatus.effectiveRate==0)
   let target=session.experimentPlayerTime ?? -1
   try await Task.sleep(for:.milliseconds(100))
   #expect(abs((session.experimentPlayerTime ?? -1)-target)<0.03)
   print("SPEED_NATIVE maximum",maximum,"rateDelta200ms",delta,"lastPTS",pts,"audioTrack",hasAudio,"audibleOutputTested",false)
  }catch {session.stop();task.cancel();_ = try? await task.value;throw error}
  session.stop();task.cancel();_ = try? await task.value
  #expect(!session.setSpeed(2))
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
   controller.togglePause();controller.increaseSpeed()
   #expect(controller.speedStatus.selected==2 && controller.isPaused)
   controller.seek(to:1)
   try await wait{!controller.isPreparing}
   #expect(controller.isPaused && controller.speedStatus.selected==2)
   let old=controller.playbackGeneration
   controller.play(file:file,source:source)
   #expect(controller.playbackGeneration != old && controller.speedStatus.selected==1 && !controller.canResetSpeed)
   try await wait{controller.canIncreaseSpeed}
   #expect(controller.speedStatus.selected==1 && !controller.isPaused)
   controller.stop()
   try await Task.sleep(for:.milliseconds(100))
   #expect(!controller.canIncreaseSpeed && !controller.canResetSpeed && controller.speedStatus.selected==1)
  }catch {controller.stop();throw error}
 }
 #endif
}
