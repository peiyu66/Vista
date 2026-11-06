import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia
private actor CancellingSource:MediaByteSource {
 func fileSize(for file:MediaFile)async throws->UInt64 {4096}
 func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data {throw CancellationError()}
}
struct ReadCancellationTraceTests {
 @Test func firstInitiatorAndCompletionDelayArePreserved() {
  let t=ReadCancellationTrace(now:100),id=t.begin()
  t.reading(id,true);t.delivered(id,512);t.cancel(id,cleanup:false,now:100.1)
  t.cancel(id,cleanup:true,now:100.2);t.readCancelled(id);t.finish(id,now:100.4)
  let r=t.snapshot()[0]
  #expect(r.origin=="loader" && r.readingAtCancel && r.readThrewCancellation)
  #expect(abs((r.releaseMS ?? 0)-300)<0.001 && r.bytesDelivered==512)
 }
 @Test func cleanupBeforeReadIsNotAReadFailureAndRecordsAreBounded() {
  let t=ReadCancellationTrace(now:10)
  for n in 0..<100 {let id=t.begin();t.cancel(id,cleanup:true,now:11);t.finish(id,now:11+Double(n)/1000)}
  #expect(t.snapshot().count==64)
  #expect(t.snapshot().allSatisfy {$0.origin=="cleanup" && !$0.readingAtCancel && !$0.readThrewCancellation})
  #expect(t.text.contains("cleanup 0"))
 }
 @Test func boundedTraceOverhead() {
  let t=ReadCancellationTrace(),start=ProcessInfo.processInfo.systemUptime
  for _ in 0..<10000 {let id=t.begin();t.reading(id,true);t.cancel(id,cleanup:false);t.readCancelled(id);t.finish(id)}
  #expect(t.snapshot().count==64)
  print("TRACE_10000_REQUESTS_MS",(ProcessInfo.processInfo.systemUptime-start)*1000)
 }
 @Test func normalReadHasNoCancellationEvidence() {
  let t=ReadCancellationTrace();let id=t.begin();t.reading(id,true);t.delivered(id,256);t.reading(id,false);t.finish(id)
  #expect(t.snapshot().isEmpty)
 }
 @Test @MainActor func sourceCancellationIsNotMistakenForLoaderCancellation()async throws {
  let metrics=PlaybackMetrics(source:.synthetic)
  do { _=try await HardwarePlayback().play(file:MediaFile(components:["synthetic.mp4"]),source:CancellingSource(),metrics:metrics,onInfo:{_ in},onFrame:{_ in});Issue.record("Expected read failure") }
  catch { }
  let rows=metrics.cancellationTrace.snapshot().filter(\.readThrewCancellation)
  #expect(!rows.isEmpty)
  #expect(rows.allSatisfy {$0.origin=="source" && $0.cancelAtMS==nil})
  print("TRACE_SOURCE_CANCEL",rows.map {"\($0.request):\($0.origin):\(Int($0.finishedAtMS))ms"})
 }
}
