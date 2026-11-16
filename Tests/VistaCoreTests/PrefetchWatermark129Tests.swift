import Foundation
import Testing
@testable import VistaCore

/// Deterministic memory-only sources. Counts are wrapper source calls, not SMB RPCs.
@Suite(.serialized) @MainActor struct PrefetchWatermark129Tests {
    enum Synthetic: Error { case failed }
    @MainActor final class Source: PlaybackCacheSource, PlaybackSourceRevisionProviding {
        var size: UInt64 = 4096, token: UInt64? = 1
        var active = true, stopped = false
        var isPlaybackRecovering: Bool { false }
        var recoveryActiveStartedAt: TimeInterval? { nil }
        var recoveryActiveElapsed: TimeInterval { 0 }
        var supportsRetainedCacheRevalidation: Bool { true }
        var calls: [(String, Range<UInt64>)] = []
        var outstanding = 0, maximum = 0
        var blockNextPrefetch = false, blockNextDemand = false, failNextPrefetch = false, shortNextPrefetch = false
        var blockPrefetchAt: Int?
        var gate: CheckedContinuation<Void, Never>?
        var epochHook: (() -> Void)?
        func playbackCacheEpoch() throws -> UInt64? { epochHook?(); return stopped || !active ? nil : token }
        func fileSize(for file: MediaFile) async throws -> UInt64 { size }
        func freshPlaybackIdentity() async throws -> PlaybackSourceIdentity {
            .init(size: size, modificationDate: nil, creationDate: nil)
        }
        func validatePlaybackRevision(_ baseline: PlaybackSourceIdentity) throws {
            guard baseline.size == size else { throw Synthetic.failed }
        }
        func awaitSourceOperationsDrained() async throws { #expect(outstanding == 0) }
        func data(_ range: Range<UInt64>) -> Data {
            var data = Data(count: range.count)
            data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                var offset = range.lowerBound
                while offset < range.upperBound {
                    let count = Int(min(256 - offset % 256, range.upperBound - offset))
                    bytes.baseAddress!.advanced(by: Int(offset - range.lowerBound)).initializeMemory(
                        as: UInt8.self, repeating: UInt8(truncatingIfNeeded: offset / 256) ^ UInt8(token ?? 0), count: count)
                    offset += UInt64(count)
                }
            }
            return data
        }
        func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            try await operation("d", range)
        }
        func readForPrefetch(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            try await operation("p", range)
        }
        func operation(_ kind: String, _ range: Range<UInt64>) async throws -> Data {
            calls.append((kind, range)); outstanding += 1; maximum = max(maximum, outstanding)
            defer { outstanding -= 1 }
            let block = kind == "p" ? blockNextPrefetch || blockPrefetchAt == prefetched.count : blockNextDemand
            if kind == "p" { blockNextPrefetch = false } else { blockNextDemand = false }
            if block { await withCheckedContinuation { gate = $0 } }
            if kind == "p", failNextPrefetch { failNextPrefetch = false; throw Synthetic.failed }
            if kind == "p", shortNextPrefetch { shortNextPrefetch = false; return data(range.lowerBound..<(range.upperBound - 1)) }
            return data(range)
        }
        func readCompletingCachedSegments(_ file: MediaFile, range: Range<UInt64>, segments: [PlaybackCachedSegment], epoch: UInt64) async throws -> PlaybackCachedReadResult {
            if !active { active = true }
            guard token == epoch else { return .init(data: try await read(file, range: range), usedCachedBytes: 0) }
            var result = Data(), cursor = range.lowerBound, used = 0
            for segment in segments {
                if cursor < segment.range.lowerBound { result.append(try await read(file, range: cursor..<segment.range.lowerBound)) }
                result.append(segment.data); cursor = segment.range.upperBound; used += segment.data.count
            }
            if cursor < range.upperBound { result.append(try await read(file, range: cursor..<range.upperBound)) }
            return .init(data: result, usedCachedBytes: used)
        }
        func release() { let saved = gate; gate = nil; saved?.resume() }
        func setPlaybackSceneActive(_ active: Bool) { self.active = active }
        func cancelPlayback() { stopped = true }
        func awaitPlaybackCleanup() async throws { #expect(outstanding == 0) }
        var prefetched: [Range<UInt64>] { calls.filter { $0.0 == "p" }.map(\.1) }
    }
    let file = try! MediaFile(components: ["generated.mp4"])
    let mib = 1_048_576
    func make(_ b: Source, arena: Int = 640) -> PlaybackPrefetchSource {
        .init(file: file, source: b, configuration: .init(lowWatermarkBytes: 32, highWatermarkBytes: 64, chunkBytes: 8, totalCapacityBytes: arena))
    }
    func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<100_000 { if predicate() { return }; await Task.yield() }
        Issue.record("Bounded synthetic wait expired"); throw Synthetic.failed
    }
    func idle(_ w: PlaybackPrefetchSource) async throws { try await until { w.recoveryActivity.busy == 0 } }
    func read(_ w: PlaybackPrefetchSource, _ b: Source, _ range: Range<UInt64>) async throws -> Data {
        let value = try await w.read(file, range: range); #expect(value == b.data(range)); return value
    }
    func prime(_ w: PlaybackPrefetchSource, _ b: Source, start: UInt64 = 0) async throws {
        _ = try await w.fileSize(for: file); w.setPrefetchEnabled(true)
        _ = try await read(w,b,start..<(start+8)); _ = try await read(w,b,(start+8)..<(start+16))
        try await idle(w)
    }
    func conserved(_ w: PlaybackPrefetchSource) {
        let m=w.metrics
        #expect(m.speculativeBytes == m.hitBytes + m.joinedBytes + m.discardedBytes + m.retiredSpeculativeBytes + UInt64(m.residentBytes))
        #expect(m.maxInFlightBytes <= 2*mib && m.maxStorageAllocatedBytes <= 160*mib)
    }

    @Test func productionDefaultsFillOneFixedSixteenMiBWindow() async throws {
        let b=Source(); b.size=64*UInt64(mib)
        let c=PlaybackPrefetchSource.Configuration()
        #expect(c.lowWatermarkBytes == 8*mib && c.capacityBytes == 16*mib && c.chunkBytes == 2*mib && c.totalCapacityBytes == 160*mib)
        let w=PlaybackPrefetchSource(file:file,source:b)
        _ = try await w.fileSize(for:file); w.setPrefetchEnabled(true)
        _ = try await read(w,b,0..<UInt64(2*mib)); _ = try await read(w,b,UInt64(2*mib)..<UInt64(4*mib))
        try await idle(w)
        let f=w.rangeDiagnosticSnapshot().forward
        #expect(b.prefetched.count == 8 && b.prefetched.allSatisfy { $0.count == 2*mib })
        #expect(f.cursor == UInt64(4*mib) && f.target == UInt64(20*mib) && f.contiguousAheadBytes == 16*mib && f.refilling == false)
        #expect(w.metrics.maxStorageAllocatedBytes == 160*mib && b.maximum == 1)
        print("WATERMARK_PRODUCTION demandCalls=2 prefetchCalls=\(b.prefetched.count) prefetchBytes=\(w.metrics.speculativeBytes) ahead=\(f.contiguousAheadBytes!) ring=\(w.metrics.maxStorageAllocatedBytes) maximum=\(b.maximum)")
        conserved(w); try await w.awaitPlaybackCleanup()
    }
    @Test func strictLowBoundaryHysteresisAndBackread() async throws {
        let b=Source(), w=make(b); try await prime(w,b)
        #expect(b.prefetched.count == 8)
        for start in stride(from:16, to:48, by:8) { _ = try await read(w,b,UInt64(start)..<UInt64(start+8)) }
        try await idle(w)
        #expect(w.rangeDiagnosticSnapshot().forward.contiguousAheadBytes == 32 && b.prefetched.count == 8)
        _ = try await read(w,b,0..<8); try await idle(w)
        #expect(w.rangeDiagnosticSnapshot().forward.cursor == 48 && b.prefetched.count == 8)
        // One byte below low starts a cycle, but full-chunk guard stops at high-1.
        _ = try await read(w,b,48..<49); try await idle(w)
        let f=w.rangeDiagnosticSnapshot().forward
        #expect(f.cursor == 49 && f.target == 113 && f.contiguousAheadBytes == 63 && b.prefetched.count == 12)
        #expect(b.prefetched.last == 104..<112)
        _ = try await read(w,b,0..<8); try await idle(w)
        #expect(b.prefetched.count == 12 && w.rangeDiagnosticSnapshot().forward.cursor == 49)
        print("WATERMARK_BOUNDARY atLowCalls=8 belowLowCalls=12 nonalignedAhead=63 high=64")
        conserved(w); try await w.awaitPlaybackCleanup()
    }
    @Test func demandWinsAfterSourceDrainAndCancellationPreservesFrontier() async throws {
        let b=Source(), w=make(b); b.blockNextPrefetch=true
        _ = try await w.fileSize(for:file); w.setPrefetchEnabled(true)
        _ = try await read(w,b,0..<8); _ = try await read(w,b,8..<16)
        try await until { b.gate != nil }
        let demand=Task { try await w.read(file,range:256..<264) }
        try await until { w.recoveryActivity.queued == 1 }
        let cancelled=Task { try await w.read(file,range:512..<520) }
        try await until { w.recoveryActivity.queued == 2 }; cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancelled queued demand returned") } catch is CancellationError {}
        #expect(b.outstanding == 1 && b.calls.count == 3)
        b.release(); #expect(try await demand.value == b.data(256..<264)); try await idle(w)
        #expect(b.calls[3].0 == "d" && b.calls[3].1 == 256..<264 && b.maximum == 1)
        #expect(w.rangeDiagnosticSnapshot().forward.cursor == 16 && b.prefetched.count == 8)
        print("WATERMARK_PRIORITY maximum=\(b.maximum) formalAfterDrain=\(b.calls[3].0) frontier=16 prefetchCalls=\(b.prefetched.count)")
        conserved(w); try await w.awaitPlaybackCleanup()
    }
    @Test func completingHighWaterBeforeQueuedDemandClosesHysteresis() async throws {
        let b=Source(), w=make(b); b.blockPrefetchAt=8
        _ = try await w.fileSize(for:file); w.setPrefetchEnabled(true)
        _ = try await read(w,b,0..<8); _ = try await read(w,b,8..<16)
        try await until { b.gate != nil }
        // This partial-cache demand waits behind the final fill. Its completion
        // advances 8 bytes but must not inherit the now-completed refill cycle.
        let metadata=Task { try await w.fileSize(for:file) }
        try await until { w.recoveryActivity.queued == 1 }
        let demand=Task { try await w.read(file,range:16..<24) }
        try await until { w.recoveryActivity.queued == 2 }
        b.release(); _ = try await metadata.value
        #expect(try await demand.value == b.data(16..<24)); try await idle(w)
        #expect(w.rangeDiagnosticSnapshot().forward.cursor == 24)
        #expect(w.rangeDiagnosticSnapshot().forward.contiguousAheadBytes == 56)
        #expect(w.rangeDiagnosticSnapshot().forward.refilling == false && b.prefetched.count == 8)
        conserved(w); try await w.awaitPlaybackCleanup()
    }
    @Test func actualCancellationDrainsBeforeNextRead() async throws {
        let b=Source(), w=make(b); try await prime(w,b)
        b.blockNextDemand=true
        let blocked=Task { try await w.read(file,range:256..<264) }; try await until { b.gate != nil }
        blocked.cancel(); do { _ = try await blocked.value; Issue.record("Cancelled demand returned") } catch is CancellationError {}
        let next=Task { try await w.read(file,range:512..<520) }; try await until { w.recoveryActivity.queued == 1 }
        #expect(b.outstanding == 1 && b.calls.last!.1 == 256..<264)
        b.release(); #expect(try await next.value == b.data(512..<520)); try await idle(w)
        #expect(b.maximum == 1 && w.rangeDiagnosticSnapshot().forward.cursor == 16)
        conserved(w); try await w.awaitPlaybackCleanup()
    }
    @Test func seekEpochBackgroundAndRevisionDrainRemainSafe() async throws {
        let b=Source(), w=make(b); b.blockNextPrefetch=true
        _ = try await w.fileSize(for:file); w.setPrefetchEnabled(true)
        _ = try await read(w,b,0..<8); _ = try await read(w,b,8..<16); try await until { b.gate != nil }
        let drain=Task { await w.suspendAndDrainForSourceWindow() }
        try await until { !w.rangeDiagnosticSnapshot().forward.enabled }
        #expect(b.outstanding == 1); b.release(); await drain.value
        try await w.awaitSourceOperationsDrained()
        #expect(w.rangeDiagnosticSnapshot().forward.cursor == nil && w.metrics.validCacheBytes == 16)
        w.resumeAfterSourceWindowDrain(); _ = try await read(w,b,0..<8); _ = try await read(w,b,8..<16); try await idle(w)
        w.setPlaybackSceneActive(false); #expect(w.metrics.cacheQuarantined)
        w.setPlaybackSceneActive(true); w.setPrefetchEnabled(true)
        let before=w.metrics.directCacheReplyCount
        _ = try await read(w,b,0..<8); try await idle(w)
        #expect(!w.metrics.cacheQuarantined && w.metrics.directCacheReplyCount == before)
        b.token=2
        _ = try await read(w,b,0..<8); try await idle(w)
        #expect(w.rangeDiagnosticSnapshot().forward.cursor == nil && w.diagnosticObservedEpoch == 2)
        #expect(b.maximum == 1); conserved(w); try await w.awaitPlaybackCleanup()
    }
    @Test func ringEvictsOnlyOnNewWritesAndRetainsUsefulDormantWitness() async throws {
        let b=Source(), w=make(b,arena:80); try await prime(w,b,start:512)
        let snapshot=try await read(w,b,512..<520); try await idle(w)
        let before=w.metrics.storageWrittenBytes
        _ = try await read(w,b,512..<520); try await idle(w)
        #expect(w.metrics.storageWrittenBytes == before && w.metrics.validCacheBytes == 80)
        // Older uncached demand replaces the completed-demand witness, not forward data.
        _ = try await read(w,b,0..<8); _ = try await read(w,b,8..<16); try await idle(w)
        let f=w.rangeDiagnosticSnapshot().forward
        #expect(f.cursor == 528 && f.target == 592 && f.contiguousAheadBytes == 64 && b.prefetched.count == 8)
        #expect(w.metrics.validCacheBytes == 80 && w.metrics.storageWrittenBytes == before+16)
        #expect(snapshot == b.data(512..<520))
        _ = try await read(w,b,528..<536); try await idle(w)
        #expect(w.rangeDiagnosticSnapshot().forward.cursor == 536 && b.maximum == 1)
        print("WATERMARK_RING valid=\(w.metrics.validCacheBytes) storage=\(w.metrics.storageAllocatedBytes) immutableSnapshot=8 retainedAhead=64")
        conserved(w); try await w.awaitPlaybackCleanup()
    }
    @Test func eofAndSourceFailuresCannotSpinRefill() async throws {
        let b=Source(); b.size=75; let w=make(b)
        try await prime(w,b)
        #expect(b.prefetched.count == 8 && b.prefetched.last == 72..<75)
        #expect(w.rangeDiagnosticSnapshot().forward.cursor == 16 && w.rangeDiagnosticSnapshot().forward.target == 75)
        #expect(w.rangeDiagnosticSnapshot().forward.contiguousAheadBytes == 59)
        conserved(w); try await w.awaitPlaybackCleanup()
        let error=Source(), errorW=make(error); error.failNextPrefetch=true
        try await prime(errorW,error)
        #expect(error.prefetched.count == 1 && errorW.rangeDiagnosticSnapshot().forward.cursor == nil)
        conserved(errorW); try await errorW.awaitPlaybackCleanup()
        let short=Source(), shortW=make(short); short.shortNextPrefetch=true
        try await prime(shortW,short)
        #expect(short.prefetched.count == 1 && shortW.metrics.discardedBytes == 7)
        conserved(shortW); try await shortW.awaitPlaybackCleanup()
    }
    @Test func noncontiguousRetainedIslandDoesNotCountAsAhead() async throws {
        let b=Source(), w=make(b)
        _ = try await w.fileSize(for:file); w.setPrefetchEnabled(true)
        _ = try await read(w,b,256..<320); w.invalidatePrefetch(reason:.seek); try await idle(w)
        _ = try await read(w,b,0..<8); _ = try await read(w,b,8..<16); try await idle(w)
        #expect(b.prefetched.count == 8 && w.rangeDiagnosticSnapshot().forward.contiguousAheadBytes == 64)
        #expect(w.rangeDiagnosticSnapshot().forward.target == 80 && w.metrics.validCacheBytes == 144)
        conserved(w); try await w.awaitPlaybackCleanup()
    }
}
