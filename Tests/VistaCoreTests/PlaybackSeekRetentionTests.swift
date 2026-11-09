import Foundation
import Testing
@testable import VistaCore

/// Formal-demand retention only. Generated Data, no transport, media, device or speculative lane.
@Suite(.serialized)
@MainActor struct PlaybackSeekRetentionTests {
    private let file = try! MediaFile(components: ["generated-seek-retention.mp4"])
    @MainActor private final class Source: PlaybackCacheSource {
        let bytes = Data((0..<256).map(UInt8.init))
        var token: UInt64? = 1
        var active = true, stopped = false
        var reads: [Range<UInt64>] = [], speculative = 0
        var onRead: (@MainActor () -> Void)?
        var supportsRetainedCacheRevalidation: Bool { true }
        var isPlaybackRecovering: Bool { false }
        var recoveryActiveStartedAt: TimeInterval? { nil }
        var recoveryActiveElapsed: TimeInterval { 0 }
        func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(bytes.count) }
        func playbackCacheEpoch() throws -> UInt64? { stopped || !active ? nil : token }
        func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            reads.append(range)
            let hook = onRead; onRead = nil; hook?()
            return bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        func readForPrefetch(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            speculative += 1
            return try await read(file, range: range)
        }
        func setPlaybackSceneActive(_ active: Bool) { self.active = active }
        func cancelPlayback() { stopped = true }
        func awaitPlaybackCleanup() async throws {}
    }
    private func beginSeek(_ source: PlaybackPrefetchSource) {
        // Native's existing two synchronous seek invalidations are intentionally preserved.
        source.invalidatePrefetch(reason: .seek)
        source.setPrefetchEnabled(false, reason: .seek)
    }
    private func bytes(_ range: Range<UInt64>) -> Data { Data(range.map { UInt8($0) }) }
    private func assertNoSpeculation(_ source: PlaybackPrefetchSource, _ base: Source) {
        #expect(base.speculative == 0)
        #expect(source.metrics.speculativeBytes == 0)
        #expect(source.metrics.diagnostics.forwardCreateCount == 0)
    }

    @Test func seekDemandRetainsAndHitsWithoutEarningForwardCredit() async throws {
        let base = Source(), source = PlaybackPrefetchSource(file: file, source: base)
        _ = try await source.fileSize(for: file)
        source.setPrefetchEnabled(true)
        #expect(try await source.read(file, range: 0..<8) == bytes(0..<8))
        beginSeek(source)
        #expect(try await source.read(file, range: 64..<88) == bytes(64..<88))
        #expect(try await source.read(file, range: 64..<88) == bytes(64..<88))
        #expect(try await source.read(file, range: 88..<112) == bytes(88..<112))
        #expect(try await source.read(file, range: 0..<8) == bytes(0..<8))
        #expect(base.reads == [0..<8, 64..<88, 88..<112])
        #expect(source.metrics.historyBytes == 56 && source.metrics.historyHitBytes == 32)
        assertNoSpeculation(source, base)
        source.setPrefetchEnabled(true)
        #expect(source.rangeDiagnosticSnapshot().forward.windowID == nil)
        assertNoSpeculation(source, base)
        try await source.awaitPlaybackCleanup()
    }

    @Test func oldGenerationResultCannotFillSeekRing() async throws {
        let base = Source(), source = PlaybackPrefetchSource(file: file, source: base)
        source.setPrefetchEnabled(true)
        _ = try await source.read(file, range: 0..<8)
        base.onRead = { beginSeek(source) }
        #expect(try await source.read(file, range: 64..<88) == bytes(64..<88))
        #expect(source.metrics.historyBytes == 8)
        #expect(try await source.read(file, range: 64..<88) == bytes(64..<88))
        #expect(try await source.read(file, range: 64..<88) == bytes(64..<88))
        #expect(base.reads == [0..<8, 64..<88, 64..<88])
        #expect(source.metrics.historyBytes == 32)
        assertNoSpeculation(source, base)
        try await source.awaitPlaybackCleanup()
    }

    @Test func changedOrUnknownEpochCannotFillSeekRing() async throws {
        for replacement: UInt64? in [2, nil] {
            let base = Source(), source = PlaybackPrefetchSource(file: file, source: base)
            beginSeek(source)
            _ = try await source.read(file, range: 0..<8)
            base.onRead = { base.token = replacement }
            #expect(try await source.read(file, range: 64..<88) == bytes(64..<88))
            #expect(source.metrics.historyBytes == 0 && source.metrics.validCacheBytes == 0)
            #expect(try await source.read(file, range: 64..<88) == bytes(64..<88))
            #expect(source.metrics.historyBytes == (replacement == nil ? 0 : 24))
            assertNoSpeculation(source, base)
            try await source.awaitPlaybackCleanup()
        }
    }

    @Test func everyOtherDisableReasonClearsSeekRetention() async throws {
        for reason: PrefetchInvalidationReason in [.explicit, .disabled, .sceneInactive, .memoryPressure, .stop, .notReady, .playbackInactive] {
            let base = Source(), source = PlaybackPrefetchSource(file: file, source: base)
            beginSeek(source)
            source.setPrefetchEnabled(false, reason: reason)
            _ = try await source.read(file, range: 64..<88)
            _ = try await source.read(file, range: 64..<88)
            #expect(base.reads == [64..<88, 64..<88])
            #expect(source.metrics.historyBytes == 0)
            assertNoSpeculation(source, base)
            try await source.awaitPlaybackCleanup()
        }
        // Direct consistency invalidation must also revoke the seek-only allowance.
        let base = Source(), source = PlaybackPrefetchSource(file: file, source: base)
        beginSeek(source); source.invalidatePrefetch(reason: .explicit)
        _ = try await source.read(file, range: 64..<88)
        #expect(source.metrics.historyBytes == 0)
        try await source.awaitPlaybackCleanup()
    }

    @Test func pressureAndStopCannotBeOverriddenByLaterSeek() async throws {
        let base = Source(), source = PlaybackPrefetchSource(file: file, source: base)
        beginSeek(source); _ = try await source.read(file, range: 0..<8)
        source.handleMemoryPressure(); beginSeek(source)
        _ = try await source.read(file, range: 64..<88)
        _ = try await source.read(file, range: 64..<88)
        #expect(source.metrics.historyBytes == 0 && base.reads.count == 3)
        source.cancelPlayback(); beginSeek(source)
        do { _ = try await source.read(file, range: 64..<88); Issue.record("Stop must reject demand") }
        catch { #expect(error is CancellationError) }
        #expect(base.reads.count == 3 && source.metrics.storageAllocatedBytes == 0)
        assertNoSpeculation(source, base)
        try await source.awaitPlaybackCleanup()
    }

    @Test func backgroundQuarantineAndPauseKeepTheirOriginalBoundaries() async throws {
        let base = Source(), source = PlaybackPrefetchSource(file: file, source: base)
        beginSeek(source); _ = try await source.read(file, range: 0..<8)
        source.setPlaybackSceneActive(false)
        #expect(source.metrics.cacheQuarantined && source.metrics.historyBytes == 8)
        _ = try await source.read(file, range: 64..<88)
        #expect(source.metrics.cacheQuarantined && source.metrics.historyBytes == 8)
        source.setPlaybackSceneActive(true)
        _ = try await source.read(file, range: 64..<88)
        #expect(!source.metrics.cacheQuarantined && source.metrics.historyBytes == 8)
        source.setPrefetchEnabled(false, reason: .pause)
        _ = try await source.read(file, range: 64..<88)
        _ = try await source.read(file, range: 64..<88)
        #expect(source.metrics.historyBytes == 32 && base.reads.count == 4)
        assertNoSpeculation(source, base)
        try await source.awaitPlaybackCleanup()
    }

    @Test func seekWritesWrapWithinCapacityWithoutAliasingReplies() async throws {
        let base = Source(), config = PlaybackPrefetchSource.Configuration(capacityBytes: 16, chunkBytes: 8, totalCapacityBytes: 32)
        let source = PlaybackPrefetchSource(file: file, source: base, configuration: config)
        beginSeek(source)
        let first = try await source.read(file, range: 0..<24)
        let cached = try await source.read(file, range: 0..<24)
        for lower: UInt64 in [32, 64, 96] {
            #expect(try await source.read(file, range: lower..<(lower + 24)) == bytes(lower..<(lower + 24)))
            #expect(source.metrics.historyBytes == 32)
            #expect(source.metrics.storageAllocatedBytes == 32)
        }
        #expect(first == bytes(0..<24) && cached == bytes(0..<24))
        #expect(try await source.read(file, range: 96..<120) == bytes(96..<120))
        #expect(base.reads == [0..<24, 32..<56, 64..<88, 96..<120])
        #expect(source.metrics.maxTotalCacheBytes <= 56)
        #expect(source.metrics.storageWrittenBytes == 96)
        #expect(source.metrics.diagnostics.historyEvictedBytes == 64)
        let production = PlaybackPrefetchSource.Configuration()
        #expect(production.totalCapacityBytes == 160 * 1_048_576)
        #expect(production.capacityBytes == 4 * 1_048_576 && production.chunkBytes == 2 * 1_048_576)
        assertNoSpeculation(source, base)
        try await source.awaitPlaybackCleanup()
    }

    private enum Failure: Error { case transport }
    @MainActor private final class Session: MediaByteSource {
        let value: UInt8
        var fails = false, reads: [Range<UInt64>] = []
        init(_ value: UInt8) { self.value = value }
        func fileSize(for file: MediaFile) async throws -> UInt64 { 256 }
        func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            reads.append(range)
            if fails { throw Failure.transport }
            return Data(repeating: value, count: range.count)
        }
    }
    @MainActor private final class RecoveryHarness {
        let old = Session(1), fresh = Session(2)
        var creates = 0
        var changedIdentity = false
        let file: MediaFile
        init(_ file: MediaFile) { self.file = file }
        lazy var source = PlaybackRecoveringSource(file: file, initial: old,
            metadata: { session, _ in
                PlaybackSourceIdentity(size: 256,
                    modificationDate: Date(timeIntervalSince1970: self.changedIdentity && session === self.fresh ? 200 : 100),
                    creationDate: Date(timeIntervalSince1970: 50))
            }, makeFresh: { self.creates += 1; return self.fresh }, retire: { _ in },
            shouldRecover: { $0 is Failure }, isCurrent: { true }, diagnostics: nil)
    }

    @Test func seekPartialRecoveryNeverMixesIdentityOrAddsRetryBudget() async throws {
        for mode in 0..<3 { // Successful same identity, changed identity, failed sole retry.
            let h = RecoveryHarness(file)
            let source = PlaybackPrefetchSource(file: file, source: h.source)
            _ = try await source.fileSize(for: file)
            beginSeek(source)
            #expect(try await source.read(file, range: 0..<8) == Data(repeating: 1, count: 8))
            h.old.fails = true; h.changedIdentity = mode == 1; h.fresh.fails = mode == 2
            do {
                let result = try await source.read(file, range: 0..<24)
                #expect(mode == 0 && result == Data(repeating: 2, count: 24))
            } catch {
                if mode == 1 { #expect(error as? PlaybackSourceRecoveryError == .identityChanged) }
                else if mode == 2 { #expect(error is Failure) }
                else { Issue.record("Same-identity single recovery unexpectedly failed: \(error)") }
            }
            #expect(h.creates == 1)
            #expect(h.old.reads == [0..<8, 8..<24])
            #expect(h.fresh.reads == (mode == 1 ? [] : [0..<24]))
            #expect(source.metrics.historyBytes == 0 && source.metrics.historyHitBytes == 0)
            if mode == 0 {
                // A later demand qualifies the new epoch; the recovery reply itself did not.
                #expect(try await source.read(file, range: 0..<24) == Data(repeating: 2, count: 24))
                #expect(try await source.read(file, range: 0..<24) == Data(repeating: 2, count: 24))
                #expect(h.fresh.reads == [0..<24, 0..<24] && source.metrics.historyBytes == 24)
            }
            #expect(source.metrics.speculativeBytes == 0)
            try await source.awaitPlaybackCleanup()
        }
    }
}
