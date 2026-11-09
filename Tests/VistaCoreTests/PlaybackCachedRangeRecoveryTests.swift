import Foundation
import Testing
@testable import VistaCore

/// Pure Data sessions only. No SMB, sockets, private media or device operations.
@Suite(.serialized)
@MainActor struct PlaybackCachedRangeRecoveryTests {
    private enum Failure: Error, Equatable { case transport }

    @MainActor private final class Session: MediaByteSource {
        let number: UInt8
        var reads: [Range<UInt64>] = []
        var body: (@MainActor (Range<UInt64>) async throws -> Data)?
        init(_ number: UInt8) { self.number = number }
        func fileSize(for file: MediaFile) async throws -> UInt64 { 128 }
        func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            reads.append(range)
            if let body { return try await body(range) }
            return Data(repeating: number, count: Int(range.upperBound - range.lowerBound))
        }
    }

    @MainActor private final class Completion {
        private var entered = false
        private var arrival: CheckedContinuation<Void, Never>?
        private var result: CheckedContinuation<Data, any Error>?
        func wait() async throws -> Data {
            entered = true; arrival?.resume(); arrival = nil
            return try await withCheckedThrowingContinuation { result = $0 }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { arrival = $0 }
        }
        func complete(_ data: Data) {
            precondition(result != nil)
            result?.resume(returning: data); result = nil
        }
    }

    @MainActor private final class Harness {
        let file = try! MediaFile(components: ["generated.mp4"])
        let old = Session(1), fresh = Session(2)
        var creates = 0, metadataCalls: [UInt8] = [], retired: [UInt8] = []
        var current = true
        var identity = PlaybackSourceIdentity(size: 128, modificationDate: Date(timeIntervalSince1970: 100), creationDate: Date(timeIntervalSince1970: 50))
        var metadataBody: (@MainActor (Session) async throws -> PlaybackSourceIdentity)?
        lazy var source = PlaybackRecoveringSource(
            file: file, initial: old,
            metadata: { session, _ in
                self.metadataCalls.append(session.number)
                if let body = self.metadataBody { return try await body(session) }
                return self.identity
            },
            makeFresh: { self.creates += 1; return self.fresh },
            retire: { self.retired.append($0.number) },
            shouldRecover: { ($0 as? Failure) == .transport },
            isCurrent: { self.current }, diagnostics: nil
        )
        func establishEpoch() async throws -> UInt64 {
            _ = try await source.fileSize(for: file)
            return try #require(try source.playbackCacheEpoch())
        }
        var slices: [PlaybackCachedSegment] {
            [PlaybackCachedSegment(range: 28..<32, data: Data(repeating: 8, count: 4)),
             PlaybackCachedSegment(range: 22..<26, data: Data(repeating: 9, count: 4))]
        }
        func complete(epoch: UInt64) async throws -> PlaybackCachedReadResult {
            let erased: any PlaybackCacheSource = source
            return try await erased.readCompletingCachedSegments(file, range: 20..<40, segments: slices, epoch: epoch)
        }
    }

    @MainActor private final class DefaultSource: PlaybackCacheSource {
        var reads: [Range<UInt64>] = []
        var isPlaybackRecovering: Bool { false }
        var recoveryActiveStartedAt: TimeInterval? { nil }
        var recoveryActiveElapsed: TimeInterval { 0 }
        func setPlaybackSceneActive(_ active: Bool) {}
        func cancelPlayback() {}
        func awaitPlaybackCleanup() async throws {}
        func playbackCacheEpoch() throws -> UInt64? { 0 }
        func fileSize(for file: MediaFile) async throws -> UInt64 { 128 }
        func readForPrefetch(_ file: MediaFile, range: Range<UInt64>) async throws -> Data { try await read(file, range: range) }
        func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            reads.append(range)
            return Data(repeating: 3, count: Int(range.upperBound - range.lowerBound))
        }
    }

    private func expectFailure<E: Error & Equatable>(_ expected: E, _ body: @MainActor () async throws -> Void) async {
        do { try await body(); Issue.record("Expected failure") }
        catch { #expect(error as? E == expected) }
    }

    @Test func defaultCapabilityUsesOneFullReadAndReportsNoCachedBytes() async throws {
        let source = DefaultSource(), h = Harness()
        let erased: any PlaybackCacheSource = source
        #expect(!erased.supportsRetainedCacheRevalidation)
        let result = try await erased.readCompletingCachedSegments(h.file, range: 20..<40, segments: h.slices, epoch: 0)
        #expect(result.data == Data(repeating: 3, count: 20))
        #expect(result.usedCachedBytes == 0 && source.reads == [20..<40])
    }

    @Test func sortedIntersectionsReadOnlyHeadMiddleAndTailSequentially() async throws {
        let h = Harness(), epoch = try await h.establishEpoch()
        let result = try await h.complete(epoch: epoch)
        let expected = Data(repeating: 1, count: 2) + Data(repeating: 9, count: 4) +
            Data(repeating: 1, count: 2) + Data(repeating: 8, count: 4) + Data(repeating: 1, count: 8)
        #expect(result.data == expected && result.usedCachedBytes == 8)
        #expect(h.old.reads == [20..<22, 26..<28, 32..<40])
        #expect(h.metadataCalls == [1] && h.creates == 0)
        try await h.source.awaitPlaybackCleanup()
    }

    @Test func clippedAdjacentAndOverlappingSlicesCanFullyCoverDemand() async throws {
        let h = Harness(), epoch = try await h.establishEpoch()
        // Non-zero Data indices and ranges extending outside demand must be clipped safely.
        let segmentData = Data([7, 7, 9, 9, 9, 9, 9, 9]).dropFirst(2)
        let segments = [PlaybackCachedSegment(range: 24..<36, data: Data(repeating: 8, count: 12)),
                        PlaybackCachedSegment(range: 18..<24, data: segmentData),
                        PlaybackCachedSegment(range: 34..<44, data: Data(repeating: 6, count: 10))]
        let result = try await h.source.readCompletingCachedSegments(h.file, range: 20..<40, segments: segments, epoch: epoch)
        #expect(result.data == Data(repeating: 9, count: 4) + Data(repeating: 8, count: 12) + Data(repeating: 6, count: 4))
        #expect(result.usedCachedBytes == 20 && h.old.reads.isEmpty && h.creates == 0)
        try await h.source.awaitPlaybackCleanup()
    }

    @Test func unqualifiedEpochOrMalformedSlicesUseFullDemand() async throws {
        for reason in [0, 1, 3, 4, 5, 6] {
            let h = Harness()
            let epoch = reason == 0 ? 0 : try await h.establishEpoch()
            if reason == 3 {
                h.old.body = { _ in throw Failure.transport }
                await expectFailure(Failure.transport) { _ = try await h.source.readForPrefetch(h.file, range: 0..<4) }
                h.old.reads.removeAll(); h.old.body = nil
            }
            let segments: [PlaybackCachedSegment]
            switch reason {
            case 4: segments = [PlaybackCachedSegment(range: 22..<26, data: Data(repeating: 9, count: 3))]
            case 5: segments = Array(repeating: h.slices[0], count: 9)
            case 6: segments = [PlaybackCachedSegment(range: 44..<48, data: Data(repeating: 9, count: 4))]
            default: segments = h.slices
            }
            let result = try await h.source.readCompletingCachedSegments(h.file, range: 20..<40, segments: segments, epoch: reason == 1 ? epoch &+ 1 : epoch)
            #expect(result.data == Data(repeating: 1, count: 20))
            #expect(result.usedCachedBytes == 0 && h.old.reads == [20..<40] && h.creates == 0)
            try await h.source.awaitPlaybackCleanup()
        }
    }

    @Test func laterGapFailureDiscardsEveryPieceAndRecoversWholeRangeOnce() async throws {
        let failingRanges: [Range<UInt64>] = [26..<28, 32..<40]
        for failingRange in failingRanges {
            let h = Harness(), epoch = try await h.establishEpoch()
            h.old.body = { range in
                if range == failingRange { throw Failure.transport }
                return Data(repeating: 1, count: Int(range.upperBound - range.lowerBound))
            }
            let result = try await h.complete(epoch: epoch)
            #expect(result.data == Data(repeating: 2, count: 20) && result.usedCachedBytes == 0)
            #expect(h.old.reads == (failingRange.lowerBound == 26 ? [20..<22, 26..<28] : [20..<22, 26..<28, 32..<40]))
            #expect(h.fresh.reads == [20..<40] && h.creates == 1 && h.retired == [1])
            #expect(h.metadataCalls == [1, 2, 2])
            try await h.source.awaitPlaybackCleanup()
        }
    }

    @Test func failedFullRecoveryNeverGetsASecondBudget() async throws {
        let h = Harness(), epoch = try await h.establishEpoch()
        h.old.body = { range in
            if range == 26..<28 { throw Failure.transport }
            return Data(repeating: 1, count: Int(range.upperBound - range.lowerBound))
        }
        h.fresh.body = { _ in throw Failure.transport }
        await expectFailure(Failure.transport) { _ = try await h.complete(epoch: epoch) }
        #expect(h.creates == 1 && h.old.reads == [20..<22, 26..<28] && h.fresh.reads == [20..<40])
        try await h.source.awaitPlaybackCleanup()
    }

    @Test func changedRecoveryIdentityRejectsCachedAndAlreadyReadPieces() async throws {
        for changeAfterRead in [false, true] {
            let h = Harness(), epoch = try await h.establishEpoch()
            h.old.body = { range in
                if range == 26..<28 { throw Failure.transport }
                return Data(repeating: 1, count: Int(range.upperBound - range.lowerBound))
            }
            let original = h.identity
            h.metadataBody = { session in
                if session === h.old || (changeAfterRead && h.fresh.reads.isEmpty) { return original }
                return PlaybackSourceIdentity(size: 128, modificationDate: Date(timeIntervalSince1970: 200), creationDate: original.creationDate)
            }
            await expectFailure(PlaybackSourceRecoveryError.identityChanged) { _ = try await h.complete(epoch: epoch) }
            #expect(h.old.reads == [20..<22, 26..<28] && h.creates == 1)
            #expect(h.fresh.reads == (changeAfterRead ? [20..<40] : []))
            try await h.source.awaitPlaybackCleanup()
        }
    }

    @Test func cancellationStopOrFileChangeDuringHeadCannotReadNextGapOrPublish() async throws {
        for reason in 0..<3 {
            let h = Harness(), epoch = try await h.establishEpoch(), completion = Completion()
            h.old.body = { _ in try await completion.wait() }
            let read = Task { @MainActor in try await h.complete(epoch: epoch) }
            await completion.waitUntilEntered()
            if reason == 0 { read.cancel() }
            else if reason == 1 { h.source.cancelPlayback() }
            else { h.current = false }
            completion.complete(Data(repeating: 1, count: 2))
            do { _ = try await read.value; Issue.record("Expected cancellation") }
            catch { #expect(error is CancellationError) }
            #expect(h.old.reads == [20..<22] && h.fresh.reads.isEmpty && h.creates == 0)
            try await h.source.awaitPlaybackCleanup()
        }
    }

    @Test func sceneBecomingInactiveKeepsAdmittedDemandPiecesAcrossGaps() async throws {
        let h = Harness(), epoch = try await h.establishEpoch(), completion = Completion()
        h.old.body = { range in
            if range == 20..<22 { return try await completion.wait() }
            return Data(repeating: 1, count: Int(range.upperBound - range.lowerBound))
        }
        let read = Task { @MainActor in try await h.complete(epoch: epoch) }
        await completion.waitUntilEntered()
        h.source.setPlaybackSceneActive(false)
        completion.complete(Data(repeating: 1, count: 2))
        for _ in 0..<20 { await Task.yield() }
        #expect(h.old.reads == [20..<22])
        h.source.setPlaybackSceneActive(true)
        let result = try await read.value
        #expect(result.data.count == 20 && result.usedCachedBytes == 8)
        #expect(h.old.reads == [20..<22, 26..<28, 32..<40] && h.creates == 0)
        #expect(try h.source.playbackCacheEpoch() == epoch)
        #expect(h.metadataCalls == [1, 1])
        try await h.source.awaitPlaybackCleanup()
    }

    @Test func shortGapAndOversizedDemandDoNotRecover() async throws {
        let h = Harness(), epoch = try await h.establishEpoch()
        h.old.body = { _ in Data([1]) }
        await expectFailure(PlaybackSourceRecoveryError.invalidResponse) { _ = try await h.complete(epoch: epoch) }
        await expectFailure(PlaybackSourceRecoveryError.invalidRange) {
            _ = try await h.source.readCompletingCachedSegments(h.file, range: 0..<(MediaReadPlan.maximumChunkBytes + 1), segments: h.slices, epoch: epoch)
        }
        #expect(h.old.reads == [20..<22] && h.fresh.reads.isEmpty && h.creates == 0)
        try await h.source.awaitPlaybackCleanup()
    }
    @Test func wrappedSharedHistoryAndAheadDiscardAllPiecesOnLaterGapRecovery() async throws {
        let h = Harness()
        let wrapper = PlaybackPrefetchSource(file: h.file, source: h.source,
            configuration: .init(capacityBytes: 16, chunkBytes: 8, totalCapacityBytes: 32))
        wrapper.setPrefetchEnabled(true)
        for offset in stride(from: 0, to: 48, by: 8) {
            _ = try await wrapper.read(h.file, range: UInt64(offset)..<UInt64(offset + 8))
        }
        _ = try await wrapper.fileSize(for: h.file)
        _ = try await wrapper.read(h.file, range: 48..<56)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while wrapper.metrics.residentBytes != 16, ContinuousClock.now < deadline { await Task.yield() }
        try #require(wrapper.metrics.residentBytes == 16)
        wrapper.setPrefetchEnabled(false, reason: .pause)
        #expect(wrapper.metrics.historyBytes == 16 && wrapper.metrics.totalCacheBytes == 32)
        h.old.body = { range in
            if range == 72..<74 { throw Failure.transport }
            return Data(repeating: 1, count: range.count)
        }
        #expect(try await wrapper.read(h.file, range: 38..<74) == Data(repeating: 2, count: 36))
        #expect(Array(h.old.reads.suffix(2)) == [38..<40, 72..<74])
        #expect(h.fresh.reads == [38..<74] && h.creates == 1 && h.retired == [1])
        #expect(wrapper.metrics.historyHitBytes == 0 && wrapper.metrics.hitBytes == 0 && wrapper.metrics.joinedBytes == 0)
        #expect(wrapper.metrics.discardedBytes == 16 && wrapper.metrics.totalCacheBytes == 0)
        #expect(wrapper.metrics.storageAllocatedBytes == 0)
        try await wrapper.awaitPlaybackCleanup()
    }

}
