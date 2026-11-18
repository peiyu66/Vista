import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia
@testable import VistaSMB

#if DEBUG || VISTA_DIAGNOSTICS
@Suite(.serialized) @MainActor struct MP4SeekDiagnosticsTests {
 typealias Stage=MP4SeekDiagnostics.Stage
 typealias Fixture=PlaybackRangeDiagnosticsTests
 func setup(limit:Int=4096)->(URL,LifecycleDiagnostics) {
  let url=FileManager.default.temporaryDirectory.appendingPathComponent("VistaSeekTest-"+UUID().uuidString)
  return (url,LifecycleDiagnostics(directory:url,build:"0",fileLimit:1_048_576,pendingLimit:limit,mirror:false,criticalDurability:false))
 }
 func rows(_ url:URL,_ writer:LifecycleDiagnostics)throws->[LifecycleRecord] {
  writer.drainForTesting()
  return try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:nil)
   .filter{$0.pathExtension=="jsonl"}.flatMap {try Data(contentsOf:$0).split(separator:10).map{try JSONDecoder().decode(LifecycleRecord.self,from:Data($0))}}
   .filter{$0.event == .mp4Seek}.sorted{$0.sequence<$1.sequence}
 }
 func isStage(_ row:LifecycleRecord,_ stage:Stage)->Bool{row.fields["phase"]==Double(stage.rawValue)}
 func read(_ w:PlaybackPrefetchSource,_ trace:MP4SeekDiagnostics,_ range:Range<UInt64>,chunk:UInt64,epoch:Int=7)async throws->Data {
  try await MP4SeekDiagnosticContext.$trace.withValue(trace) {
   try await PlaybackReadDiagnosticContext.$correlation.withValue(.init(bridge:9,request:chunk,chunk:chunk,seek:epoch)) {
    try await w.read(MediaFile(components:["generated.mp4"]),range:range)
   }
  }
 }
 @Test func geometryCountsUnionAndDistinguishesHolesFromOutside() {
  let v=MP4SeekDiagnostics.cacheFields(range:0..<40,spans:[20..<30,10..<18,15..<22])
  #expect(v[.cacheOverlapBytes]==20 && v[.cacheBeforeBytes]==10 && v[.cacheAfterBytes]==10 && v[.cacheHoleBytes]==0)
  let hole=MP4SeekDiagnostics.cacheFields(range:8..<32,spans:[10..<15,20..<25])
  #expect(hole[.cacheOverlapBytes]==10 && hole[.cacheHoleBytes]==5 && hole[.cacheBeforeBytes]==2 && hole[.cacheAfterBytes]==7)
  #expect(MP4SeekDiagnostics.cacheFields(range:100..<110,spans:[])[.cacheEmpty]==1)
  #expect(MP4SeekDiagnostics.cacheFields(range:100..<110,spans:[])[.cacheHoleBytes]==nil)
  // Compare overlapping intervals against an independent byte-set oracle.
  for seed in 0..<200 {
   let spans=(0..<7).map { i -> Range<UInt64> in
    let lo=UInt64((seed*7+i*13)%45);return lo..<(lo+UInt64((seed+i*3)%10))
   }
   let r=UInt64(seed%19)..<UInt64(20+seed%37),v=MP4SeekDiagnostics.cacheFields(range:r,spans:spans)
   let occupied=Set(spans.flatMap{Array($0)})
   #expect(v[.cacheOverlapBytes]==Double(r.filter{occupied.contains($0)}.count))
   if !occupied.isEmpty {#expect(v[.cacheBeforeBytes]! + v[.cacheAfterBytes]! + v[.cacheHoleBytes]! + v[.cacheOverlapBytes]! == Double(r.count))}
  }
 }
 @Test func boundedDetailPreservesBoundaryAndExposesSuppression()throws {
  let (url,writer)=setup();let trace=MP4SeekDiagnostics(epoch:7,target:42,sourceKind:2,writer:writer)
  writer.withPausedWriterForTesting {
   for _ in 0..<(MP4SeekDiagnostics.detailLimit+9) {trace.record(.bridgeStarted)}
   trace.record(.seekIssued,boundary:true);trace.record(.seekIssued,boundary:true)
   trace.close(2);trace.record(.smbReturned);trace.close(3)
  }
  let all=try rows(url,writer)
  #expect(all.filter{isStage($0,.bridgeStarted)}.count==MP4SeekDiagnostics.detailLimit)
  #expect(all.filter{isStage($0,.seekIssued)}.count==1)
  #expect(all.filter{isStage($0,.terminal)}.count==1)
  #expect(all.last?.fields["diagnosticSuppressed"]==9 && all.last?.fields["detail"]==2)
  #expect(writer.status.dropped==0 && writer.status.writerFailures==0)
  #expect(all.allSatisfy{$0.fields["nativeClock"] != nil && $0.fields["epoch"]==7})
 }
 @Test func writerPressureIsReportedAndNewSeekGetsNewBudget()throws {
  let (url,writer)=setup(limit:3)
  let first=MP4SeekDiagnostics(epoch:1,target:1,sourceKind:1,writer:writer)
  writer.withPausedWriterForTesting {
   for _ in 0..<100 {first.record(.bridgeStarted)}
   first.close(2)
  }
  let second=MP4SeekDiagnostics(epoch:2,target:2,sourceKind:1,writer:writer)
  second.record(.bridgeStarted);second.close(3)
  let all=try rows(url,writer)
  #expect(writer.status.dropped>0)
  #expect(all.contains{$0.dropped>0})
  #expect(first.id != second.id)
  #expect(all.last?.fields["diagnosticCount"]==1 && all.last?.fields["diagnosticSuppressed"]==0)
 }
 @Test func realWrapperDistinguishesFullPartialMissAndRejectedCache()async throws {
  for reject in [false,true] {
   let (url,writer)=setup(),fixture=Fixture(),source=Fixture.Source(),w=fixture.wrapper(source)
   let trace=MP4SeekDiagnostics(epoch:7,target:12,sourceKind:2,writer:writer);w.seekDiagnostics=trace
   _=try await read(w,trace,4..<8,chunk:1);_=try await read(w,trace,12..<16,chunk:2)
   let calls=source.reads
   _=try await read(w,trace,4..<8,chunk:3);#expect(source.reads==calls)
   source.reject=reject
   _=try await read(w,trace,2..<18,chunk:4)
   trace.close(1);w.seekDiagnostics=nil;try await w.awaitPlaybackCleanup()
   let all=try rows(url,writer)
   let full=try #require(all.first{isStage($0,.wrapperReturned) && $0.fields["chunkID"]==3})
   #expect(full.fields["usedCacheBytes"]==4 && full.fields["selectedCacheBytes"]==4)
   #expect(!all.contains{isStage($0,.sourceStarted) && $0.fields["chunkID"]==3})
   let selection=try #require(all.first{isStage($0,.cacheSelection) && $0.fields["chunkID"]==4})
   #expect(selection.fields["cacheOverlapBytes"]==8 && selection.fields["cacheHoleBytes"]==4)
   #expect(selection.fields["cacheBeforeBytes"]==2 && selection.fields["cacheAfterBytes"]==2)
   let partial=try #require(all.first{isStage($0,.wrapperReturned) && $0.fields["chunkID"]==4})
   #expect(partial.fields["usedCacheBytes"]==Double(reject ? 0:8))
   let starts=all.filter{isStage($0,.sourceStarted)},ends=all.filter{isStage($0,.sourceReturned)}
   #expect(starts.count==3 && ends.count==3)
   for start in starts {
    let end=try #require(ends.first{$0.fields["sourceCallID"]==start.fields["sourceCallID"]})
    #expect(end.fields["finishedAt"]!>=start.fields["startedAt"]!)
    #expect(start.fields["readSeekEpoch"]==7 && start.fields["bridgeID"]==9)
   }
  }
 }
 @Test func queuedWaitAndCancellationPreserveOriginalSeekIdentity()async throws {
  let (url,writer)=setup(),fixture=Fixture(),source=Fixture.Source(),w=fixture.wrapper(source)
  let old=MP4SeekDiagnostics(epoch:1,target:1,sourceKind:2,writer:writer);w.seekDiagnostics=old
  source.hold=true
  let first=Task{try await read(w,old,0..<8,chunk:1,epoch:1)}
  try await fixture.until{source.gate != nil}
  old.close(2)
  let next=MP4SeekDiagnostics(epoch:2,target:2,sourceKind:2,writer:writer);w.seekDiagnostics=next
  let second=Task{try await read(w,next,16..<24,chunk:2,epoch:2)}
  try await fixture.until{w.rangeDiagnosticSnapshot().queued.count==1}
  second.cancel()
  do{_=try await second.value;Issue.record("cancelled queued request returned")}catch is CancellationError{}
  source.release();_=try await first.value
  next.close(3);w.seekDiagnostics=nil;try await w.awaitPlaybackCleanup()
  let all=try rows(url,writer)
  let oldReturn=try #require(all.first{isStage($0,.sourceReturned) && $0.fields["chunkID"]==1})
  #expect(oldReturn.fields["epoch"]==2 && oldReturn.fields["readSeekEpoch"]==1)
  let cancelled=try #require(all.first{isStage($0,.wrapperCancelled) && $0.fields["chunkID"]==2})
  #expect(cancelled.fields["startedAt"]==nil && cancelled.fields["finishedAt"]!>=cancelled.fields["queuedAt"]!)
  #expect(!all.contains{isStage($0,.sourceStarted) && $0.fields["chunkID"]==2})
 }
 @Test func queuedRequestRetainsContextAcrossExistingPumpTask()async throws {
  let (url,writer)=setup(),fixture=Fixture(),source=Fixture.Source(),w=fixture.wrapper(source)
  source.hold=true
  let first=Task{try await w.read(fixture.file,range:0..<8)}
  try await fixture.until{source.gate != nil}
  let trace=MP4SeekDiagnostics(epoch:7,target:42,sourceKind:2,writer:writer);w.seekDiagnostics=trace
  let queued=Task{try await read(w,trace,16..<24,chunk:8)}
  try await fixture.until{w.rangeDiagnosticSnapshot().queued.count==1}
  source.release();_=try await first.value;_=try await queued.value
  trace.close(1);w.seekDiagnostics=nil;try await w.awaitPlaybackCleanup()
  let all=try rows(url,writer)
  let work=try #require(all.first{isStage($0,.wrapperReturned) && $0.fields["chunkID"]==8})
  #expect(work.fields["startedAt"]!>=work.fields["queuedAt"]!)
  #expect(all.contains{isStage($0,.sourceStarted) && $0.fields["chunkID"]==8 && $0.fields["readSeekEpoch"]==7})
 }
 private actor MemoryTransport:SMBRangeTransport {
  let data:Data,fail:Bool
  init(_ data:Data,fail:Bool=false){self.data=data;self.fail=fail}
  func attributes(at path:String) async throws->[URLResourceKey:any Sendable] {
   [.fileResourceTypeKey:URLFileResourceType.regular,.fileSizeKey:UInt64(data.count)]
  }
  func read(at path:String,range:Range<UInt64>) async throws->Data {
   try await Task.sleep(for:.milliseconds(2))
   if fail {throw URLError(.networkConnectionLost)}
   return data.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))
  }
 }
 @Test func actualSMBReaderKeepsSubrangeIdentityAndErrorBoundary()async throws {
  for fail in [false,true] {
   let (url,writer)=setup()
   // Use a single trace writer for the asserted records; ordinary reader log is independent.
   let seek=MP4SeekDiagnostics(epoch:7,target:42,sourceKind:2,writer:writer)
   let reader=SMBMediaReader(transport:MemoryTransport(Data(repeating:3,count:40),fail:fail),diagnostics:setup().1,session:99)
   do {
    let data=try await MP4SeekDiagnosticContext.$trace.withValue(seek) {
     try await PlaybackReadDiagnosticContext.$correlation.withValue(.init(bridge:4,request:5,chunk:6,seek:7)) {
      try await reader.playbackRead(MediaFile(components:["must-not-appear-in-log.mp4"]),range:12..<20)
     }
    }
    #expect(!fail && data.count==8)
   }catch{#expect(fail)}
   seek.close(1)
   let all=try rows(url,writer)
   let start=try #require(all.first{isStage($0,.smbStarted)}),end=try #require(all.first{isStage($0,fail ? .smbFailed:.smbReturned)})
   #expect(start.fields["rangeLower"]==12 && start.fields["rangeUpper"]==20)
   #expect(start.fields["sourceCallID"]==end.fields["sourceCallID"] && end.fields["session"]==99)
   #expect(end.fields["chunkID"]==6 && end.fields["finishedAt"]!>=start.fields["startedAt"]!)
   #expect(!String(decoding:try JSONEncoder().encode(all),as:UTF8.self).contains("must-not-appear"))
  }
 }
 @Test func actualAVPlayerSeekReportsProxyBoundariesAndReadLinks()async throws {
  let (url,writer)=setup(),fixture=Fixture()
  let bytes=try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!)
  let reader=SMBMediaReader(transport:MemoryTransport(bytes),diagnostics:setup().1,session:100)
  let native=NativePlaybackSession(stallLimit:5,muted:true)
  native.mp4SeekWriterForTesting=writer
  var frames=0,lastSession:UUID?
  let task=Task {
   try await native.play(file:MediaFile(components:["synthetic.mp4"]),source:reader,onInfo:{_ in},onState:{_ in},onFrame:{frame in
    frames+=1;lastSession=frame.session;native.recordPresentation(session:frame.session)
   })
  }
  do {
   try await fixture.until{frames>=2}
   native.pause();let oldSession=try #require(lastSession)
   let seek=Task{try await native.seek(to:3.5,maximumBackward:0,maximumForward:0)}
   await Task.yield();native.recordPresentation(session:oldSession)
   try await seek.value
   let count=frames;native.resume()
   try await fixture.until{frames>count}
   native.stop();task.cancel();_=try? await task.value
   let all=try rows(url,writer)
   let stages:[Stage]=[.entered,.seekIssued,.seekAwaitReturned,.outputAvailable,.copyStarted,.copyReturned,.frameDelivered,.presentationNotified,.closingState,.terminal]
   var prior = -Double.infinity
   for stage in stages {
    let row=try #require(all.first{isStage($0,stage)})
    #expect(all.filter{isStage($0,stage)}.count==1)
    let at=try #require(row.fields["nativeClock"]);#expect(at>=prior);prior=at
   }
   #expect(all.last?.fields["detail"]==1)
   let chunks=all.filter{isStage($0,.bridgeStarted)}
   for chunk in chunks {
    #expect(all.contains{(isStage($0,.bridgeResponded) || isStage($0,.bridgeFailed)) && $0.fields["chunkID"]==chunk.fields["chunkID"]}
     || (all.first{isStage($0,.closingState)}?.fields["active"] ?? 0)>0) // unfinished work is explicit
   }
   #expect(writer.status.writerFailures==0 && writer.status.dropped==0)
   print("MP4_SEEK_AVPLAYER_TRACE rows",all.count,"chunks",chunks.count,"terminal",all.last?.fields["detail"] ?? -1)
  }catch {
   native.stop();task.cancel();_=try? await task.value;throw error
  }
 }

}
#endif
