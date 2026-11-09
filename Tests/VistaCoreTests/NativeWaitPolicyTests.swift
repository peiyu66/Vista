import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import VistaCore
@testable import VistaMedia

struct NativeStallRecoveryGateTests {
 private func take(_ gate:inout NativeStallRecoveryGate,now:Double=0,active:Bool=true,scene:Bool=true,paused:Bool=false,seeking:Bool=false,ready:Bool=true,transportPaused:Bool=true,empty:Bool=false,position:Double=1,duration:Double=5,speed:Double=1,ranges:[Range<Double>]=[0..<5])->Bool {
  gate.takeResume(now:now,active:active,sceneActive:scene,paused:paused,seeking:seeking,ready:ready,transportPaused:transportPaused,bufferEmpty:empty,position:position,duration:duration,selectedSpeed:speed,ranges:ranges)
 }
 @Test func onlyCurrentDataStallArmsPacedRecovery() {
  var gate=NativeStallRecoveryGate()
  #expect(!take(&gate));#expect(gate.blockedBy == .noEpisode)
  gate.stalled(eligible:false);#expect(!take(&gate))
  gate.stalled(eligible:true);#expect(take(&gate));#expect(!take(&gate))
  gate.stalled(eligible:true);gate.clear();#expect(!take(&gate))
 }
 @Test func pauseSeekStopBackgroundFailureAndEOFNeverResume() {
  var gate=NativeStallRecoveryGate();gate.stalled(eligible:true)
  #expect(!take(&gate,active:false));#expect(!take(&gate,scene:false))
  #expect(!take(&gate,paused:true));#expect(!take(&gate,seeking:true))
  #expect(!take(&gate,ready:false));#expect(!take(&gate,transportPaused:false))
  #expect(!take(&gate,empty:true));#expect(!take(&gate,position:5))
  #expect(!take(&gate,position:.nan));#expect(!take(&gate,duration:.infinity))
  #expect(!take(&gate,speed:0));#expect(!take(&gate,speed:.nan))
  #expect(gate.pending);#expect(take(&gate))
 }
 @Test func quarterSecondIsScaledByRateAndCappedAtEOF() {
  var gate=NativeStallRecoveryGate();gate.stalled(eligible:true)
  #expect(!take(&gate,speed:5,ranges:[0..<2]));#expect(gate.blockedBy == .insufficientCoverage)
  #expect(!take(&gate,ranges:[0..<0.9,1.1..<5]))
  #expect(take(&gate,speed:5,ranges:[0..<2.25]))
  gate.clear();gate.stalled(eligible:true)
  #expect(take(&gate,position:4.9,speed:5))
 }
 @Test func onlyConfirmedProgressClearsPacedBoundedAttempts() {
  var gate=NativeStallRecoveryGate();gate.stalled(eligible:true)
  #expect(!take(&gate,now:10,transportPaused:false)) // .playing alone is not progress.
  #expect(gate.pending && gate.attempts==0)
  #expect(take(&gate,now:10));#expect(gate.pending && gate.attempts==1)
  #expect(!take(&gate,now:10.499));#expect(take(&gate,now:10.5))
  gate.stalled(eligible:true) // Duplicate notifications do not renew the episode.
  #expect(gate.attempts==2);#expect(!take(&gate,now:10.75))
  #expect(take(&gate,now:11));#expect(!take(&gate,now:100))
  #expect(gate.attempts==3 && gate.pending && gate.blockedBy == .attemptLimit)
  gate.clear() // Two advancing media clock/frame samples confirmed recovery.
  #expect(!take(&gate,now:101))
  gate.stalled(eligible:true);#expect(take(&gate,now:101) && gate.attempts==1)
 }
 @Test func recoveryBudgetStartsAtAttemptAndExcludesInactiveTime() {
  var gate=NativeStallRecoveryGate();gate.stalled(eligible:true)
  gate.observeElapsed(now:100,eligible:true)
  #expect(!gate.recoveryExpired(limit:1)) // General network waiting has no new deadline.
  #expect(take(&gate,now:100))
  gate.observeElapsed(now:100.5,eligible:true)
  gate.observeElapsed(now:101,eligible:false)
  gate.observeElapsed(now:1000,eligible:false)
  gate.observeElapsed(now:2000,eligible:true)
  #expect(gate.recoveryActiveElapsed==1)
  gate.stalled(eligible:true);#expect(take(&gate,now:2000))
  gate.observeElapsed(now:2001,eligible:true)
  #expect(gate.recoveryExpired(limit:2)) // Another attempt or notification cannot reset it.
  gate.clear();#expect(!gate.recoveryExpired(limit:2) && gate.recoveryActiveElapsed==0)
 }
 @Test func everyRetryRechecksIntentReadinessAndLatestSpeed() {
  var gate=NativeStallRecoveryGate();gate.stalled(eligible:true);#expect(take(&gate,now:0))
  #expect(!take(&gate,now:1,active:false));#expect(!take(&gate,now:1,scene:false))
  #expect(!take(&gate,now:1,paused:true));#expect(!take(&gate,now:1,seeking:true))
  #expect(!take(&gate,now:1,ready:false));#expect(!take(&gate,now:1,empty:true))
  #expect(!take(&gate,now:1,position:5));#expect(!take(&gate,now:.nan))
  #expect(!take(&gate,now:-1));#expect(gate.attempts==1)
  #expect(!take(&gate,now:1,speed:5,ranges:[0..<2]))
  #expect(take(&gate,now:1,speed:2,ranges:[0..<2]))
 }

