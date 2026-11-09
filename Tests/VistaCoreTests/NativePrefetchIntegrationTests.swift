import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

@MainActor private final class PrefetchPlaybackMemory:MediaByteSource {
    let data:Data
    var reads=0
    init(data:Data) {self.data=data}
    func fileSize(for file:MediaFile)async throws->UInt64 {UInt64(data.count)}
    func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data {
        reads += 1
        try await Task.sleep(for:.milliseconds(8))
        try Task.checkCancellation()
        return data.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))
    }
}

@Suite(.serialized) @MainActor struct NativePrefetchIntegrationTests {
    private enum Failure:Error {case timeout,unexpectedRecovery}
    private func wait(_ check:()->Bool)async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(8))
        while !check() {guard ContinuousClock.now<end else{throw Failure.timeout};try await Task.sleep(for:.milliseconds(10))}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION"] != nil,"Requires generated synthetic AV fixture"))
    func boundedSourcePreservesPauseSeekRateBackgroundAndStop()async throws {
        let path=try #require(ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION"])
        let memory=PrefetchPlaybackMemory(data:try Data(contentsOf:URL(fileURLWithPath:path)))
        let file=try MediaFile(components:["generated.mp4"])
        let identity=PlaybackSourceIdentity(size:UInt64(memory.data.count),modificationDate:Date(timeIntervalSince1970:100),creationDate:Date(timeIntervalSince1970:50))
        let recovering=PlaybackRecoveringSource(file:file,initial:memory,metadata:{_,_ in identity},makeFresh:{throw Failure.unexpectedRecovery},retire:{_ in},shouldRecover:{_ in false},isCurrent:{true},diagnostics:nil)
        let source=PlaybackPrefetchSource(file:file,source:recovering)
        let native=NativePlaybackSession(stallLimit:8,muted:true)
        var frames=0
        let task=Task {try await native.play(file:file,source:source,onInfo:{_ in},onState:{_ in},onFrame:{frame in frames += 1;native.recordPresentation(session:frame.session)})}
        do {
            try await wait{frames>2}
            #expect(native.experimentAutomaticWait == false)
            #expect(native.setSpeed(2.5))
            native.pause();try await Task.sleep(for:.milliseconds(80))
            #expect(native.isPlaybackPaused && native.speedStatus.effectiveRate == 0)
            try await native.seek(to:12,maximumBackward:0)
            #expect(native.isPlaybackPaused && native.selectedSpeed == 2.5)
            // Same forwarding order used by PlaybackController. Active alone never plays.
            source.setPlaybackSceneActive(false);native.setPlaybackSceneActive(false)
            source.setPlaybackSceneActive(true);native.setPlaybackSceneActive(true)
            try await Task.sleep(for:.milliseconds(60));#expect(native.isPlaybackPaused && native.speedStatus.effectiveRate == 0)
            let before=frames;native.resume()
            try await wait{frames>before+2 && native.speedStatus.effectiveRate == 2.5}
            var log=native.anonymousLogValues()
            #expect(log[.prefetchHitBytes] != nil && log[.seekMS] != nil && log[.presentMS] != nil)
            // Controller/renderer fields added to a normal sample, not arbitrary text.
            for field:PlaybackLogField in [.position,.playing,.paused,.preparing,.buffering,.width,.height,.projection,.layout,.route,.textureCount,.textureMS,.uploaded,.coalesced,.decoder,.logFailures,.logDropped] {log[field]=12345.678901234}
            let logBytes=try JSONEncoder().encode(PlaybackLogRecord(event:.sample,values:log,build:"75")).count
            #expect(logBytes<PlaybackLogStore.ordinaryRecordLimit);print("FULL_NATIVE_LOG_BYTES",logBytes)
            source.handleMemoryPressure()
            let after=frames;try await wait{frames>after+2}
            print("NATIVE_PREFETCH memoryReads",memory.reads,"frames",frames,"selectedRate",native.selectedSpeed,"metrics",source.metrics)
        }catch {
            native.stop();task.cancel();_ = try? await task.value;try? await source.awaitPlaybackCleanup();throw error
        }
        native.stop();task.cancel();_ = try? await task.value
        try await source.awaitPlaybackCleanup()
        await #expect(throws:CancellationError.self) {try await source.read(file,range:0..<16)}
    }
}
