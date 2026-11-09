import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

/// Synthetic numeric witnesses only, never a natural AVPlayer stall replay.
struct PlaybackHypothesisDiagnosticsTests {
 private func poll(_ d:inout PlaybackHypothesisDiagnostics,_ t:Double,validity:Int=71,pts:Double?=nil,query:Double?=nil,returned:Double?=nil) {
  d.poll(now:t,clock:t*2,query:query ?? t*2,targetHost:100+t,hostLead:0.008,validity:validity,
   returnedPTS:returned,copiedPTS:pts,timebaseValidity:3,effective:2,itemStatus:1,rate:2,transport:2,metricEpoch:7)
 }
 private func snapshot(_ t:Double)->PlaybackStallProbeDiagnostics.Snapshot {
  var s=PlaybackStallProbeDiagnostics.Snapshot(now:t);s.clock=t*2;s.effectiveRate=2;s.timebaseValidity=3
  s.sourceKind = .local;s.bridgeActive=0;s.probeBlock=1;s.coverageSeconds=2;return s
 }
 private func work()->NativeStallRecoveryGate.DemandObservation {
  .init(bridge:.init(available:true,activeRequests:0,requests:1,chunks:1,cancellations:0,deliveredBytes:100,returns:1,responses:1),source:nil,supported:true,frameCount:2)
 }
 @Test func postAutomaticFloorTwoCollectsRealPollCountersAndTail() throws {
  var d=PlaybackHypothesisDiagnostics();d.captureSource(nil);d.arm(command:42,now:0,lastPTS:0,clock:0)
  for n in 1...200 {poll(&d,Double(n)/100)}
  #expect(d.shouldEmit(now:2))
  let r=try #require({ d.record(now:2,metricEpoch:7,snapshot:snapshot(2)) }())
  #expect(r.reason==1 && r.automaticCommand==42 && r.sourceEpoch==nil && r.metricEpoch==7)
  #expect(r.counters[1]==200 && r.counters[2]==0 && r.counters[5]==0)
  #expect(r.polls.count<=12 && r.counters[9]>0 && r.counters[10]>0)
  #expect((r.polls.last?.first ?? nil) ?? 0 > 1.8)
 }
 @Test func rareInvalidQueryCopyNilAndReturnedPTSAreRetainedWithoutSecondCopy() throws {
  var d=PlaybackHypothesisDiagnostics();poll(&d,0)
  poll(&d,0.01,validity:65,query:.nan)
  poll(&d,0.02,validity:71|128|256,returned:0.025)
  let r=try #require({ d.record(now:0.03,metricEpoch:7,snapshot:snapshot(0.03),final:true) }())
  #expect(r.polls.count==3 && r.counters[7]==1 && r.counters[3]==1)
  #expect(r.polls[1][2]==nil && r.polls[2][6]==0.025 && r.polls[2][7]==nil)
 }
 @Test func monotonicClockRollbackClearsProofAndPinnedWitnessSurvivesNoProofTail() throws {
  var gate=NativePlaybackIntentRecovery(),d=PlaybackHypothesisDiagnostics();gate.acceptCommand(now:0,kind:.manual)
  func observe(_ t:Double,_ clock:Double,_ pts:Double?)->Bool {
   d.poll(now:t,clock:clock,query:clock,targetHost:100+t,hostLead:0.008,validity:71,
    returnedPTS:pts,copiedPTS:pts,timebaseValidity:3,effective:3,itemStatus:1,rate:3,transport:2,metricEpoch:9)
   let before=gate.diagnosticState
   let action=gate.observe(now:t,eligible:true,position:clock,duration:30,speed:3,empty:false,ranges:[0..<30],outputValid:true,outputAt:t,copiedPTS:pts,demand:work())
   d.gate(now:t,before:before,after:gate.diagnosticState,idle:true,supported:true,empty:false,coverage:10,input:[clock,pts,t,1,1,30,3])
   return action
  }
  #expect(!observe(0,5.7,5.7));#expect(!observe(0.1,5.901340584,5.899666667))
  #expect(gate.diagnosticState[0]==1)
  _=d.record(now:0.1,metricEpoch:9,snapshot:snapshot(0.1),reason:25) // A prior admitted event occupies the paced slot.
  #expect(!observe(0.2,5.774123918,nil));#expect(gate.detail == .clockRollback)
  let throttled=d.record(now:0.2,metricEpoch:9,snapshot:snapshot(0.2));#expect(throttled==nil)
  for n in 3...103 {#expect(!observe(Double(n)/10,5.774123918,nil))}
  let r=try #require({ d.record(now:10.3,metricEpoch:9,snapshot:snapshot(10.3),final:true) }())
  let clear=try #require(r.lastProofClear)
  #expect(clear.before[0]==1 && clear.before[2]==5.901340584 && clear.after[0]==0)
  #expect(clear.after[16]==Double(NativePlaybackIntentRecovery.Detail.clockRollback.rawValue))
  #expect(clear.at==0.2 && clear.input==[5.774123918,nil,0.2,1,1,30,3])
  #expect(gate.detail == .noProof && r.gates.count<=4 && clear.idle==true)
  #expect(r.counters[10]>12 && r.polls.allSatisfy{($0[0] ?? 0)>0.2} && r.suppressed==1)
  // The existing gate remains blocked: instrumentation does not repair this hypothesis.
 }
 @Test func repeatedMissingDeadlineDoesNotEvictSemanticTransition() throws {
  var d=PlaybackHypothesisDiagnostics(),before=[Double?](repeating:0,count:18),after=before
  after[16]=Double(NativePlaybackIntentRecovery.Detail.noProof.rawValue);after[15]=5
  for n in 0..<100 {
   before[16]=Double(NativePlaybackIntentRecovery.Detail.deadlineAbsent.rawValue)
   d.gate(now:Double(n)/100,before:before,after:after,idle:true,supported:true,empty:false,coverage:1)
  }
  let r=try #require({ d.record(now:1,metricEpoch:1,snapshot:snapshot(1),final:true) }());#expect(r.gates.count==1)
 }
 @Test func lateEvidenceAndFinalHaveIndependentBoundedAdmission() throws {
  var d=PlaybackHypothesisDiagnostics();d.arm(command:1,now:0,lastPTS:0,clock:0)
  var records=0,t=1.0
  for _ in 0..<20 {
   poll(&d,t)
   if d.record(now:t,metricEpoch:1,snapshot:snapshot(t),reason:1) != nil {records += 1}
   t += 0.01
  }
  #expect(records==1) // Startup cannot spend all eight slots.
  for n in 1...12 {
   t += 40_000;poll(&d,t,query:Double(n))
   if d.record(now:t,metricEpoch:1,snapshot:snapshot(t),reason:1) != nil {records += 1}
  }
  #expect(records==8)
  let final=try #require({ d.record(now:t,metricEpoch:1,snapshot:snapshot(t),final:true) }())
  #expect(final.reason==100 && final.polls.last?[2]==12 && final.suppressed>0)
  let duplicate=d.record(now:t,metricEpoch:1,snapshot:snapshot(t),final:true);#expect(duplicate==nil)
 }
 @Test func sourceAndLifecycleScopesCannotMixMetricEpochOrOldTail() throws {
  var d=PlaybackHypothesisDiagnostics();d.captureSource(77);d.arm(command:4,now:0,lastPTS:0,clock:0);poll(&d,0.1)
  #expect(d.sourceChanged(78));let old=try #require({ d.record(now:1,metricEpoch:9,snapshot:snapshot(1),reason:31) }())
  #expect(old.sourceEpoch==77 && old.metricEpoch==9)
  d.resetScope();d.captureSource(78);poll(&d,2)
  let new=try #require({ d.record(now:2,metricEpoch:10,snapshot:snapshot(2),final:true) }())
  #expect(new.scope==old.scope+1 && new.sourceEpoch==78 && new.automaticCommand==nil)
  #expect(new.polls.count==1 && new.polls[0][0]==2)
 }
 @Test func extremeNumericPayloadFitsUnchangedWriterWithExplicitTrimming() throws {
  var d=PlaybackHypothesisDiagnostics()
  var state=[Double?](repeating:Double.greatestFiniteMagnitude,count:18)
  for n in 0..<24 {
   poll(&d,Double(n),validity:455,pts:Double(n),query:Double.greatestFiniteMagnitude,returned:Double.greatestFiniteMagnitude)
   var before=state;before[0]=1;state[0]=0;state[12]=Double(n);state[16]=Double(n)
   d.gate(now:Double(n),before:before,after:state,idle:false,supported:true,empty:false,coverage:Double.greatestFiniteMagnitude,input:Array(repeating:Double.greatestFiniteMagnitude,count:7))
  }
  let r=try #require({ d.record(now:25,metricEpoch:9,snapshot:snapshot(25),final:true) }())
  let enriched=PlaybackLogRecord(hypothesis:r,session:8,build:"100")
   .withRecoveryLogLosses(dropped:Int.max,failures:Int.max)
   .withWaitLosses(dropped:UInt64.max,rejected:UInt64.max,failures:UInt64.max,missingPayload:UInt64.max,
    oversize:UInt64.max,encoding:UInt64.max,rotatedFiles:UInt64.max,expiredFiles:UInt64.max)
  let data=try JSONEncoder().encode(enriched)
  #expect(data.count<8192 && PlaybackLogStore.ordinaryRecordLimit==8192 && PlaybackLogStore.waitJournalLimit==1_048_576)
  print("HYPOTHESIS_FULL_WRITER_BUDGET bytes=\(data.count) pollRows=\(r.polls.count) gateRows=\(r.gates.count) omittedPollRows=\(r.omittedPollRows) omittedGateRows=\(r.omittedGateRows)")
  #expect(r.polls.count<=12 && r.gates.count<=4)
  let decoded=try JSONDecoder().decode(PlaybackLogRecord.self,from:data)
  #expect(decoded.hypothesis?.snapshot.probeBlock==1 && decoded.hypothesis?.metricEpoch==9)
 }
 @Test func productionPollRemainsSingleAndRecoveryCallsUnchanged() throws {
  let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let s=try String(contentsOf:root.appendingPathComponent("Sources/VistaMedia/NativePlaybackSession.swift"),encoding:.utf8)
  #expect(s.components(separatedBy:"output.hasNewPixelBuffer(").count==2)
  #expect(s.components(separatedBy:"output.copyPixelBuffer(").count==2)
  #expect(s.contains("try await Task.sleep(for:.milliseconds(8))"))
  #expect(s.contains("if kind == .manual {endHypothesisScope(40)}"))
  #expect(s.contains("if hypothesisDiagnostics.hasFaultEvidence {"))
  #expect(s.contains("sourceChanged(prefetchSource?.diagnosticObservedEpoch) {endHypothesisScope(31)}"))
  #expect(s.contains("native.automaticallyWaitsToMinimizeStalling=waitPolicy.automaticallyWaits"))
  let helper=try String(contentsOf:root.appendingPathComponent("Sources/VistaMedia/PlaybackHypothesisDiagnostics.swift"),encoding:.utf8)
  #expect(!helper.contains(".play()") && !helper.contains("copyPixelBuffer") && !helper.contains("Task.sleep"))
 }
 @Test func finalRetainsFaultTailAcrossPausedScopeWhenPacedSlotWasUnavailable() throws {
  var d=PlaybackHypothesisDiagnostics();d.arm(command:42,now:0,lastPTS:0,clock:0)
  for n in 1...100 {poll(&d,Double(n)/100)}
  _=d.record(now:1,metricEpoch:3,snapshot:snapshot(1))
  poll(&d,2)
  d.saveScopeTail(now:2,metricEpoch:3,snapshot:snapshot(2),reason:22)
  let blocked=d.record(now:2,metricEpoch:3,snapshot:snapshot(2),reason:22);#expect(blocked==nil)
  d.resetScope();poll(&d,3)
  let final=try #require({d.record(now:4,metricEpoch:4,snapshot:snapshot(4),final:true)}())
  #expect(final.scope==0 && final.automaticCommand==42 && final.metricEpoch==3)
  #expect(final.at==2 && final.finalizedAt==4 && final.reason==22 && final.polls.last?[0]==2)
 }

 @Test(arguments:[9.9,10.6]) func missingDeadlineBetweenRealQueriesCannotHideRareRollbackOrJump(query:Double) throws {
  var d=PlaybackHypothesisDiagnostics()
  poll(&d,0,query:10)
  d.poll(now:0.008,clock:0.016,query:nil,targetHost:nil,hostLead:nil,validity:0,
   returnedPTS:nil,copiedPTS:nil,timebaseValidity:3,effective:2,itemStatus:1,rate:2,transport:2,metricEpoch:7)
  poll(&d,0.016,query:query)
  let r=try #require({d.record(now:0.02,metricEpoch:7,snapshot:snapshot(0.02),final:true)}())
  #expect(r.polls.count==2 && r.polls[0][2]==10 && r.polls[1][2]==query)
  #expect(r.polls[1][0]==0.016 && r.counters[1]==2 && r.counters[8]==1)
 }
 @Test func fullSemanticKeyRecordsNewCommandAndQuietReasonWithoutBlockChange() throws {
  var d=PlaybackHypothesisDiagnostics(),state=[Double?](repeating:0,count:18)
  state[12]=1;state[15]=8;state[16]=15;state[17]=2
  d.gate(now:0,before:state,after:state,idle:true,supported:true,empty:false,coverage:1)
  state[12]=2
  d.gate(now:0.01,before:state,after:state,idle:true,supported:true,empty:false,coverage:1)
  state[17]=64
  d.gate(now:0.02,before:state,after:state,idle:true,supported:true,empty:false,coverage:1)
  let r=try #require({d.record(now:0.03,metricEpoch:1,snapshot:snapshot(0.03),final:true)}())
  #expect(r.gates.count==3 && r.gates[1].after[12]==2 && r.gates[2].after[17]==64)
 }
 @Test func manualCommandDiagnosticScopeDisarmsOldAutomaticAttribution() throws {
  var d=PlaybackHypothesisDiagnostics();d.arm(command:1,now:0,lastPTS:0,clock:0)
  poll(&d,0.1);d.resetScope() // Production acceptIntentCommand(.manual) uses this fence.
  for n in 2...200 {poll(&d,Double(n)/100)}
  #expect(!d.isArmed && !d.shouldEmit(now:2) && !d.hasFaultEvidence)
  let r=try #require({d.record(now:2,metricEpoch:1,snapshot:snapshot(2),final:true)}())
  #expect(r.scope==1 && r.automaticCommand==nil && r.automaticAt==nil)
 }

}
