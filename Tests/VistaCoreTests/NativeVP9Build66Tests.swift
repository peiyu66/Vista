import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

#if os(macOS)
/// Synthetic in-memory recovery flag only. No SMB, sockets, device, or decoder identity claim.
@MainActor private final class VP9RecoveringFixture: PlaybackRecoveryControlling {
    let data: Data
    var reads = 0
    var cancelled = false
    var sceneActive = true
    var recoveryActiveStartedAt: TimeInterval?
    var isPlaybackRecovering: Bool { recoveryActiveStartedAt != nil }
    var recoveryActiveElapsed: TimeInterval {
        recoveryActiveStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
    }
    init() throws {
        data = try Data(contentsOf: #require(Bundle.module.url(forResource: "NativeVP9AV", withExtension: "mp4")))
    }
    func setPlaybackSceneActive(_ active: Bool) { sceneActive = active }
    func cancelPlayback() { cancelled = true; recoveryActiveStartedAt = nil }
    func awaitPlaybackCleanup() async throws { cancelPlayback() }
    func fileSize(for file: MediaFile) async throws -> UInt64 {
        guard !cancelled else { throw CancellationError() }
        return UInt64(data.count)
    }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        guard !cancelled else { throw CancellationError() }
        reads += 1
        if reads == 1 {
            recoveryActiveStartedAt = ProcessInfo.processInfo.systemUptime
            defer { recoveryActiveStartedAt = nil }
            // Longer than the ordinary 0.2-second stall budget, within recovery grace.
            try await Task.sleep(for: .milliseconds(450))
        }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        guard range.upperBound <= data.count else { throw PlaybackFailure.readFailed }
        return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
}

@Suite(.serialized) @MainActor struct NativeVP9Build66Tests {
    private enum Failure: Error { case timeout }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @Test func recoveryGracePreservesInitialPauseSpeedSeekAndExplicitResume() async throws {
        let source = try VP9RecoveringFixture()
        let session = NativePlaybackSession(stallLimit: 0.2, muted: true)
        var frames = 0
        var codec = "", audio = false
        let task = Task {
            try await session.play(file: MediaFile(components: ["synthetic.mp4"]), source: source,
                startAt: 1, startPaused: true,
                onInfo: { codec = $0.codec; audio = $0.hasAudio }, onState: { _ in },
                onFrame: { _ in frames += 1 })
        }
        do {
            try await wait { frames > 0 }
            #expect(codec == "vp09" && audio && source.reads > 0)
            #expect(session.isPlaybackPaused && session.speedStatus.effectiveRate == 0)
            #expect(session.selectedSpeed == 1 && !source.isPlaybackRecovering)
            #expect(session.setSpeed(2))
            try await session.seek(to: 2, maximumBackward: 0, maximumForward: 0)
            #expect(session.isPlaybackPaused && session.selectedSpeed == 2)
            #expect(session.speedStatus.effectiveRate == 0)
            let paused = try #require(session.experimentPlayerTime)
            try await Task.sleep(for: .milliseconds(100))
            #expect(abs((session.experimentPlayerTime ?? -1) - paused) < 0.03)
            #expect(abs(paused - 2) < 0.03)
            let before = frames
            session.resume()
            try await wait { frames >= before + 2 && session.speedStatus.effectiveRate == 2 }
            #expect(session.decoderDescription == "解碼方式：系統管理（未知）")
            session.stop()
            await #expect(throws: CancellationError.self) { try await task.value }
            let stopped = frames
            try await Task.sleep(for: .milliseconds(100))
            #expect(source.cancelled && frames == stopped && !session.setSpeed(2))
            print("NATIVE_VP9_BUILD66", "frames", frames, "reads", source.reads,
                  "pausedSeek", paused, "rate", 2, "recoveryFlagFixture", true,
                  "realSMB", false, "audibleOutputTested", false)
        } catch {
            session.stop(); task.cancel(); _ = try? await task.value
            throw error
        }
    }
}
#endif
