import Foundation
import CoreGraphics
@main struct InputLogTests {
 @MainActor static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
  let directory=root.appendingPathComponent("VistaShortcutDiagnostics")
  #if DEBUG || VISTA_DIAGNOSTICS
  let log=ShortcutInputLog(directory:directory)
  var emitted:[ShortcutInputMemoryProbe.Event]=[]
  var now=100.0
  let p=ShortcutInputMemoryProbe(clock:{now},sink:{emitted.append($0);log.persist($0)})
  let a=UUID(),b=UUID()
  func input(_ kind:ShortcutInputMemoryProbe.Kind,_ id:UUID,_ x:Double=10) {
   p.input(kind,id:id,ordinal:id==a ? 1:2,point:CGPoint(x:x,y:22),rect:CGRect(x:0,y:10,width:200,height:54),viewport:CGSize(width:300,height:500),offset:4,contentHeight:900,about:false,removing:false,playback:false)
  }
  input(.changed,a);precondition(p.events.isEmpty)
  p.editing(true);p.highlight(true,id:a);input(.changed,a);now += 0.01;input(.changed,a,12)
  p.scroll(offset:5);now += 0.005;p.scroll(offset:20)
  p.lifecycle(.inactive,id:a);p.boundary(.cleared,active:a);input(.ended,a)
  input(.changed,b);input(.ended,b);p.lifecycle(.inactive,id:b)
  p.editing(false)
  precondition(emitted.map(\.kind)==[.captureStarted,.highlightActive,.changed,.scroll,.inactive,.cleared,.ended,.changed,.ended,.inactive,.captureStopped])
  precondition(emitted[2].count==2 && emitted[2].firstContext?.x==10 && emitted[2].context?.x==12)
  precondition(emitted[3].firstOffset==5 && emitted[3].offset==20)
  let count=emitted.count;input(.changed,a);p.scroll(offset:99);precondition(emitted.count==count)
  // Test real asynchronous writer output, not just a fake sink or successful compile.
  let file=directory.appendingPathComponent("current.jsonl")
  var text=""
  for _ in 0..<500 {
   text=(try? String(contentsOf:file,encoding:.utf8)) ?? ""
   if text.contains("\"inputKind\":10") {break}
   Thread.sleep(forTimeInterval:0.01)
  }
  let lines=try text.split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
  let inputLines=lines.filter{$0["event"] as? String == "shortcutInput"}
  precondition(inputLines.count==11,"all start/end and coalesced groups must persist")
  precondition(!text.contains(a.uuidString) && !text.contains(b.uuidString))
  precondition(!text.contains("critical-"))
  for record in inputLines {
   let fields=record["fields"] as! [String:Double]
   precondition(fields["scope"]==212 && fields["handleFrame"]==44 && fields["targetDiameter"]==36 && fields["targetInset"]==4)
  }
  // Independent memory bounds, alias bounds and unknown-attempt behavior.
  let memory=ShortcutInputMemoryProbe()
  memory.begin()
  for _ in 0..<1000 {memory.boundary(.cleared);memory.boundary(.editingChanged)}
  precondition(memory.events.count==128 && memory.discardedGroups==1873)
  memory.stop();memory.begin();memory.lifecycle(.inactive,id:UUID());precondition(memory.events.count==1)
  precondition(memory.snapshot().contains("inactive is not proof of cancellation"))
  print("PASS Diagnostic: actual JSONL, automatic editing capture, coalescing, both inactive/end orders, stopped no-op, anonymous data, bounded memory")
  #else
  // Exercise the exact shared writer with every event/field defined for this diagnostic.
  let writer=LifecycleDiagnostics(directory:directory,mirror:false,criticalDurability:false)
  for i in 1...12 {writer.record(.shortcutInput,[.scope:212,.inputKind:Double(i),.row:1])}
  Thread.sleep(forTimeInterval:0.05)
  precondition(!FileManager.default.fileExists(atPath:directory.path))
  let legacy=root.appendingPathComponent("existing-logs");try FileManager.default.createDirectory(at:legacy,withIntermediateDirectories:true)
  let sentinel=legacy.appendingPathComponent("current.jsonl");let old=Data("historic-do-not-touch".utf8);try old.write(to:sentinel)
  try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1)],ofItemAtPath:sentinel.path)
  let writerWithOld=LifecycleDiagnostics(directory:legacy,mirror:false,criticalDurability:false);writerWithOld.record(.shortcutInput,[.scope:212])
  Thread.sleep(forTimeInterval:0.05)
  let retained=try Data(contentsOf:sentinel);precondition(retained==old)
  let modification=try FileManager.default.attributesOfItem(atPath:sentinel.path)[.modificationDate] as! Date;precondition(modification.timeIntervalSince1970==1)
  print("PASS Release: exact diagnostic writer invoked, no new log; existing old log bytes and mtime unchanged")
  #endif
 }
}
