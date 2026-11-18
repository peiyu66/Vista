import Foundation
import Testing
import VistaCore
@testable import Adapter

@MainActor final class MemoryRead216:MediaByteSource {
 let bytes:Data;var ranges:[Range<UInt64>]=[]
 var hold=false,entered=false,failNext=false
 init(_ bytes:Data){self.bytes=bytes}
 func fileSize(for file:MediaFile)async throws->UInt64{UInt64(bytes.count)}
 func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data{
  ranges.append(range)
  if hold {entered=true}
  while hold{try await Task.sleep(for:.milliseconds(2));try Task.checkCancellation()}
  if failNext{failNext=false;throw URLError(.networkConnectionLost)}
  return bytes.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))
 }
}
@Suite(.serialized) @MainActor struct ReadPhase216AdapterTests {
 let mib=1_048_576
 func until(_ f:()->Bool)async throws{
  let deadline=ContinuousClock.now.advanced(by:.seconds(5))
  while !f(){try #require(ContinuousClock.now<deadline);try await Task.sleep(for:.milliseconds(2))}
 }
 func source(_ data:Data)async throws->(MemoryRead216,PlaybackPrefetchSource,SMBOperationSource,LocalWindowByteSource){
  let file=try MediaFile(components:["generated.bin"]),raw=MemoryRead216(data)
  let identity=PlaybackSourceIdentity(size:UInt64(data.count),modificationDate:Date(timeIntervalSince1970:100),creationDate:Date(timeIntervalSince1970:50))
  let recovery=PlaybackRecoveringSource(file:file,initial:raw,metadata:{_,_ in identity},makeFresh:{throw URLError(.notConnectedToInternet)},retire:{_ in},shouldRecover:{_ in false},isCurrent:{true},diagnostics:nil)
  let cache=PlaybackPrefetchSource(file:file,source:recovery)
  _=try await cache.fileSize(for:file)
  let owner=try await SMBOperationSource.create(file:file,playbackID:UUID(),cache:cache,identity:{identity},readRevision:{_ in},drain:{},journal:AdapterJournal(),vlcReadAheadEnabled:true)
  let window=try await owner.beginWindow(generation:1)
  cache.setPrefetchEnabled(false,reason:.pause)
  return(raw,cache,owner,window)
 }
 func callback(_ c:AsyncInputContext,_ offset:UInt64,_ count:Int)async->(Int,Data,Bool){
  await Task.detached{
   let output=UnsafeMutablePointer<UInt8>.allocate(capacity:count+16);defer{output.deallocate()}
   output.initialize(repeating:0xFD,count:count+16)
   let n=c.read(offset:offset,count:count,output:output)
   let untouched=(max(n,0)..<(count+16)).allSatisfy{output[$0]==0xFD}
   return(n,n>=0 ? Data(bytes:output,count:n):Data(),untouched)
  }.value
 }
 @Test func callbacksRespectCallerCapacityPhasesEOFAndGenerations()async throws {
  let data=Data((0..<(8*mib+17)).map{UInt8($0%251)})
  let (_,cache,owner,window)=try await source(data),context=AsyncInputContext(window:window)
  #expect(context.readLimit216==UInt64(mib));owner.setReadReference216(context.readLimit216)
  let first=await callback(context,0,4*mib);#expect(first.0==mib && first.1==data.prefix(mib) && first.2)
  context.setReadPhase216(.continuous);owner.setReadReference216(context.readLimit216)
  let next=await callback(context,UInt64(mib),4*mib);#expect(next.0==2*mib && next.1==data.subdata(in:mib..<3*mib) && next.2)
  for n in [1,65_536,262_144,524_288] {let r=await callback(context,UInt64(3*mib),n);#expect(r.0==n && r.1==data.subdata(in:3*mib..<3*mib+n) && r.2)}
  let tail=await callback(context,UInt64(data.count-17),17);#expect(tail.0==17 && tail.1==data.suffix(17) && tail.2)
  let bad=await callback(context,UInt64(data.count-10),20);#expect(bad.0 == -1 && bad.2)
  context.invalidate();if let t=context.taskAfterJoin(){await t.value};context.clearTaskAfterDrain()
  #expect((await callback(context,0,128)).0 == -1)
  let witness=try await owner.retireAndDrain(stamp:window.stamp);#expect(witness.confirmedBySourceOwner)
  let second=try await owner.beginWindow(generation:2),fresh=AsyncInputContext(window:second)
  #expect(fresh.readLimit216==UInt64(mib))
  let r=await callback(fresh,0,2*mib);#expect(r.0==mib && r.1==data.prefix(mib))
  fresh.invalidate();if let t=fresh.taskAfterJoin(){await t.value}
  _=try await owner.retireAndDrain(stamp:second.stamp);try await owner.closeAfterDrain()
  #expect(cache.readAheadFailures==0)
 }
 @Test func inFlightReadKeepsCapturedRangeAndCancellationDiscardsPublication()async throws {
  let data=Data(repeating:3,count:8*mib)
  let (raw,_,owner,window)=try await source(data),context=AsyncInputContext(window:window)
  raw.hold=true
  let read=Task{await callback(context,0,4*mib)}
  try await until{raw.entered}
  #expect(raw.ranges.last?.count==mib)
  context.setReadPhase216(.continuous);owner.setReadReference216(context.readLimit216)
  raw.hold=false
  let first=await read.value;#expect(first.0==mib)
  raw.hold=true;raw.entered=false
  let pending=Task{await callback(context,UInt64(4*mib),4*mib)}
  try await until{raw.entered}
  #expect(raw.ranges.last?.count==2*mib)
  context.setReadPhase216(.startup);context.invalidate();raw.hold=false
  let cancelled=await pending.value;#expect(cancelled.0 == -1 && cancelled.2)
  if let t=context.taskAfterJoin(){await t.value}
  #expect(context.snapshot().inFlight==0)
  _=try await owner.retireAndDrain(stamp:window.stamp);try await owner.closeAfterDrain()
 }
 @Test func optionalReadAheadUsesCurrentReferenceAndReturnsExactDemand()async throws {
  let data=Data((0..<(16*mib)).map{UInt8($0%239)})
  let (raw,cache,owner,window)=try await source(data)
  for (phase,base) in [(PlaybackReadPhase216.startup,0),(.continuous,8*mib)] {
   owner.setReadReference216(phase.bytes)
   for i in 0..<5 {
    let a=base+i*524_288,r=a..<a+524_288
    let result=try await owner.readVLCInput(stamp:window.stamp,file:owner.file,range:UInt64(r.lowerBound)..<UInt64(r.upperBound))
    #expect(result==data.subdata(in:r))
   }
   #expect(raw.ranges.contains{$0.lowerBound>=UInt64(base) && $0.count==Int(phase.bytes)})
  }
  #expect(cache.readAheadAttempts>=2 && cache.readAheadFailures==0)
  _=try await owner.retireAndDrain(stamp:window.stamp);try await owner.closeAfterDrain()
 }
 @Test func optionalReadAheadFailureFallsBackToOriginalDemand()async throws {
  let data=Data(repeating:17,count:8*mib)
  let (raw,cache,owner,window)=try await source(data)
  owner.setReadReference216(PlaybackReadPhase216.continuous.bytes)
  for i in 0..<2 {_=try await owner.readVLCInput(stamp:window.stamp,file:owner.file,range:UInt64(i*524_288)..<UInt64((i+1)*524_288))}
  raw.failNext=true
  let bytes=try await owner.readVLCInput(stamp:window.stamp,file:owner.file,range:UInt64(mib)..<UInt64(mib+524_288))
  #expect(bytes==data.subdata(in:mib..<mib+524_288))
  #expect(cache.readAheadFailures==1)
  #expect(raw.ranges.suffix(2).map(\.count)==[2*mib,524_288])
  _=try await owner.retireAndDrain(stamp:window.stamp);try await owner.closeAfterDrain()
 }
 @Test func realLocalOwnerAcceptsTwoMiBAndPreservesExactBytes()async throws {
  let data=Data(repeating:91,count:5*mib+31)
  let url=FileManager.default.temporaryDirectory.appendingPathComponent("local-read216-"+UUID().uuidString)
  try data.write(to:url);defer{try? FileManager.default.removeItem(at:url)}
  let owner=try LocalOperationSource.adoptCoordinatedURL(url,file:MediaFile(components:["local.bin"]),playbackID:UUID(),scopeLease:LocalSecurityScopeLease(root:url.deletingLastPathComponent(),acquired:false),journal:AdapterJournal())
  let window=try await owner.beginWindow(generation:1),context=AsyncInputContext(window:window)
  context.setReadPhase216(.continuous)
  let r=await callback(context,0,4*mib)
  #expect(r.0==2*mib && r.1==data.prefix(2*mib) && r.2)
  let tail=await callback(context,UInt64(data.count-31),31);#expect(tail.0==31 && tail.1==data.suffix(31) && tail.2)
  context.invalidate();if let t=context.taskAfterJoin(){await t.value}
  _=try await owner.retireAndDrain(stamp:window.stamp);try await owner.closeAfterDrain()
 }
 @Test func sustainedLargeDemandsKeepBytesOrderedWithoutMoreThanTwoMiBPerRead()async throws {
  let data=Data((0..<(32*mib)).map{UInt8(($0/4096)%251)})
  let (raw,_,owner,window)=try await source(data),context=AsyncInputContext(window:window)
  context.setReadPhase216(.continuous);owner.setReadReference216(context.readLimit216)
  var offset=0,output=Data()
  while offset<data.count {
   let r=await callback(context,UInt64(offset),min(4*mib,data.count-offset))
   try #require(r.0>0);#expect(r.2);output.append(r.1);offset+=r.0
  }
  #expect(output==data && raw.ranges.allSatisfy{$0.count<=2*mib})
  #expect(context.snapshot().peakInFlight==1 && context.snapshot().publishedBytes==data.count)
  context.invalidate();if let t=context.taskAfterJoin(){await t.value}
  _=try await owner.retireAndDrain(stamp:window.stamp);try await owner.closeAfterDrain()
 }
}
