import Foundation
import Testing
@testable import VistaCore

/// Synthetic sessions only; no network, private media or device operations.
@Suite(.serialized) @MainActor struct PlaybackBackgroundCacheValidationTests {
    private enum Failure: Error { case transport }
    @MainActor private final class Session: MediaByteSource {
        var reads = 0
        var byte: UInt8 = 2
        var fail = false
        var action: (@MainActor () async -> Void)?
        func fileSize(for file: MediaFile) async throws -> UInt64 { 32 }
        func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            reads += 1
            await action?()
            if fail { throw Failure.transport }
            return Data(repeating: byte, count: range.count)
        }
    }
    @MainActor private final class Harness {
        let file = try! MediaFile(components: ["synthetic.mp4"])
        let old = Session(), fresh = Session()
        var stats = 0, creates = 0
        var metadataAction: (@MainActor (Session) async throws -> Void)?
        var fingerprint = PlaybackSourceIdentity(size: 32, modificationDate: Date(timeIntervalSince1970: 100), creationDate: Date(timeIntervalSince1970: 50))
        lazy var source = PlaybackRecoveringSource(file: file, initial: old, metadata: { session, _ in
            self.stats += 1
            try await self.metadataAction?(session)
            return self.fingerprint
        }, makeFresh: { self.creates += 1; return self.fresh }, retire: { _ in },
        shouldRecover: { $0 is Failure }, isCurrent: { true }, diagnostics: nil)
        func establish() async throws {
            _ = try await source.fileSize(for: file)
        }
        func background() { source.setPlaybackSceneActive(false); source.setPlaybackSceneActive(true) }
        func cached() async throws -> PlaybackCachedReadResult {
            try await source.readCompletingCachedSegments(file, range: 0..<4,
                segments: [.init(range: 0..<4, data: Data(repeating: 9, count: 4))], epoch: 0)
        }
    }
    @Test func foregroundFullHitRequiresFreshMetadataOncePerBackground() async throws {
        let h = Harness(); try await h.establish()
        h.background()
        #expect(try h.source.playbackCacheEpoch() == nil)
        #expect(try await h.cached().usedCachedBytes == 4)
        #expect(h.stats == 2 && h.old.reads == 0 && h.creates == 0)
        #expect(try await h.cached().usedCachedBytes == 4)
        #expect(h.stats == 2)
        h.background()
        #expect(try await h.cached().usedCachedBytes == 4)
        #expect(h.stats == 3)
        try await h.source.awaitPlaybackCleanup()
    }
    @Test func wrapperRetainsBackgroundBytesAndValidatesBeforeFullHit() async throws {
        let h = Harness()
        let wrapper = PlaybackPrefetchSource(file: h.file, source: h.source,
            configuration: .init(capacityBytes: 8, chunkBytes: 4, totalCapacityBytes: 16))
        wrapper.setPrefetchEnabled(true)
        _ = try await wrapper.fileSize(for: h.file)
        _ = try await wrapper.read(h.file, range: 0..<4)
        let retained = wrapper.metrics.totalCacheBytes
        #expect(retained == 4 && h.old.reads == 1)
        wrapper.setPlaybackSceneActive(false)
        #expect(wrapper.metrics.totalCacheBytes == retained)
        #expect(wrapper.metrics.cacheQuarantined && wrapper.metrics.diagnostics.quarantineEnteredCount == 1)
        #expect(try h.source.playbackCacheEpoch() == nil)
        wrapper.setPlaybackSceneActive(true)
        let data = try await wrapper.read(h.file, range: 0..<4)
        #expect(data == Data(repeating: 2, count: 4))
        #expect(h.stats == 2 && h.old.reads == 1 && h.creates == 0)
        #expect(!wrapper.metrics.cacheQuarantined && wrapper.metrics.diagnostics.quarantineValidatedCount == 1)
        #expect(wrapper.metrics.diagnostics.quarantineClearedCount == 0)
        try await wrapper.awaitPlaybackCleanup()
    }
    @Test func incompleteForegroundMetadataCannotReplaceQuarantinedArena() async throws {
        for includeReady in [false, true] {
        let h = Harness()
        let wrapper = PlaybackPrefetchSource(file: h.file, source: h.source,
            configuration: .init(capacityBytes: 8, chunkBytes: 4, totalCapacityBytes: 16))
        wrapper.setPrefetchEnabled(true)
        _ = try await wrapper.fileSize(for: h.file)
        _ = try await wrapper.read(h.file, range: 0..<4)
        if includeReady {
            _ = try await wrapper.read(h.file, range: 4..<8)
            for _ in 0..<100 {
                if wrapper.metrics.residentBytes == 8 { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(wrapper.metrics.residentBytes == 8)
        }
        let readCount = h.old.reads
        let ready = wrapper.metrics.residentBytes
        let range: Range<UInt64> = includeReady ? 8..<12 : 0..<4
        let original = h.fingerprint
        let valid = wrapper.metrics.validCacheBytes
        let written = wrapper.metrics.storageWrittenBytes
        let allocated = wrapper.metrics.storageAllocatedBytes
        wrapper.setPlaybackSceneActive(false)
        wrapper.setPlaybackSceneActive(true)
        h.fingerprint = .init(size: 32, modificationDate: nil, creationDate: nil)
        h.old.byte = 3 // Distinguish the fallback payload from the retained synthetic bytes.
        #expect(try await wrapper.read(h.file, range: range) == Data(repeating: 3, count: 4))
        #expect(try h.source.playbackCacheEpoch() == nil)
        #expect(h.old.reads == readCount + 1 && h.creates == 0)
        #expect(wrapper.metrics.validCacheBytes == valid)
        #expect(wrapper.metrics.storageWrittenBytes == written)
        #expect(wrapper.metrics.storageAllocatedBytes == allocated)
        #expect(wrapper.metrics.cacheQuarantined && wrapper.metrics.residentBytes == ready)
        #expect(wrapper.metrics.discardedBytes == 0 && wrapper.metrics.hitBytes == 0)
        h.fingerprint = original
        #expect(try await wrapper.read(h.file, range: range) == Data(repeating: 2, count: 4))
        #expect(h.old.reads == readCount + 1 && h.creates == 0)
        #expect(wrapper.metrics.validCacheBytes == valid)
        #expect(wrapper.metrics.storageWrittenBytes == written)
        #expect(wrapper.metrics.speculativeBytes == wrapper.metrics.hitBytes + wrapper.metrics.joinedBytes + wrapper.metrics.discardedBytes + wrapper.metrics.retiredSpeculativeBytes + UInt64(wrapper.metrics.residentBytes))
        try await wrapper.awaitPlaybackCleanup()
        }
    }
    @Test func runningPrefetchRevokedByBackgroundDoesNotForceCachedDemandReread() async throws {
        let h = Harness()
        let wrapper = PlaybackPrefetchSource(file: h.file, source: h.source,
            configuration: .init(capacityBytes: 8, chunkBytes: 4, totalCapacityBytes: 16))
        wrapper.setPrefetchEnabled(true)
        _ = try await wrapper.fileSize(for: h.file)
        var entered: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        var didEnter = false
        h.old.action = {
            if h.old.reads < 3 { return }
            didEnter = true; entered?.resume(); entered = nil
            await withCheckedContinuation { release = $0 }
        }
        _ = try await wrapper.read(h.file, range: 0..<4)
        _ = try await wrapper.read(h.file, range: 4..<8)
        if !didEnter { await withCheckedContinuation { entered = $0 } }
        wrapper.setPlaybackSceneActive(false)
        #expect(wrapper.metrics.validCacheBytes == 8)
        wrapper.setPlaybackSceneActive(true)
        h.old.action = nil
        release?.resume()
        #expect(try await wrapper.read(h.file, range: 0..<4) == Data(repeating: 2, count: 4))
        #expect(h.stats == 2 && h.old.reads == 3 && h.creates == 0)
        try await wrapper.awaitPlaybackCleanup()
    }
    @Test func changedFreshMetadataCannotPublishRetainedBytes() async throws {
        let h = Harness(); try await h.establish(); h.background()
        h.fingerprint = .init(size: 32, modificationDate: Date(timeIntervalSince1970: 200), creationDate: Date(timeIntervalSince1970: 50))
        do { _ = try await h.cached(); Issue.record("Published changed identity") }
        catch { #expect(error as? PlaybackSourceRecoveryError == .identityChanged) }
        #expect(h.stats == 2 && h.old.reads == 0 && h.creates == 0)
        try await h.source.awaitPlaybackCleanup()
    }
    @Test func transientStatFailureUsesOnlyOriginalDemandRecovery() async throws {
        for retryFails in [false, true] {
            let h = Harness(); try await h.establish(); h.background()
            h.metadataAction = { session in if session === h.old { throw Failure.transport } }
            h.fresh.fail = retryFails
            do {
                let result = try await h.cached()
                #expect(!retryFails && result.usedCachedBytes == 0 && result.data == Data(repeating: 2, count: 4))
            } catch { #expect(retryFails && error is Failure) }
            #expect(h.creates == 1 && h.old.reads == 0 && h.fresh.reads == 1)
            try await h.source.awaitPlaybackCleanup()
        }
    }
    @Test func incompleteFreshMetadataFallsBackWithoutQualifyingCache() async throws {
        let h = Harness(); try await h.establish(); h.background()
        h.fingerprint = .init(size: 32, modificationDate: nil, creationDate: nil)
        let result = try await h.cached()
        #expect(result.usedCachedBytes == 0 && h.old.reads == 1 && h.creates == 0)
        #expect(try h.source.playbackCacheEpoch() == nil)
        try await h.source.awaitPlaybackCleanup()
    }
    @Test func backgroundDuringGapRejectsMixedAssemblyAfterChangedFreshStat() async throws {
        let h = Harness(); try await h.establish()
        var entered: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        var didEnter = false
        h.old.action = {
            didEnter = true; entered?.resume(); entered = nil
            await withCheckedContinuation { release = $0 }
        }
        let task = Task { @MainActor in
            try await h.source.readCompletingCachedSegments(h.file, range: 0..<8,
                segments: [.init(range: 0..<4, data: Data(repeating: 9, count: 4))], epoch: 0)
        }
        if !didEnter { await withCheckedContinuation { entered = $0 } }
        h.background()
        h.fingerprint = .init(size: 32, modificationDate: Date(timeIntervalSince1970: 200), creationDate: Date(timeIntervalSince1970: 50))
        release?.resume()
        do { _ = try await task.value; Issue.record("Published stale mixed assembly") }
        catch { #expect(error as? PlaybackSourceRecoveryError == .identityChanged) }
        #expect(h.stats == 2 && h.old.reads == 1 && h.creates == 0)
        try await h.source.awaitPlaybackCleanup()
    }
    @Test func pendingMetadataCannotPublishAfterCancellationStopOrAnotherBackground() async throws {
        for action in 0..<3 {
            let h = Harness(); try await h.establish(); h.background()
            var entered: CheckedContinuation<Void, Never>?
            var release: CheckedContinuation<Void, Never>?
            var didEnter = false
            h.metadataAction = { _ in
                if didEnter { return }
                didEnter = true; entered?.resume(); entered = nil
                await withCheckedContinuation { release = $0 }
            }
            let task = Task { @MainActor in try await h.cached() }
            if !didEnter { await withCheckedContinuation { entered = $0 } }
            if action == 0 { task.cancel() }
            if action == 1 { h.source.cancelPlayback() }
            if action == 2 { h.background() }
            release?.resume()
            do {
                let result = try await task.value
                #expect(action == 2 && result.usedCachedBytes == 4 && h.stats == 3)
            } catch { #expect(action != 2 && error is CancellationError) }
            #expect(h.old.reads == 0 && h.creates == 0)
            try await h.source.awaitPlaybackCleanup()
        }
    }
}
