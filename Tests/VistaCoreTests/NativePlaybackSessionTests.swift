import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import VistaCore
@testable import VistaMedia

// Synthetic memory source only. No SMB server or private media.
private actor ImmutableExperimentSource: MediaByteSource {
    let data: Data
    let delay: Duration
    var disconnected = false
    var failedReads = 0
    init(data: Data, delay: Duration) { self.data = data; self.delay = delay }
    func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(data.count) }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        guard !disconnected, range.upperBound <= data.count else {
            failedReads += 1
            throw PlaybackFailure.readFailed
        }
        return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
    func disconnect() { disconnected = true }
    func failures() -> Int { failedReads }
}

@Suite(.serialized) struct NativePlaybackSessionTests {
 @Test @MainActor func sourceFailureIsReportedAndFreshSessionRecovers()async throws {
  let data=try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!)
  let failed=ImmutableExperimentSource(data:data,delay:.milliseconds(20));await failed.disconnect()
  let session=NativePlaybackSession(stallLimit:2,muted:true)
  await #expect(throws:NativePlaybackSession.Failure.source) {
   try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:failed,onInfo:{_ in},onState:{_ in},onFrame:{_ in Issue.record("Frame from failed source")})
  }
  let healthy=ImmutableExperimentSource(data:data,delay:.milliseconds(20));var count=0
  let task=Task {try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:healthy,onInfo:{_ in},onState:{_ in},onFrame:{_ in count += 1;if count==3 {session.stop()}})}
  await #expect(throws:CancellationError.self){try await task.value}
  let healthyFailures=await healthy.failures();#expect(count==3 && healthyFailures==0)
  let normalStop=session.anonymousLogValues()
  #expect(Int(normalStop[.resumeContext] ?? -1) & 1 == 0 && normalStop[.playerClock]==nil)
 }
 @Test @MainActor func slowSourceAndNoProgressAreDifferent()async throws {
  let data=try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!)
  let source=ImmutableExperimentSource(data:data,delay:.seconds(2)),session=NativePlaybackSession(stallLimit:0.1,muted:true)
  await #expect(throws:NativePlaybackSession.Failure.stalled) {
   try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,onInfo:{_ in},onState:{_ in},onFrame:{_ in})
  }
  #expect(await source.failures()==0)
 }
 @Test @MainActor func seekPauseCancelAndNoLateFrames()async throws {
  let data=try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!)
  let source=ImmutableExperimentSource(data:data,delay:.milliseconds(20)),session=NativePlaybackSession(stallLimit:2,muted:true)
  var count=0,last=0.0
  let task=Task {try await session.play(file:MediaFile(components:["synthetic.mp4"]),source:source,onInfo:{_ in},onState:{_ in},onFrame:{frame in count += 1;last=frame.time})}
  let limit=ContinuousClock.now.advanced(by:.seconds(5))
  while count<2,ContinuousClock.now<limit {try await Task.sleep(for:.milliseconds(10))}
  #expect(count>=2)
  session.pause();let paused=count;try await Task.sleep(for:.milliseconds(100));#expect(count==paused)
  let first=Task{try await session.seek(to:1.2)};let second=Task{try await session.seek(to:3.9)}
  _ = try? await first.value;try await second.value;session.resume()
  let end=ContinuousClock.now.advanced(by:.seconds(2))
  while count==paused,ContinuousClock.now<end {try await Task.sleep(for:.milliseconds(10))}
  #expect(last>=2.9 && last<=4.1)
  task.cancel();await #expect(throws:CancellationError.self){try await task.value}
  let stopped=count;try await Task.sleep(for:.milliseconds(100));let sourceFailures=await source.failures();#expect(count==stopped && sourceFailures==0)
  let cancelled=session.anonymousLogValues()
  #expect(Int(cancelled[.resumeContext] ?? -1) & 1 == 0 && cancelled[.playerClock]==nil)
 }
}