 @Test func loggedThreeAttemptExhaustionRearmsOnlyForNewContiguousMedia() {
  var gate=NativeStallRecoveryGate();gate.stalled(eligible:true)
  // The player's clock can advance without delivered video, so this is still
  // one unconfirmed episode. Later data around the stopped clock must help.
  #expect(take(&gate,now:0,position:53,duration:100,speed:2.5,ranges:[50..<54]))
  #expect(take(&gate,now:0.5,position:55,duration:100,speed:2.5,ranges:[50..<56]))
  #expect(take(&gate,now:1,position:58.4,duration:100,speed:2.5,ranges:[50..<59.5]))
  gate.observeElapsed(now:2,eligible:true)
  #expect(!take(&gate,now:2,position:62.694,duration:100,speed:2,ranges:[62..<62.75]))
  #expect(gate.blockedBy == .insufficientCoverage)
  #expect(take(&gate,now:3,position:62.694,duration:100,speed:2,ranges:[62..<66.83]))
  #expect(gate.attempts==4 && gate.pending && gate.recoveryActiveElapsed==2)
  #expect(!take(&gate,now:4,position:62.694,duration:100,speed:2,ranges:[62..<66.83]))
  #expect(gate.blockedBy == .attemptLimit)
 }
 @Test func newBufferRetriesArePacedAndCannotRenewBudgetOrReplayOldCoverage() {
  var gate=NativeStallRecoveryGate();gate.stalled(eligible:true)
  for n in 0..<3 {#expect(take(&gate,now:Double(n)*0.5,duration:100,ranges:[0..<3]))}
  #expect(!take(&gate,now:1.999,duration:100,ranges:[0..<5]))
  #expect(gate.blockedBy == .retryDelay)
  #expect(!take(&gate,now:2,duration:100,ranges:[0..<3.1,10..<20]))
  #expect(!take(&gate,now:2,duration:100,ranges:[0..<2]))
  #expect(!take(&gate,now:2,duration:100,ranges:[0..<3]))
  #expect(!take(&gate,now:2,duration:100,speed:0.5,ranges:[0..<3]))
  #expect(take(&gate,now:2,duration:100,ranges:[0..<3.25]))
  #expect(!take(&gate,now:2.999,duration:100,ranges:[0..<7]))
  #expect(take(&gate,now:3,duration:100,ranges:[0..<7]))
  gate.stalled(eligible:true)
  gate.observeElapsed(now:15,eligible:true)
  #expect(gate.recoveryExpired(limit:15) && gate.attempts==5)
  // check() ends playback before another resume; neither data nor retries reset it.
  gate.clear();gate.stalled(eligible:true)
  #expect(take(&gate,now:0,duration:100,ranges:[0..<8]))
  #expect(take(&gate,now:0.5,duration:100,ranges:[0..<6]))
  #expect(take(&gate,now:1,duration:100,ranges:[0..<7]))
  #expect(!take(&gate,now:2,duration:100,ranges:[0..<8])) // Retains the first attempt's high-water.
  #expect(!take(&gate,now:2,duration:100,speed:5,ranges:[0..<9]))
  #expect(take(&gate,now:2,duration:100,speed:2,ranges:[0..<8.5]))
  gate.observeElapsed(now:3,eligible:false)
  gate.observeElapsed(now:100,eligible:false)
  gate.observeElapsed(now:200,eligible:true)
  #expect(gate.recoveryActiveElapsed==3)
  #expect(take(&gate,now:200,duration:100,speed:5,ranges:[0..<9.75]))
  gate.observeElapsed(now:212,eligible:true)
  #expect(gate.recoveryExpired(limit:15)) // A late improvement does not erase pre-inactive time.
 }
 @Test func improvedBufferStillHonorsIntentReadinessAndEOF() {
  var gate=NativeStallRecoveryGate();gate.stalled(eligible:true)
  for n in 0..<3 {#expect(take(&gate,now:Double(n)*0.5,ranges:[0..<4.9]))}
  #expect(!take(&gate,now:2,active:false));#expect(!take(&gate,now:2,scene:false))
  #expect(!take(&gate,now:2,paused:true));#expect(!take(&gate,now:2,seeking:true))
  #expect(!take(&gate,now:2,ready:false));#expect(!take(&gate,now:2,transportPaused:false))
  #expect(!take(&gate,now:2,empty:true));#expect(!take(&gate,now:2,position:5))
  #expect(gate.attempts==3)
  #expect(take(&gate,now:2,position:4.9,speed:5)) // Short final tail is new media.
  #expect(!take(&gate,now:3,position:4.9,speed:1))
  gate.clear();#expect(!take(&gate,now:4)) // Pause/seek/replacement cancels the old episode.
 }

}


/// Pure policy fixtures. These do not recreate the user's AVFoundation stall.
struct NativeDemandProbeTests {
 private func observation(requests:UInt64=1,chunks:UInt64=1,cancelled:UInt64=0,bytes:UInt64=100,
                          active:Int=0,frames:Int=5,supported:Bool=true,
                          source:PlaybackPrefetchSource.RecoveryActivity?=nil)->NativeStallRecoveryGate.DemandObservation {
  .init(bridge:.init(available:true,activeRequests:active,requests:requests,chunks:chunks,
   cancellations:cancelled,deliveredBytes:bytes,returns:chunks,responses:chunks),source:source,supported:supported,frameCount:frames)
 }
 private func take(_ gate:inout NativeStallRecoveryGate,now:Double,position:Double=100.179398,
                   active:Bool=true,scene:Bool=true,paused:Bool=false,seeking:Bool=false,ready:Bool=true,
                   transportPaused:Bool=true,empty:Bool=true,speed:Double=2,
                   ranges:[Range<Double>]=[100..<100.274],demand:NativeStallRecoveryGate.DemandObservation?=nil,
                   mode:NativeStallRecoveryGate.Mode = .all)->Bool {
  gate.takeResume(now:now,active:active,sceneActive:scene,paused:paused,seeking:seeking,ready:ready,
   transportPaused:transportPaused,bufferEmpty:empty,position:position,duration:200,
   selectedSpeed:speed,ranges:ranges,demand:demand ?? observation(),mode:mode)
 }
 private func quiet(_ gate:inout NativeStallRecoveryGate,from:Double=0,demand:NativeStallRecoveryGate.DemandObservation?=nil) {
  #expect(!take(&gate,now:from,demand:demand))
  #expect(!take(&gate,now:from+0.25,demand:demand))
 }
 @Test func loggedThinEmptyStateAllowsExactlyOneFreshProbeAndSpendsSharedBudget() {
  var gate=NativeStallRecoveryGate()
  #expect(!take(&gate,now:0));gate.stalled(eligible:true)
  quiet(&gate);#expect(!take(&gate,now:0.499))
  #expect(take(&gate,now:0.5))
  #expect(gate.probeUsed && gate.attempts==1 && gate.pending && gate.lastResumeKind == .demandProbe)
  #expect(gate.probeQuietSeconds==0.5)
  for i in 1...20 {gate.stalled(eligible:true);#expect(!take(&gate,now:0.5+Double(i)*0.1,speed:i%2==0 ? 2:2.5))}
  gate.observeElapsed(now:15.5,eligible:true)
  #expect(gate.recoveryExpired(limit:15) && gate.attempts==1 && gate.probeUsed)
 }
 @Test func nonemptyThinCoverageHasSameProbeButFullCoverageKeepsOriginalPath() {
  var thin=NativeStallRecoveryGate();thin.stalled(eligible:true)
  for now in [0.0,0.25] {#expect(!take(&thin,now:now,empty:false))}
  #expect(take(&thin,now:0.5,empty:false) && thin.lastResumeKind == .demandProbe)
  var full=NativeStallRecoveryGate();full.stalled(eligible:true)
  for now in [0.0,0.5,1.0] {#expect(take(&full,now:now,empty:false,ranges:[100..<110]))}
  #expect(!full.probeUsed && full.lastResumeKind == .buffered)
  #expect(!take(&full,now:2,empty:false,ranges:[100..<110]))
  #expect(full.blockedBy == .attemptLimit && !full.probeUsed)
  for now in [2.0,2.25,2.5] {#expect(!take(&full,now:now))}
  #expect(full.probeBlockedBy == .attemptLimit)
 }
 @Test func probeAndBufferedRecoveryShareInitialAttemptsAndFrontier() {
  var gate=NativeStallRecoveryGate();gate.stalled(eligible:true)
  quiet(&gate);#expect(take(&gate,now:0.5))
  #expect(!take(&gate,now:0.999,empty:false,ranges:[100..<110]))
  #expect(take(&gate,now:1,empty:false,ranges:[100..<110]))
  #expect(take(&gate,now:1.5,empty:false,ranges:[100..<110]))
  #expect(!take(&gate,now:2.5,empty:false,ranges:[100..<110]))
  #expect(take(&gate,now:2.5,empty:false,ranges:[100..<110.5]))
  #expect(gate.attempts==4 && gate.probeUsed)
 }
 @Test func workBetweenSamplesAndEveryProgressSignalRestartQuietWindow() {
  for variant in 0..<6 {
   var gate=NativeStallRecoveryGate();gate.stalled(eligible:true);quiet(&gate)
   let changed=observation(requests:variant==0 ? 2:1,chunks:variant==1 ? 2:1,
    cancelled:variant==2 ? 1:0,bytes:variant==3 ? 200:100,frames:variant==4 ? 6:5)
   let position=variant==5 ? 100.19:100.179398
   #expect(!take(&gate,now:0.5,position:position,demand:changed))
   #expect(!take(&gate,now:0.75,position:position,demand:changed))
   #expect(take(&gate,now:1,position:position,demand:changed))
  }
 }
 @Test func staleBackwardOrInvalidObservationCannotBankQuietTime() {
  var gate=NativeStallRecoveryGate();gate.stalled(eligible:true);quiet(&gate)
  #expect(!take(&gate,now:0.625)) // Gap exceeds 0.25 seconds.
  #expect(!take(&gate,now:0.875));#expect(take(&gate,now:1.125))
  gate.clear();gate.stalled(eligible:true);quiet(&gate)
  #expect(!take(&gate,now:0.1));#expect(!take(&gate,now:0.35));#expect(take(&gate,now:0.6))
  gate.clear();gate.stalled(eligible:true);quiet(&gate)
  #expect(!take(&gate,now:.nan));#expect(!take(&gate,now:1))
  #expect(!take(&gate,now:1.25));#expect(take(&gate,now:1.5))
 }
 @Test func guardsBusyAndUnknownSourcesNeverProbe() {
  for variant in 0..<9 {
   var gate=NativeStallRecoveryGate();gate.stalled(eligible:true)
   for now in [0.0,0.25,0.5,0.75,1.0] {
    #expect(!take(&gate,now:now,active:variant != 0,scene:variant != 1,paused:variant==2,
     seeking:variant==3,ready:variant != 4,transportPaused:variant != 5,speed:variant==6 ? .nan:2,
     demand:observation(active:variant==7 ? 1:0,supported:variant != 8)))
   }
   #expect(gate.attempts==0 && !gate.probeUsed)
  }
 }
 @Test func inactiveSourceRecoveryAndCancellationRequireFreshWindowButNeverRenewUsed() {
  var gate=NativeStallRecoveryGate();gate.stalled(eligible:true);quiet(&gate)
  #expect(!take(&gate,now:0.5,scene:false))
  #expect(!take(&gate,now:10));#expect(!take(&gate,now:10.25))
  #expect(!take(&gate,now:10.5,ready:false))
  quiet(&gate,from:20);#expect(take(&gate,now:20.5))
  gate.observeElapsed(now:21,eligible:false);gate.resetProbeObservation()
  gate.observeElapsed(now:100,eligible:true)
  #expect(!take(&gate,now:100));#expect(gate.probeUsed && gate.attempts==1)
  #expect(gate.recoveryActiveElapsed==0.5)
  gate.clear();gate.stalled(eligible:true);quiet(&gate,from:101);#expect(take(&gate,now:101.5))
 }
 @Test func waitingDecisionPrecedesSameBoundaryProbeAndNewFramePreventsGrant() {
  var gate=NativeStallRecoveryGate(),policy=PlaybackAutomaticSpeedPolicy()
  gate.stalled(eligible:true)
  var selected=2.5,decision:PlaybackAutomaticSpeedPolicy.Decision?
  for now in [0.0,0.25,0.5] {
   #expect(!take(&gate,now:now,speed:selected,mode:.bufferedOnly))
   let status=PlaybackSpeedStatus(selected:selected,effectiveRate:0,ready:true,supportsFastForward:true,paused:false,waiting:true)
   decision=policy.update(now:now,status:status,eligible:true,playing:false,recovering:true,clock:100.179398,outputPolled:false,copiedFramePTS:nil)
   if let decision {selected=decision.nextSpeed}
   let approved=take(&gate,now:now,speed:selected,mode:.probeOnly)
   #expect(approved == (now==0.5))
  }
  #expect(decision?.nextSpeed==2 && selected==2 && gate.attempts==1 && gate.probeUsed)
  for playing in [true,false] {
   #expect(!take(&gate,now:1,transportPaused:!playing,speed:selected,mode:.probeOnly))
   #expect(gate.pending && gate.attempts==1) // Neither command state proves frames.
  }
  gate.clear();gate.stalled(eligible:true)
  quiet(&gate)
  #expect(!take(&gate,now:0.5,demand:observation(frames:6),mode:.probeOnly))
  #expect(gate.attempts==0 && gate.probeQuietSeconds==0)
 }
 @Test func actualSourceEpochChangeInvalidatesProbeButNotNormalBufferedResume() {
  func source(epoch:UInt64,generation:UInt64=0)->PlaybackPrefetchSource.RecoveryActivity {
   .init(available:true,queued:0,busy:0,generation:generation,admission:0,requests:1,prefetches:0,epoch:epoch)
  }
  var gate=NativeStallRecoveryGate();gate.stalled(eligible:true)
  quiet(&gate,demand:observation(source:source(epoch:1)))
  let next=observation(source:source(epoch:2))
  for now in [0.5,0.75,1.0] {#expect(!take(&gate,now:now,demand:next))}
  #expect(gate.probeBlockedBy == .sourceChanged && gate.attempts==0)
  #expect(take(&gate,now:1,empty:false,ranges:[100..<110],demand:next))
  gate.clear();gate.stalled(eligible:true);quiet(&gate,demand:observation(source:source(epoch:1)))
  let generation=observation(source:source(epoch:1,generation:1))
  #expect(!take(&gate,now:0.5,demand:generation));#expect(!take(&gate,now:0.75,demand:generation))
  #expect(take(&gate,now:1,demand:generation))
 }
}

private actor WaitPolicyFixtureSource:MediaByteSource {
 let data:Data
 private(set) var reads=0
 init(data:Data){self.data=data}
 func fileSize(for file:MediaFile)async throws->UInt64 {UInt64(data.count)}
 func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data {
  try await Task.sleep(for:.milliseconds(20));try Task.checkCancellation();reads += 1
  return data.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))
 }
}

@Suite(.serialized) @MainActor struct NativeWaitPolicyTests {
 private enum Failure:Error {case timeout}
 private func wait(_ check:()->Bool)async throws {
  let end=ContinuousClock.now.advanced(by:.seconds(8))
  while !check(){guard ContinuousClock.now<end else{throw Failure.timeout};try await Task.sleep(for:.milliseconds(10))}
 }
 private func source()throws->WaitPolicyFixtureSource {
  WaitPolicyFixtureSource(data:try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!))
 }
 @Test(arguments:[NativePlaybackWaitPolicy.systemAutomatic,.resourceLoaderControlled])
 func compareSyntheticStartupSeekAndPause(policy:NativePlaybackWaitPolicy)async throws {
  let source=try source(),session=NativePlaybackSession(stallLimit:5,muted:true,waitPolicy:policy)
  let start=ProcessInfo.processInfo.systemUptime;var frames=0,first=0.0
  let task=Task {try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1;if frames==1 {first=ProcessInfo.processInfo.systemUptime;session.pause()}})}
  do {
   try await wait{frames>0}
   #expect(session.experimentAutomaticWait==policy.automaticallyWaits)
   #expect(!session.experimentDemandProbeSourceSupported)
   #expect(session.isPlaybackPaused && !session.speedStatus.waiting)
   #expect(session.setSpeed(2.5));try await session.seek(to:2,maximumBackward:0)
   #expect(session.isPlaybackPaused && session.speedStatus.effectiveRate==0 && session.selectedSpeed==2.5)
   session.resume();try await wait{session.speedStatus.effectiveRate==2.5}
   print("WAIT_POLICY_AB automatic",policy.automaticallyWaits,"firstFrameMS",Int((first-start)*1000),"reads",await source.reads,"seekMS",Int(((session.requestMetrics.seekCompleted ?? 0)-session.requestMetrics.started)*1000))
  }catch {session.stop();task.cancel();_ = try? await task.value;throw error}
  session.stop();task.cancel();_ = try? await task.value
 }
 /// Injected command mechanism, not a natural empty-buffer/no-demand reproduction.
 /// The pure gate suite separately proves the exact eligibility and one-shot bound.
 @Test func syntheticIntentCommandSeamPreservesRateAndRejectsUserPauseAndSameLoop() async throws {
  // Explicit qualification seam only. No injected stall notification or manual
  // transport pause, and no claim that this reproduces a natural device stall.
  let url=Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!
  let local=LocalDirectoryProvider(testRoot:url.deletingLastPathComponent())
  let session=NativePlaybackSession(stallLimit:10,muted:true);var frames=0
  let task=Task {try await session.play(file:MediaFile(components:[url.lastPathComponent]),source:local,
   startPaused:true,onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1})}
  do {
   try await wait{frames>0};let player=try #require(session.experimentPlayer)
   #expect(session.setSpeed(2))
   session.performIntentResume(qualified:true)
   #expect(session.experimentStallResumes==0 && player.rate==0 && session.isPlaybackPaused)
   session.resume();try await wait{frames>=3}
   session.performIntentResume(qualified:false);#expect(session.experimentStallResumes==0)
   session.performIntentResume(qualified:true)
   #expect(session.experimentStallResumes==1 && session.selectedSpeed==2 && player.defaultRate==2)
   let attempt=try #require(session.experimentIntentLastRecord)
   #expect(attempt.phase == .attempt && attempt.issued && attempt.after.playerRate==2)
   #expect(!session.experimentPendingDataStall && attempt.commandEvidence?.kind == .resume)
   session.performIntentResume(qualified:true)
   #expect(session.experimentStallResumes==1) // no await: identical production loop
   session.pause();session.performIntentResume(qualified:true)
   #expect(session.experimentStallResumes==1 && player.rate==0)
  } catch {session.stop();task.cancel();_ = try? await task.value;throw error}
  session.stop();task.cancel();_ = try? await task.value
 }
 @Test func manualRateCommandCapturesActualBeforeAfterAndPauseIntent() async throws {
  let url=Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!
  let local=LocalDirectoryProvider(testRoot:url.deletingLastPathComponent())
  let session=NativePlaybackSession(stallLimit:10,muted:true);var frames=0
  let task=Task {try await session.play(file:MediaFile(components:[url.lastPathComponent]),source:local,
   startPaused:true,onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1})}
  do {
   try await wait{frames>0}
   #expect(session.setSpeed(2))
   let paused=try #require(session.experimentIntentLastRecord)
   #expect(paused.phase == .command && paused.kind == .manual && !paused.issued)
   #expect(paused.before?.selectedSpeed==1 && paused.after.selectedSpeed==2 && paused.after.defaultRate==2)
   #expect(paused.after.playerRate==0 && session.isPlaybackPaused && session.experimentStallResumes==0)
   session.resume();try await wait{frames>3}
   #expect(session.setSpeed(3))
   let playing=try #require(session.experimentIntentLastRecord)
   #expect(playing.phase == .command && playing.issued && playing.command>paused.command)
   #expect(playing.before?.selectedSpeed==2 && playing.after.selectedSpeed==3 && playing.after.defaultRate==3)
   #expect(playing.after.timebaseValidity != nil && playing.acceptedAt != nil)
  } catch {session.stop();task.cancel();_ = try? await task.value;throw error}
  session.stop();task.cancel();_ = try? await task.value
 }
 @Test func localProbeCommandPreservesSelectedRateAndRequiresLiveIntent() async throws {
  let url=Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!
  let local=LocalDirectoryProvider(testRoot:url.deletingLastPathComponent())
  let session=NativePlaybackSession(stallLimit:10,muted:true);var frames=0,sawPolledFrame=false
  let task=Task {try await session.play(file:MediaFile(components:[url.lastPathComponent]),source:local,
   startPaused:true,onInfo:{_ in},onState:{_ in},onFrame:{_ in
    frames += 1
    if session.experimentOutputQueryValidity & (32|64|128) == (32|64|128) {sawPolledFrame=true}
   })}
  do {
   try await wait{frames>0}
   let player=try #require(session.experimentPlayer)
   #expect(session.experimentDemandProbeSourceSupported)
   #expect(session.setSpeed(2))
   session.performStallResume(kind:.demandProbe)
   #expect(session.experimentStallResumes==0 && player.rate==0) // Explicit pause wins.
   session.resume();player.pause()
   let before=frames
   session.performStallResume(kind:.demandProbe)
   #expect(session.experimentStallResumes==1 && session.selectedSpeed==2 && player.defaultRate==2)
   try await wait{session.speedStatus.effectiveRate==2 && frames>=before+3}
   let activity=try #require(session.experimentRecoveryActivity)
   #expect(activity.requests>0 && activity.chunks>0 && activity.responses>0 && activity.deliveredBytes>0)
   #expect(activity.returns>=activity.responses && sawPolledFrame)
   session.setPlaybackSceneActive(false);player.pause()
   session.performStallResume(kind:.demandProbe)
   #expect(session.experimentStallResumes==1 && player.rate==0)
   session.setPlaybackSceneActive(true);session.pause()
  } catch {session.stop();task.cancel();_ = try? await task.value;throw error}
  session.stop();task.cancel();_ = try? await task.value
 }
 @Test func injectedDataStallPreservesIntentRateAndLifecycle()async throws {
  let source=try source(),session=NativePlaybackSession(stallLimit:5,muted:true)
  var frames=0,lastState:NativePlaybackSession.State = .preparing
  let task=Task {try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,onInfo:{_ in},onState:{lastState=$0},onFrame:{_ in frames += 1})}
  do {
   try await wait{frames>1}
   let player=try #require(session.experimentPlayer),item=try #require(player.currentItem)
   #expect(session.setSpeed(2.5))
   // Inject transport pause without a stall notification: do not invent permission to resume.
   player.pause();try await wait{lastState == .waiting}
   #expect(!session.isPlaybackPaused && session.speedStatus.waiting)
   try await Task.sleep(for:.milliseconds(80));#expect(player.rate==0 && session.experimentStallResumes==0)
   // A current-item data-stall event plus already buffered media permits one resume.
   NotificationCenter.default.post(name:AVPlayerItem.playbackStalledNotification,object:item)
   try await wait{session.experimentStallResumes==1 && session.speedStatus.effectiveRate==2.5}
   session.setPlaybackSceneActive(false);player.pause()
   NotificationCenter.default.post(name:AVPlayerItem.playbackStalledNotification,object:item)
   try await Task.sleep(for:.milliseconds(80));#expect(player.rate==0 && session.experimentStallResumes==1)
   session.pause();session.setPlaybackSceneActive(true)
   NotificationCenter.default.post(name:AVPlayerItem.playbackStalledNotification,object:item)
   try await Task.sleep(for:.milliseconds(80))
   #expect(session.isPlaybackPaused && player.rate==0 && session.experimentStallResumes==1)
   try await session.seek(to:1,maximumBackward:0)
   #expect(session.isPlaybackPaused && player.rate==0)
   session.resume();try await wait{session.speedStatus.effectiveRate==2.5}
   session.stop();NotificationCenter.default.post(name:AVPlayerItem.playbackStalledNotification,object:item)
   try await Task.sleep(for:.milliseconds(80));#expect(player.rate==0 && session.experimentStallResumes==1)
  }catch {session.stop();task.cancel();_ = try? await task.value;throw error}
  session.stop();task.cancel();_ = try? await task.value
 }
}

