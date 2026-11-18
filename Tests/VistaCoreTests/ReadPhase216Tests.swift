import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia
#if VISTA_READ_PHASE216
@MainActor private final class Phase216Source:MediaByteSource {
 let data=Data(repeating:0xA7,count:40*1_048_576)
 var ranges:[Range<UInt64>]=[],holdPrefetch=true,held=false
 func fileSize(for file:MediaFile)async throws->UInt64{UInt64(data.count)}
 func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data {
  ranges.append(range)
  if ranges.count>2 && holdPrefetch {held=true}
  while ranges.count>2 && holdPrefetch{try await Task.sleep(for:.milliseconds(2));try Task.checkCancellation()}
  return data.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))
 }
}
@Suite(.serialized) @MainActor struct ReadPhase216Tests {
 @Test func singleReferencesAndMP4Lifecycle()async throws {
  #expect(PlaybackReadReference216.startupBytes==1_048_576)
  #expect(PlaybackReadReference216.continuousBytes==2_097_152)
  #expect(MediaReadPlan.maximumChunkBytes==PlaybackReadPhase216.continuous.bytes)
  #expect(PlaybackPrefetchSource.Configuration().chunkBytes==Int(PlaybackReadPhase216.continuous.bytes))
  let source=Phase216Source(),file=try MediaFile(components:["test.bin"])
  let bridge=ResourceBridge(source:source,file:file,size:UInt64(source.data.count),contentType:"public.mpeg-4",chunkBytes:MediaReadPlan.nativeChunkBytes)
  let old=UUID(),new=UUID()
  for reason in [6,7,8] { // opening, manual reduction, automatic reduction
   bridge.beginReadPhase216(old,reason:reason)
   #expect(bridge.currentDemandChunkLimit==PlaybackReadPhase216.startup.bytes)
   bridge.deliveredSeekFrame(old,paused:true)
   #expect(bridge.currentDemandChunkLimit==PlaybackReadPhase216.startup.bytes)
   bridge.resumeSeekChunks()
   #expect(bridge.currentDemandChunkLimit==PlaybackReadPhase216.continuous.bytes)
  }
  bridge.beginReadPhase216(old,reason:7);bridge.beginSeekChunks(new)
  bridge.deliveredSeekFrame(old,paused:false);bridge.cancelSeekChunks(old)
  #expect(bridge.currentDemandChunkLimit==PlaybackReadPhase216.startup.bytes)
  bridge.deliveredSeekFrame(new,paused:false)
  #expect(bridge.currentDemandChunkLimit==PlaybackReadPhase216.continuous.bytes)
  await bridge.stop()
 }
 @Test func speculativePrefetchChangesOnlyNewReadsAndRetainsCapacity()async throws {
  let raw=Phase216Source(),file=try MediaFile(components:["prefetch.bin"])
  let id=PlaybackSourceIdentity(size:UInt64(raw.data.count),modificationDate:Date(timeIntervalSince1970:100),creationDate:Date(timeIntervalSince1970:50))
  let source=PlaybackRecoveringSource(file:file,initial:raw,metadata:{_,_ in id},makeFresh:{throw URLError(.notConnectedToInternet)},retire:{_ in},shouldRecover:{_ in false},isCurrent:{true},diagnostics:nil)
  let cache=PlaybackPrefetchSource(file:file,source:source)
  _=try await cache.fileSize(for:file)
  cache.setReadReference216(PlaybackReadPhase216.startup.bytes)
  cache.setPrefetchEnabled(true,reason:.disabled)
  let first=try await cache.read(file,range:0..<PlaybackReadPhase216.startup.bytes)
  #expect(first==raw.data.prefix(Int(PlaybackReadPhase216.startup.bytes)))
  let next=try await cache.read(file,range:PlaybackReadPhase216.startup.bytes..<(2*PlaybackReadPhase216.startup.bytes))
  #expect(next==first) // Two adjacent actual demands establish the existing forward window.
  let deadline=ContinuousClock.now.advanced(by:.seconds(3))
  while !raw.held && ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(2))}
  try #require(raw.held)
  let held=try #require(raw.ranges.last)
  #expect(held.count==Int(PlaybackReadPhase216.startup.bytes))
  cache.setReadReference216(PlaybackReadPhase216.continuous.bytes)
  #expect(raw.ranges.last==held)
  raw.holdPrefetch=false
  let finish=ContinuousClock.now.advanced(by:.seconds(3))
  while !raw.ranges.contains(where:{$0.count==Int(PlaybackReadPhase216.continuous.bytes)}) && ContinuousClock.now<finish {try await Task.sleep(for:.milliseconds(2))}
  #expect(raw.ranges.contains{$0.count==Int(PlaybackReadPhase216.continuous.bytes)})
  #expect(raw.ranges.allSatisfy{$0.count<=Int(PlaybackReadPhase216.continuous.bytes)})
  cache.cancelPlayback();try await cache.awaitPlaybackCleanup()
 }
}
#endif
