import Testing
@testable import VistaCore

/// Pure injected observations: no AVPlayer, media, network, device or wall sleeps.
struct PlaybackAutomaticSpeedPolicyTests {
 private struct Simulation {
  var policy=PlaybackAutomaticSpeedPolicy()
  var time=10.0,clock=100.0,speed=5.0,tick=0
  var decisions:[(time:Double,value:PlaybackAutomaticSpeedPolicy.Decision)]=[]
  mutating func step(dt:Double=1.0/90,frame:Bool=true,repeatedPTS:Double?=nil,
   poll:Bool=true,clockMoving:Bool=true,eligible:Bool=true,playing:Bool=true,
   waiting:Bool=false,paused:Bool=false,ready:Bool=true,effective:Double?=nil,recovering:Bool=false) {
   time += dt;tick += 1
   if clockMoving {clock += dt*speed}
   let status=PlaybackSpeedStatus(selected:speed,effectiveRate:effective ?? (waiting ? 0:speed),
    ready:ready,supportsFastForward:true,paused:paused,waiting:waiting)
   if let result=policy.update(now:time,status:status,eligible:eligible,playing:playing,recovering:recovering,clock:clock,
    outputPolled:poll,copiedFramePTS:frame ? repeatedPTS ?? clock:nil) {
    decisions.append((time,result));speed=result.nextSpeed
   }
  }
  mutating func dense(_ seconds:Double=2) {
   for _ in 0..<Int(seconds*90) {step()}
  }
  mutating func sparse(_ seconds:Double,frameEvery:Int=180) {
   for _ in 0..<Int(seconds*90) {step(frame:tick%frameEvery==0)}
  }
  mutating func wait(_ seconds:Double) {
   for _ in 0..<Int(seconds*90) {step(frame:false,clockMoving:false,playing:false,waiting:true)}
  }
 }
 private func status(_ speed:Double=5,waiting:Bool=true)->PlaybackSpeedStatus {
  .init(selected:speed,effectiveRate:waiting ? 0:speed,ready:true,supportsFastForward:true,waiting:waiting)
 }
 private func update(_ policy:inout PlaybackAutomaticSpeedPolicy,_ now:Double,_ speed:Double=5,
  waiting:Bool=true)->PlaybackAutomaticSpeedPolicy.Decision? {
  policy.update(now:now,status:status(speed,waiting:waiting),eligible:true,playing:!waiting,
   clock:100+now*speed,outputPolled:true,copiedFramePTS:nil)
 }
 private func firstSparseReduction()->Simulation {
  var sim=Simulation();sim.dense()
  for _ in 0..<900 {
   sim.step(frame:false)
   if !sim.decisions.isEmpty {break}
  }
  #expect(sim.decisions.count==1 && sim.speed==4.5)
  return sim
 }
 // Exact timestamps supplied directly, independent from accumulated simulation time.
 private struct RapidReplay {
  var policy=PlaybackAutomaticSpeedPolicy()
  var origin=1.0
  var anchor=1.02
  var decision:PlaybackAutomaticSpeedPolicy.Decision?
  init(baselineFPS:Double=60) {
   let duration=baselineFPS<21 ? 20/baselineFPS:1
   origin=duration;anchor=duration+0.02
   for tick in 0...100 {
    let time=Double(tick)/100*duration
    let frame=baselineFPS<21 ? tick%5==0 : (tick==0 || Int((Double(tick)/100+0.0000001)*baselineFPS)>Int((Double(tick-1)/100+0.0000001)*baselineFPS))
    _=policy.update(now:time,status:.init(selected:2,effectiveRate:2,ready:true,supportsFastForward:true),
     eligible:true,playing:true,clock:time*2,outputPolled:true,copiedFramePTS:frame ? time*2:nil)
   }
   policy.manualSpeedDidChange(now:origin)
   for tick in 1...2 {_=send(Double(tick)/100,frame:false)}
  }
  @discardableResult mutating func send(_ elapsed:Double,frame:Bool=false,pts:Double?=nil,
   effective:Double=2.5,poll:Bool=true,clockFactor:Double=1,waiting:Bool=false)->PlaybackAutomaticSpeedPolicy.Decision? {
   let time=origin+elapsed,clock=origin*2+elapsed*2.5*clockFactor
   let value=policy.update(now:time,status:.init(selected:2.5,effectiveRate:effective,ready:true,supportsFastForward:true,waiting:waiting),
    eligible:true,playing:!waiting,clock:clock,outputPolled:poll,copiedFramePTS:frame ? pts ?? clock:nil)
   if let value {decision=value};return value
  }
 }
 @Test func build100IndependentGapKeepsRollingAndWaitingUnchanged() {
  #expect(PlaybackAutomaticSpeedPolicy.sparseInterval==0.3 && PlaybackAutomaticSpeedPolicy.minimumSparseFrameGap==0.2)
  #expect(PlaybackAutomaticSpeedPolicy.lowCadenceFPS==20 && PlaybackAutomaticSpeedPolicy.lowCadenceFrameCount==6)
  #expect(PlaybackAutomaticSpeedPolicy.lowCadenceCheckInterval==0.05 && PlaybackAutomaticSpeedPolicy.minimumLowCadenceChecks==2)
  #expect(PlaybackAutomaticSpeedPolicy.maximumShortObservationGap==0.1 && PlaybackAutomaticSpeedPolicy.minimumSparseSpeed==2.5)
  #expect(PlaybackAutomaticSpeedPolicy.cooldown==3 && PlaybackBufferingSpeedPolicy.interval==0.5)
  #expect(PlaybackBufferingSpeedPolicy.minimum==2 && PlaybackSpeedStatus.increment==0.5)
  #expect(PlaybackAutomaticSpeedPolicy.baselineInterval==1 && PlaybackAutomaticSpeedPolicy.minimumBaselineFPS==12)
 }
 @Test func fastGapBeforeAndAtDeadlineAndFrameWinsSameCallback() {
  for deliver in [false,true] {
   var replay=RapidReplay()
   for tick in 3..<22 {#expect(replay.send(Double(tick)/100)==nil)}
   let at=replay.send(0.221,frame:deliver)
   if deliver {#expect(at==nil)}
   else {#expect(at?.sparseTrigger == .frameGap && at?.nextSpeed==2 && at?.advancingFrames==0)}
  }
 }
 @Test(arguments:[2.0,5,10,15,24,30,60]) func regularCadenceAcrossMinimalPhases(fps:Double) {
  for phase in [0.0,0.017] {
   var replay=RapidReplay();var previousBucket=Int(phase*fps)
   for tick in 3...202 {
    let elapsed=Double(tick-2)/100
    let bucket=Int((elapsed+phase)*fps+0.00000001)
    let frame=bucket>previousBucket;previousBucket=bucket
    if let value=replay.send(Double(tick)/100,frame:frame) {
     #expect(fps<20)
     #expect(value.sparseTrigger == (fps==2 ? .frameGap:.lowCadence))
     #expect(value.recentAdvancingFrames<6 && value.nextSpeed==2)
     break
    }
   }
   #expect((replay.decision != nil)==(fps<20))
  }
 }
 @Test func firstAdvancingFrameIsCountedAndHealthyCheckResetsLowStreak() {
  var replay=RapidReplay()
  // Six deliveries including the first postconfirmation copy prevent a low check.
  for tick in 3...32 {#expect(replay.send(Double(tick)/100,frame:[3,8,13,18,23,28].contains(tick))==nil)}
  #expect(replay.send(0.33)==nil)
  for tick in 34...36 {#expect(replay.send(Double(tick)/100)==nil)}
  // A fresh burst restores the count before the second low check.
  for tick in 37...42 {#expect(replay.send(Double(tick)/100,frame:true)==nil)}
  for tick in 43...55 {#expect(replay.send(Double(tick)/100)==nil)}
 }
 @Test func densityNeedsIndependentTwentyFPSHealthyReference() {
  for baseline in [19.99,20.0] {
   var replay=RapidReplay(baselineFPS:baseline)
   for tick in 3...102 {
    if replay.send(Double(tick)/100,frame:tick%10==0) != nil {break}
   }
   #expect((replay.decision != nil)==(baseline>=20))
   if let decision=replay.decision {#expect(decision.sparseTrigger == .lowCadence && decision.healthyReferenceFPS>=20)}
  }
 }
 @Test(arguments:0..<3) func shortObserverGuardsRestartOrRejectEvidence(kind:Int) {
  var replay=RapidReplay()
  if kind==0 {
   for tick in 3...20 {#expect(replay.send(Double(tick)/100)==nil)}
   #expect(replay.send(0.31)==nil) // 0.11 s observer gap cannot itself complete .3 s.
   for tick in 32...50 {#expect(replay.send(Double(tick)/100)==nil)}
   #expect(replay.send(0.52)?.sparseTrigger == .frameGap)
  } else {
   for tick in 3...100 {
    #expect(replay.send(Double(tick)/100,poll:kind==1 ? tick%4==0:true,clockFactor:kind==2 ? 0.25:1)==nil)
   }
  }
 }
 @Test func literalEffectiveTwoPointFourNineDoesNotBankShortEvidence() {
  var replay=RapidReplay()
  for tick in 3...102 {#expect(replay.send(Double(tick)/100,effective:2.49)==nil)}
  // Two fresh matching callbacks reanchor, without borrowing the below-gate gap.
  for tick in 103...123 {#expect(replay.send(Double(tick)/100)==nil)}
  let result=replay.send(1.25)
  #expect(result?.sparseTrigger == .frameGap && result?.nextSpeed==2)
 }
 @Test func duplicatePTSIsNotFreshAndInvalidPTSInvalidatesReference() {
  var duplicate=RapidReplay()
  for tick in 3...32 {_=duplicate.send(Double(tick)/100,frame:true,pts:2)}
  #expect(duplicate.decision?.sparseTrigger == .frameGap && duplicate.decision?.advancingFrames==0)
  for invalid in [Double.nan,.infinity,-.infinity,-1] {
   var replay=RapidReplay();#expect(replay.send(0.03,frame:true,pts:invalid)==nil)
   #expect(!replay.policy.diagnostics.baselineReady)
   for tick in 4...100 {#expect(replay.send(Double(tick)/100)==nil)}
  }
 }
 @Test func lowerGateClearsBothBranchesAndAReincreaseNeedsFreshConfirmation() {
  var sim=Simulation();sim.speed=2.5;sim.dense()
  for _ in 0..<17 {sim.step(frame:false)}
  sim.speed=2
  for _ in 0..<90 {sim.step(frame:false,effective:2.5)}
  #expect(sim.decisions.isEmpty)
  sim.policy.manualSpeedDidChange(now:sim.time);sim.speed=2.5
  sim.step(frame:false);#expect(sim.policy.diagnostics.awaitingRateStart)
  sim.step(frame:false);#expect(!sim.policy.diagnostics.awaitingRateStart)
  let confirmed=sim.time
  for _ in 0..<16 {sim.step(frame:false)}
  #expect(sim.decisions.isEmpty)
  for _ in 0..<5 {sim.step(frame:false)}
  #expect(sim.decisions.count==1 && sim.speed==2 && sim.decisions[0].time-confirmed>=0.2)
  for _ in 0..<90 {sim.step(frame:false,effective:2.5)}
  #expect(sim.decisions.count==1)
 }
 @Test func weakHealthyWindowsCannotRefreshExpiredTwentyFPSManualReference() {
  var sim=Simulation();sim.speed=2;sim.dense()
  for _ in 0..<1080 {sim.step(frame:sim.tick%6==0)} // Actual 15 fps, not >=20.
  #expect(sim.policy.diagnostics.baselineReady)
  sim.policy.manualSpeedDidChange(now:sim.time);sim.speed=2.5
  for _ in 0..<180 {sim.step(frame:sim.tick%9==0)} // Regular 10 fps has no .3 s gap.
  #expect(sim.decisions.isEmpty)
 }
 @Test func effectiveRateToleranceDoesNotRelaxOrReplaceTheSparseGate() {
  for effective in [4.99,4.99.nextDown] {
   var sim=Simulation();sim.dense()
   for _ in 0..<32 {sim.step(frame:false,effective:effective)}
   #expect((sim.decisions.count==1)==(abs(effective-5)<=PlaybackAutomaticSpeedPolicy.effectiveRateTolerance))
  }
 }
 @Test func independentGapMayDecideBeforeRollingMatures() {
  var replay=RapidReplay()
  for tick in 3...40 {
   if let result=replay.send(Double(tick)/100,frame:tick==7) {
    #expect(result.sparseTrigger == .frameGap && result.sequence==1 && result.nextSpeed==2)
    #expect(result.lowCadenceChecks==0 && result.observedSeconds==0.2)
    break
   }
  }
  #expect(replay.decision != nil)
 }
 @Test func waitingBoundarySharedCooldownAndFreshObservation() {
  var policy=PlaybackAutomaticSpeedPolicy()
  #expect(update(&policy,0)==nil)
  #expect(update(&policy,0.499)==nil)
  let first=update(&policy,0.5)
  #expect(first?.nextSpeed==4.5 && first?.reason == .buffering && first?.sequence==1)
  #expect(update(&policy,3.499,4.5)==nil)
  #expect(update(&policy,3.5,4.5)==nil)
  #expect(update(&policy,3.999,4.5)==nil)
  let second=update(&policy,4,4.5)
  #expect(second?.nextSpeed==4 && second?.sequence==2)
  // A very late post-cooldown poll starts a new half-second, not a catch-up cut.
  #expect(update(&policy,100,4)==nil)
  #expect(update(&policy,100.499,4)==nil)
  #expect(update(&policy,100.5,4)?.nextSpeed==3.5)
 }
 @Test func sustainedWaitingMayRepeatButNeverBurstOrCrossFloor() {
  var sim=Simulation();sim.wait(35)
  #expect(sim.speed==2 && sim.decisions.count==6)
  for (index,entry) in sim.decisions.enumerated() {
   #expect(entry.value.reason == .buffering)
   #expect(entry.value.sequence==UInt64(index+1))
   #expect(entry.value.nextSpeed==4.5-Double(index)*0.5)
   if index>0 {#expect(entry.time-sim.decisions[index-1].time>=3.5)}
  }
 }
 @Test(arguments:[0,1]) func build91SparseCadenceTriggersOneHalfStepAtTwoPointFive(episode:Int) {
  let seconds=episode==0 ? 7.023:8.920,polls=episode==0 ? 633:803
  var sim=Simulation();sim.speed=2.5;sim.dense()
  // Replay the aggregate cadence shape: 3/633 or 4/803 advancing copied PTS.
  // These are generated observations, not access to the original video.
  for poll in 1...polls {sim.step(dt:seconds/Double(polls),frame:poll%180==0)}
  #expect(sim.decisions.count==1 && sim.speed==2)
  let decision=sim.decisions.first?.value
  #expect(decision?.reason == .sparseOutput)
  #expect((decision?.observedSeconds ?? 0)>=0.2)
  #expect((decision?.outputPolls ?? 0)>=6)
  #expect((decision?.advancingFrames ?? 100)<=3)
  #expect((decision?.maximumFrameGap ?? 0)>=0.2)
  #expect((decision?.clockAdvance ?? 0)>0.3)
 }
 @Test func persistentSparseOutputRepeatsAfterNewRateStartsAndNewWindow() {
  var sim=Simulation();sim.dense();sim.sparse(40)
  #expect(sim.speed==2 && sim.decisions.count==6)
  for (index,entry) in sim.decisions.enumerated() {
   #expect(entry.value.reason == .sparseOutput)
   #expect(entry.value.observedSeconds>=0.2)
   if index>0 {
    let spacing=entry.time-sim.decisions[index-1].time
    #expect(spacing>=0.2 && spacing<3)
   }
  }
 }
 @Test func healthyOutputAndBriefHitchDoNotReduce() {
  var sim=Simulation();sim.dense(8)
  for _ in 0..<17 {sim.step(frame:false)} // <0.2 s, then normal output.
  sim.dense(8)
  #expect(sim.decisions.isEmpty && sim.speed==5)
 }
 @Test func consistentlyLowFrameRateNeverEstablishesDenseBaseline() {
  var sim=Simulation();sim.sparse(30)
  #expect(sim.decisions.isEmpty)
 }
 @Test func recoveredOutputAfterRateStartDoesNotCauseExtraStep() {
  var sim=firstSparseReduction()
  #expect(sim.decisions.count==1)
  sim.dense(20)
  #expect(sim.decisions.count==1)
 }
 @Test func duplicatePTSDoesNotCountAsNewOutputAndPixelsAreNotInputs() {
  var sim=Simulation();sim.speed=2.5;sim.dense()
  let repeated=sim.clock
  for _ in 0..<900 {sim.step(repeatedPTS:repeated)}
  #expect(sim.decisions.count==1 && sim.decisions.first?.value.reason == .sparseOutput)
  // Conversely, even identical-looking images are healthy when their PTS advance.
  var advancing=Simulation();advancing.dense(20)
  #expect(advancing.decisions.isEmpty)
 }
 @Test func clockStopAndInsufficientPollingCannotProveSparseOutput() {
  var stopped=Simulation();stopped.dense()
  for _ in 0..<900 {stopped.step(frame:false,clockMoving:false)}
  stopped.sparse(10)
  #expect(stopped.decisions.isEmpty)
  var slow=Simulation();slow.dense()
  for _ in 0..<400 {slow.step(dt:0.05,frame:false)}
  #expect(slow.decisions.isEmpty)
  var noPoll=Simulation();noPoll.dense()
  for _ in 0..<900 {noPoll.step(frame:false,poll:false)}
  #expect(noPoll.decisions.isEmpty)
 }
 @Test(arguments:0..<5) func intentionalOrIneligibleTransitionsDiscardSparseEvidence(kind:Int) {
  var sim=Simulation();sim.dense();sim.sparse(0.2)
  switch kind {
   case 0:sim.step(frame:false,paused:true)
   case 1:sim.step(frame:false,eligible:false) // seek / background / source failure / end
   case 2:sim.step(frame:false,playing:false) // transport recovery
   case 3:sim.step(frame:false,ready:false)
   default:sim.policy.interruptObservation()
  }
  sim.sparse(10)
  #expect(sim.decisions.isEmpty)
 }
 @Test(arguments:[false,true]) func healthyTwoTimesThenManualIncreaseCanDetectImmediateSparseOutput(explicitHook:Bool) {
  var sim=Simulation();sim.speed=2;sim.dense()
  if explicitHook {sim.policy.manualSpeedDidChange(now:sim.time)}
  sim.speed=2.5;let changedAt=sim.time;sim.sparse(7.023)
  #expect(sim.decisions.count==1 && sim.speed==2)
  #expect(sim.decisions.first?.value.reason == .sparseOutput)
  if let time=sim.decisions.first?.time {#expect(time-changedAt>=0.2 && time-changedAt<4.1)}
 }
 @Test func staleOrInterruptedHealthyBaselineCannotTransferOnManualIncrease() {
  for interrupted in [false,true] {
   var sim=Simulation();sim.speed=2;sim.dense()
   if interrupted {sim.policy.interruptObservation()}else{sim.sparse(11)}
   sim.policy.manualSpeedDidChange(now:sim.time);sim.speed=2.5;sim.sparse(10)
   #expect(sim.decisions.isEmpty)
  }
 }
 @Test func healthyOneTimesBaselineCanTransferButLowFPSOneTimesCannot() {
  var normal=Simulation();normal.speed=1;normal.dense();normal.speed=2.5;normal.sparse(6)
  #expect(normal.decisions.count==1 && normal.speed==2)
  var low=Simulation();low.speed=1;low.sparse(5);low.speed=2.5;low.sparse(6)
  #expect(low.decisions.isEmpty)
 }
 @Test(arguments:[1.0,1.5,2.0]) func manualLowRatesNeverAutomaticallyIncreaseOrReduce(speed:Double) {
  var sim=Simulation();sim.speed=speed;sim.dense();sim.sparse(8);sim.wait(8)
  #expect(sim.speed==speed && sim.decisions.isEmpty)
 }
 @Test func loopHitchAndClockOrPTSDiscontinuityResetBaseline() {
  for kind in 0..<4 {
   var sim=Simulation();sim.dense()
   switch kind {
    case 0:sim.step(dt:2,frame:false)
    case 1:sim.clock -= 10;sim.step(frame:false)
    case 2:sim.clock += 10;sim.step(frame:false)
    default:sim.step(repeatedPTS:0)
   }
   sim.sparse(10)
   #expect(sim.decisions.isEmpty)
  }
 }
 @Test func bothSymptomsSameUpdatePreferWaitingAndOnlyOneReduction() {
  var sim=Simulation();sim.dense();sim.sparse(0.2)
  sim.wait(1)
  #expect(sim.decisions.count==1 && sim.decisions[0].value.reason == .buffering)
  sim.sparse(0.2)
  #expect(sim.decisions.count==1) // Confirmation and a complete new window are still required.
  sim.sparse(0.2)
  #expect(sim.decisions.count==2 && sim.decisions[1].value.reason == .sparseOutput)
  let spacing=sim.decisions[1].time-sim.decisions[0].time
  #expect(spacing>=0.2 && spacing<3.5)
 }
 @Test func sparseThenWaitingUsesSameCooldownAndFreshWaitingWindow() {
  var sim=firstSparseReduction()
  #expect(sim.decisions.count==1 && sim.decisions[0].value.reason == .sparseOutput)
  sim.wait(10)
  #expect(sim.decisions.count>=2)
  #expect(sim.decisions[1].value.reason == .buffering)
  #expect(sim.decisions[1].time-sim.decisions[0].time>=3.5)
 }
 @Test func manualChangeAndInterruptionDoNotBypassCooldown() {
  var policy=PlaybackAutomaticSpeedPolicy()
  #expect(update(&policy,0)==nil)
  #expect(update(&policy,0.5)?.nextSpeed==4.5)
  policy.interruptObservation()
  #expect(update(&policy,1,5)==nil)
  #expect(update(&policy,3.499,5)==nil)
  #expect(update(&policy,3.5,5)==nil)
  #expect(update(&policy,4,5)?.nextSpeed==4.5)
 }
 @Test func invalidTimesAndRollbackNeverTrigger() {
  var policy=PlaybackAutomaticSpeedPolicy()
  #expect(update(&policy,10)==nil)
  for invalid in [Double.nan,.infinity,-.infinity,-1] {#expect(update(&policy,invalid)==nil)}
  #expect(update(&policy,11)==nil)
  #expect(update(&policy,9)==nil)
  #expect(update(&policy,9.499)==nil)
  #expect(update(&policy,9.5)?.nextSpeed==4.5)
  #expect(update(&policy,8,4.5)==nil)
  #expect(update(&policy,100,4.5)==nil)
 }
 @Test func onlySessionResetClearsCooldown() {
  var policy=PlaybackAutomaticSpeedPolicy()
  #expect(update(&policy,0)==nil)
  #expect(update(&policy,0.5)?.sequence==1)
  policy.reset()
  #expect(update(&policy,1)==nil)
  #expect(update(&policy,1.5)?.sequence==1)
 }
 @Test func requestedRateAndClockProgressAloneDoNotProveNewEffectiveRate() {
  var sim=firstSparseReduction()
  for _ in 0..<450 {sim.step(frame:false,effective:5)} // Selected 4.5, timebase still reports 5.
  #expect(sim.decisions.count==1 && sim.policy.diagnostics.awaitingRateStart)
  let matchingAt=sim.time
  for _ in 0..<16 {sim.step(frame:false)}
  #expect(sim.decisions.count==1)
  for _ in 0..<5 {sim.step(frame:false)}
  #expect(sim.decisions.count==2)
  #expect(sim.decisions[1].time-matchingAt>=0.2 && sim.decisions[1].time-matchingAt<0.4)
 }
 @Test func matchingRateWithoutClockProgressNeverStartsSparseWindow() {
  var sim=firstSparseReduction()
  for _ in 0..<450 {sim.step(frame:false,clockMoving:false)}
  #expect(sim.decisions.count==1 && sim.policy.diagnostics.awaitingRateStart)
  let movingAt=sim.time
  for _ in 0..<16 {sim.step(frame:false)}
  #expect(sim.decisions.count==1)
  for _ in 0..<5 {sim.step(frame:false)}
  #expect(sim.decisions.count==2 && sim.decisions[1].time-movingAt>=0.2)
 }
 @Test func twoPostDecisionSamplesConfirmRateButNeverReuseDecisionOrConfirmationCallback() {
  var sim=firstSparseReduction()
  for _ in 0..<5 {sim.step(dt:0,frame:false)}
  #expect(sim.decisions.count==1 && sim.policy.diagnostics.awaitingRateStart)
  sim.step(frame:false)
  #expect(sim.policy.diagnostics.awaitingRateStart) // First sample, not the old decision clock.
  sim.step(frame:false)
  #expect(!sim.policy.diagnostics.awaitingRateStart) // Second sample supplies one positive delta.
  let confirmedAt=sim.time
  for _ in 0..<16 {sim.step(frame:false)}
  #expect(sim.decisions.count==1)
  for _ in 0..<5 {sim.step(frame:false)}
  #expect(sim.decisions.count==2 && sim.decisions[1].time-confirmedAt>=0.2)
  #expect(sim.decisions[1].value.advancingFrames==0)
  #expect(sim.decisions[1].value.clockAdvance<7) // Only the new 4.5× observation window.
 }
 @Test func lateOldPTSDoesNotRearmOrCountButZeroNewPTSStillCanReduce() {
  var sim=firstSparseReduction()
  let lateOldPTS=sim.clock-100
  for i in 0..<32 {sim.step(repeatedPTS:lateOldPTS+Double(i)/1000)}
  #expect(sim.decisions.count==2 && sim.decisions[1].value.reason == .sparseOutput)
  #expect(sim.decisions[1].value.advancingFrames==0)
  #expect(sim.decisions[1].time-sim.decisions[0].time>=0.2 && sim.decisions[1].time-sim.decisions[0].time<3)
 }
 @Test func healthyNewRateOutputMayLegitimatelyTrailMediaClock() {
  var sim=firstSparseReduction()
  for _ in 0..<900 {sim.step(repeatedPTS:sim.clock-0.25)}
  #expect(sim.decisions.count==1 && sim.policy.diagnostics.baselineReady)
  #expect(!sim.policy.diagnostics.awaitingRateStart)
 }
 @Test(arguments:[false,true]) func manualRateTransportTransitionPreservesFreshHealthyBaseline(waiting:Bool) {
  var sim=Simulation();sim.speed=2;sim.dense()
  sim.policy.manualSpeedDidChange(now:sim.time);sim.speed=2.5
  for _ in 0..<9 {sim.step(frame:false,clockMoving:false,playing:false,waiting:waiting,effective:0)}
  #expect(sim.policy.diagnostics.baselineReady && sim.policy.diagnostics.awaitingRateStart)
  sim.sparse(6)
  #expect(sim.decisions.count==1 && sim.speed==2 && sim.decisions[0].value.reason == .sparseOutput)
 }
 @Test func automaticRateTransportTransitionPreservesConfirmedSparseIncident() {
  var sim=firstSparseReduction()
  for _ in 0..<90 {sim.step(frame:false,clockMoving:false,playing:false,effective:0)}
  #expect(sim.policy.diagnostics.baselineReady && sim.policy.diagnostics.awaitingRateStart)
  sim.sparse(14)
  #expect(sim.speed==2 && sim.decisions.count==6)
 }
 @Test(arguments:0..<3) func intentionalInterruptionOrSourceRecoveryCannotKeepRateTransitionBaseline(kind:Int) {
  var sim=Simulation();sim.speed=2;sim.dense()
  sim.policy.manualSpeedDidChange(now:sim.time);sim.speed=2.5
  switch kind {
   case 0:sim.step(frame:false,paused:true)
   case 1:sim.step(frame:false,eligible:false) // Seek / background / source recovery / failure.
   default:sim.policy.interruptObservation()
  }
  #expect(!sim.policy.diagnostics.baselineReady)
  sim.sparse(8)
  #expect(sim.decisions.isEmpty)
 }
 @Test func manualTransferredBaselineMustStillBeFreshAtActualRateStart() {
  var sim=Simulation();sim.speed=2;sim.dense()
  sim.policy.manualSpeedDidChange(now:sim.time);sim.speed=2.5
  for _ in 0..<990 {sim.step(frame:false,effective:2)} // Rate starts >10 s after the last healthy window.
  #expect(sim.policy.diagnostics.awaitingRateStart && sim.decisions.isEmpty)
  sim.step(frame:false);sim.step(frame:false)
  #expect(!sim.policy.diagnostics.baselineReady)
  #expect(sim.policy.diagnostics.lastResetReason == .staleManualBaseline)
  sim.sparse(8)
  #expect(sim.decisions.isEmpty)
 }
 @Test func stoppedOrDiscontinuousClockDuringRateStartCannotUseOldProgress() {
  for reversed in [false,true] {
   var sim=firstSparseReduction();sim.step(frame:false)
   sim.clock += reversed ? -10:10
   sim.step(frame:false)
   #expect(!sim.policy.diagnostics.baselineReady && sim.policy.diagnostics.lastResetReason == .clock)
   sim.sparse(8)
   #expect(sim.decisions.count==1)
  }
 }
 @Test func diagnosticSnapshotsDoNotCountRepeatedUnchangedResetsEveryLoop() {
  for kind in 0..<3 {
   var sim=Simulation();sim.speed=2;sim.dense()
   if kind==1 {sim.policy.manualSpeedDidChange(now:sim.time);sim.speed=2.5}
   func sample(_ sim:inout Simulation) {
    switch kind {
     case 0:sim.step(frame:false,eligible:false)
     case 1:sim.step(frame:false,playing:false,effective:0)
     default:sim.step(frame:false,recovering:true)
    }
   }
   sample(&sim);let count=sim.policy.diagnostics.resetCount
   for _ in 0..<100 {sample(&sim)}
   #expect(sim.policy.diagnostics.resetCount==count)
   #expect(sim.policy.diagnostics.lastResetReason == (kind==0 ? .ineligible:kind==1 ? .rateTransition:.recovery))
   sim.policy.reset()
   #expect(sim.policy.diagnostics.resetCount==0 && sim.policy.diagnostics.lastResetReason == .none)
  }
 }
 @Test func diagnosticResetReasonsSeparateObservationClockPTSAndPollFailures() {
  for kind in 0..<4 {
   var sim=Simulation();sim.dense()
   switch kind {
    case 0:sim.step(dt:0.5,frame:false)
    case 1:sim.clock -= 1;sim.step(frame:false)
    case 2:sim.step(repeatedPTS:0)
    default:for _ in 0..<24 {sim.step(frame:false,poll:false)}
   }
   let expected:PlaybackAutomaticSpeedPolicy.ResetReason = kind==0 ? .observationGap:kind==1 ? .clock:kind==2 ? .pts:.poll
   #expect(sim.policy.diagnostics.lastResetReason == expected)
   #expect(!sim.policy.diagnostics.baselineReady)
  }
 }
 @Test func pendingStillSetCanObserveSparseOutputAfterTwoFreshSamplesAndEntireNewWindow() {
  var sim=Simulation();sim.speed=2.5;sim.dense();sim.sparse(0.18)
  let oldPTS=sim.clock
  sim.step(repeatedPTS:oldPTS,recovering:true)
  let resets=sim.policy.diagnostics.resetCount
  #expect(sim.decisions.isEmpty && sim.policy.diagnostics.baselineReady)
  sim.step(dt:0,repeatedPTS:oldPTS,recovering:true) // Entry callback is not first confirmation evidence.
  #expect(sim.policy.diagnostics.awaitingRateStart)
  sim.step(repeatedPTS:oldPTS,recovering:true)
  #expect(sim.policy.diagnostics.awaitingRateStart)
  sim.step(repeatedPTS:oldPTS,recovering:true)
  #expect(!sim.policy.diagnostics.awaitingRateStart)
  let confirmed=sim.time
  for _ in 0..<16 {sim.step(repeatedPTS:oldPTS,recovering:true)}
  #expect(sim.decisions.isEmpty && sim.policy.diagnostics.resetCount==resets)
  for _ in 0..<5 {sim.step(repeatedPTS:oldPTS,recovering:true)}
  #expect(sim.decisions.count==1 && sim.speed==2)
  #expect(sim.decisions[0].time-confirmed>=0.2 && sim.decisions[0].value.advancingFrames==0)
  #expect(sim.decisions[0].value.clockAdvance<4) // Pre-entry clock delta was discarded.
  for _ in 0..<270 {sim.step(repeatedPTS:oldPTS,recovering:true)}
  #expect(sim.decisions.count==1 && sim.speed==2)
 }
 @Test func repeatedPendingEdgesDiscardPartialWindowsButSteadyPendingDoesNotRestartThem() {
  var sim=Simulation();sim.speed=2.5;sim.dense()
  for _ in 0..<3 {
   for _ in 0..<9 {sim.step(frame:false,recovering:true)}
   for _ in 0..<9 {sim.step(frame:false)}
   #expect(sim.decisions.isEmpty && sim.policy.diagnostics.baselineReady)
  }
  for _ in 0..<60 {sim.step(frame:false)}
  #expect(sim.decisions.count==1 && sim.speed==2)
 }
 @Test(arguments:[false,true]) func pendingClearThenBriefZeroRateKeepsReferenceUntilActualStart(waiting:Bool) {
  var sim=Simulation();sim.speed=2.5;sim.dense()
  for _ in 0..<9 {sim.step(frame:false,recovering:true)}
  for _ in 0..<9 {sim.step(frame:false,clockMoving:false,playing:!waiting,waiting:waiting,effective:0)}
  #expect(sim.decisions.isEmpty && sim.policy.diagnostics.baselineReady && sim.policy.diagnostics.awaitingRateStart)
  sim.sparse(3)
  #expect(sim.decisions.count==1 && sim.speed==2 && sim.decisions[0].value.reason == .sparseOutput)
 }
 @Test func ordinaryRecoveryCannotInventNeverObservedHealthyReference() {
  var sim=Simulation();sim.speed=2.5;sim.sparse(3)
  for _ in 0..<450 {sim.step(frame:sim.tick%180==0,recovering:true)}
  #expect(!sim.policy.diagnostics.baselineReady)
  sim.sparse(8)
  #expect(sim.decisions.isEmpty)
 }
 @Test(arguments:[0,360]) func pendingNeverRefreshesManualBaselineExpiryBeforeEffectiveRateActuallyStarts(manualAfter:Int) {
  var sim=Simulation();sim.speed=2;sim.dense()
  for i in 0..<990 {
   if i==manualAfter {sim.policy.manualSpeedDidChange(now:sim.time);sim.speed=2.5}
   sim.step(effective:sim.speed-0.5,recovering:true) // Copied output alone cannot prove the selected rate started.
  }
  #expect(sim.decisions.isEmpty && sim.policy.diagnostics.awaitingRateStart)
  sim.step(frame:false,recovering:true);sim.step(frame:false,recovering:true)
  #expect(!sim.policy.diagnostics.baselineReady && sim.policy.diagnostics.lastResetReason == .staleManualBaseline)
  sim.sparse(8)
  #expect(sim.decisions.isEmpty)
 }
 @Test func manualChangeInRecoveryRetainsOnlyStillFreshReference() {
  var sim=Simulation();sim.speed=2;sim.dense()
  for _ in 0..<9 {sim.step(frame:false,recovering:true)}
  sim.policy.manualSpeedDidChange(now:sim.time);sim.speed=2.5
  sim.step(frame:false,recovering:true)
  for _ in 0..<9 {sim.step(frame:false,clockMoving:false,effective:0)}
  sim.sparse(3)
  #expect(sim.decisions.count==1 && sim.speed==2)
 }
 @Test(arguments:0..<4) func hardInvalidationDuringPendingStillRemovesHealthyReference(kind:Int) {
  var sim=Simulation();sim.speed=2.5;sim.dense();sim.step(frame:false,recovering:true)
  switch kind {
   case 0:sim.step(frame:false,paused:true,recovering:true)
   case 1:sim.policy.interruptObservation() // Explicit seek / background boundary.
   case 2:for _ in 0..<450 {sim.step(frame:false,eligible:false,recovering:true)} // Bad/recovering source.
   default:sim.step(frame:false,ready:false,recovering:true)
  }
  for _ in 0..<9 {sim.step(frame:false,recovering:true)}
  #expect(!sim.policy.diagnostics.baselineReady)
  sim.sparse(8)
  #expect(sim.decisions.isEmpty)
 }
 @Test(arguments:0..<4) func invalidFreshObservationAfterRecoveryStillClearsReference(kind:Int) {
  var sim=Simulation();sim.speed=2.5;sim.dense()
  for _ in 0..<9 {sim.step(frame:false,recovering:true)}
  sim.step(frame:false);sim.step(frame:false)
  switch kind {
   case 0:sim.clock -= 1;sim.step(frame:false)
   case 1:let first=sim.clock;sim.step(repeatedPTS:first);sim.step(repeatedPTS:first-0.001)
   case 2:for _ in 0..<24 {sim.step(frame:false,poll:false)}
   default:sim.step(dt:0.5,frame:false)
  }
  #expect(!sim.policy.diagnostics.baselineReady)
  sim.sparse(8)
  #expect(sim.decisions.isEmpty)
 }
 @Test func waitingDuringRecoveryKeepsExistingCooldownAndFreshHalfSecondRules() {
  var sim=Simulation();sim.dense()
  for _ in 0..<900 {sim.step(frame:false,clockMoving:false,playing:false,waiting:true,effective:0,recovering:true)}
  #expect(sim.decisions.count==3 && sim.policy.diagnostics.baselineReady)
  for (index,decision) in sim.decisions.enumerated() {
   #expect(decision.value.reason == .buffering)
   if index>0 {#expect(decision.time-sim.decisions[index-1].time>=3.5)}
  }
  let previousCount=sim.decisions.count
  sim.sparse(0.4)
  #expect(sim.decisions.count==previousCount+1 && sim.decisions.last?.value.reason == .sparseOutput)
 }
 @Test func automaticSparseStepsCanContinueAcrossOrdinaryRecoveriesThroughFloor() {
  var sim=firstSparseReduction()
  for _ in 0..<5 {
   let before=sim.decisions.count
   for _ in 0..<9 {sim.step(frame:false,recovering:true)} // .1 s cannot mature a fresh gap.
   #expect(sim.decisions.count==before)
   for _ in 0..<32 {
    sim.step(frame:false)
    if sim.decisions.count>before {break} // Do not inject another full window after success.
   }
   #expect(sim.decisions.count==before+1)
  }
  #expect(sim.speed==2 && sim.decisions.count==6)
  for _ in 0..<180 {sim.step(frame:false,recovering:true)}
  sim.sparse(5)
  #expect(sim.speed==2 && sim.decisions.count==6)
 }
 @Test func continuousPendingWithNoNewFramesMayTakeRepeatedVerifiedStepsThroughFloor() {
  var sim=Simulation();sim.dense()
  for _ in 0..<1440 {sim.step(frame:false,recovering:true)}
  #expect(sim.speed==2 && sim.decisions.count==6)
  for (index,decision) in sim.decisions.enumerated() {
   #expect(decision.value.reason == .sparseOutput && decision.value.advancingFrames==0)
   if index>0 {#expect(decision.time-sim.decisions[index-1].time>=0.2)}
  }
  sim.policy.manualSpeedDidChange(now:sim.time);sim.speed=1
  for _ in 0..<450 {sim.step(frame:false,recovering:true)}
  #expect(sim.speed==1 && sim.decisions.count==6)
 }
 @Test func healthyOutputWithPendingStillSetDoesNotReduce() {
  var sim=Simulation();sim.dense()
  for _ in 0..<1800 {sim.step(recovering:true)}
  #expect(sim.decisions.isEmpty && sim.policy.diagnostics.baselineReady)
  #expect(!sim.policy.diagnostics.awaitingRateStart)
 }
 @Test func actualWaitingOverridesPartialSparseWindowEvenIfPendingNeverClears() {
  var sim=Simulation();sim.dense()
  for _ in 0..<18 {sim.step(frame:false,recovering:true)}
  for _ in 0..<36 {sim.step(frame:false,clockMoving:false,playing:false,waiting:true,effective:0,recovering:true)}
  #expect(sim.decisions.isEmpty) // 0.4 s is too short for waiting; old sparse window was discarded.
  for _ in 0..<18 {sim.step(frame:false,recovering:true)}
  #expect(sim.decisions.isEmpty)
  for _ in 0..<135 {sim.step(frame:false,clockMoving:false,playing:false,waiting:true,effective:0,recovering:true)}
  #expect(sim.decisions.count==1 && sim.decisions[0].value.reason == .buffering)
  for _ in 0..<18 {sim.step(frame:false,recovering:true)}
  #expect(sim.decisions.count==1)
  for _ in 0..<18 {sim.step(frame:false,recovering:true)}
  #expect(sim.decisions.count==2 && sim.decisions[1].value.reason == .sparseOutput)
 }
 @Test func clockStopsWhilePendingStillSetInvalidatesReferenceWithoutAnotherPendingEdge() {
  var sim=Simulation();sim.dense()
  for _ in 0..<9 {sim.step(frame:false,recovering:true)}
  for _ in 0..<30 {sim.step(frame:false,clockMoving:false,recovering:true)}
  #expect(!sim.policy.diagnostics.baselineReady && sim.policy.diagnostics.lastResetReason == .clock)
  for _ in 0..<900 {sim.step(frame:false,recovering:true)}
  #expect(sim.decisions.isEmpty)
 }
 @Test func clearingPendingDoesNotRestartAlreadyVerifiedPlayingWindow() {
  var sim=Simulation();sim.speed=2.5;sim.dense()
  sim.step(frame:false,recovering:true);sim.step(frame:false,recovering:true);sim.step(frame:false,recovering:true)
  let confirmed=sim.time
  #expect(!sim.policy.diagnostics.awaitingRateStart)
  for _ in 0..<9 {sim.step(frame:false,recovering:true)}
  for _ in 0..<23 {sim.step(frame:false)}
  #expect(sim.decisions.count==1 && sim.speed==2)
  #expect(sim.decisions[0].time-confirmed>=0.2 && sim.decisions[0].time-confirmed<0.4)
 }
 @Test func manualSpeedChangeWhilePendingStaysSetRequiresIndependentFreshEvidence() {
  var sim=Simulation();sim.speed=2;sim.dense()
  for _ in 0..<18 {sim.step(frame:false,recovering:true)}
  sim.policy.manualSpeedDidChange(now:sim.time);sim.speed=2.5
  sim.step(frame:false,recovering:true)
  #expect(sim.policy.diagnostics.awaitingRateStart)
  sim.step(frame:false,recovering:true)
  #expect(!sim.policy.diagnostics.awaitingRateStart)
  let confirmed=sim.time
  for _ in 0..<16 {sim.step(frame:false,recovering:true)}
  #expect(sim.decisions.isEmpty)
  for _ in 0..<5 {sim.step(frame:false,recovering:true)}
  #expect(sim.decisions.count==1 && sim.decisions[0].time-confirmed>=0.2)
 }
 @Test(arguments:0..<3) func zeroRateAndStallNotificationOrderCannotEraseHealthyReference(order:Int) {
  var sim=Simulation();sim.speed=2;sim.dense()
  sim.policy.manualSpeedDidChange(now:sim.time);sim.speed=2.5;sim.sparse(0.2)
  #expect(sim.policy.diagnostics.baselineReady && !sim.policy.diagnostics.awaitingRateStart)
  switch order {
   case 0:sim.step(frame:false,clockMoving:false,effective:0) // timebase zero arrives before either notification
   case 1:sim.step(frame:false,clockMoving:false,effective:0,recovering:true)
   default:sim.step(frame:false,clockMoving:false,playing:false,waiting:true,effective:0)
  }
  #expect(sim.policy.diagnostics.baselineReady)
  for _ in 0..<13 {sim.step(frame:false,clockMoving:false,playing:false,waiting:true,effective:0,recovering:true)}
  sim.step(frame:false,clockMoving:false,effective:0,recovering:true)
  sim.step(frame:false,recovering:true);sim.step(frame:false,recovering:true)
  let confirmed=sim.time
  #expect(!sim.policy.diagnostics.awaitingRateStart && sim.policy.diagnostics.baselineReady)
  for _ in 0..<16 {sim.step(frame:false,recovering:true)}
  #expect(sim.decisions.isEmpty)
  for _ in 0..<5 {sim.step(frame:false,recovering:true)}
  #expect(sim.decisions.count==1 && sim.speed==2 && sim.decisions[0].value.reason == .sparseOutput)
  #expect(sim.decisions[0].time-confirmed>=0.2 && sim.decisions[0].value.advancingFrames==0)
 }
 @Test func unannouncedShortZeroRateCanRearmWithoutAnyLaterStallNotification() {
  var sim=Simulation();sim.speed=2.5;sim.dense();sim.sparse(0.18)
  let oldPTS=sim.clock
  for _ in 0..<9 {sim.step(repeatedPTS:oldPTS,clockMoving:false,effective:0)}
  #expect(sim.policy.diagnostics.baselineReady && sim.policy.diagnostics.awaitingRateStart)
  sim.step(repeatedPTS:oldPTS);sim.step(repeatedPTS:oldPTS)
  let confirmed=sim.time
  for _ in 0..<16 {sim.step(repeatedPTS:oldPTS)}
  #expect(sim.decisions.isEmpty)
  for _ in 0..<5 {sim.step(repeatedPTS:oldPTS)}
  #expect(sim.decisions.count==1 && sim.decisions[0].value.advancingFrames==0)
  #expect(sim.decisions[0].time-confirmed>=0.2)
 }
 @Test func continuousZeroRateDoesNotAccumulateTimeDecisionsOrRepeatedResetCounts() {
  var sim=Simulation();sim.speed=2.5;sim.dense()
  sim.step(frame:false,clockMoving:false,effective:0)
  let count=sim.policy.diagnostics.resetCount
  for _ in 0..<1080 {sim.step(frame:false,clockMoving:false,effective:0)}
  #expect(sim.decisions.isEmpty && sim.policy.diagnostics.resetCount==count)
  #expect(sim.policy.diagnostics.baselineReady && sim.policy.diagnostics.awaitingRateStart)
  sim.step(frame:false);sim.step(frame:false)
  let confirmed=sim.time
  for _ in 0..<16 {sim.step(frame:false)}
  #expect(sim.decisions.isEmpty)
  for _ in 0..<5 {sim.step(frame:false)}
  #expect(sim.decisions.count==1 && sim.decisions[0].time-confirmed>=0.2)
 }
 @Test(arguments:0..<4) func trueInterruptionAfterZeroRateStillClearsReference(kind:Int) {
  var sim=Simulation();sim.speed=2.5;sim.dense();sim.step(frame:false,clockMoving:false,effective:0)
  switch kind {
   case 0:sim.step(frame:false,clockMoving:false,playing:false,paused:true,effective:0)
   case 1:sim.step(frame:false,eligible:false,effective:0) // scene / seek / source recovery / failure
   case 2:sim.step(frame:false,ready:false,effective:0)
   default:sim.policy.interruptObservation()
  }
  #expect(!sim.policy.diagnostics.baselineReady)
  sim.sparse(8)
  #expect(sim.decisions.isEmpty)
 }
 @Test func normalDenseOutputAfterZeroRateDoesNotGetADeferredReduction() {
  var sim=Simulation();sim.speed=2.5;sim.dense()
  for _ in 0..<9 {sim.step(frame:false,clockMoving:false,effective:0)}
  sim.dense(8)
  #expect(sim.decisions.isEmpty && sim.policy.diagnostics.baselineReady)
 }
 @Test(arguments:[false,true]) func zeroRateNeverRefreshesExpiredManualReference(changeBeforeZero:Bool) {
  var sim=Simulation();sim.speed=2;sim.dense()
  if changeBeforeZero {sim.policy.manualSpeedDidChange(now:sim.time);sim.speed=2.5}
  for _ in 0..<1080 {sim.step(frame:false,clockMoving:false,effective:0)}
  if !changeBeforeZero {sim.policy.manualSpeedDidChange(now:sim.time);sim.speed=2.5}
  sim.sparse(8)
  #expect(sim.decisions.isEmpty && !sim.policy.diagnostics.baselineReady)
 }
 @Test func repeatedZeroRateTransitionsCannotBankEarlierPartialWindows() {
  var sim=Simulation();sim.speed=2.5;sim.dense()
  for _ in 0..<3 {
   sim.step(frame:false,clockMoving:false,effective:0)
   sim.step(frame:false);sim.step(frame:false)
   for _ in 0..<16 {sim.step(frame:false)}
   #expect(sim.decisions.isEmpty)
  }
  for _ in 0..<60 {sim.step(frame:false)}
  #expect(sim.decisions.count==1 && sim.speed==2)
 }
 @Test func newZeroRateExceptionDoesNotAcceptNegativeOrNonFiniteEffectiveRates() {
  for invalid in [Double.nan,.infinity,-.infinity,-1] {
   var sim=Simulation();sim.speed=2.5;sim.dense()
   sim.step(frame:false,effective:invalid)
   #expect(!sim.policy.diagnostics.baselineReady)
   sim.sparse(8)
   #expect(sim.decisions.isEmpty)
  }
 }
 @Test(arguments:[25.0,30.0,90.0]) func independentGapConservativelyCountsPollBoundary(hz:Double) {
  var replay=RapidReplay()
  for tick in 1...Int(hz) {
   if replay.send(0.02+Double(tick)/hz) != nil {break}
  }
  #expect((replay.decision != nil)==(hz>=30))
  if let d=replay.decision {#expect(d.observedSeconds==0.2 && d.outputPolls>=6 && d.maximumFrameGap>=0.2)}
 }
 @Test(arguments:[0.0,0.017]) func nearTwentyRollingRetainsPointThreeEvidence(phase:Double) {
  var replay=RapidReplay(),previous=Int(phase*19)
  for n in 1...900 {
   let elapsed=Double(n)/90,bucket=Int((elapsed+phase)*19+1e-8)
   let frame=bucket>previous;previous=bucket
   if let d=replay.send(0.02+elapsed,frame:frame) {
    #expect(d.sparseTrigger == .lowCadence && d.observedSeconds==0.3)
    #expect(d.lowCadenceChecks==2 && d.maximumFrameGap<0.2 && d.outputPolls==9)
    break
   }
  }
  #expect(replay.decision != nil)
 }

}