// Optional larger, project-generated noise fixture. No NAS/SMB or private media.
// Generate in the validation directory and set VISTA_SYNTHETIC_STARVATION.
private actor StarvationFixtureSource:MediaByteSource {
 let data:Data
 let delay:Duration
 private var ceiling:UInt64 = .max
 private var maxDelivered:UInt64=0
 private(set) var blockedReads=0
 private(set) var blockedNow=0
 init(data:Data,delay:Duration = .milliseconds(20)){self.data=data;self.delay=delay}
 func allowThrough(_ offset:UInt64){ceiling=offset}
 func allowMore(_ bytes:UInt64){ceiling=maxDelivered+bytes}
 func fileSize(for file:MediaFile)async throws->UInt64 {UInt64(data.count)}
 func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data {
  let wasBlocked=range.upperBound>ceiling
  if wasBlocked {blockedReads += 1;blockedNow += 1}
  defer {if wasBlocked {blockedNow -= 1}}
  while range.upperBound>ceiling {try await Task.sleep(for:.milliseconds(10));try Task.checkCancellation()}
  // Preserve the fixture's byte rate as the production demand ceiling changes.
  // A fixed per-call delay would accidentally make 1 MiB four times faster,
  // preloading most of this short movie before a second depletion can occur.
  let units=max(1,Int((range.upperBound-range.lowerBound+262_143)/262_144))
  try await Task.sleep(for:delay*units);try Task.checkCancellation()
  maxDelivered=max(maxDelivered,range.upperBound)
  return data.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))
 }
}
@Suite(.serialized) @MainActor struct NativeStarvationTests {
 private enum Failure:Error {case timeout}
 private func wait(_ check:()->Bool)async throws {
  let end=ContinuousClock.now.advanced(by:.seconds(25))
  while !check(){guard ContinuousClock.now<end else{throw Failure.timeout};try await Task.sleep(for:.milliseconds(10))}
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION"] != nil,"Requires project-generated AAC starvation fixture"))
 func realDepletionRefillInactiveAndManualResume()async throws {
  let path=try #require(ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION"])
  let source=StarvationFixtureSource(data:try Data(contentsOf:URL(fileURLWithPath:path)))
  let session=NativePlaybackSession(stallLimit:5,muted:true);var frames=0,finished=false,stage=0,lastSnapshot="none"
  var observedWaitingEpisodes=0.0
  let task=Task {defer{finished=true};try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,onInfo:{_ in},onState:{state in
   // One existing public snapshot per real state boundary, not a per-poll probe.
   if state == .waiting {observedWaitingEpisodes=session.anonymousLogValues()[.waitEpisodes] ?? 0}
  },onFrame:{_ in frames += 1})}
  do {
   try await wait{frames>2}
   let episodesBeforeDepletion=session.anonymousLogValues()[.waitEpisodes] ?? 0
   stage=1;await source.allowThrough(0)
   try await wait{session.experimentPendingDataStall && session.experimentPlayer?.timeControlStatus == .paused && observedWaitingEpisodes>episodesBeforeDepletion}
   #expect(!session.isPlaybackPaused && session.speedStatus.waiting)
   let waitingDiagnostics=session.anonymousLogValues()
   #expect((waitingDiagnostics[.waitEpisodes] ?? 0)>episodesBeforeDepletion && waitingDiagnostics[.waitIncomplete] == 1)
   stage=2;session.setPlaybackSceneActive(false)
   let inactiveDiagnostics=session.anonymousLogValues()
   #expect(inactiveDiagnostics[.waitIncomplete] == 0 && inactiveDiagnostics[.waitCompleted] == inactiveDiagnostics[.waitEpisodes])
   await source.allowMore(MediaReadPlan.nativeChunkBytes)
   try await Task.sleep(for:.milliseconds(5300))
   #expect(!finished && session.experimentStallResumes==0 && session.speedStatus.effectiveRate==0)
   stage=3;session.setPlaybackSceneActive(true)
   try await wait{session.experimentStallResumes==1 && session.speedStatus.effectiveRate==1}
   stage=4
   try await wait{
    if let player=session.experimentPlayer,let item=player.currentItem {
     lastSnapshot="state \(player.timeControlStatus.rawValue) rate \(player.rate) effective \(session.speedStatus.effectiveRate) empty \(item.isPlaybackBufferEmpty) full \(item.isPlaybackBufferFull) likely \(item.isPlaybackLikelyToKeepUp) position \(player.currentTime().seconds) pending \(session.experimentPendingDataStall)"
    }
    return session.experimentPendingDataStall && session.experimentPlayer?.timeControlStatus == .paused
   }
   stage=5;let stalledFrame=frames
   session.pause();await source.allowThrough(.max)
   try await Task.sleep(for:.milliseconds(150))
   #expect(session.isPlaybackPaused && session.speedStatus.effectiveRate==0 && session.experimentStallResumes==1)
   session.resume();try await wait{frames>stalledFrame+2 && session.speedStatus.effectiveRate==1}
   print("REAL_DATA_STALL cycles",2,"automaticResumes",session.experimentStallResumes,"inactiveWaitMS",5300,"frames",frames)
  }catch {
   print("STARVATION_LAST",lastSnapshot)
   print("STARVATION_TIMEOUT stage",stage,"frames",frames,"finished",finished,"pending",session.experimentPendingDataStall,"rate",session.speedStatus.effectiveRate,"state",session.experimentPlayer?.timeControlStatus.rawValue ?? -1)
   session.stop();task.cancel();do{try await task.value}catch{print("STARVATION_TASK",error)};throw error
  }
  session.stop()
  let stoppedDiagnostics=session.anonymousLogValues()
  #expect(stoppedDiagnostics[.waitIncomplete] == 0 && stoppedDiagnostics[.waitCompleted] == stoppedDiagnostics[.waitEpisodes])
  task.cancel();_ = try? await task.value
 }
}

