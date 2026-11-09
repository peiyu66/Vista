import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

@Suite(.serialized) struct PlaybackWaitArchiveTests {
 private func directory()->URL {FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)}
 private func episode(_ id:UInt64=1)->PlaybackLogRecord {
  var record=PlaybackWaitEpisodeDiagnostics.Record(session:7,episode:id,requestEpoch:3,origin:.loop,start:.init(now:1))
  record.reason = .stop;record.finished=2
  return PlaybackLogRecord(waitEpisode:record,build:"92")
 }
 // Exercise storage boundaries independently of the evolving bounded production
 // schema. Padding is a synthetic numeric-field key, never production text.
 private func paddedEpisode(bytes:Int,id:UInt64=1)throws->PlaybackLogRecord {
  var object=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(episode(id))) as? [String:Any])
  object["values"]=[String(repeating:"x",count:bytes):1]
  return try JSONDecoder().decode(PlaybackLogRecord.self,from:JSONSerialization.data(withJSONObject:object))
 }
 private func rows(_ url:URL)throws->[PlaybackLogRecord] {
  try Data(contentsOf:url).split(separator:10).map {try JSONDecoder().decode(PlaybackLogRecord.self,from:Data($0))}
 }
 @Test func ordinaryStormCannotRotateRetainedWaitEvidence() throws {
  let dir=directory();defer{try? FileManager.default.removeItem(at:dir)}
  let store=PlaybackLogStore(directory:dir,limit:4096)
  store.enqueue(episode());store.drainForTesting()
  let retained=try Data(contentsOf:dir.appendingPathComponent("wait-current.jsonl"))
  for i in 0..<400 {
   store.enqueue(.init(event:.sample,values:[.position:Double(i)]));store.drainForTesting()
  }
  #expect(try Data(contentsOf:dir.appendingPathComponent("wait-current.jsonl")) == retained)
  #expect(FileManager.default.fileExists(atPath:dir.appendingPathComponent("previous-3.jsonl").path))
  #expect(!FileManager.default.fileExists(atPath:dir.appendingPathComponent("wait-previous-1.jsonl").path))
  let decoded=try rows(dir.appendingPathComponent("wait-current.jsonl"))
  #expect(decoded.count == 1 && decoded[0].waitEpisode?.session == 7 && decoded[0].waitEpisode?.episode == 1)
  #expect(decoded[0].waitEpisode?.start.at == 1 && decoded[0].waitEpisode?.finished == 2)
 }
 @Test func waitRotationIsIndependentBoundedAndCountsDeletedFiles() throws {
  let dir=directory();defer{try? FileManager.default.removeItem(at:dir)}
  let store=PlaybackLogStore(directory:dir)
  store.enqueue(.init(event:.sample,values:[.position:42]));store.drainForTesting()
  let ordinary=try Data(contentsOf:dir.appendingPathComponent("current.jsonl"))
  for id in UInt64(1)...6 {
   store.enqueue(try paddedEpisode(bytes:550_000,id:id));store.drainForTesting()
  }
  #expect(try Data(contentsOf:dir.appendingPathComponent("current.jsonl")) == ordinary)
  var ids:[UInt64]=[],total=0
  for name in ["wait-current.jsonl","wait-previous-1.jsonl","wait-previous-2.jsonl","wait-previous-3.jsonl"] {
   let data=try Data(contentsOf:dir.appendingPathComponent(name));total += data.count
   #expect(data.count<PlaybackLogStore.waitJournalLimit && data.last == 10)
   let records=try rows(dir.appendingPathComponent(name))
   #expect(records.count == 1)
   ids.append(try #require(records.first?.waitEpisode?.episode))
  }
  #expect(ids == [6,5,4,3] && total<4*PlaybackLogStore.waitJournalLimit)
  #expect(!FileManager.default.fileExists(atPath:dir.appendingPathComponent("wait-previous-4.jsonl").path))
  store.enqueue(.init(event:.failed,values:[:]));store.drainForTesting()
  let terminal=try #require(rows(dir.appendingPathComponent("current.jsonl")).last)
  #expect(terminal.values["waitJournalRotatedFiles"] == 2 && terminal.values["waitJournalExpiredFiles"] == 0)
 }
 @Test func expirationCountsOnlyActuallyRemovedWaitFiles() throws {
  let dir=directory();defer{try? FileManager.default.removeItem(at:dir)}
  let store=PlaybackLogStore(directory:dir,retention:60)
  for id in UInt64(1)...3 {store.enqueue(try paddedEpisode(bytes:550_000,id:id));store.drainForTesting()}
  for name in ["wait-current.jsonl","wait-previous-1.jsonl","wait-previous-2.jsonl"] {
   try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-120)],ofItemAtPath:dir.appendingPathComponent(name).path)
  }
  // Ordinary traffic also enforces age retention, without rotating wait files.
  store.enqueue(.init(event:.sample,values:[:]));store.drainForTesting()
  store.enqueue(episode(4));store.drainForTesting()
  let retained=try #require(rows(dir.appendingPathComponent("wait-current.jsonl")).first)
  #expect(retained.values["waitJournalExpiredFiles"] == 3 && retained.values["waitJournalRotatedFiles"] == 0)
  store.enqueue(.init(event:.failed,values:[:]));store.drainForTesting()
  #expect(try rows(dir.appendingPathComponent("current.jsonl")).last?.values["waitJournalExpiredFiles"] == 3)
 }
 @Test func oversizeIsRejectedBeforeMutationAndDoesNotSplitRows() throws {
  let dir=directory();defer{try? FileManager.default.removeItem(at:dir)}
  let store=PlaybackLogStore(directory:dir)
  store.enqueue(episode());store.drainForTesting()
  let original=try Data(contentsOf:dir.appendingPathComponent("wait-current.jsonl"))
  store.enqueue(try paddedEpisode(bytes:PlaybackLogStore.waitJournalLimit));store.drainForTesting()
  #expect(store.status.dropped == 1)
  #expect(try Data(contentsOf:dir.appendingPathComponent("wait-current.jsonl")) == original)
  store.enqueue(episode(2));store.drainForTesting()
  let retained=try rows(dir.appendingPathComponent("wait-current.jsonl"))
  #expect(retained.count == 2 && retained.last?.waitEpisode?.episode == 2)
  #expect(retained.last?.values["waitLogRejectedOversize"] == 1 && retained.last?.values["waitLogRejectedMissingPayload"] == 0)
 }
 @Test func waitFileFailureLeavesOrdinaryTerminalWritable() throws {
  let dir=directory();defer{try? FileManager.default.removeItem(at:dir)}
  try FileManager.default.createDirectory(at:dir.appendingPathComponent("wait-current.jsonl"),withIntermediateDirectories:true)
  let store=PlaybackLogStore(directory:dir)
  store.enqueue(episode());store.drainForTesting()
  #expect(store.status.failures == 1)
  store.enqueue(.init(event:.failed,values:[:]));store.drainForTesting()
  let terminal=try #require(rows(dir.appendingPathComponent("current.jsonl")).first)
  #expect(terminal.event == .failed && terminal.values["waitLogFailures"] == 1)
 }
}
