import Foundation
import Testing
@testable import VistaMedia
@testable import VistaCore
struct PlaybackLogTests {
 @Test func noAdmissionCountersEncodeInSampleAndTerminalSummary()throws {
  var snapshot=PrefetchDiagnosticsSnapshot()
  snapshot.noAdmissionWindow=11; snapshot.noAdmissionDemandOrGrace=12
  snapshot.noAdmissionDisabledOrEpoch=13; snapshot.noAdmissionFilledOrBudget=14
  for event in [PlaybackLogEvent.sample, .prefetchSummary] {
   let record=PlaybackLogRecord(event:event,values:snapshot.playbackLogValues,build:"83")
   let encoded=try JSONEncoder().encode(record)
   let decoded=try JSONDecoder().decode(PlaybackLogRecord.self,from:encoded)
   #expect(decoded.values["pfNoAdmissionWindow"] == 11)
   #expect(decoded.values["pfNoAdmissionDemandOrGrace"] == 12)
   #expect(decoded.values["pfNoAdmissionDisabledOrEpoch"] == 13)
   #expect(decoded.values["pfNoAdmissionFilledOrBudget"] == 14)
   #expect(encoded.count < 4096 && snapshot.generatedRecords == 0)
  }
 }
 @Test func wholeSessionForwardCountersEncodeWithoutDetailQuota() throws {
  var d=PrefetchDiagnosticsSnapshot()
  d.demandFullCacheCount=101;d.demandPartialCacheCount=102;d.demandZeroCacheCount=103
  d.demandCancelledCount=4;d.demandFailedCount=5
  d.demandSourceWaitCount=205;d.demandSourceCallCount=205;d.demandSourceWaitSeconds=1.25
  d.forwardCreateCount=6;d.forwardAdvanceCount=7;d.forwardBackreadPreservedCount=800
  d.forwardCancelPreservedCount=9;d.forwardSuspendCount=10;d.forwardRebaseCount=11
  d.forwardDistantPendingCount=12;d.forwardLifecycleRetiredCount=13;d.forwardEpochRetiredCount=14
  d.forwardEvidenceRetiredCount=15;d.forwardDemandFailureRetiredCount=16;d.forwardPrefetchFailureRetiredCount=17
  d.forwardUnretainedEvidenceCount=18;d.forwardTransitionID=999;d.forwardTransition = .cancelPreserved
  d.generatedRecords=1000;d.suppressedRecords=744;d.historyGeneratedRecords=64
  for event in [PlaybackLogEvent.sample,.prefetchSummary] {
   let encoded=try JSONEncoder().encode(PlaybackLogRecord(event:event,values:d.playbackLogValues,build:"96"))
   let v=try JSONDecoder().decode(PlaybackLogRecord.self,from:encoded).values
   #expect(v["pfDemandFullCacheCount"] == 101 && v["pfDemandPartialCacheCount"] == 102 && v["pfDemandZeroCacheCount"] == 103)
   #expect(v["pfDemandCancelledCount"] == 4 && v["pfDemandFailedCount"] == 5)
   #expect(v["pfDemandSourceWaitCount"] == 205 && v["pfDemandSourceCallCount"] == 205 && v["pfDemandSourceWaitMS"] == 1250)
   #expect(v["pfForwardBackreadPreservedCount"] == 800 && v["pfForwardCancelPreservedCount"] == 9)
   #expect(v["pfForwardTransitionID"] == 999 && v["pfForwardTransition"] == Double(PrefetchForwardTransition.cancelPreserved.rawValue))
   #expect(v["pfForwardEvidenceRetiredCount"] == 15 && encoded.count < 4096)
  }
 }
 @Test func independentPrefetchDetailBudgetsEncodeInSummary()throws {
  var snapshot=PrefetchDiagnosticsSnapshot()
  snapshot.generatedRecords=1000; snapshot.suppressedRecords=744
  snapshot.historyGeneratedRecords=700; snapshot.historySuppressedRecords=636
  let record=PlaybackLogRecord(event:.sample,values:snapshot.playbackLogValues,build:"82")
  let encoded=try JSONEncoder().encode(record)
  let decoded=try JSONDecoder().decode(PlaybackLogRecord.self,from:encoded)
  #expect(decoded.values["pfTraceGenerated"] == 1000)
  #expect(decoded.values["pfTraceSuppressed"] == 744)
  #expect(decoded.values["pfTraceHistoryGenerated"] == 700)
  #expect(decoded.values["pfTraceHistorySuppressed"] == 636)
  #expect(decoded.values["pfTracePrefetchGenerated"] == 300)
  #expect(decoded.values["pfTracePrefetchSuppressed"] == 108)
 }

