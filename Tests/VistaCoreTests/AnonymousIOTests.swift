import Testing
import Foundation
@testable import VistaMedia
@testable import VistaCore
#if VISTA_ANON_IO_EXPERIMENT
struct AnonymousIOTests {
 @Test @MainActor func oldReadsRemainUntilCompletionAndSnapshotsFreeze() {
  let a=AnonymousIOAggregate();a.beginEpoch(now:0)
  let old=a.begin(now:0.1);a.beginEpoch(now:1)
  let fresh=a.begin(now:1.1),before=a.snapshot()
  #expect(before.oldAtStart==1 && before.oldRemaining==1 && before.inFlight==2)
  a.end(old,now:1.5,bytes:500,cancelled:true,failed:false)
  a.end(fresh,now:1.7,bytes:100,cancelled:false,failed:false)
  a.end(fresh,now:2,bytes:100,cancelled:false,failed:false)
  let after=a.snapshot();#expect(after.finished==1 && after.bytes==100 && after.oldRemaining==0 && after.lastOldMS==500)
  #expect(before.oldRemaining==1 && before.finished==0)
  #expect(after.text.hasPrefix("I/O 起1 完1 取消0 錯0 在途0"))
 }
 @Test @MainActor func boundedSlotsFailureAndAggregateOverhead() {
  let a=AnonymousIOAggregate();a.beginEpoch(now:0)
  let ids=(0..<8).map{a.begin(now:Double($0))};#expect(a.begin(now:9)==nil && a.overflow==1)
  for id in ids {a.end(id,now:10,bytes:0,cancelled:false,failed:true)}
  #expect(a.snapshot().failed==8 && a.snapshot().inFlight==0)
  let start=ContinuousClock.now
  for i in 0..<10000 {let t=Double(i);let id=a.begin(now:t);a.end(id,now:t+0.01,bytes:262144,cancelled:false,failed:false)}
  print("ANON_IO_10000",start.duration(to:.now))
  #expect(a.snapshot().inFlight==0 && a.snapshot().peak==8)
 }
}
#endif

#if VISTA_ANON_IO_EXPERIMENT
private struct AnonymousCanarySource:MediaByteSource {
 let data:Data
 func fileSize(for file:MediaFile)async throws->UInt64{UInt64(data.count)}
 func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data {try Task.checkCancellation();return data.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))}
}
extension AnonymousIOTests {
 @Test @MainActor func sessionOutputOmitsSyntheticIdentity()async throws {
  let source=AnonymousCanarySource(data:try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!))
  let session=NativePlaybackSession(stallLimit:5,muted:true);var report=""
  do {try await session.play(file:MediaFile(components:["CANARY-host","CANARY-user-secret.mp4"]),source:source,onInfo:{_ in},onState:{_ in},onFrame:{frame in session.recordPresentation(session:frame.session);report=session.diagnosticsText;session.stop()})}catch is CancellationError {}
  #expect(report.contains("呈現 I/O 起") && !report.contains("CANARY") && !report.contains(".mp4") && !report.contains("smb://"))
 }
}
#endif
