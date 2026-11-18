import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import VistaCore
@testable import VistaMedia
#if VISTA_EARLY_SEEK_PLAY
private final class Seek216Events: @unchecked Sendable {
 private let lock=NSLock();private var items:[String]=[]
 func add(_ value:String){lock.lock();items.append(value);lock.unlock()}
 var values:[String]{lock.lock();defer{lock.unlock()};return items}
}
@Suite(.serialized) @MainActor struct SeekEarly216SubmissionTests {
 @Test func deferredCompletionDoesNotDelayPlay() async throws {
  let events=Seek216Events();var completion:(@Sendable(Bool)->Void)?
  let task=Task {await SeekPlaybackSubmission216.perform(submit:{callback in events.add("seek");completion=callback},afterSubmission:{events.add("play")},completionObserved:{_ in events.add("callback")})}
  while completion==nil {await Task.yield()}
  #expect(events.values == ["seek","play"])
  completion?(true);#expect(await task.value)
  #expect(events.values == ["seek","play","callback"])
 }
 @Test func synchronousCompletionAndInterruptedCompletion() async {
  for success in [true,false] {
   let events=Seek216Events()
   let result=await SeekPlaybackSubmission216.perform(submit:{callback in events.add("seek");callback(success)},afterSubmission:{events.add("intent")},completionObserved:{_ in events.add("callback")})
   #expect(result==success)
   #expect(events.values == ["seek","callback","intent"])
  }
 }
}
@MainActor private final class Seek216Source:MediaByteSource {
 let bytes:Data;var reads:[Range<UInt64>]=[]
 var hold=false,enteredHold=false
 init(_ bytes:Data){self.bytes=bytes}
 func fileSize(for file:MediaFile) async throws->UInt64{UInt64(bytes.count)}
 func read(_ file:MediaFile,range:Range<UInt64>) async throws->Data {
  reads.append(range)
  if hold {enteredHold=true}
  while hold {try await Task.sleep(for:.milliseconds(5));try Task.checkCancellation()}
  try await Task.sleep(for:.milliseconds(3));try Task.checkCancellation()
  return bytes.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))
 }
}
@Suite(.serialized) @MainActor struct SeekEarly216IntegrationTests {
 enum Failure:Error{case timeout}
 func until(_ condition:()->Bool)async throws{
  let deadline=ContinuousClock.now.advanced(by:.seconds(15))
  while !condition(){guard ContinuousClock.now<deadline else{throw Failure.timeout};try await Task.sleep(for:.milliseconds(5))}
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["VISTA_SEEK215_FIXTURE"] != nil))
 func realPlayerPauseRateSupersedeAndSourceStop() async throws {
  let path=try #require(ProcessInfo.processInfo.environment["VISTA_SEEK215_FIXTURE"])
  let source=Seek216Source(try Data(contentsOf:URL(fileURLWithPath:path)))
  let native=NativePlaybackSession(stallLimit:12,muted:true)
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent("vista-seek216-"+UUID().uuidString)
  let writer=LifecycleDiagnostics(directory:dir,fileLimit:4_194_304,pendingLimit:2048,mirror:false,criticalDurability:false)
  native.mp4SeekWriterForTesting=writer
  var frames:[(UUID,Double)]=[],whilePending=0
  let playback=Task {try await native.play(file:MediaFile(components:["synthetic216.mp4"]),source:source,onInfo:{_ in},onState:{_ in},onFrame:{f in
   if native.experimentSeekPending{whilePending+=1}
   frames.append((f.session,f.time));native.recordPresentation(session:f.session)
  })}
  var secondSource:Seek216Source?
  var secondPlayback:Task<Void,Error>?
  do {
   try await until{frames.count>=2}
   #expect(native.setSpeed(2))
   source.hold=true
   let seek=Task{try await native.seek(to:24,maximumBackward:0)}
   try await until{native.experimentSeekPending && source.enteredHold}
   #expect(native.experimentPlayer?.rate==2)
   #expect(native.experimentCurrentDemandChunkLimit==1_048_576)
   native.pause();#expect(native.isPlaybackPaused && native.experimentPlayer?.rate==0)
   #expect(native.setSpeed(1.5));#expect(native.experimentPlayer?.rate==0)
   native.resume();#expect(native.experimentPlayer?.rate==1.5)
   #expect(native.setSpeed(1));#expect(native.experimentPlayer?.rate==1)
   native.pause()
   source.hold=false;try await seek.value
   #expect(native.isPlaybackPaused && native.experimentPlayer?.rate==0)
   native.resume()
   try await until{frames.contains{$0.1>=24 && $0.1<25} && native.experimentCurrentDemandChunkLimit==2_097_152}
   native.stop();playback.cancel();_=try? await playback.value
   // A fresh source avoids assuming a prior seek's AVPlayer cache is empty.
   let nextSource=Seek216Source(source.bytes);secondSource=nextSource
   frames=[]
   secondPlayback=Task {try await native.play(file:MediaFile(components:["second216.mp4"]),source:nextSource,onInfo:{_ in},onState:{_ in},onFrame:{f in
    if native.experimentSeekPending{whilePending+=1}
    frames.append((f.session,f.time));native.recordPresentation(session:f.session)
   })}
   try await until{frames.count>=2}
   #expect(native.experimentCurrentDemandChunkLimit==2_097_152)
   let previousSession=frames.last!.0
   native.pause();nextSource.hold=true;nextSource.enteredHold=false
   let old=Task{try await native.seek(to:24,maximumBackward:0)}
   try await until{native.experimentSeekPending && nextSource.enteredHold}
   #expect(native.experimentPlayer?.rate==0)
   let latest=Task{try await native.seek(to:12,maximumBackward:0)}
   _=try? await old.value
   nextSource.hold=false;try await latest.value
   #expect(native.isPlaybackPaused && native.experimentPlayer?.rate==0)
   native.resume()
   try await until{frames.contains{$0.0 != previousSession && $0.1>=12 && $0.1<13}}
   #expect(!frames.contains{$0.0 != previousSession && $0.1>=24 && $0.1<25})
   #expect(whilePending==0)
   nextSource.hold=true;nextSource.enteredHold=false
   let stoppedSeek=Task{try await native.seek(to:30,maximumBackward:0)}
   try await until{native.experimentSeekPending && nextSource.enteredHold}
   let stoppedPlayer=try #require(native.experimentPlayer)
   native.stop();nextSource.hold=false
   _=try? await stoppedSeek.value
   #expect(stoppedPlayer.rate==0)
   secondPlayback?.cancel();_=try? await secondPlayback?.value
   writer.drainForTesting()
   let files=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).filter{$0.pathExtension=="jsonl"}
   let rows=try files.flatMap{try Data(contentsOf:$0).split(separator:10).map{try JSONSerialization.jsonObject(with:Data($0)) as! [String:Any]}}
   let fields=rows.compactMap{$0["fields"] as? [String:Double]}
   let firstID=try #require(fields.first{$0["phase"]==1}?["trace"])
   let first=fields.filter{$0["trace"]==firstID}
   let command=try #require(first.first{$0["phase"]==12 && $0["detail"]==1}?["nativeClock"])
   let callback=try #require(first.first{$0["phase"]==13}?["nativeClock"])
   let resumed=try #require(first.first{$0["phase"]==3}?["nativeClock"])
   #expect(command<callback && callback<=resumed)
   #expect(first.contains{$0["phase"]==14})
   let firstFrame=try #require(first.first{$0["phase"]==7})
   #expect(firstFrame["nativeClock"]! >= resumed)
   let clockDifference=abs(firstFrame["framePTS"]!-firstFrame["playerTime"]!)
   #expect(clockDifference<0.1) // Synthetic 30fps fixture, system media clock; not audible sync proof.
   #expect(writer.status.dropped==0 && writer.status.writerFailures==0)
   print("SEEK216_AVPLAYER", "rows",rows.count,"playBeforeCallbackMS",(callback-command)*1000,"journal",dir.path)
  } catch {source.hold=false;secondSource?.hold=false;native.stop();playback.cancel();secondPlayback?.cancel();_=try? await playback.value;_=try? await secondPlayback?.value;throw error}
 }
}
#endif