extension NativeStarvationTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION_SILENT"] != nil,"Requires project-generated silent starvation fixture"))
 func repeatedSilentDepletionHasBoundedFailureInsteadOfInventedResume()async throws {
  let path=try #require(ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION_SILENT"])
  let source=StarvationFixtureSource(data:try Data(contentsOf:URL(fileURLWithPath:path)))
  let session=NativePlaybackSession(stallLimit:5,muted:true);var frames=0,hasAudio=true
  let task=Task {try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,onInfo:{hasAudio=$0.hasAudio},onState:{_ in},onFrame:{_ in frames += 1})}
  do {
   try await wait{frames>2};try #require(!hasAudio)
   await source.allowThrough(0)
   try await wait{session.experimentPendingDataStall && session.experimentPlayer?.timeControlStatus == .paused}
   await source.allowMore(MediaReadPlan.nativeChunkBytes)
   try await wait{session.experimentStallResumes==1 && session.speedStatus.effectiveRate==1}
   // The second silent-video depletion may keep timeControlStatus/rate/buffer flags
   // reporting playback despite no frames. Do not turn frame absence into autoplay.
   await #expect(throws:NativePlaybackSession.Failure.stalled){try await task.value}
   #expect(session.experimentStallResumes==1)
   print("SILENT_DATA_STALL boundedFailure",true,"automaticResumes",session.experimentStallResumes)
  }catch {session.stop();task.cancel();_ = try? await task.value;throw error}
  session.stop();task.cancel();_ = try? await task.value
 }
}

