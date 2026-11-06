import Foundation
import Testing
@testable import VistaMedia
struct PlaybackLogTests {
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
}