 @Test func boundedRotatingAnonymousLogs()throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:dir)}
  let store=PlaybackLogStore(directory:dir,limit:4096)
  let start=ProcessInfo.processInfo.systemUptime
  for i in 0..<100 {store.enqueue(.init(event:.sample,values:[.frames:Double(i),.bytes:123,.position:Double.nan],build:"PRIVATE/secret.mp4"));store.drainForTesting()}
  let files=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)
  #expect(files.count<=4 && files.count>1)
  var total=0
  for file in files {
   let data=try Data(contentsOf:file);total+=data.count;#expect(data.count<=4096)
   let text=String(decoding:data,as:UTF8.self);#expect(!text.contains("PRIVATE") && !text.contains("secret") && !text.contains("NaN"))
   for line in text.split(separator:"\n") {let value=try JSONDecoder().decode(PlaybackLogRecord.self,from:Data(line.utf8));#expect(value.build=="0" && value.values["position"]==nil)}
  }
  #expect(total<=16384 && store.status.failures==0)
  print("LOG100 elapsed_ms",(ProcessInfo.processInfo.systemUptime-start)*1000,"bytes",total)
 }
 @Test func expiryFailureAndBurstAreBounded()throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:dir)}
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  let stale=dir.appendingPathComponent("previous-3.jsonl");try Data("stale".utf8).write(to:stale)
  try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-8*86400)],ofItemAtPath:stale.path)
  let store=PlaybackLogStore(directory:dir)
  for i in 0..<10000 {store.enqueue(.init(event:i==9999 ? .failed:.sample,values:[.frames:Double(i)]))};store.drainForTesting()
  #expect(!FileManager.default.fileExists(atPath:stale.path));#expect(store.status.dropped>0)
  let text=try String(contentsOf:dir.appendingPathComponent("current.jsonl"),encoding:.utf8);#expect(text.contains("failed"))
  let blocking=dir.appendingPathComponent("not-directory");try Data().write(to:blocking)
  let failure=PlaybackLogStore(directory:blocking);failure.enqueue(.init(event:.failed,values:[:]));failure.drainForTesting();#expect(failure.status.failures==1)
 }
 @Test func prefetchDetailKeepsNonCriticalBoundedJournalPolicy()throws {
  #expect(!PlaybackLogEvent.prefetchTrace.isCritical)
  #expect(!PlaybackLogEvent.sample.isCritical)
  #expect(PlaybackLogEvent.stopped.isCritical && PlaybackLogEvent.failed.isCritical && PlaybackLogEvent.prefetchSummary.isCritical)
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:dir)}
  let store=PlaybackLogStore(directory:dir,limit:4096)
  for _ in 0..<40 {store.enqueue(.init(event:.prefetchTrace,values:[.bytes:2097152],build:"81"));store.drainForTesting()}
  store.enqueue(.init(event:.stopped,values:[:],build:"81"));store.drainForTesting()
  let files=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)
  #expect(files.count<=4 && store.status.failures==0)
  for file in files {#expect(try Data(contentsOf:file).count<=4096)}
  let latest=try String(contentsOf:dir.appendingPathComponent("current.jsonl"),encoding:.utf8)
  #expect(latest.contains("prefetchTrace") && latest.contains("stopped"))
 }

 @Test func prefetchRecordEncodesRelativeOffsetsWithoutFreeText()throws {
  let trace=PrefetchDiagnosticRecord(sessionID:1,sequence:2,prefetchID:3,requestID:4,generation:5,epoch:6,
   prefetchGeneration:4,prefetchEpoch:6,event:.demandEnqueued,reason:.requestQueued,invalidationReason:.explicit,
   prefetchBytes:2097152,previousPrefetchDelta:131072,prefetchPrefixBytes:0,prefetchOverlapBytes:2031616,demandBytes:2097152,demandDelta:-65536,
   readyBytes:262144,readyPrefixBytes:0,readyOverlapBytes:262144,inFlightBytes:2097152,inFlightPrefixBytes:0,inFlightOverlapBytes:2031616,
   queueDepth:1,usedReadyBytes:0,usedJoinedBytes:0,discardedBytes:0,stateBits:97,historyBytes:2097152,historyOverlapBytes:65536,totalCacheBytes:6291456,inFlightReservedBytes:2097152,demandOwnedBytes:0,usedHistoryBytes:65536,waitedForPrefetch:true,waitMilliseconds:7,historyEvictedBytes:0,historyDelta:1966080)
  let log=PlaybackLogRecord(prefetch:trace,build:"PRIVATE/secret.mp4")
  let data=try JSONEncoder().encode(log)
  #expect(data.count<4096 && log.event == .prefetchTrace && log.build == "0")
  #expect(log.values["pfTraceDemandDelta"] == -65536)
  #expect(log.values["pfTraceHistoryOverlap"] == 65536 && log.values["pfTraceUsedHistory"] == 65536)
  #expect(log.values["pfTraceHistoryDelta"] == 1966080)
  #expect(log.values["pfTraceCacheBytes"] == 6291456 && log.values["pfTraceWaited"] == 1 && log.values["pfTraceWaitMS"] == 7)
  #expect(log.values["pfTraceReadGeneration"] == 4 && log.values["pfTraceGeneration"] == 5)
  let text=String(decoding:data,as:UTF8.self)
  #expect(!text.contains("PRIVATE") && !text.contains("secret") && !text.contains("absolute"))
  let roundtrip=try JSONDecoder().decode(PlaybackLogRecord.self,from:data)
  #expect(roundtrip.values == log.values)
 }

}