@MainActor private final class SilentRefillTrace {
 let started=ProcessInfo.processInfo.systemUptime
 var rawStalls=0,frames=0,lastPTS=0.0,lastFrameAt=0.0
 func record(_ stage:String,session:NativePlaybackSession) {
  guard let player=session.experimentPlayer,let item=player.currentItem else {
   print("SILENT_REFILL_TRACE",stage,"player-unavailable");return
  }
  let ranges=item.loadedTimeRanges.map(\.timeRangeValue).map{String(format:"%.3f-%.3f",$0.start.seconds,CMTimeRangeGetEnd($0).seconds)}.joined(separator:",")
  print("SILENT_REFILL_TRACE",stage,"wall",String(format:"%.3f",ProcessInfo.processInfo.systemUptime-started),
   "clock",String(format:"%.3f",player.currentTime().seconds),"frames",frames,"lastPTS",String(format:"%.3f",lastPTS),
   "status",player.timeControlStatus.rawValue,"rate",player.rate,"effective",session.speedStatus.effectiveRate,
   "empty",item.isPlaybackBufferEmpty,"likely",item.isPlaybackLikelyToKeepUp,"ranges",ranges,
   "rawStalls",rawStalls,"pending",session.experimentPendingDataStall,"resumes",session.experimentStallResumes)
 }
}

