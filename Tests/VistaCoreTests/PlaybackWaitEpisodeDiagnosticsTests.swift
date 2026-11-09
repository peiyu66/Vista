import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

@Suite(.serialized) struct PlaybackWaitEpisodeDiagnosticsTests {
 typealias Trace=PlaybackWaitEpisodeDiagnostics
 private func snapshot(_ t:Double)->Trace.Snapshot {
  var s=Trace.Snapshot(now:t);s.clock=t;s.rate=2;s.speed=2;s.frontier=t+0.5;return s
 }
 private func requireRecord(_ r:Trace.Record?) throws->Trace.Record {try #require(r)}
 private func start(_ trace:inout Trace,_ time:Double=1)->Trace.Record? {
  trace.observe(waiting:true,eligible:true,session:1,epoch:2,origin:.loop,snapshot:{snapshot(time)})
 }
 @Test func immediateResumeBeforeNextLoopStateStillRetainsStart() {
  var t=Trace()
  _=t.copiedFrame(now:0,pts:0,clock:0,eligible:true,snapshot:{snapshot(0)})
  t.notified(now:1)
  _=start(&t)
  t.resumed(snapshot:{snapshot(1.001)})
  #expect(t.observe(waiting:false,eligible:true,session:1,epoch:2,origin:.loop,snapshot:{snapshot(1.01)}) == nil)
  let record=t.copiedFrame(now:1.02,pts:0.02,clock:0.02,eligible:true,snapshot:{snapshot(1.02)})
  #expect(record?.start.at == 1 && record?.resume?.at == 1.001 && record?.exit?.at == 1.01)
  #expect(record?.frame?.at == 1.02 && record?.notificationAt == 1 && record?.reason == .advanced)
  #expect(record?.firstCopyRelation == 1 && record?.framePTS == 0.02)
  #expect(t.copiedFrame(now:1.03,pts:0.03,clock:0.03,eligible:true,snapshot:{Issue.record("Snapshot after episode finished");return snapshot(1.03)}) == nil)
 }
 @Test func duplicateNonfiniteAndStationaryClockDoNotCloseEpisode() {
  var t=Trace();_=t.copiedFrame(now:0,pts:4,clock:4,eligible:true,snapshot:{snapshot(0)});_=start(&t)
  t.resumed(snapshot:{snapshot(1.01)})
  _=t.observe(waiting:false,eligible:true,session:1,epoch:2,origin:.loop,snapshot:{snapshot(1.02)})
  #expect(t.copiedFrame(now:1.03,pts:.nan,clock:4,eligible:true,snapshot:{snapshot(1.03)}) == nil)
  #expect(t.copiedFrame(now:1.04,pts:4,clock:4,eligible:true,snapshot:{snapshot(1.04)}) == nil)
  #expect(t.copiedFrame(now:1.05,pts:4.01,clock:4,eligible:true,snapshot:{snapshot(1.05)}) == nil)
  let r=t.copiedFrame(now:1.06,pts:4.02,clock:4.02,eligible:true,snapshot:{snapshot(1.06)})
  #expect(r?.firstCopyAt == 1.04 && r?.firstCopyRelation == 2 && r?.duplicateCopies == 1)
  #expect(r?.frame?.at == 1.06 && r?.framePTS == 4.02)
 }
 @Test func firstCopyBeforeResumeIsPreservedButDoesNotProveRecovery() {
  var t=Trace();_=t.copiedFrame(now:0,pts:4,clock:4,eligible:true,snapshot:{snapshot(0)});_=start(&t)
  _=t.copiedFrame(now:1.01,pts:4,clock:4,eligible:true,snapshot:{Issue.record("Early copy must stay lightweight");return snapshot(1.01)})
  #expect(t.active?.firstCopyAt == 1.01 && t.active?.firstCopyRelation == 2 && t.active?.frame == nil)
  t.resumed(snapshot:{snapshot(1.02)})
  _=t.observe(waiting:false,eligible:true,session:1,epoch:2,origin:.loop,snapshot:{snapshot(1.03)})
  let r=t.copiedFrame(now:1.04,pts:4.1,clock:4.1,eligible:true,snapshot:{snapshot(1.04)})
  #expect(r?.firstCopyAt == 1.01 && r?.frame?.at == 1.04)
 }
 @Test func notificationDoesNotLeakAcrossCompletedOrInterruptedEpisodes() {
  var t=Trace();_=start(&t);t.notified(now:1.01)
  let r=t.abort(.seek,now:1.1);#expect(r?.notificationAt == 1.01)
  _=start(&t,2);#expect(t.active?.notificationAt == nil)
  _=t.copiedFrame(now:2.01,pts:1,clock:1,eligible:true,snapshot:{snapshot(2.01)})
  _=t.observe(waiting:false,eligible:true,session:1,epoch:2,origin:.loop,snapshot:{snapshot(2.02)})
  t.notified(now:2.03)
  _=t.copiedFrame(now:2.04,pts:2,clock:2,eligible:true,snapshot:{snapshot(2.04)})
  _=start(&t,3);#expect(t.active?.notificationAt == nil)
 }
 @Test func pendingNotificationWithoutActualWaitNeverCreatesEpisodeOrResume() {
  var t=Trace();t.notified(now:1)
  _=t.observe(waiting:false,eligible:true,session:1,epoch:1,origin:.notification,snapshot:{Issue.record("Not a boundary");return snapshot(1)})
  t.resumed(snapshot:{Issue.record("Pending is not an episode");return snapshot(1)})
  _=t.observe(waiting:true,eligible:false,session:1,epoch:1,origin:.loop,snapshot:{Issue.record("Ineligible wait");return snapshot(1)})
  #expect(t.active == nil && t.seen == 0)
 }
 @Test(arguments:[Trace.End.pause,.seek,.inactive,.stop,.failure,.sourceRecovery,.ended,.userResume,.sourceEpoch])
 func interruptionsEndAttributionAndAllowLaterEpisode(_ reason:Trace.End) {
  var t=Trace();_=start(&t)
  let r=t.abort(reason,now:1.1)
  #expect(r?.reason == reason && r?.exit == nil && r?.frame == nil)
  #expect(t.active == nil && t.lastFramePTS == nil)
  _=start(&t,2);#expect(t.active?.episode == 2 && t.active?.resume == nil)
 }
 @Test func exitThenReentryCannotOverwriteOriginalWait() {
  var t=Trace();_=start(&t)
  _=t.observe(waiting:false,eligible:true,session:1,epoch:2,origin:.loop,snapshot:{snapshot(1.1)})
  let previous=start(&t,1.2)
  #expect(previous?.episode == 1 && previous?.reason == .superseded && previous?.start.at == 1)
  #expect(t.active?.episode == 2 && t.active?.start.at == 1.2)
 }
 @Test func repeatedResumeAndFrameSnapshotsAreBounded() {
  var t=Trace();_=t.copiedFrame(now:0,pts:0,clock:0,eligible:true,snapshot:{snapshot(0)});_=start(&t)
  for i in 0..<100 {t.resumed(snapshot:{snapshot(1+Double(i)*0.001)})}
  #expect(t.active?.resume?.at == 1 && t.active?.resumeCalls == 100)
  for i in 1...100 {_=t.copiedFrame(now:2+Double(i),pts:Double(i),clock:Double(i),eligible:true,snapshot:{snapshot(2+Double(i))})}
  #expect(t.active?.frame?.at == 3)
  let r=t.observe(waiting:false,eligible:true,session:1,epoch:2,origin:.loop,snapshot:{snapshot(103)})
  #expect(r?.frame?.at == 3 && r?.resumeCalls == 100)
 }
 @Test func lifetimeQuotaNeverExhaustsAndBurstRateRemainsBounded() {
  var t=Trace(),emitted=0
  for _ in 0..<100 {_=start(&t,1);if t.abort(.pause,now:1) != nil {emitted += 1}}
  #expect(emitted == 4 && t.suppressed == 96)
  _=start(&t,2);#expect(t.abort(.pause,now:2) == nil)
  _=start(&t,3);#expect(t.abort(.pause,now:3)?.suppressed == 97)
  for i in 1...10_000 {
   let now=3+Double(i)*2;_=start(&t,now)
   #expect(t.abort(.pause,now:now) != nil)
  }
  #expect(t.seen == 10_102)
  var n=Trace.maximumCounter-1;Trace.increment(&n);Trace.increment(&n);#expect(n == Trace.maximumCounter)
 }
 @Test func finiteTypedPayloadIsPrivateAndBelowJournalLimit() throws {
  var io=PlaybackSupplyDiagnostics()
  io.beginWork(kind:.demand,id:UInt64.max,generation:UInt64.max,epoch:UInt64.max,now:123456.123456)
  io.beginCall(kind:.cachedSegments,now:123456.123457,observedEpoch:UInt64.max,generation:UInt64.max);io.endCall(result:.returned,bytes:Int.max,now:123456.223456)
  io.beginCall(kind:.read,now:123456.223457,observedEpoch:UInt64.max,generation:UInt64.max)
  var s=snapshot(123456.3);s.supply=io.snapshot(session:UInt64.max,generation:UInt64.max,epoch:UInt64.max,queueDepth:Int.max,oldestQueuedAt:123456.123456)
  s.clock = .nan;s.rate = .infinity;s.frontier = -.infinity;s.lastFrameAt=123455.0;s.lastFramePTS=12345;s.lastDeliveryAt=123456.223456;s.deliveryBytes=UInt64.max
  var t=Trace();_=t.copiedFrame(now:123456,pts:1,clock:1,eligible:true,snapshot:{s})
  _=t.observe(waiting:true,eligible:true,session:Trace.maximumCounter,epoch:Int.max,origin:.loop,snapshot:{s})
  t.resumed(snapshot:{s})
  _=t.copiedFrame(now:123456.4,pts:2,clock:2,eligible:true,snapshot:{s})
  let r=try requireRecord(t.observe(waiting:false,eligible:true,session:1,epoch:1,origin:.loop,snapshot:{s}))
  let log=PlaybackLogRecord(waitEpisode:r,build:"PRIVATE/secret.mp4").withWaitLosses(dropped:Trace.maximumCounter,rejected:Trace.maximumCounter,failures:Trace.maximumCounter)
  let data=try JSONEncoder().encode(log),text=String(decoding:data,as:UTF8.self)
  #expect(data.count<4096 && log.build == "0" && !PlaybackLogEvent.waitEpisode.isCritical)
  #expect(!text.contains("PRIVATE") && !text.contains("secret") && !text.contains("Infinity") && !text.contains("NaN"))
  #expect(r.start.clock == nil && r.start.rate == nil && r.start.frontier == nil)
  #expect(try JSONDecoder().decode(PlaybackLogRecord.self,from:data).waitEpisode?.episode == 1)
  // All four ordinary finite boundaries, every supply field and maximal loss/ID
  // counters. The nonfinite sanitization above must not hide size regressions.
  s.clock=123456.3;s.rate=2;s.frontier=123456.8
  var full=Trace.Record(session:Trace.maximumCounter,episode:Trace.maximumCounter,requestEpoch:Int.max,origin:.notification,start:s)
  full.resume=s;full.exit=s;full.frame=s;full.notificationAt=123456.2;full.resumeCause=1;full.lastResumeAt=123456.3
  full.firstCopyAt=123456.4;full.firstCopyPTS=123456.5;full.firstCopyRelation=2;full.framePTS=123456.6
  full.resumeCalls=Trace.maximumCounter;full.duplicateCopies=Trace.maximumCounter;full.reason = .advanced;full.finished=123456.7;full.suppressed=Trace.maximumCounter
  let finiteLog=PlaybackLogRecord(waitEpisode:full,build:"89").withWaitLosses(dropped:Trace.maximumCounter,rejected:Trace.maximumCounter,failures:Trace.maximumCounter)
  let finiteData=try JSONEncoder().encode(finiteLog)
  #expect(finiteData.count<4096)
  print("WAIT_EPISODE_PAYLOAD_BYTES finite_four_boundaries",finiteData.count,"sanitized",data.count,"limit",4096)
 }
 @MainActor private final class CounterOwner {var counters=PlaybackWaitEpisodeCounters()}
 @Test @MainActor func delayedCleanupKeepsFinalCountersAfterOwnerReleaseAndReuse() {
  var owner:CounterOwner?=CounterOwner()
  weak var weakOwner=owner
  weak var oldCounters=owner?.counters
  var delayed:(@MainActor ()->[PlaybackLogField:Double])? = { [counters=owner!.counters] in counters.values }
  var t=Trace()
  for _ in 0..<4 {_=start(&t,1);_=t.abort(.pause,now:1)}
  _=start(&t,1)
  owner?.counters.update(seen:t.seen,completed:t.completed,suppressed:t.suppressed,incomplete:t.active != nil)
  #expect(delayed?()[.waitIncomplete] == 1)
  let suppressedAbort=t.abort(.stop,now:1)
  #expect(suppressedAbort == nil && t.suppressed == 1)
  owner?.counters.update(seen:t.seen,completed:t.completed,suppressed:t.suppressed,incomplete:t.active != nil)
  // Reuse binds a new counter object, then the entire owner can disappear.
  owner?.counters=PlaybackWaitEpisodeCounters()
  owner?.counters.update(seen:99,completed:0,suppressed:0,incomplete:true)
  owner=nil
  #expect(weakOwner == nil && oldCounters != nil)
  let values=delayed?()
  #expect(values?[.waitEpisodes] == 5 && values?[.waitCompleted] == 5)
  #expect(values?[.waitSuppressed] == 1 && values?[.waitIncomplete] == 0)
  delayed=nil
  #expect(oldCounters == nil)
 }
 @Test func rollingLaneRetainsRecentEpisodesAndAccountsForDrops() throws {
  var buffer=PlaybackWaitEpisodeLogBuffer(),t=Trace()
  for i in 0..<100 {
   let time=Double(i)*2;_=start(&t,time)
   buffer.append(PlaybackLogRecord(waitEpisode:try requireRecord(t.abort(.pause,now:time))))
  }
  #expect(buffer.pending.count == 4 && buffer.dropped == 96)
  #expect(buffer.take()?.waitEpisode?.episode == 97)
 }
 @Test func loggerRejectsMissingPayloadAndNextRecordSurvives() throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:dir)}
  let store=PlaybackLogStore(directory:dir)
  let huge=PlaybackLogRecord(event:.waitEpisode,values:Dictionary(uniqueKeysWithValues:PlaybackLogField.allCases.map{($0,Double.greatestFiniteMagnitude)}))
  #expect(try JSONEncoder().encode(huge).count>4096)
  store.enqueue(huge);store.drainForTesting()
  #expect(store.status.dropped == 1)
  var t=Trace();_=start(&t)
  store.enqueue(PlaybackLogRecord(waitEpisode:try requireRecord(t.abort(.stop,now:1.1))));store.drainForTesting()
  let text=try String(contentsOf:dir.appendingPathComponent("wait-current.jsonl"),encoding:.utf8)
  let r=try JSONDecoder().decode(PlaybackLogRecord.self,from:Data(text.trimmingCharacters(in:.whitespacesAndNewlines).utf8))
  #expect(r.values["waitLogRejected"] == 1)
  #expect(r.values["waitLogRejectedMissingPayload"] == 1 && r.values["waitLogRejectedOversize"] == 0)
 }
 @Test func loggerKeepsTerminalEventsAndReportsEpisodeWriteFailures() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:root)}
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let blocked=root.appendingPathComponent("journal");try Data().write(to:blocked)
  let store=PlaybackLogStore(directory:blocked)
  var t=Trace();_=start(&t)
  let r=try requireRecord(t.abort(.stop,now:1.1))
  store.enqueue(PlaybackLogRecord(waitEpisode:r));store.drainForTesting()
  #expect(store.status.failures == 1)
  try FileManager.default.removeItem(at:blocked)
  for _ in 0..<500 {store.enqueue(.init(event:.prefetchTrace,values:[:]))}
  store.enqueue(PlaybackLogRecord(waitEpisode:r));store.enqueue(.init(event:.failed,values:[:]));store.drainForTesting()
  let text=try String(contentsOf:blocked.appendingPathComponent("current.jsonl"),encoding:.utf8)
  let waitText=try String(contentsOf:blocked.appendingPathComponent("wait-current.jsonl"),encoding:.utf8)
  let rows=try (text+waitText).split(separator:"\n").map {try JSONDecoder().decode(PlaybackLogRecord.self,from:Data($0.utf8))}
  #expect(rows.contains{$0.event == .failed && $0.values["waitLogFailures"] == 1})
  #expect(rows.contains{$0.event == .waitEpisode && $0.values["waitLogFailures"] == 1})
 }
}
