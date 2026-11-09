import Foundation
import Testing
@testable import VistaMedia
@testable import VistaCore

@Suite(.serialized) struct PlaybackStallProbeDiagnosticsTests {
 private typealias D=PlaybackStallProbeDiagnostics
 private func required<T>(_ value:T?) throws -> T {try #require(value)}
 private func snapshot(_ time:Double,clock:Double=10,pts:Double?=nil)->D.Snapshot {
  var s=D.Snapshot(now:time)
  s.clock=clock;s.lastFramePTS=10;s.copiedFramePTS=pts;s.progressEligible=true
  s.bridgeRequests=0;s.bridgeDataRequests=0;s.bridgeChunks=0;s.bridgeCancellations=0;s.deliveredBytes=0
  s.bridgeReturns=0;s.bridgeResponses=0;s.bridgeActive=0
  s.selectedSpeed=2;s.defaultRate=2;s.playerRate=0;s.effectiveRate=0
  return s
 }
 private func started()->D {
  var d=D();d.begin(epoch:1,snapshot:snapshot(0))
  _=d.attempt(before:snapshot(1),after:snapshot(1.1));return d
 }
 @Test func ordinaryShortWaitsDoNotExhaustActualProbeBudget() throws {
  var d=D()
  for i in 0..<1000 {
   d.begin(epoch:1,snapshot:snapshot(Double(i)))
   d.rejected(reason:3)
   let terminal=d.finish(.progress,snapshot:snapshot(Double(i)+0.5));#expect(terminal == nil)
  }
  d.begin(epoch:1,snapshot:snapshot(1001))
  let firstAttempt=d.attempt(before:snapshot(1002),after:snapshot(1002.1));#expect(firstAttempt != nil)
  let completion=try required(d.finishSession(snapshot:snapshot(1003)))
  #expect(completion.terminal != nil && completion.summary.attemptsEmitted==1)
  #expect(completion.summary.seenEpisodes==1001 && completion.summary.rejectedObservations==1000)
  #expect(completion.summary.attemptsSuppressed==0)
 }
 @Test func hardBudgetAndSummaryCountEmissionNotDurability() throws {
  var d=D();var records=0
  for i in 0..<100 {
   let t=Double(i)*3
   d.begin(epoch:i,snapshot:snapshot(t))
   if d.attempt(before:snapshot(t+1),after:snapshot(t+1.1)) != nil {records += 1}
   let duplicate=d.attempt(before:snapshot(t+1.2),after:snapshot(t+1.3));#expect(duplicate == nil)
   if d.finish(.failure,snapshot:snapshot(t+2)) != nil {records += 1}
  }
  let completion=try required(d.finishSession(snapshot:snapshot(400)))
  #expect(records==32 && completion.terminal==nil)
  #expect(completion.summary.attemptsSeen==100 && completion.summary.attemptsEmitted==16)
  #expect(completion.summary.attemptsSuppressed==84 && completion.summary.terminalsEmitted==16)
  #expect(completion.summary.recovered==0 && completion.summary.incomplete==16)
  let duplicateFinish=d.finishSession(snapshot:snapshot(401));#expect(duplicateFinish == nil)
  let lateBegin=d.begin(epoch:101,snapshot:snapshot(402));#expect(lateBegin == nil && !d.isObserving)
 }
 @Test func rejectionCodesAreBoundedAndUnknownIsNotInventedAsZero() throws {
  var d=D();d.begin(epoch:1,snapshot:snapshot(0))
  for code in [0,1,63,-1,64,Int.max] {d.rejected(reason:code)}
  let summary=try required(d.finishSession(snapshot:snapshot(1))).summary
  #expect(summary.rejectedObservations==5 && summary.invalidRejections==3)
  #expect(summary.rejectionReasons==((UInt64(1)<<63)|2))
  #expect(summary.lastRejection==63 && summary.attemptsSeen==0)
  var empty=D();let zero=try required(empty.finishSession(snapshot:snapshot(0))).summary
  #expect(zero.rejectedObservations==0 && zero.rejectionReasons==0 && zero.lastRejection==nil)
 }
 @Test func demandReturnResponseBytesAndVideoProgressRemainSeparate() throws {
  var d=started()
  var s=snapshot(2);s.bridgeRequests=1;s.bridgeDataRequests=1;d.observe(s)
  s=snapshot(3);s.bridgeRequests=1;s.bridgeDataRequests=1;s.bridgeReturns=1;d.observe(s)
  s=snapshot(4);s.bridgeRequests=1;s.bridgeDataRequests=1;s.bridgeReturns=1;s.bridgeResponses=1;s.deliveredBytes=1024;d.observe(s)
  s=snapshot(5,clock:10.1,pts:10.1);s.bridgeRequests=1;s.bridgeDataRequests=1;s.deliveredBytes=1024;d.observe(s)
  s=snapshot(6,clock:10.2,pts:10.2);s.bridgeRequests=1;s.bridgeDataRequests=1;s.deliveredBytes=1024;d.observe(s)
  let record=try required(d.finish(.progress,snapshot:snapshot(7)))
  #expect(record.firstDemandAt==2 && record.firstReturnAt==3)
  #expect(record.firstResponseAt==4 && record.firstBytesAt==4)
  #expect(record.firstClockAt==5 && record.firstAdvancingPTSAt==5 && record.recoveredAt==6)
  #expect(record.milestones==255)
 }
 @Test func duplicateRegressedPTSOrClockAndOneFrameNeverProveRecovery() throws {
  var d=started()
  d.observe(snapshot(2,clock:11,pts:10))
  d.observe(snapshot(3,clock:12,pts:9))
  d.observe(snapshot(4,clock:13,pts:9.5))
  d.observe(snapshot(5,clock:14,pts:10.1))
  let record=try required(d.finish(.progress,snapshot:snapshot(6)))
  #expect(record.firstAdvancingPTSAt==5 && record.recoveredAt==nil)
  let summary=try required(d.finishSession(snapshot:snapshot(7))).summary
  #expect(summary.recovered==0 && summary.incomplete==1)
  var frozen=started()
  frozen.observe(snapshot(2,clock:10,pts:10.1));frozen.observe(snapshot(3,clock:10,pts:10.2))
  let frozenEnd=try required(frozen.finish(.progress,snapshot:snapshot(4)));#expect(frozenEnd.recoveredAt==nil)
 }
 @Test func inactivityDoesNotSpendAnotherAttemptAndNeedsFreshPair() throws {
  var d=started();d.observe(snapshot(2,clock:10.1,pts:10.1))
  d.interruptObservation()
  var inactive=snapshot(3,clock:10.2,pts:10.2);inactive.progressEligible=false;d.observe(inactive)
  let secondAttempt=d.attempt(before:snapshot(4),after:snapshot(4.1));#expect(d.isObserving && secondAttempt == nil)
  d.observe(snapshot(5,clock:10.3,pts:10.3))
  let first=try required(d.finish(.progress,snapshot:snapshot(6)))
  #expect(first.recoveredAt==nil)
 }
 @Test func missingCountersAndMissingBaselineCannotBecomeRecoveryEvidence() throws {
  var d=D();var missing=D.Snapshot(now:0);missing.progressEligible=true
  d.begin(epoch:1,snapshot:missing)
  missing.at=1;let before=missing;missing.at=1.1
  _=d.attempt(before:before,after:missing)
  d.observe(snapshot(2,clock:20,pts:20));d.observe(snapshot(3,clock:21,pts:21))
  let terminal=try required(d.finish(.progress,snapshot:snapshot(4)))
  #expect(terminal.firstDemandAt==nil && terminal.firstBytesAt==nil && terminal.firstClockAt==nil)
  #expect(terminal.firstAdvancingPTSAt==nil && terminal.recoveredAt==nil)
  let data=try JSONEncoder().encode(PlaybackLogRecord(stallProbe:terminal,session:4,build:"98"))
  let record=try JSONDecoder().decode(PlaybackLogRecord.self,from:data)
  #expect(record.stallProbe?.before.bridgeRequests==nil)
  #expect(record.stallProbe?.after.bridgeRequests==0)
 }
 @Test func startupWithoutPriorPTSRequiresTwoPostCommandFrames() throws {
  var d=D();var before=snapshot(1);before.lastFramePTS=nil
  d.begin(epoch:1,snapshot:before)
  _=d.attempt(before:before,after:snapshot(1.1))
  d.observe(snapshot(2,clock:10.1,pts:0))
  d.observe(snapshot(3,clock:10.2,pts:0.1))
  let terminal=try required(d.finish(.progress,snapshot:snapshot(4)))
  #expect(terminal.before.lastFramePTS==nil && terminal.firstAdvancingPTSAt==3 && terminal.recoveredAt==3)
 }
 @Test func contentInformationRequestDoesNotInventDataDemand() throws {
  var d=started();var s=snapshot(2);s.bridgeRequests=1;d.observe(s)
  let terminal=try required(d.finish(.failure,snapshot:snapshot(3)))
  #expect(terminal.firstDemandAt==nil && terminal.firstBytesAt==nil)
 }
 @Test func queryTimestampValidityAndNonfiniteValuesArePreservedOrMissing() throws {
  var d=D();var before=snapshot(1)
  before.outputObservationAt=0.9;before.queryTime=10.2;before.queryClockDifference=0.2
  before.queryValidity=3;before.targetHostLeadSeconds=nil
  before.copyQueryDifference = .infinity;before.lastProgressAge = .nan
  d.begin(epoch:1,snapshot:before)
  let record=try required(d.attempt(before:before,after:snapshot(1.1)))
  let decoded=try JSONDecoder().decode(PlaybackLogRecord.self,from:JSONEncoder().encode(PlaybackLogRecord(stallProbe:record,session:1)))
  #expect(decoded.stallProbe?.before.outputObservationAt==0.9)
  #expect(decoded.stallProbe?.before.queryValidity==3 && decoded.stallProbe?.before.queryClockDifference==0.2)
  #expect(decoded.stallProbe?.before.targetHostLeadSeconds==nil && decoded.stallProbe?.before.copyQueryDifference==nil)
  #expect(decoded.stallProbe?.before.lastProgressAge==nil)
  var invalid=D();invalid.begin(epoch:1,snapshot:D.Snapshot(now:.nan))
  let bad=try required(invalid.attempt(before:D.Snapshot(now:.nan),after:D.Snapshot(now:.infinity)))
  #expect(bad.started==nil && bad.attempted==nil && bad.before.at==nil && bad.after.at==nil)
  #expect(bad.invalidSnapshots==1)
 }
 @Test func delayedRepeatedOrRegressedObservationDoesNotCreateMilestones() throws {
  var d=started()
  d.observe(snapshot(1,clock:11,pts:11));d.observe(snapshot(.nan,clock:12,pts:12))
  d.observe(snapshot(2,clock:10.1,pts:10.1));d.observe(snapshot(2,clock:10.2,pts:10.2))
  let record=try required(d.finish(.progress,snapshot:snapshot(3)))
  #expect(record.recoveredAt==nil && record.invalidSnapshots==3)
 }
 @Test func maximumNumericPayloadFitsUnchangedRecordAndJournalLimits() throws {
  var s=D.Snapshot(now:Double.greatestFiniteMagnitude)
  s.clock = .greatestFiniteMagnitude;s.lastFramePTS = .greatestFiniteMagnitude;s.copiedFramePTS = .greatestFiniteMagnitude
  s.selectedSpeed = .greatestFiniteMagnitude;s.defaultRate = .greatestFiniteMagnitude;s.playerRate = .greatestFiniteMagnitude;s.effectiveRate = .greatestFiniteMagnitude
  s.coverageSeconds = .greatestFiniteMagnitude;s.queryTime = -.greatestFiniteMagnitude;s.queryClockDifference = -.greatestFiniteMagnitude;s.copyQueryDifference = -.greatestFiniteMagnitude
  s.targetHostLeadSeconds = -.greatestFiniteMagnitude;s.outputObservationAt = .greatestFiniteMagnitude
  s.recoveryActiveSeconds = .greatestFiniteMagnitude;s.probeQuietSeconds = .greatestFiniteMagnitude
  s.lastProgressAge = .greatestFiniteMagnitude;s.lastDeliveryAge = .greatestFiniteMagnitude;s.lastFrameAge = .greatestFiniteMagnitude
  s.context=Int.min;s.transport=Int.min;s.waitingReason=Int.min;s.queryValidity=Int.min
  s.bridgeActive=Int.min;s.sourceBusyMask=Int.min;s.attempts=Int.min;s.probeBlock=Int.min;s.bufferEmpty=true;s.progressEligible=true
  s.bridgeRequests=UInt64.max;s.bridgeDataRequests=UInt64.max;s.bridgeChunks=UInt64.max;s.bridgeCancellations=UInt64.max;s.bridgeReturns=UInt64.max;s.bridgeResponses=UInt64.max;s.deliveredBytes=UInt64.max
  s.sourceGeneration=UInt64.max;s.sourceEpoch=UInt64.max;s.sourceRequestID=UInt64.max;s.sourcePrefetchID=UInt64.max
  var d=D();d.begin(epoch:Int.min,snapshot:s);d.rejected(reason:63)
  let attempt=try required(d.attempt(before:s,after:s))
  let terminal=try required(d.finish(.failure,snapshot:s))
  for payload in [attempt,terminal] {
   let row=PlaybackLogRecord(stallProbe:payload,session:UInt64.max,build:"999999999999")
    .withWaitLosses(dropped:UInt64.max,rejected:UInt64.max,failures:UInt64.max,missingPayload:UInt64.max,oversize:UInt64.max,encoding:UInt64.max,rotatedFiles:UInt64.max,expiredFiles:UInt64.max)
    .withRecoveryLogLosses(dropped:Int.max,failures:Int.max)
   let bytes=try JSONEncoder().encode(row)
   #expect(bytes.count+1<=PlaybackLogStore.ordinaryRecordLimit)
   #expect(try JSONDecoder().decode(PlaybackLogRecord.self,from:bytes).stallProbe?.before.bridgeRequests==UInt64.max)
   print("STALL_PROBE_MAX_RECORD_BYTES",bytes.count,"phase",payload.phase.rawValue)
  }
  let decision=PlaybackAutomaticSpeedPolicy.Decision(nextSpeed:2,reason:.sparseOutput,sequence:UInt64.max,
   observedSeconds:Double.greatestFiniteMagnitude,advancingFrames:UInt64.max,outputPolls:UInt64.max,
   clockAdvance:Double.greatestFiniteMagnitude,maximumFrameGap:Double.greatestFiniteMagnitude)
  let speed=PlaybackLogRecord(automaticSpeed:decision,session:UInt64.max,previous:2.5,before:s,after:s,setterBranch:3)
   .withWaitLosses(dropped:UInt64.max,rejected:UInt64.max,failures:UInt64.max,missingPayload:UInt64.max,oversize:UInt64.max,encoding:UInt64.max,rotatedFiles:UInt64.max,expiredFiles:UInt64.max)
  let speedData=try JSONEncoder().encode(speed)
  #expect(speedData.count+1<=PlaybackLogStore.ordinaryRecordLimit)
  #expect(try JSONDecoder().decode(PlaybackLogRecord.self,from:speedData).rateChange?.before.sourceKind == .unknown)
  print("AUTOMATIC_SPEED_COMMAND_MAX_RECORD_BYTES",speedData.count)
  #expect(PlaybackLogStore.ordinaryRecordLimit==8192 && PlaybackLogStore.waitJournalLimit==1_048_576)
 }
 @Test func criticalProbeRecordsPersistWithLossCountersAndNoOrdinarySampleGrowth() throws {
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:directory)}
  let store=PlaybackLogStore(directory:directory)
  var d=D();d.begin(epoch:1,snapshot:snapshot(0))
  let attempt=try required(d.attempt(before:snapshot(1),after:snapshot(1.1)))
  let finished=try required(d.finishSession(snapshot:snapshot(2)))
  store.enqueue(PlaybackLogRecord(stallProbe:attempt,session:10,build:"98"))
  store.enqueue(PlaybackLogRecord(stallProbe:try #require(finished.terminal),session:10,build:"98"))
  store.enqueue(PlaybackLogRecord(stallProbeSummary:finished.summary,session:10,build:"98"))
  store.enqueue(PlaybackLogRecord(event:.sample,values:[.frames:3],build:"98"));store.drainForTesting()
  let rows=try String(contentsOf:directory.appendingPathComponent("current.jsonl"),encoding:.utf8).split(separator:"\n").map{try JSONDecoder().decode(PlaybackLogRecord.self,from:Data($0.utf8))}
  #expect(rows.count==4 && store.status.dropped==0 && store.status.failures==0)
  #expect(rows.filter{$0.event == .stallProbe}.count==2)
  let summary=try #require(rows.first{$0.event == .stallProbeSummary})
  #expect(summary.stallProbeSummary?.session==10 && summary.values["logDropped"]==0 && summary.values["logFailures"]==0)
  let ordinary=try #require(rows.first{$0.event == .sample})
  #expect(ordinary.values==["frames":3] && ordinary.stallProbe==nil && ordinary.stallProbeSummary==nil)
 }
}