extension NativeStarvationTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION_SILENT"] != nil,"Requires project-generated silent starvation fixture"))
 func secondSilentRefillDoesNotRequirePausedTransport()async throws {
  let path=try #require(ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION_SILENT"])
  let source=StarvationFixtureSource(data:try Data(contentsOf:URL(fileURLWithPath:path)))
  let session=NativePlaybackSession(stallLimit:5,muted:true),trace=SilentRefillTrace()
  var observer:(any NSObjectProtocol)?,hasAudio=true
  let task=Task {try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,onInfo:{hasAudio=$0.hasAudio},onState:{_ in},onFrame:{frame in trace.frames += 1;trace.lastPTS=frame.time;trace.lastFrameAt=ProcessInfo.processInfo.systemUptime})}
  do {
   try await wait{trace.frames>2};try #require(!hasAudio)
   let item=try #require(session.experimentPlayer?.currentItem)
   observer=NotificationCenter.default.addObserver(forName:AVPlayerItem.playbackStalledNotification,object:item,queue:.main) { _ in
    MainActor.assumeIsolated {trace.rawStalls += 1;trace.record("raw-stall",session:session)}
   }
   trace.record("first-source-block",session:session);await source.allowThrough(0)
   try await wait{session.experimentPendingDataStall && session.experimentPlayer?.timeControlStatus == .paused}
   trace.record("first-refill",session:session);await source.allowMore(MediaReadPlan.nativeChunkBytes)
   try await wait{session.experimentStallResumes==1 && session.speedStatus.effectiveRate==1}
   trace.record("first-resumed",session:session)
   let deadline=ContinuousClock.now.advanced(by:.seconds(15))
   // This fixture has a new noise frame every 1/12 second. A controlled pending
   // source read plus >0.5 s without a frame marks this test's depletion point.
   // It only schedules byte release; it never authorizes or invokes player.play.
   while true {
    if await source.blockedReads>=2,await source.blockedNow>0,
       ProcessInfo.processInfo.systemUptime-trace.lastFrameAt>0.5 {break}
    guard ContinuousClock.now<deadline else{throw Failure.timeout}
    try await Task.sleep(for:.milliseconds(10))
   }
   trace.record("second-refill-independent-of-state",session:session)
   let framesBefore=trace.frames,ptsBefore=trace.lastPTS,resumesBefore=session.experimentStallResumes
   await source.allowThrough(.max)
   try await wait{trace.frames>framesBefore+2 && trace.lastPTS>ptsBefore && session.speedStatus.effectiveRate==1}
   trace.record("second-frames-recovered",session:session)
   #expect(!session.isPlaybackPaused)
   print("SILENT_REFILL_RESULT recovered",true,"rawStalls",trace.rawStalls,
    "extraResumeCalls",session.experimentStallResumes-resumesBefore,"frameAdvance",trace.frames-framesBefore,
    "ptsAdvance",trace.lastPTS-ptsBefore)
  }catch {
   trace.record("failure",session:session)
   if let observer {NotificationCenter.default.removeObserver(observer)}
   session.stop();task.cancel();_ = try? await task.value;throw error
  }
  if let observer {NotificationCenter.default.removeObserver(observer)}
  session.stop();task.cancel();_ = try? await task.value
 }
}

extension NativeStarvationTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION"] != nil,"Requires project-generated AAC starvation fixture"),arguments:[(NativePlaybackWaitPolicy.systemAutomatic,false),(.resourceLoaderControlled,false),(.resourceLoaderControlled,true)])
 func automaticWaitingTransportUsesReducedRequestedAndEffectiveRate(testCase:(NativePlaybackWaitPolicy,Bool))async throws {
  let (policy,adaptiveSource)=testCase
  let path=try #require(ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION"])
  let data=try Data(contentsOf:URL(fileURLWithPath:path))
  let source=StarvationFixtureSource(data:data),file=try MediaFile(components:["synthetic.mp4"])
  let prefetch:PlaybackPrefetchSource?
  if adaptiveSource {
   // Same bounded source stack as SMB, but all bytes are project-generated memory.
   let identity=PlaybackSourceIdentity(size:UInt64(data.count),modificationDate:Date(timeIntervalSince1970:100),creationDate:Date(timeIntervalSince1970:50))
   let recovering=PlaybackRecoveringSource(file:file,initial:source,metadata:{_,_ in identity},
    makeFresh:{throw Failure.timeout},retire:{_ in},shouldRecover:{_ in false},isCurrent:{true},diagnostics:nil)
   prefetch=PlaybackPrefetchSource(file:file,source:recovering)
  }else{prefetch=nil}
  let playbackSource:any MediaByteSource
  if let prefetch {playbackSource=prefetch}else{playbackSource=source}
  let session=NativePlaybackSession(stallLimit:30,muted:true,waitPolicy:policy)
  var frames=0,stage=0
  let task=Task {try await session.play(file:file,source:playbackSource,onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1})}
  do {
   try await wait{frames>2}
   stage=1
   // Confirm the fixed production demand limit before this combined test.
   // The automatic + prefetch comparison preloads enough of this short
   // fixture to prevent depletion after gating; it is not a valid depletion
   // test. Automatic uses the bare source; shipping mode covers both.
   if adaptiveSource && policy == .resourceLoaderControlled {
    try await wait{session.experimentDemandChunkLimit==MediaReadPlan.nativeChunkBytes}
   }
   let chunkBeforeStall=session.experimentDemandChunkLimit ?? 262144
   stage=2
   #expect(session.setSpeed(5))
   await source.allowThrough(0)
   try await wait{policy == .systemAutomatic ? session.experimentPlayer?.timeControlStatus == .waitingToPlayAtSpecifiedRate : session.experimentPendingDataStall && session.experimentPlayer?.timeControlStatus == .paused}
   stage=3
   #expect(session.speedStatus.showsBufferingIndicator)
   try await wait{session.selectedSpeed==4.5}
   stage=4
   let player=try #require(session.experimentPlayer)
   #expect(player.defaultRate==4.5 && !session.isPlaybackPaused)
   #expect(player.rate==(policy == .systemAutomatic ? 4.5:0))
   #expect(player.timeControlStatus == (policy == .systemAutomatic ? .waitingToPlayAtSpecifiedRate:.paused))
   try await Task.sleep(for:.milliseconds(1800))
   #expect(session.selectedSpeed==4.5 && player.defaultRate==4.5)
   let beforeRefill=frames
   stage=5
   await source.allowMore(MediaReadPlan.nativeChunkBytes)
   try await wait{frames>beforeRefill+2 && session.speedStatus.effectiveRate==4.5 && player.timeControlStatus == .playing}
   stage=6
   try await wait{session.speedStatus.waiting}
   #expect(await source.blockedNow>0) // Not EOF mistaken for another data wait.
   stage=7
   try await wait{session.selectedSpeed==4}
   try await Task.sleep(for:.milliseconds(1800))
   #expect(session.selectedSpeed==4)
   stage=8
   let beforeSecondRefill=frames
   await source.allowThrough(.max)
   try await wait{frames>beforeSecondRefill+2 && session.speedStatus.effectiveRate==4}
   session.pause()
   #expect(session.setSpeed(1) && player.rate==0 && session.isPlaybackPaused)
   print("BUFFERING_SPEED_REAL_DEPLETION automatic",policy.automaticallyWaits,"adaptiveSource",adaptiveSource,"chunkBeforeStall",chunkBeforeStall,"episodes",2,"firstRate",4.5,"secondRate",4.0,"heldWithoutRepeatMS",1800,"manualOnePaused",true)
  }catch {
   await source.allowThrough(.max) // Release the synthetic gate before awaiting the existing non-cancelling pump drain.
   print("COMBINED_STALL_FAILURE",stage,"automatic",policy.automaticallyWaits,"adaptive",adaptiveSource,"frames",frames,"selected",session.selectedSpeed,"rate",session.speedStatus.effectiveRate,"state",session.experimentPlayer?.timeControlStatus.rawValue ?? -1,"position",session.experimentPlayerTime ?? -1,"blocked",await source.blockedNow)
   session.stop();task.cancel();_ = try? await task.value;try? await prefetch?.awaitPlaybackCleanup();throw error}
  session.stop();task.cancel();_ = try? await task.value;try await prefetch?.awaitPlaybackCleanup()
 }
}

