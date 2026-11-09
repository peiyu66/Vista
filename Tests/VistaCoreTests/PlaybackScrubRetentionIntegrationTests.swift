import Foundation
import Testing
@testable import VistaCore

/// Bounded model/Data integration of the shared submission seam and Native's
/// existing invalidation sequence. Not a SwiftUI, transport or device replay.
@Suite(.serialized) @MainActor struct PlaybackScrubRetentionIntegrationTests {
    @MainActor private final class Source: PlaybackCacheSource {
        let bytes = Data((0..<128).map(UInt8.init))
        var reads: [Range<UInt64>] = [], speculative = 0
        var supportsRetainedCacheRevalidation: Bool { true }
        var isPlaybackRecovering: Bool { false }
        var recoveryActiveStartedAt: TimeInterval? { nil }
        var recoveryActiveElapsed: TimeInterval { 0 }
        func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(bytes.count) }
        func playbackCacheEpoch() throws -> UInt64? { 1 }
        func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            reads.append(range)
            return bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        func readForPrefetch(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            speculative += 1; return try await read(file, range: range)
        }
        func setPlaybackSceneActive(_ active: Bool) {}
        func cancelPlayback() {}
        func awaitPlaybackCleanup() async throws {}
    }
    @Test func noChangeSkipsInvalidationAndRealReturnEditKeepsDemandBytes() async throws {
        let file = try MediaFile(components: ["generated-scrub-retention.mp4"])
        let base = Source(), source = PlaybackPrefetchSource(file: file, source: base)
        _ = try await source.fileSize(for: file)
        source.setPrefetchEnabled(true)
        _ = try await source.read(file, range: 0..<8)
        let owner = UUID(); var edit = PlaybackScrubInteraction(), submissions = 0
        let submit: (Double) -> Void = { _ in
            submissions += 1
            source.invalidatePrefetch(reason: .seek)
            source.setPrefetchEnabled(false, reason: .seek)
        }
        edit.begin(owner: owner, position: 42)
        let unchanged = edit.finish(owner: owner, submit: submit)
        #expect(!unchanged && submissions == 0 && source.metrics.historyBytes == 8)
        edit.update(43, owner: owner, initialPosition: 42)
        edit.begin(owner: owner, position: 42.5) // setter-before-begin preserves change
        edit.update(42, owner: owner, initialPosition: 42.5)
        let changed = edit.finish(owner: owner, submit: submit)
        let duplicate = edit.finish(owner: owner, submit: submit)
        #expect(changed && !duplicate && submissions == 1)
        let expected = base.bytes.subdata(in: 64..<80)
        #expect(try await source.read(file, range: 64..<80) == expected)
        #expect(try await source.read(file, range: 64..<80) == expected)
        #expect(try await source.read(file, range: 0..<8) == base.bytes.subdata(in: 0..<8))
        #expect(base.reads == [0..<8, 64..<80])
        #expect(base.speculative == 0 && source.metrics.speculativeBytes == 0)
        #expect(source.metrics.historyBytes == 24 && source.metrics.historyHitBytes == 24)
        #expect(source.metrics.diagnostics.forwardCreateCount == 0)
        #expect(source.rangeDiagnosticSnapshot().forward.windowID == nil)
        try await source.awaitPlaybackCleanup()
    }
}
