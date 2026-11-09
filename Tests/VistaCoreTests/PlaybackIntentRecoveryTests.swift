import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

struct NativePlaybackIntentRecoveryTests {
 private func expectValue(_ value:Bool)->Bool {value}
 private func work(bytes:UInt64=100,active:Int=0,frames:Int=2,epoch:UInt64?=nil)->NativeStallRecoveryGate.DemandObservation {
  .init(bridge:.init(available:true,activeRequests:active,requests:1,chunks:1,cancellations:0,
   deliveredBytes:bytes,returns:1,responses:1),source:epoch.map{.init(available:true,queued:0,busy:0,
   generation:0,admission:0,requests:0,prefetches:0,epoch:$0)},supported:true,frameCount:frames)
 }
 @discardableResult private func poll(_ g:inout NativePlaybackIntentRecovery,_ t:Double,clock:Double=15.712427,
  pts:Double?=nil,eligible:Bool=true,valid:Bool=true,outputAt:Double?=nil,polled:Bool=true,empty:Bool=false,
  ranges:[Range<Double>]=[0..<30],bytes:UInt64=100,active:Int=0,frames:Int=2,epoch:UInt64?=nil)->Bool {
  g.observe(now:t,eligible:eligible,position:clock,duration:30,speed:3,empty:empty,ranges:ranges,
   outputValid:valid,outputAt:outputAt ?? t,copiedPTS:pts,outputPolled:polled,demand:work(bytes:bytes,active:active,frames:frames,epoch:epoch))
 }
 private func ready(epoch:UInt64?=nil)->NativePlaybackIntentRecovery {
  var g=NativePlaybackIntentRecovery();g.acceptCommand(now:0,kind:.manual)
  poll(&g,0,clock:15,pts:15,epoch:epoch)
  poll(&g,0.1,pts:15.7487,epoch:epoch)
  return g
 }
 @Test @MainActor func controllerPauseRemainsBindableAsZeroArgumentAction() {
  let controller=PlaybackController()
  let action: @MainActor () -> Void = controller.togglePause
  action() // Exercise the actual function reference, not a direct method call.
  #expect(!controller.isPlaying && !controller.isPaused)
 }
 @Test func eightMillisecondLoopAndNinetyHzDeadlineGapsRetainFreshPollEvidence() {
  var g=ready(),lastTick=9,approved=0
  for n in 1...160 {
   let t=0.1+Double(n)*0.008,tick=Int(t*90)
   let polled=tick>lastTick;lastTick=tick
   let action=poll(&g,t,valid:polled,polled:polled)
   if action {approved += 1;#expect(polled && t>=1.1)}
   if !polled {#expect(!action)}
  }
  #expect(approved>0)
 }
 @Test func deadlineAbsenceBeyondQuarterSecondRestartsQuietWithoutCommands() {
  var g=ready()
  for n in 2...8 {#expect(!poll(&g,Double(n)*0.1))}
  for n in 9...15 {#expect(!poll(&g,Double(n)*0.1,valid:false,polled:false))}
  #expect(!poll(&g,1.6));#expect(g.quietSeconds==0)
  for n in 17...25 {#expect(!poll(&g,Double(n)*0.1))}
  #expect(poll(&g,2.61))
 }
 @Test func loggedPlayingFreezeNeedsFullSecondWithoutNotificationOrRatePrerequisite() {
  var g=ready()
  for t in [0.3,0.5,0.7,0.882,1.099] {#expect(!poll(&g,t))}
  #expect(poll(&g,1.101));#expect(g.commandAt==0 && g.commandID==1)
  // Deliberately no effective/player rate or transport parameter: zero, positive,
  // missing timebase all use the same clock/PTS evidence, not a substitute gate.
 }
 @Test func normalPointTwoAndPointSevenEightTwoTransitionsNeverRecover() {
  for delay in [0.2,0.782] {
   var g=ready();g.acceptCommand(now:0.1,kind:.automatic)
   for n in 1...50 {
    let t=0.1+Double(n)*0.02
    let moving=t>=0.1+delay
    #expect(!poll(&g,t,clock:moving ? 15.712427+t:15.712427,pts:moving ? 15.7487+t:nil))
   }
  }
 }
 @Test func slowVFRClockMovementPreventsFreezeEvenWithoutFrames() {
  var g=ready()
  for n in 1...100 {let t=0.1+Double(n)*0.1;#expect(!poll(&g,t,clock:15.712427+t*0.1))}
 }
 @Test func repeatedPTSDoesNotRefreshFreezeAndForwardPTSDoes() {
  var g=ready()
  for n in 2...10 {#expect(!poll(&g,Double(n)*0.1,pts:15.7487,frames:n))}
  #expect(poll(&g,1.11,pts:15.7487,frames:11))
  g=ready()
  for n in 2...8 {#expect(!poll(&g,Double(n)*0.1))}
  #expect(!poll(&g,0.9,pts:15.8));#expect(!poll(&g,1.1))
  #expect(!poll(&g,1.3));#expect(!poll(&g,1.5));#expect(!poll(&g,1.7));#expect(poll(&g,1.91))
 }
 @Test func anyLifecycleBlockNeedsFreshHealthyPlaybackAndCannotAct() {
  // Each production eligibility flag (pause, seek, background, unprepared,
  // source failure/recovery) is conjunctive; a blocked flag uses this path.
  var g=ready()
  for n in 2...30 {#expect(!poll(&g,Double(n)*0.1,eligible:false))}
  for n in 31...50 {#expect(!poll(&g,Double(n)*0.1))}
  #expect(g.block == .noProgress)
 }
 @Test func missingInvalidStalePollAndRollbackCannotBankQuiet() {
  for mode in 0..<4 {
   var g=ready()
   for n in 2...8 {#expect(!poll(&g,Double(n)*0.1))}
   if mode==0 {#expect(!poll(&g,1.1))} // gap > .25
   if mode==1 {#expect(!poll(&g,0.9,valid:false))}
   if mode==2 {#expect(!poll(&g,0.9,outputAt:0.1))}
   if mode==3 {#expect(!poll(&g,0.7,clock:14))}
   #expect(!poll(&g,1.2))
  }
 }
 @Test func workCountersIdleOwnershipCoverageAndEOFAllBlock() {
  var g=ready()
  for n in 2...25 {#expect(!poll(&g,Double(n)*0.1,active:1))}
  #expect(!poll(&g,2.6));#expect(!poll(&g,2.8));#expect(!poll(&g,3,bytes:101))
  #expect(!poll(&g,3.2,bytes:101));#expect(!poll(&g,3.4,bytes:101))
  #expect(!poll(&g,3.6,empty:true));#expect(!poll(&g,3.8,ranges:[0..<15.8]))
  #expect(!poll(&g,4,clock:30));#expect(!poll(&g,4.1,clock:29.99))
 }
 @Test func sourceEpochCannotReuseOldHealthyEvidence() {
  var g=ready(epoch:1)
  for n in 2...8 {#expect(!poll(&g,Double(n)*0.1,epoch:1))}
  #expect(!poll(&g,0.9,epoch:2));#expect(g.block == .sourceChanged)
  for n in 10...30 {#expect(!poll(&g,Double(n)*0.1,epoch:2))}
  #expect(g.block == .noProgress)
  #expect(!poll(&g,3.1,clock:16,pts:16,epoch:2))
  #expect(!poll(&g,3.2,clock:16.1,pts:16.1,epoch:2))
  for n in 33...41 {#expect(!poll(&g,Double(n)*0.1,clock:16.1,epoch:2))}
  #expect(poll(&g,4.21,clock:16.1,epoch:2))
 }
 @Test func acceptedCommandTimeIsFixedAndCommandOnlyRestartsObservation() {
  var g=ready()
  for n in 2...10 {#expect(!poll(&g,Double(n)*0.1))}
  #expect(g.commandAt==0)
  g.acceptCommand(now:1,kind:.automatic)
  #expect(g.commandID==2 && g.commandAt==1)
  for n in 11...20 {#expect(!poll(&g,Double(n)*0.1))}
  #expect(poll(&g,2.11));#expect(g.commandAt==1)
 }
 @Test func sharedAttemptsSurviveCommandsNotificationsLifecycleAndBytes() {
  var r=NativeStallRecoveryGate();#expect(expectValue(r.takeIntentResume(now:10)))
  #expect(r.intentUsed && !r.pending && r.attempts==1)
  r.observeElapsed(now:11,eligible:true);r.suspend();r.stalled(eligible:true)
  #expect(r.intentUsed && r.attempts==1 && r.recoveryActiveElapsed==1)
  #expect(expectValue(!r.takeIntentResume(now:12)));r.observeElapsed(now:25,eligible:true)
  #expect(r.recoveryExpired(limit:15))
  r.clear();#expect(expectValue(r.takeIntentResume(now:26))) // only confirmed motion/session end clears
 }
 @Test func explicitUserRestartClearsAlmostSpentBudgetButBackgroundDoesNot() {
  for manual in [false,true] {
   var r=NativeStallRecoveryGate();#expect(expectValue(r.takeIntentResume(now:0)))
   r.observeElapsed(now:14.9,eligible:true)
   r.interrupt(userInitiated:manual) // Same seam used by pause/resume/seek.
   r.observeElapsed(now:15.01,eligible:true)
   if manual {
    #expect(!r.recoveryExpired(limit:15) && r.attempts==0 && !r.probeUsed)
    #expect(expectValue(r.takeIntentResume(now:16)))
   } else {
    #expect(r.recoveryExpired(limit:15) && r.attempts==1 && r.probeUsed)
   }
  }
 }
 @Test func intentAndEmptyProbeConsumeOneAllowanceInBothOrders() {
  for intentFirst in [true,false] {
   var r=NativeStallRecoveryGate()
   func emptyProbe(_ t:Double)->Bool {
    r.takeResume(now:t,active:true,sceneActive:true,paused:false,seeking:false,ready:true,
     transportPaused:true,bufferEmpty:true,position:15,duration:30,selectedSpeed:3,
     ranges:[],demand:work(),mode:.probeOnly)
   }
   if intentFirst {#expect(expectValue(r.takeIntentResume(now:0)))}
   r.stalled(eligible:true)
   #expect(!emptyProbe(1));#expect(!emptyProbe(1.25))
   #expect(emptyProbe(1.5) == !intentFirst)
   #expect(!expectValue(r.takeIntentResume(now:2)))
   r.suspend();r.stalled(eligible:true)
   #expect(!emptyProbe(3));#expect(r.attempts==1 && r.probeUsed)
  }
 }
 @Test func frameLessHealthyClockFreezeCannotInventPriorPlayback() {
  var g=NativePlaybackIntentRecovery();g.acceptCommand(now:0,kind:.manual)
  for n in 0...50 {#expect(!poll(&g,Double(n)*0.1))}
  #expect(g.block == .noProgress)
 }
 @Test func bufferedAndIntentSharePacingAndInitialAttemptCeiling() {
  var r=NativeStallRecoveryGate();r.stalled(eligible:true)
  func buffered(_ t:Double)->Bool {r.takeResume(now:t,active:true,sceneActive:true,paused:false,seeking:false,ready:true,
   transportPaused:true,bufferEmpty:false,position:1,duration:30,selectedSpeed:3,ranges:[0..<30])}
  #expect(buffered(1));#expect(expectValue(!r.takeIntentResume(now:1)));#expect(expectValue(!r.takeIntentResume(now:1.1)))
  #expect(buffered(1.5));#expect(buffered(2));#expect(expectValue(!r.takeIntentResume(now:3)))
 }
}

struct NativeRecoveryProgressProofTests {
 private func expectValue(_ value:Bool)->Bool {value}
 @Test func sourceEpochCannotJoinOneOldPairToOneNewPairOrRefundBudget() {
  var p=NativeRecoveryProgressProof(),r=NativeStallRecoveryGate()
  #expect(expectValue(r.takeIntentResume(now:0)))
  p.begin(clock:15,pts:15,sourceEpoch:1)
  #expect(!expectValue(p.record(position:16,framePTS:16,eligible:true,sourceEpoch:1)))
  // Epoch update can occur without a transient recovery flag being sampled.
  #expect(!expectValue(p.record(position:17,framePTS:17,eligible:true,sourceEpoch:2)))
  #expect(r.attempts==1 && r.probeUsed)
  #expect(!expectValue(p.record(position:18,framePTS:18,eligible:true,sourceEpoch:2)))
  #expect(expectValue(p.record(position:19,framePTS:19,eligible:true,sourceEpoch:2)))
 }
 @Test func dataStallBetweenForwardPairsCannotClearSharedRecoveryBudget() {
  var p=NativeRecoveryProgressProof(),r=NativeStallRecoveryGate()
  #expect(expectValue(r.takeIntentResume(now:0)));r.stalled(eligible:true)
  p.begin(clock:0.202579958,pts:0.16666666666666666)
  #expect(!expectValue(p.record(position:0.300853376,framePTS:0.25,eligible:true)))
  r.observeElapsed(now:0.022916166693903506,eligible:true)
  // Exact DIAG1 sequence: the new notification arrives after the first
  // advancing pair but before a late buffered frame. It breaks only proof.
  p.interruptedByDataStall(eligible:true);r.stalled(eligible:true)
  let tail=p.record(position:0.333729125,framePTS:0.3333333333333333,eligible:true)
  if tail {r.clear()}
  #expect(!tail && r.attempts==1 && r.pending && r.probeUsed)
  #expect(r.recoveryActiveElapsed==0.022916166693903506)
  #expect(!expectValue(p.record(position:0.333729125,framePTS:0.4166666666666667,eligible:true)))
  r.observeElapsed(now:2,eligible:true);#expect(r.recoveryExpired(limit:2))
 }
 @Test func ineligibleStallCannotBreakHealthyProof() {
  var p=NativeRecoveryProgressProof();p.begin(clock:1,pts:1)
  #expect(!expectValue(p.record(position:2,framePTS:2,eligible:true)))
  p.interruptedByDataStall(eligible:false)
  #expect(expectValue(p.record(position:3,framePTS:3,eligible:true)))
 }
 @Test func onlyTwoForwardClockAndPTSAfterCommandProveRecovery() {
  var p=NativeRecoveryProgressProof();p.begin(clock:15.712427,pts:15.7487)
  #expect(expectValue(!p.record(position:15.8,framePTS:15.8,eligible:true)))
  #expect(expectValue(p.record(position:15.9,framePTS:15.9,eligible:true)))
 }
 @Test func bytesRateAndTransportCannotCompleteAndRollbackResetsPairs() {
  var p=NativeRecoveryProgressProof();p.begin(clock:15,pts:15)
  for _ in 0..<10 {#expect(expectValue(!p.record(position:15,framePTS:15,eligible:true)))}
  #expect(expectValue(!p.record(position:16,framePTS:16,eligible:true)))
  #expect(expectValue(!p.record(position:15,framePTS:15,eligible:true)))
  #expect(expectValue(!p.record(position:16,framePTS:16,eligible:true)))
  #expect(expectValue(p.record(position:17,framePTS:17,eligible:true)))
  p.reset();#expect(expectValue(!p.record(position:18,framePTS:18,eligible:true)))
 }
}

struct PlaybackIntentRecoveryDiagnosticsTests {
 private func required<T>(_ value:T?) throws -> T {try #require(value)}
 @Test func commandAndAttemptPayloadsStayBelowEightKiBWithFullTypedSnapshots() throws {
  var d=PlaybackIntentRecoveryDiagnostics(),s=PlaybackStallProbeDiagnostics.Snapshot(now:987654321)
  s.clock=123456.123456789;s.lastFramePTS=123456.123456789;s.copiedFramePTS=123456.123456789
  s.selectedSpeed=5;s.defaultRate=5;s.playerRate=5;s.effectiveRate=5;s.timebaseValidity=3
  s.coverageSeconds=123456;s.queryTime=123456.123456789;s.queryClockDifference=123456.123456789
  s.copyQueryDifference=123456.123456789;s.targetHostLeadSeconds=123456.123456789;s.outputObservationAt=123456.123456789
  s.recoveryActiveSeconds=15;s.probeQuietSeconds=1;s.lastProgressAge=123456;s.lastDeliveryAge=123456;s.lastFrameAge=123456
  s.context=255;s.transport=2;s.waitingReason=4;s.queryValidity=511;s.bridgeActive=8;s.sourceBusyMask=255
  s.attempts=3;s.probeBlock=12;s.bufferEmpty=false;s.progressEligible=true
  let maximum=PlaybackStallProbeDiagnostics.maximumCounter
  s.bridgeRequests=maximum;s.bridgeDataRequests=maximum;s.bridgeChunks=maximum;s.bridgeCancellations=maximum
  s.bridgeReturns=maximum;s.bridgeResponses=maximum;s.deliveredBytes=maximum;s.sourceGeneration=maximum
  s.sourceEpoch=maximum;s.sourceRequestID=maximum;s.sourcePrefetchID=maximum
  for phase:PlaybackIntentRecoveryDiagnostics.Phase in [.command,.observing,.attempt,.terminal,.summary] {
   let r=try required(d.record(phase,command:maximum,acceptedAt:987654321,kind:.manual,
    quiet:1,before:s,after:s,reason:1,issued:true))
   let payload=PlaybackLogRecord(intentRecovery:r,session:maximum,build:"99")
    .withWaitLosses(dropped:maximum,rejected:maximum,failures:maximum)
    .withRecoveryLogLosses(dropped:Int(maximum),failures:Int(maximum))
   let data=try JSONEncoder().encode(payload)
   #expect(data.count<8192)
   print("INTENT_PAYLOAD",phase.rawValue,"bytes",data.count)
  }
 }
 @Test func missingEffectiveRateStaysAbsentAndTimebaseValidityIsExplicit() throws {
  var d=PlaybackIntentRecoveryDiagnostics(),s=PlaybackStallProbeDiagnostics.Snapshot(now:1)
  s.clock=15.712427;s.effectiveRate=nil;s.timebaseValidity=0
  let r=try required(d.record(.command,command:1,acceptedAt:1,kind:.manual,quiet:0,before:s,after:s,reason:0,issued:true))
  let data=try JSONEncoder().encode(PlaybackLogRecord(intentRecovery:r,session:1,build:"99"))
  let text=String(decoding:data,as:UTF8.self)
  #expect(!text.contains("\"effective\""));#expect(text.contains("\"timebaseValidity\":0"));#expect(data.count<8192)
 }
 @Test func autoCannotExhaustManualDetailAndSuppressedLatestCommandSurvivesToAttempt() throws {
  var d=PlaybackIntentRecoveryDiagnostics(),s=PlaybackStallProbeDiagnostics.Snapshot(now:1)
  s.clock=15;s.lastFramePTS=15;s.selectedSpeed=3;s.playerRate=0;s.effectiveRate=nil;s.timebaseValidity=0
  for n in 1...30 {
   let record=d.record(.command,command:UInt64(n),acceptedAt:Double(n),kind:.automatic,
    quiet:0,before:s,after:s,reason:0,issued:false)
   #expect(record==nil)
  }
  for n in 31...50 {
   let record=d.record(.command,command:UInt64(n),acceptedAt:Double(n),kind:.manual,
    quiet:0,before:s,after:s,reason:0,issued:true)
   #expect((record != nil)==(n<47))
  }
  let attempted=try required(d.record(.attempt,command:50,acceptedAt:50,kind:.manual,
   quiet:1,before:s,after:s,reason:0,issued:true))
  #expect(attempted.commandEvidence?.id==50 && attempted.commandEvidence?.after.timebase==0)
  #expect(attempted.commandEvidence?.after.effective==nil && attempted.suppressed==4)
  _=d.record(.command,command:51,acceptedAt:51,kind:.manual,quiet:0,before:s,after:s,reason:0,issued:true)
  let terminal=try required(d.record(.terminal,command:51,acceptedAt:51,kind:.manual,
   quiet:0,before:nil,after:s,reason:10,issued:false))
  #expect(terminal.command==50 && terminal.commandEvidence?.id==50)
  let summary=try required(d.record(.summary,command:51,acceptedAt:51,kind:.manual,
   quiet:0,before:nil,after:s,reason:0,issued:false))
  #expect(summary.commandEvidence?.id==51)
 }
 @Test func boundedPhasesAggregateRejectionsAndKeepAttemptCommandOnTerminal() throws {
  var d=PlaybackIntentRecoveryDiagnostics(),s=PlaybackStallProbeDiagnostics.Snapshot(now:1)
  s.effectiveRate=3;s.timebaseValidity=3
  for n in 1...100 {
   d.reject(7)
   let r=d.record(.command,command:UInt64(n),acceptedAt:Double(n),kind:.manual,quiet:0,before:s,after:s,reason:0,issued:false)
   #expect((r != nil)==(n<=16))
  }
  _=d.record(.attempt,command:7,acceptedAt:7,kind:.automatic,quiet:1,before:s,after:s,reason:0,issued:true)
  let end=try required(d.record(.terminal,command:100,acceptedAt:100,kind:.manual,quiet:0,before:nil,after:s,reason:1,issued:false))
  #expect(end.command==7 && end.acceptedAt==7 && end.kind == .automatic)
  let summary=try required(d.record(.summary,command:100,acceptedAt:100,kind:.manual,quiet:0,before:nil,after:s,reason:0,issued:false))
  #expect(summary.suppressed==84 && summary.rejections==100 && summary.rejectionMask==128)
  #expect(d.record(.summary,command:100,acceptedAt:100,kind:.manual,quiet:0,before:nil,after:s,reason:0,issued:false)==nil)
 }
}