extension NativeStarvationTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION"] != nil,"Requires project-generated AAC starvation fixture"),arguments:[false,true])
 func interruptedFirstResumeRetriesWithoutAnotherStallNotification(adaptiveSource:Bool)async throws {
  let path=try #require(ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION"])
  let source=StarvationFixtureSource(data:try Data(contentsOf:URL(fileURLWithPath:path)))
  let file=try MediaFile(components:["synthetic.mp4"])
  let prefetch:PlaybackPrefetchSource?
  if adaptiveSource {
   let identity=PlaybackSourceIdentity(size:UInt64(await source.data.count),modificationDate:Date(timeIntervalSince1970:100),creationDate:Date(timeIntervalSince1970:50))
   let recovering=PlaybackRecoveringSource(file:file,initial:source,metadata:{_,_ in identity},
    makeFresh:{throw Failure.timeout},retire:{_ in},shouldRecover:{_ in false},isCurrent:{true},diagnostics:nil)
   prefetch=PlaybackPrefetchSource(file:file,source:recovering)
  }else{prefetch=nil}
  let playbackSource:any MediaByteSource
  if let prefetch {playbackSource=prefetch}else{playbackSource=source}
  let session=NativePlaybackSession(stallLimit:30,muted:true)
  var frames=0,inject=false,injected=false,resumesBefore=Int.max
  let raw=StallNotificationCounter();var observer:(any NSObjectProtocol)?
  defer {if let observer {NotificationCenter.default.removeObserver(observer)}}
  let task=Task {try await session.play(file:file,source:playbackSource,
   onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1},onSpeed:{status in
    // Model a transient AVPlayer recovery that returns to paused before any
    // delivered frame confirms it. There is no second data-stall notification.
    if inject && !injected && session.experimentStallResumes>resumesBefore && status.effectiveRate>0 && !status.waiting {
     injected=true;session.experimentPlayer?.pause()
    }
   })}
  do {
   try await wait{frames>2}
   if adaptiveSource {try await wait{session.experimentDemandChunkLimit==MediaReadPlan.nativeChunkBytes}}
   let item=try #require(session.experimentPlayer?.currentItem)
   observer=NotificationCenter.default.addObserver(forName:AVPlayerItem.playbackStalledNotification,object:item,queue:.main) {_ in MainActor.assumeIsolated {raw.count += 1}}
   #expect(session.setSpeed(5));await source.allowThrough(0)
   try await wait{session.experimentPendingDataStall && session.experimentPlayer?.timeControlStatus == .paused}
   try await wait{session.selectedSpeed==4.5}
   resumesBefore=session.experimentStallResumes;inject=true
   let notificationsBeforeRefill=raw.count;#expect(notificationsBeforeRefill>0)
   await source.allowMore(MediaReadPlan.nativeChunkBytes)
   try await wait{injected}
   let before=frames,end=ContinuousClock.now.advanced(by:.seconds(2))
   while frames<=before+2 && ContinuousClock.now<end {try await Task.sleep(for:.milliseconds(10))}
   let recovered=frames>before+2
   print("INTERRUPTED_RESUME_REPRO adaptiveSource",adaptiveSource,"recovered",recovered,"frames",frames-before,
    "selected",session.selectedSpeed,"rate",session.speedStatus.effectiveRate,
    "attempts",session.experimentStallResumes-resumesBefore,"pending",session.experimentPendingDataStall,"newRawStalls",raw.count-notificationsBeforeRefill)
   #expect(recovered,"A current data-stall resume must remain eligible until actual playback progress")
   if !recovered {
    session.pause();session.resume();try await wait{frames>before+2}
    print("INTERRUPTED_RESUME_MANUAL_RESTORES",true,"rate",session.speedStatus.effectiveRate)
   }else {
    #expect(session.selectedSpeed==4.5 && session.speedStatus.effectiveRate==4.5)
    #expect(session.experimentStallResumes-resumesBefore==2 && raw.count==notificationsBeforeRefill)
   }
  }catch {
   await source.allowThrough(.max);session.stop();task.cancel();_ = try? await task.value;try? await prefetch?.awaitPlaybackCleanup();throw error
  }
  await source.allowThrough(.max);session.stop();task.cancel();_ = try? await task.value;try await prefetch?.awaitPlaybackCleanup()
 }
}

extension NativeWaitPolicyTests {
 @Test(arguments:0..<5) func retryRespectsPauseInactiveSeekReplacementAndManualSpeed(action:Int)async throws {
  let source=try source(),session=NativePlaybackSession(stallLimit:5,muted:true)
  var frames=0,injected=false
  let task=Task {try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,startPaused:true,
   onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1},onSpeed:{status in
    if !injected && session.experimentStallResumes==1 && status.effectiveRate>0 && !status.waiting {
     injected=true;session.experimentPlayer?.pause()
    }
   })}
  do {
   try await wait{frames>0}
   let player=try #require(session.experimentPlayer),item=try #require(player.currentItem)
   #expect(session.setSpeed(3));session.resume();player.pause()
   NotificationCenter.default.post(name:AVPlayerItem.playbackStalledNotification,object:item)
   try await wait{injected}
   let attempts=session.experimentStallResumes,before=frames
   switch action {
   case 0:
    session.pause();#expect(session.setSpeed(1))
    try await Task.sleep(for:.milliseconds(750))
    #expect(player.rate==0 && session.isPlaybackPaused && session.selectedSpeed==1)
    #expect(session.experimentStallResumes==attempts && !session.experimentPendingDataStall)
   case 1:
    session.setPlaybackSceneActive(false);try await Task.sleep(for:.milliseconds(750))
    #expect(player.rate==0 && session.experimentStallResumes==attempts)
    session.setPlaybackSceneActive(true)
    try await wait{frames>before+2 && session.speedStatus.effectiveRate==3}
    #expect(session.experimentStallResumes==attempts+1)
   case 2:
    try await session.seek(to:0,maximumBackward:0);player.pause()
    try await Task.sleep(for:.milliseconds(750))
    #expect(player.rate==0 && session.experimentStallResumes==attempts && !session.experimentPendingDataStall)
   case 3:
    session.stop();task.cancel();_ = try? await task.value
    NotificationCenter.default.post(name:AVPlayerItem.playbackStalledNotification,object:item)
    let replacement=NativePlaybackSession(stallLimit:5,muted:true);var replacementFrames=0
    let next=Task {try await replacement.play(file:MediaFile(components:["replacement.mp4"]),source:source,startPaused:true,
     onInfo:{_ in},onState:{_ in},onFrame:{_ in replacementFrames += 1})}
    do {
     try await wait{replacementFrames>0}
     NotificationCenter.default.post(name:AVPlayerItem.playbackStalledNotification,object:item)
     try await Task.sleep(for:.milliseconds(750))
     #expect(player.rate==0 && replacement.isPlaybackPaused && replacement.speedStatus.effectiveRate==0)
     #expect(replacement.experimentStallResumes==0 && !replacement.experimentPendingDataStall)
    }catch {replacement.stop();next.cancel();_ = try? await next.value;throw error}
    replacement.stop();next.cancel();_ = try? await next.value
   default:
    #expect(session.setSpeed(2.5))
    try await wait{frames>before+2 && session.speedStatus.effectiveRate==2.5}
    #expect(session.selectedSpeed==2.5 && !session.isPlaybackPaused)
   }
  }catch {session.stop();task.cancel();_ = try? await task.value;throw error}
  session.stop();task.cancel();_ = try? await task.value
 }
}

extension NativeStarvationTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION"] != nil,"Requires project-generated AAC starvation fixture"))
 func recoveryBudgetCannotBeRenewedByIncomingBytesOrDuplicateNotifications()async throws {
  let path=try #require(ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION"])
  let source=StarvationFixtureSource(data:try Data(contentsOf:URL(fileURLWithPath:path)),delay:.milliseconds(80))
  let session=NativePlaybackSession(stallLimit:2,muted:true)
  var frames=0,interrupted=0,inject=false,firstAttempt:Double?,failure:(any Error)?
  let task=Task {
   do {try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,
    onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1},onSpeed:{status in
     if inject && session.experimentStallResumes>interrupted && status.effectiveRate>0 && !status.waiting {
      if firstAttempt==nil {firstAttempt=ProcessInfo.processInfo.systemUptime}
      interrupted=session.experimentStallResumes;session.experimentPlayer?.pause()
      if let item=session.experimentPlayer?.currentItem {NotificationCenter.default.post(name:AVPlayerItem.playbackStalledNotification,object:item)}
     }
    })}catch {failure=error}
  }
  do {
   try await wait{frames>2}
   let player=try #require(session.experimentPlayer),item=try #require(player.currentItem)
   #expect(session.setSpeed(3));player.pause();inject=true
   let readsBefore=session.requestMetrics.reads
   NotificationCenter.default.post(name:AVPlayerItem.playbackStalledNotification,object:item)
   try await wait{failure != nil}
   #expect(failure as? NativePlaybackSession.Failure == .stalled)
   let elapsed=ProcessInfo.processInfo.systemUptime-(try #require(firstAttempt))
   // The first onSpeed callback is observed a few ms after the attempt timestamp.
   #expect(elapsed>=1.9 && elapsed<3.5)
   #expect(interrupted==3 && session.requestMetrics.reads>readsBefore)
   let terminal=session.anonymousLogValues()
   #expect(terminal[.stallTimeout]==2 && terminal[.stallAttempts]==3 && terminal[.stallPending]==1)
   #expect(terminal[.stallResumes]==3)
   // The fourth attempt is paced at one second after the third, so the original
   // two-second budget can expire while waiting for that interval.
   #expect([NativeStallRecoveryGate.Block.attemptLimit,.retryDelay].map{Double($0.rawValue)}.contains(terminal[.stallBlockedBy] ?? -1))
   #expect((terminal[.stallNotifications] ?? 0)>=1 && (terminal[.stallActiveMS] ?? 0)>=2000)
   #expect(terminal[.playerClock] != nil && terminal[.transportStatus]==0 && terminal[.bufferAheadMS] != nil)
   #expect((terminal[.deliveredBytes] ?? 0)>0 && terminal[.currentDemandChunkBytes] != nil)
   #expect(session.experimentPlayer==nil) // These are pre-cleanup values, not a live player.
   let record=PlaybackLogRecord(event:.failed,values:terminal,build:"75")
   #expect(try JSONEncoder().encode(record).count<4096)
   session.stop();#expect(session.anonymousLogValues()==terminal)
   print("TERMINAL_STALL_EVIDENCE",String(decoding:try JSONEncoder().encode(record),as:UTF8.self))
   print("BOUNDED_RESUME_FAILURE elapsed",elapsed,"attempts",interrupted,"continuingReads",session.requestMetrics.reads-readsBefore)
  }catch {await source.allowThrough(.max);session.stop();task.cancel();_ = await task.value;throw error}
  await source.allowThrough(.max);session.stop();task.cancel();_ = await task.value
 }
}

