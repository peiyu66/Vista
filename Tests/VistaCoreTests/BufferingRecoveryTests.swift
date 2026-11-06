import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import VistaCore
@testable import VistaMedia
@Suite(.serialized) struct BufferingRecoveryTests {
 @MainActor private func setup()async throws->(PlaybackTimeline,PlaybackAudioClock,AudioPlayback) {
  let asset=AVURLAsset(url:Bundle.module.url(forResource:"SyntheticAV",withExtension:"mp4")!)
  let track=try #require(try await asset.loadTracks(withMediaType:.audio).first),clock=PlaybackAudioClock(muted:true)
  let audio=try AudioPlayback(asset:asset,track:track,clock:clock),timeline=PlaybackTimeline()
  timeline.attachAudio(clock,feed:{try await audio.pump(through:$0)});try await timeline.present(at:0) {};try await audio.pump(through:2)
  return(timeline,clock,audio)
 }
 @Test @MainActor func reproduceUnbufferedLeadButHoldClockDuringVideoWork()async throws {
  var baselineFailed=false
  do {
   let(t,c,a)=try await setup()
   do {for i in 1...9 {try await Task.sleep(for:.milliseconds(500));_=try await t.present(at:Double(i)/30) {}}}
   catch let e as PlaybackFailure {#expect(e.message.contains("audioLead"));baselineFailed=true;print("BASELINE_SLOW_VIDEO",e.message)}
   await a.stop();t.detachAudio();_ = c
  }
  #expect(baselineFailed)
  let(t,c,a)=try await setup();var delivered=0;var states=[Bool]()
  t.onBufferingChange={states.append($0)}
  do {
   for i in 1...9 {
    let before=c.time,work=t.beginVideoWork();try await Task.sleep(for:.milliseconds(500))
    #expect(t.isBuffering);#expect(c.time-before<0.25);t.endVideoWork(work)
    if try await !t.skipLateVideoFrame(at:Double(i)/30) {_=try await t.present(at:Double(i)/30){delivered += 1}}
   }
   #expect(delivered>0 && states.contains(true));print("BUFFERED_SLOW_VIDEO",delivered,"frames clock",c.time,"drops",t.droppedVideoFrames)
  }catch{await a.stop();t.detachAudio();throw error}
  await a.stop();t.detachAudio();#expect(!t.isBuffering)
 }
 @Test @MainActor func userPauseResumeAndStopRemainIndependent()async throws {
  let(t,c,a)=try await setup();let work=t.beginVideoWork();try await Task.sleep(for:.milliseconds(280));#expect(t.isBuffering)
  t.pause();#expect(t.isPaused && !t.isBuffering);t.endVideoWork(work)
  let paused=c.time;try await Task.sleep(for:.milliseconds(280));#expect(abs(c.time-paused)<0.03)
  t.resume();_=try await t.present(at:paused+0.04) {};#expect(!t.isPaused && !t.isBuffering)
  _=t.beginVideoWork();t.stopAudio();try await Task.sleep(for:.milliseconds(280));#expect(!t.isBuffering)
  await a.stop();t.detachAudio()
 }
 @Test @MainActor func bufferingDeadlineStillRejectsStalledVideo()async throws {
  let(t,_,a)=try await setup();let work=t.beginVideoWork()
  try await Task.sleep(for:.seconds(15.3));t.endVideoWork(work)
  do { _=try await t.skipLateVideoFrame(at:0);Issue.record("Expected bounded buffering failure") }
  catch let error as PlaybackFailure {#expect(error.message.contains("videoBufferingTimeout"))}
  await a.stop();t.detachAudio();#expect(!t.isBuffering)
 }
 @Test @MainActor func fastWorkDoesNotEnterBuffering()async throws {
  let(t,_,a)=try await setup();var entered=false;t.onBufferingChange={if $0 {entered=true}}
  let work=t.beginVideoWork();t.endVideoWork(work);try await Task.sleep(for:.milliseconds(150));#expect(!entered && !t.isBuffering)
  await a.stop();t.detachAudio()
 }
}
@Suite(.serialized) struct BufferingLifecycleTests {
 @Test @MainActor func backgroundPauseRequiresExplicitResumeAndStopCancels() async throws {
  let player=PlaybackController()
  player.play(file:try MediaFile(components:["synthetic.mp4"]),source:DemoMediaSource())
  for _ in 0..<500 {
   if player.isPlaying && !player.isPreparing {break}
   try await Task.sleep(for:.milliseconds(10))
  }
  #expect(player.isPlaying && !player.isPreparing)
  player.pauseForBackground();#expect(player.isPaused)
  let at=player.position
  try await Task.sleep(for:.milliseconds(200));#expect(player.position==at)
  player.pauseForBackground();#expect(player.isPaused)
  player.togglePause();#expect(!player.isPaused)
  player.stop();#expect(!player.isPlaying && !player.isBuffering)
 }
 @Test @MainActor func backgroundDuringPreparationStopsRatherThanAutoplays() throws {
  let player=PlaybackController()
  player.play(file:try MediaFile(components:["synthetic.mp4"]),source:DemoMediaSource())
  player.pauseForBackground();#expect(!player.isPlaying && !player.isPreparing)
 }
}
