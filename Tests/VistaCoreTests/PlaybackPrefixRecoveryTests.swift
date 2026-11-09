import Foundation
import Testing
@testable import VistaCore

/// Pure in-memory sessions. No SMB, sockets, private media or device operations.
@Suite(.serialized)
@MainActor struct PlaybackPrefixRecoveryTests {
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
            isCurrent: { true }, diagnostics: nil
        )
        func establishEpoch() async throws -> UInt64 {
            _ = try await source.fileSize(for: file)
            return try #require(try source.playbackCacheEpoch())
        }
        func complete(epoch: UInt64, prefix: Data = Data(repeating: 1, count: 4)) async throws -> PlaybackPrefixReadResult {
            try await source.readCompletingPrefix(file, range: 20..<32, prefix: prefix, epoch: epoch)
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

    @Test func defaultCapabilityUsesOneFullReadAndReportsNoPrefix() async throws {
        let source = DefaultSource()
        let erased: any PlaybackCacheSource = source
        let file = try MediaFile(components: ["generated.mp4"])
        let result = try await erased.readCompletingPrefix(file, range: 20..<32, prefix: Data(repeating: 1, count: 4), epoch: 0)
        #expect(result.data == Data(repeating: 3, count: 12))
        #expect(result.usedPrefixBytes == 0 && source.reads == [20..<32])
    }

    @Test func qualifiedEpochOnlyReadsTheMissingSuffix() async throws {
        let h = Harness(), epoch = try await h.establishEpoch()
        let erased: any PlaybackCacheSource = h.source
        let result = try await erased.readCompletingPrefix(h.file, range: 20..<32, prefix: Data([5, 6, 7, 8]), epoch: epoch)
        #expect(result.data == Data([5, 6, 7, 8]) + Data(repeating: 1, count: 8))
        #expect(result.usedPrefixBytes == 4 && h.old.reads == [24..<32])
        #expect(h.creates == 0 && h.metadataCalls == [1])
        try await h.source.awaitPlaybackCleanup()
    }

    @Test func aCompleteQualifiedPrefixNeedsNoTransportRead() async throws {
        let h = Harness(), epoch = try await h.establishEpoch()
        let result = try await h.complete(epoch: epoch, prefix: Data(repeating: 1, count: 12))
        #expect(result.data == Data(repeating: 1, count: 12))
        #expect(result.usedPrefixBytes == 12 && h.old.reads.isEmpty && h.creates == 0)
        try await h.source.awaitPlaybackCleanup()
    }

    @Test func wrongEpochOrInvalidPrefixFallsBackToFullRead() async throws {
        for reason in [0, 2, 3, 4] {
            let h = Harness(), epoch = try await h.establishEpoch()
            let prefix = Data(repeating: 9, count: reason == 2 ? 13 : reason == 3 ? 0 : 4)
            if reason == 4 {
                h.old.body = { _ in throw Failure.transport }
                await expectFailure(Failure.transport) { _ = try await h.source.readForPrefetch(h.file, range: 0..<4) }
                h.old.reads.removeAll(); h.old.body = nil
            }
            let result = try await h.complete(epoch: reason == 0 ? epoch &+ 1 : epoch, prefix: prefix)
            #expect(result.data == Data(repeating: 1, count: 12))
            #expect(result.usedPrefixBytes == 0 && h.old.reads == [20..<32] && h.creates == 0)
            try await h.source.awaitPlaybackCleanup()
        }
    }

    @Test func initialMetadataDoesNotRetroactivelyQualifyAPrefix() async throws {
        let h = Harness()
        let result = try await h.complete(epoch: 0, prefix: Data(repeating: 9, count: 4))
        #expect(result.data == Data(repeating: 1, count: 12))
        #expect(result.usedPrefixBytes == 0 && h.old.reads == [20..<32])
        try await h.source.awaitPlaybackCleanup()
    }

    @Test func failedSuffixRecoversOnceAndRetriesTheWholeOriginalRange() async throws {
        let h = Harness(), epoch = try await h.establishEpoch()
        h.old.body = { _ in throw Failure.transport }
        let result = try await h.complete(epoch: epoch)
        #expect(result.data == Data(repeating: 2, count: 12) && result.usedPrefixBytes == 0)
        #expect(h.old.reads == [24..<32] && h.fresh.reads == [20..<32])
        #expect(h.creates == 1 && h.retired == [1] && h.metadataCalls == [1, 2, 2])
        try await h.source.awaitPlaybackCleanup()
    }

    @Test func failedFullFallbackNeverGetsASecondRecoveryBudget() async throws {
        for usePrefix in [true, false] {
            let h = Harness(), epoch = try await h.establishEpoch()
            h.old.body = { _ in throw Failure.transport }
            h.fresh.body = { _ in throw Failure.transport }
            await expectFailure(Failure.transport) { _ = try await h.complete(epoch: usePrefix ? epoch : epoch &+ 1) }
            #expect(h.creates == 1 && h.old.reads == [usePrefix ? 24..<32 : 20..<32])
            #expect(h.fresh.reads == [20..<32])
            try await h.source.awaitPlaybackCleanup()
        }
    }

    @Test func initialMetadataRecoveryAlsoConsumesTheOnlyBudget() async throws {
        let h = Harness()
        h.metadataBody = { session in if session === h.old { throw Failure.transport }; return h.identity }
        h.fresh.body = { _ in throw Failure.transport }
        await expectFailure(Failure.transport) { _ = try await h.complete(epoch: 0) }
        #expect(h.creates == 1 && h.old.reads.isEmpty && h.fresh.reads == [20..<32])
        try await h.source.awaitPlaybackCleanup()
    }

    @Test func changedIdentityBeforeOrAfterFullRetryRejectsAllBytes() async throws {
        for changeAfterRead in [false, true] {
            let h = Harness(), epoch = try await h.establishEpoch()
            h.old.body = { _ in throw Failure.transport }
            let original = h.identity
            h.metadataBody = { session in
                if session === h.old || (changeAfterRead && h.fresh.reads.isEmpty) { return original }
                return PlaybackSourceIdentity(size: 128, modificationDate: Date(timeIntervalSince1970: 200), creationDate: original.creationDate)
            }
            await expectFailure(PlaybackSourceRecoveryError.identityChanged) { _ = try await h.complete(epoch: epoch) }
            #expect(h.creates == 1 && h.old.reads == [24..<32])
            #expect(h.fresh.reads == (changeAfterRead ? [20..<32] : []))
            try await h.source.awaitPlaybackCleanup()
        }
    }

    @Test func sceneBecomingInactiveDuringSuffixKeepsDemandOwnedPrefix() async throws {
        let h = Harness(), epoch = try await h.establishEpoch(), completion = Completion()
        h.old.body = { range in
            if range == 24..<32 { return try await completion.wait() }
            return Data(repeating: 7, count: Int(range.upperBound - range.lowerBound))
        }
        let read = Task { @MainActor in try await h.complete(epoch: epoch) }
        await completion.waitUntilEntered()
        h.source.setPlaybackSceneActive(false)
        completion.complete(Data(repeating: 7, count: 8))
        for _ in 0..<20 { await Task.yield() }
        h.source.setPlaybackSceneActive(true)
        let result = try await read.value
        #expect(result.data == Data(repeating: 1, count: 4) + Data(repeating: 7, count: 8))
        #expect(result.usedPrefixBytes == 4 && h.old.reads == [24..<32] && h.creates == 0)
        #expect(try h.source.playbackCacheEpoch() == epoch)
        #expect(h.metadataCalls == [1, 1])
        try await h.source.awaitPlaybackCleanup()
    }

    @Test func cancellationDuringSuffixCannotPublishPrefixOrStartRecovery() async throws {
        for cancelSource in [false, true] {
            let h = Harness(), epoch = try await h.establishEpoch(), completion = Completion()
            h.old.body = { _ in try await completion.wait() }
            let read = Task { @MainActor in try await h.complete(epoch: epoch) }
            await completion.waitUntilEntered()
            if cancelSource { h.source.cancelPlayback() } else { read.cancel() }
            completion.complete(Data(repeating: 1, count: 8))
            do { _ = try await read.value; Issue.record("Expected cancellation") }
            catch { #expect(error is CancellationError) }
            #expect(h.old.reads == [24..<32] && h.fresh.reads.isEmpty && h.creates == 0)
            try await h.source.awaitPlaybackCleanup()
        }
    }

    @Test func shortSuffixRemainsAnInvalidResponseWithoutFallbackOrRecovery() async throws {
        let h = Harness(), epoch = try await h.establishEpoch()
        h.old.body = { _ in Data(repeating: 1, count: 7) }
        await expectFailure(PlaybackSourceRecoveryError.invalidResponse) { _ = try await h.complete(epoch: epoch) }
        #expect(h.old.reads == [24..<32] && h.fresh.reads.isEmpty && h.creates == 0)
        try await h.source.awaitPlaybackCleanup()
    }

    @Test func prefetchUsesTheSameTwoMiBLimitAsDemand() async throws {
        let h = Harness(), maximum = MediaReadPlan.maximumChunkBytes
        h.identity = PlaybackSourceIdentity(size: maximum + 1, modificationDate: Date(timeIntervalSince1970: 100), creationDate: Date(timeIntervalSince1970: 50))
        _ = try await h.establishEpoch()
        let data = try await h.source.readForPrefetch(h.file, range: 0..<maximum)
        #expect(UInt64(data.count) == maximum && maximum == 2 * 1_024 * 1_024)
        await expectFailure(PlaybackSourceRecoveryError.invalidRange) { _ = try await h.source.readForPrefetch(h.file, range: 0..<(maximum + 1)) }
        #expect(h.old.reads == [0..<maximum] && h.creates == 0)
        try await h.source.awaitPlaybackCleanup()
    }
}