@MainActor private final class StallNotificationCounter {var count=0}

@MainActor private final class StallSourceRecoveryFixture:PlaybackRecoveryControlling {
 let data:Data
 var recovering=false,cancelled=false
 init(data:Data){self.data=data}
 var isPlaybackRecovering:Bool {recovering}
 var recoveryActiveStartedAt:TimeInterval? {recovering ? ProcessInfo.processInfo.systemUptime:nil}
 var recoveryActiveElapsed:TimeInterval {0}
 func setPlaybackSceneActive(_ active:Bool){}
 func cancelPlayback(){cancelled=true}
 func awaitPlaybackCleanup()async throws{}
 func fileSize(for file:MediaFile)async throws->UInt64 {UInt64(data.count)}
 func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data {
  try Task.checkCancellation();if cancelled {throw CancellationError()}
  return data.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))
 }
}

extension NativeWaitPolicyTests {
 @Test func sourceRecoveryPreservesRetryAndPausesItsPlaybackBudget()async throws {
  let source=StallSourceRecoveryFixture(data:try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!))
  let session=NativePlaybackSession(stallLimit:1,muted:true)
  var frames=0,injected=false
  let task=Task {try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,startPaused:true,
   onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1},onSpeed:{status in
    if !injected && session.experimentStallResumes==1 && status.effectiveRate>0 && !status.waiting {
     injected=true;session.experimentPlayer?.pause();source.recovering=true
    }
   })}
  do {
   try await wait{frames>0}
   let player=try #require(session.experimentPlayer),item=try #require(player.currentItem)
   #expect(session.setSpeed(3));session.resume();player.pause()
   NotificationCenter.default.post(name:AVPlayerItem.playbackStalledNotification,object:item)
   try await wait{injected}
   let before=frames
   try await Task.sleep(for:.milliseconds(1300)) // Longer than this test's playback recovery budget.
   #expect(session.experimentStallResumes==1 && session.experimentPendingDataStall && player.rate==0)
   let selected=session.selectedSpeed
   source.recovering=false
   try await wait{frames>before+2 && session.speedStatus.effectiveRate==selected}
   #expect(session.experimentStallResumes==2 && !session.experimentPendingDataStall)
   print("SOURCE_RECOVERY_RETRY preserved",true,"selected",selected,"effective",session.speedStatus.effectiveRate)
  }catch {session.stop();task.cancel();_ = try? await task.value;throw error}
  session.stop();task.cancel();_ = try? await task.value
 }
}

extension NativeStarvationTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION"] != nil,"Requires project-generated AAC starvation fixture"))
 func threeInterruptedResumesRecoverWhenNewBufferedMediaArrives()async throws {
  let path=try #require(ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION"])
  let source=StarvationFixtureSource(data:try Data(contentsOf:URL(fileURLWithPath:path)))
  let file=try MediaFile(components:["synthetic.mp4"])
  let identity=PlaybackSourceIdentity(size:UInt64(await source.data.count),modificationDate:Date(timeIntervalSince1970:100),creationDate:Date(timeIntervalSince1970:50))
  let recovering=PlaybackRecoveringSource(file:file,initial:source,metadata:{_,_ in identity},
   makeFresh:{throw Failure.timeout},retire:{_ in},shouldRecover:{_ in false},isCurrent:{true},diagnostics:nil)
  let prefetch=PlaybackPrefetchSource(file:file,source:recovering)
  let session=NativePlaybackSession(stallLimit:15,muted:true)
  var frames=0,interrupted=0,inject=false,attemptTimes:[Double]=[]
  let raw=StallNotificationCounter();var observer:(any NSObjectProtocol)?
  defer{if let observer {NotificationCenter.default.removeObserver(observer)}}
  let task=Task {try await session.play(file:file,source:prefetch,
   onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1},onSpeed:{status in
    if inject && session.experimentStallResumes>attemptTimes.count && status.effectiveRate>0 && !status.waiting {
     attemptTimes.append(ProcessInfo.processInfo.systemUptime)
     if interrupted<3 {interrupted += 1;session.experimentPlayer?.pause()}
    }
   })}
  do {
   try await wait{frames>2}
   let player=try #require(session.experimentPlayer),item=try #require(player.currentItem)
   observer=NotificationCenter.default.addObserver(forName:AVPlayerItem.playbackStalledNotification,object:item,queue:.main){_ in MainActor.assumeIsolated{raw.count += 1}}
   #expect(session.setSpeed(3));await source.allowThrough(0)
   try await wait{session.experimentPendingDataStall && player.timeControlStatus == .paused}
   try await wait{session.selectedSpeed==2.5}
   inject=true;let notifications=raw.count
   await source.allowMore(MediaReadPlan.nativeChunkBytes)
   try await wait{interrupted==3}
   try await Task.sleep(for:.milliseconds(1150))
   #expect(player.rate==0 && session.experimentPendingDataStall && session.experimentStallResumes==3)
   let before=frames,bytesBefore=session.requestMetrics.bytes
   await source.allowMore(MediaReadPlan.nativeChunkBytes)
   let end=ContinuousClock.now.advanced(by:.seconds(3))
   while frames<=before+2 && ContinuousClock.now<end {try await Task.sleep(for:.milliseconds(10))}
   let recovered=frames>before+2
   print("THREE_ATTEMPT_REFILL_REPRO recovered",recovered,"attempts",session.experimentStallResumes,
    "frames",frames-before,"newBytes",session.requestMetrics.bytes-bytesBefore,"newStalls",raw.count-notifications,
    "bufferMS",session.anonymousLogValues()[.bufferAheadMS] ?? -1,"selected",session.selectedSpeed)
   #expect(recovered,"New buffered media must permit a paced fourth recovery within the original budget")
   if recovered {
    #expect(session.experimentStallResumes==4 && interrupted==3 && raw.count==notifications)
    #expect(!session.experimentPendingDataStall && session.speedStatus.effectiveRate==2.5)
    #expect(attemptTimes.count==4 && attemptTimes[3]-attemptTimes[2]>=0.99)
   }
  }catch {await source.allowThrough(.max);session.stop();task.cancel();_ = try? await task.value;try? await prefetch.awaitPlaybackCleanup();throw error}
  await source.allowThrough(.max);session.stop();task.cancel();_ = try? await task.value;try await prefetch.awaitPlaybackCleanup()
 }
}
