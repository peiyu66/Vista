import Foundation
import Testing
@testable import VistaCore

@Suite(.serialized) @MainActor struct PlaybackSupplyDiagnosticsTests {
 @Test func sourceReturnIsNotDeliveryAndEpochIsNotRewritten() {
  var d=PlaybackSupplyDiagnostics()
  d.beginWork(kind:.demand,id:9,generation:2,epoch:3,now:1)
  d.beginCall(kind:.cachedSegments,now:1.01)
  d.cancelWork(id:9)
  let during=d.snapshot(session:1,generation:4,epoch:5,queueDepth:2,oldestQueuedAt:0.9)
  #expect(during.work?.cancelled == true && during.work?.epoch == 3 && during.epoch == 5)
  #expect(during.call?.kind == .cachedSegments && during.queueDepth == 2 && during.oldestQueuedAt == 0.9)
  d.endCall(result:.returned,bytes:8,now:1.1);d.endWork()
  let after=d.snapshot(session:1,generation:4,epoch:5,queueDepth:0,oldestQueuedAt:nil)
  #expect(after.work == nil && after.call == nil && after.lastReturn?.result == .returned)
  #expect(after.lastReturn?.call.work.epoch == 3 && after.lastReturn?.bytes == 8)
  // The source returned bytes. This API deliberately makes no delivery claim.
 }
 @Test func cancellationDomainsAndLastReturnRemainFixedSize() {
  var d=PlaybackSupplyDiagnostics()
  for i in 1...10_000 {
   d.beginWork(kind:.prefetch,id:UInt64(i),generation:2,epoch:3,now:Double(i))
   d.beginCall(kind:.prefetch,now:Double(i));d.cancelWork(id:UInt64(i))
   #expect(d.work?.cancelled == false)
   d.endCall(result:.cancelled,bytes:0,now:Double(i)+0.1);d.endWork()
  }
  #expect(d.lastReturn?.call.work.id == 10_000 && d.lastReturn?.result == .cancelled)
  d.beginWork(kind:.demand,id:8,generation:4,epoch:nil,now:20_000)
  d.beginCall(kind:.read,now:20_000);d.endCall(result:.failed,bytes:0,now:20_001)
  #expect(d.lastReturn?.result == .failed && d.lastReturn?.call.work.epoch == nil)
 }
 @MainActor private final class Source:PlaybackCacheSource {
  var token:UInt64?=1,epochCalls=0
  var inspect:(()->Void)?
  var hold=false,gate:CheckedContinuation<Void,Never>?
  func release(){hold=false;let old=gate;gate=nil;old?.resume()}
  var isPlaybackRecovering:Bool{false}
  var recoveryActiveStartedAt:TimeInterval?{nil}
  var recoveryActiveElapsed:TimeInterval{0}
  func playbackCacheEpoch()throws->UInt64?{epochCalls += 1;return token}
  func setPlaybackSceneActive(_ active:Bool){}
  func cancelPlayback(){}
  func awaitPlaybackCleanup()async throws{}
  func fileSize(for file:MediaFile)async throws->UInt64{inspect?();return 128}
  func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data{inspect?();if hold {await withCheckedContinuation{gate=$0}};return Data(repeating:1,count:range.count)}
  func readForPrefetch(_ file:MediaFile,range:Range<UInt64>)async throws->Data{inspect?();return Data(repeating:1,count:range.count)}
 }
 @Test func wrapperHooksIdentifySizeReadAndDoNotValidateOnSnapshot() async throws {
  let f=try MediaFile(components:["generated.mp4"]),s=Source()
  let w=PlaybackPrefetchSource(file:f,source:s,configuration:.init(capacityBytes:16,chunkBytes:8,totalCapacityBytes:64))
  s.inspect={let snap=w.supplyDiagnosticSnapshot();#expect(snap.call?.kind == .size && snap.work?.kind == .size)}
  _=try await w.fileSize(for:f)
  s.inspect={let snap=w.supplyDiagnosticSnapshot();#expect(snap.call?.kind == .read && snap.work?.kind == .demand)}
  _=try await w.read(f,range:0..<8)
  let calls=s.epochCalls
  let snap=w.supplyDiagnosticSnapshot()
  #expect(snap.lastReturn?.call.kind == .read && snap.lastReturn?.bytes == 8 && snap.lastReturn?.result == .returned)
  #expect(w.diagnosticObservedEpoch == 1 && s.epochCalls == calls)
  try await w.awaitPlaybackCleanup()
 }
 private func until(_ predicate:()->Bool) async throws {
  for _ in 0..<1000 {if predicate(){return};try await Task.sleep(for:.milliseconds(1))}
  Issue.record("Pure Data diagnostic fixture did not settle")
 }
 @Test func queuedCancellationAndSourceEpochReturnStayDistinct() async throws {
  let f=try MediaFile(components:["generated.mp4"]),s=Source()
  let w=PlaybackPrefetchSource(file:f,source:s,configuration:.init(capacityBytes:16,chunkBytes:8,totalCapacityBytes:64))
  _=try await w.fileSize(for:f);s.hold=true
  let first=Task{try await w.read(f,range:0..<8)}
  try await until{s.gate != nil}
  let second=Task{try await w.read(f,range:8..<16)}
  try await until{w.supplyDiagnosticSnapshot().queueDepth == 1}
  let snapshot=w.supplyDiagnosticSnapshot(),calls=s.epochCalls
  #expect(snapshot.work?.kind == .demand && snapshot.work?.epoch == 1 && snapshot.oldestQueuedAt != nil)
  for _ in 0..<10 {_=w.supplyDiagnosticSnapshot()};#expect(s.epochCalls == calls)
  first.cancel();try await until{w.supplyDiagnosticSnapshot().work?.cancelled == true}
  // Source still returns successfully; wrapper cancellation rejects the payload.
  s.token=2;s.release()
  do {_=try await first.value;Issue.record("Cancelled wrapper demand delivered")}catch is CancellationError{}
  _=try await second.value
  let after=w.supplyDiagnosticSnapshot()
  #expect(after.epoch == 2 && after.lastReturn?.call.work.epoch == 1 && after.lastReturn?.call.observedEpoch == 2 && after.lastReturn?.result == .returned)
  try await w.awaitPlaybackCleanup()
 }
 @Test func prefetchAndFullCacheHitDoNotMasqueradeAsSourceDemand() async throws {
  let f=try MediaFile(components:["generated.mp4"]),s=Source()
  let w=PlaybackPrefetchSource(file:f,source:s,configuration:.init(capacityBytes:16,chunkBytes:8,totalCapacityBytes:64))
  _=try await w.fileSize(for:f);w.setPrefetchEnabled(true)
  var observations=0
  s.inspect={let snap=w.supplyDiagnosticSnapshot();if snap.call?.kind == .prefetch {
   observations += 1;#expect(snap.work?.kind == .prefetch && snap.call?.work.kind == .prefetch)
  }}
  _=try await w.read(f,range:0..<8);_=try await w.read(f,range:8..<16)
  try await until{observations == 2 && w.supplyDiagnosticSnapshot().work == nil}
  let last=w.supplyDiagnosticSnapshot().lastReturn
  _=try await w.read(f,range:0..<8)
  #expect(w.supplyDiagnosticSnapshot().lastReturn == last)
  #expect(last?.call.kind == .prefetch && last?.bytes == 8)
  try await w.awaitPlaybackCleanup()
 }

}
