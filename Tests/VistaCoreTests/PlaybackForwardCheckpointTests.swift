import Foundation
import Testing
@testable import VistaCore

/// Range-generated Data and explicit gates only. No SMB, media, device or network work.
@Suite(.serialized) @MainActor struct PlaybackForwardCheckpointTests {
    private let file = try! MediaFile(components: ["generated-checkpoint.mp4"])
    @MainActor private final class Source: PlaybackCacheSource {
        var token: UInt64? = 1, active = true, stopped = false
        var supportsRetainedCacheRevalidation: Bool { true }
        var isPlaybackRecovering: Bool { false }
        var recoveryActiveStartedAt: TimeInterval? { nil }
        var recoveryActiveElapsed: TimeInterval { 0 }
        var demands: [Range<UInt64>] = [], speculation: [Range<UInt64>] = []
        var blockedDemand: Range<UInt64>?, blockedSpeculation: Int?
        var gate: CheckedContinuation<Void, Never>?
        var outstanding = 0, maxOutstanding = 0, validations = 0
        var changeEpochDuringDemand = false
        static func bytes(_ range: Range<UInt64>, epoch: UInt64 = 1) -> Data {
            var data = Data(count: range.count)
            data.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for i in bytes.indices {
                    let position = range.lowerBound + UInt64(i)
                    bytes[i] = UInt8(truncatingIfNeeded: position &+ (position >> 12) &+ (position >> 20) &+ epoch)
                }
            }
            return data
        }
        func playbackCacheEpoch() throws -> UInt64? { stopped || !active ? nil : token }
        func fileSize(for file: MediaFile) async throws -> UInt64 { 128 * 1_048_576 }
        func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            demands.append(range); outstanding += 1; maxOutstanding = max(maxOutstanding,outstanding)
            defer { outstanding -= 1 }
            if blockedDemand == range { await withCheckedContinuation { gate = $0 } }
            try Task.checkCancellation()
            if changeEpochDuringDemand { token = 2; changeEpochDuringDemand = false }
            return Self.bytes(range,epoch:token ?? 1)
        }
        func readForPrefetch(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            speculation.append(range); outstanding += 1; maxOutstanding = max(maxOutstanding,outstanding)
            defer { outstanding -= 1 }
            if blockedSpeculation == speculation.count { await withCheckedContinuation { gate = $0 } }
            return Self.bytes(range,epoch:token ?? 1)
        }
        func readCompletingCachedSegments(_ file: MediaFile, range: Range<UInt64>, segments: [PlaybackCachedSegment], epoch: UInt64) async throws -> PlaybackCachedReadResult {
            validations += 1
            if epoch != token { return .init(data:try await read(file,range:range),usedCachedBytes:0) }
            var result = Data(), cursor = range.lowerBound, used = 0
            for segment in segments {
                if cursor < segment.range.lowerBound { result.append(try await read(file,range:cursor..<segment.range.lowerBound)) }
                result.append(segment.data); used += segment.data.count; cursor = segment.range.upperBound
            }
            if cursor < range.upperBound { result.append(try await read(file,range:cursor..<range.upperBound)) }
            try Task.checkCancellation()
            return .init(data:result,usedCachedBytes:used)
        }
        func release() { blockedDemand = nil; blockedSpeculation = nil; let value = gate; gate = nil; value?.resume() }
        func setPlaybackSceneActive(_ active: Bool) { self.active = active }
        func cancelPlayback() { stopped = true }
        func awaitPlaybackCleanup() async throws {}
    }
    private func until(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<2000 { if predicate() { return }; try await Task.sleep(for:.milliseconds(1)) }
        Issue.record("Synthetic checkpoint gate did not settle")
    }
    private func make(_ base: Source, arena: Int = 64) async throws -> PlaybackPrefetchSource {
        let s = PlaybackPrefetchSource(file:file,source:base,configuration:.init(capacityBytes:16,chunkBytes:8,totalCapacityBytes:arena))
        _ = try await s.fileSize(for:file); s.setPrefetchEnabled(false,reason:.pause)
        return s
    }
    private func read(_ s: PlaybackPrefetchSource, _ b: Source, _ range: Range<UInt64>) async throws {
        #expect(try await s.read(file,range:range) == Source.bytes(range,epoch:b.token ?? 1))
        #expect(b.maxOutstanding <= 1)
        #expect(s.metrics.storageAllocatedBytes <= 32*1_048_576)
    }
    private func prime(_ s: PlaybackPrefetchSource, _ b: Source) async throws {
        try await read(s,b,0..<8); try await read(s,b,8..<16)
    }
    private func cancelDemand(_ s: PlaybackPrefetchSource, _ b: Source, _ range: Range<UInt64>) async throws {
        b.blockedDemand = range
        let pending = Task { try await s.read(file,range:range) }
        try await until { b.gate != nil }
        pending.cancel(); b.release()
        do { _ = try await pending.value; Issue.record("Cancelled demand returned bytes") } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        try await until { b.outstanding == 0 }
        // Let the serial pump finish its cancellation catch before testing admission.
        for _ in 0..<10 { await Task.yield() }
    }
    @Test(arguments:[0,1,2]) func cancellationPreservesExistingQuotaWithoutRenewing(consumed: Int) async throws {
        let b = Source()
        let w = try await make(b); try await prime(w,b)
        if consumed > 0 {
            w.diagnosticSink = { record in
                if record.event == .retained, b.speculation.count == consumed { w.setPrefetchEnabled(false,reason:.pause) }
            }
            w.setPrefetchEnabled(true)
            try await until { b.speculation.count == consumed && w.metrics.speculativeBytes == UInt64(consumed*8) }
            w.diagnosticSink = nil
        }
        let before = w.rangeDiagnosticSnapshot().forward
        try await cancelDemand(w,b,80..<88)
        let cancelled = w.rangeDiagnosticSnapshot().forward
        #expect(cancelled.cursor == before.cursor && cancelled.target == before.target)
        #expect(cancelled.reads == before.reads && !cancelled.suspended)
        #expect(w.metrics.diagnostics.forwardCancelPreservedCount == 1)
        // Build96: ordinary cancellation preserves existing unspent credit. Enabling
        // (not an arbitrary history hit) admits the remaining reads after FIFO drain.
        w.setPrefetchEnabled(true)
        try await until { b.speculation.count == 2 && w.metrics.speculativeBytes == 16 }
        try await read(w,b,16..<16) // empty success grants no fresh credit
        for _ in 0..<4 { try await read(w,b,2..<4); try await Task.sleep(for:.milliseconds(4)) }
        #expect(b.speculation == [16..<24,24..<32])
        #expect(w.rangeDiagnosticSnapshot().forward.reads == 2)
        #expect(b.maxOutstanding == 1)
        try await w.awaitPlaybackCleanup()
    }
    @Test(arguments:["seek","background","epoch","unavailable","stop","memory"]) func lifecycleRetiresDormantProgress(boundary: String) async throws {
        let b = Source()
        let s = try await make(b); try await prime(s,b); try await cancelDemand(s,b,80..<88)
        switch boundary {
        case "seek": s.invalidatePrefetch(reason:.seek)
        case "background": s.setPlaybackSceneActive(false); s.setPlaybackSceneActive(true)
        case "epoch": b.token = 2
        case "unavailable": b.token = nil
        case "stop": s.cancelPlayback()
        default: s.handleMemoryPressure()
        }
        s.setPrefetchEnabled(true)
        if boundary != "stop" { try await read(s,b,2..<4) }
        if boundary == "unavailable" { b.token = 1; try await read(s,b,6..<8) }
        try await Task.sleep(for:.milliseconds(10))
        #expect(b.speculation.isEmpty)
        if boundary == "background" { #expect(b.validations == 1); #expect(!s.metrics.cacheQuarantined) }
        try await s.awaitPlaybackCleanup()
    }
    @Test(arguments:[false,true]) func changedEpochCannotBorrowOldAdjacency(duringRead: Bool) async throws {
        let b = Source()
        let w = try await make(b); try await prime(w,b)
        if duringRead { b.changeEpochDuringDemand = true } else { b.token = 2 }
        try await read(w,b,16..<24)
        w.setPrefetchEnabled(true); try await Task.sleep(for:.milliseconds(10))
        #expect(b.speculation.isEmpty)
        // A second completed adjacent demand in the new epoch may earn a new window.
        try await read(w,b,24..<32)
        if duringRead {
            // A response crossing an epoch boundary is not same-epoch seed evidence.
            try await Task.sleep(for:.milliseconds(5)); #expect(b.speculation.isEmpty)
            try await read(w,b,32..<40)
        }
        try await until { b.speculation.count == 2 }
        let start: UInt64 = duringRead ? 40 : 32
        #expect(b.speculation == [start..<(start+8),(start+8)..<(start+16)])
        try await w.awaitPlaybackCleanup()
    }
    @Test func inFlightSpeculationDrainsBeforeContinuingUnspentCredit() async throws {
        let b = Source()
        let s = try await make(b); try await prime(s,b)
        b.blockedSpeculation = 1; s.setPrefetchEnabled(true)
        try await until { b.gate != nil }
        var queued = false
        s.diagnosticSink = { if $0.event == .demandEnqueued { queued = true } }
        let pending = Task { try await s.read(file,range:80..<88) }
        try await until { queued }; pending.cancel()
        do { _ = try await pending.value; Issue.record("Cancelled waiter returned") } catch {}
        #expect(b.outstanding == 1); #expect(b.demands == [0..<8,8..<16])
        b.release(); try await until { s.metrics.speculativeBytes == 16 }
        #expect(b.speculation == [16..<24,24..<32])
        try await read(s,b,2..<4)
        try await Task.sleep(for:.milliseconds(10)); #expect(b.speculation.count == 2)
        #expect(s.rangeDiagnosticSnapshot().forward.reads == 2)
        #expect(b.maxOutstanding == 1)
        try await s.awaitPlaybackCleanup()
    }
    @Test func completedCallerCancellationCannotRetireNewForwardProgress() async throws {
        let b = Source()
        let s = try await make(b)
        let completed = Task { try await s.read(file,range:0..<8) }
        #expect(try await completed.value == Source.bytes(0..<8))
        try await read(s,b,8..<16)
        completed.cancel()
        s.setPrefetchEnabled(true); try await until { b.speculation.count == 2 }
        #expect(b.speculation == [16..<24,24..<32])
        try await s.awaitPlaybackCleanup()
    }
    @Test func sparseRetainedBytesDoNotInventForwardCursor() async throws {
        let b = Source()
        let s = try await make(b)
        let islands: [Range<UInt64>] = [0..<4,100..<108,200..<208]
        for range in islands { try await read(s,b,range) }
        s.setPrefetchEnabled(true)
        try await read(s,b,0..<4); try await Task.sleep(for:.milliseconds(10))
        #expect(b.speculation.isEmpty)
        // Actual adjacent forward progress at 8 earns only the nearby bounded window.
        try await read(s,b,4..<8); try await until { b.speculation.count == 2 }
        #expect(b.speculation == [8..<16,16..<24])
        try await s.awaitPlaybackCleanup()
    }
    @Test func evictionRetiresCheckpointRatherThanRefillingOldEvidence() async throws {
        let b = Source()
        let s = try await make(b,arena:16)
        // Preserve an older prefix as insertion-newer so the first prefetch replaces
        // the checkpoint's own completed range before a backward cache hit is served.
        try await read(s,b,8..<16); try await read(s,b,0..<8); try await read(s,b,8..<16)
        s.setPrefetchEnabled(true)
        try await until { b.speculation.count == 1 && s.metrics.speculativeBytes == 8 }
        try await Task.sleep(for:.milliseconds(10)); #expect(b.speculation == [16..<24])
        let before = b.demands.count
        try await read(s,b,0..<4); try await Task.sleep(for:.milliseconds(10))
        #expect(b.demands.count == before); #expect(b.speculation == [16..<24])
        #expect(s.metrics.validCacheBytes == 16)
        try await s.awaitPlaybackCleanup()
    }
    @Test func forwardCursorSurvivesBackreadsAndAdvancesOnlyOnDemand() async throws {
        let b = Source()
        let s = try await make(b); try await prime(s,b)
        try await read(s,b,2..<4)
        // This is adjacent to the independent forward cursor, not to the last backread.
        try await read(s,b,16..<24)
        s.setPrefetchEnabled(true); try await until { b.speculation.count == 2 }
        #expect(b.speculation == [24..<32,32..<40])
        #expect(b.maxOutstanding == 1)
        try await s.awaitPlaybackCleanup()
    }
    @Test func metadataDeclinedEvidenceCannotBecomeDormantCheckpoint() async throws {
        let b = Source()
        let w = try await make(b,arena:4096)
        // Fill the bounded metadata map with disjoint one-byte retained islands.
        for i in 0..<PlaybackPrefetchSource.Metrics.cacheMetadataEntryLimit {
            let offset = UInt64(i*2)
            try await read(w,b,offset..<(offset+1))
        }
        #expect(w.metrics.cacheMetadataEntries == 1024)
        #expect(w.metrics.validCacheBytes == 1024)
        let written = w.metrics.storageWrittenBytes
        try await read(w,b,10000..<10001)
        try await read(w,b,10001..<10002) // sequential success, but insertion is declined
        #expect(w.metrics.storageWrittenBytes == written)
        #expect(w.metrics.validCacheBytes == 1024)
        try await cancelDemand(w,b,20000..<20008)
        w.setPrefetchEnabled(true)
        let calls = b.demands.count
        try await read(w,b,0..<1) // valid old island must not resurrect absent evidence
        try await Task.sleep(for:.milliseconds(10))
        #expect(b.demands.count == calls); #expect(b.speculation.isEmpty)
        #expect(w.metrics.storageWrittenBytes == written)
        try await w.awaitPlaybackCleanup()
    }
    @Test func confirmedSixBackreadsAfterCancellationPrefix() async throws {
        let m: UInt64 = 1_048_576, b = Source()
        // Preserve the original 32 MiB checkpoint replay independently of production defaults.
        let s = PlaybackPrefetchSource(file:file,source:b,configuration:.init(totalCapacityBytes:32*1_048_576))
        _ = try await s.fileSize(for:file); s.setPrefetchEnabled(false,reason:.pause)
        for i in 0..<10 { try await read(s,b,UInt64(i)*2*m..<UInt64(i+1)*2*m) }
        try await read(s,b,16842752..<16908288) // request25
        try await cancelDemand(s,b,20971520..<23068672) // request26
        try await read(s,b,16973824..<17956864) // request27
        try await read(s,b,17956864..<20054016) // request28
        // Source sees only the uncached tail of request29.
        b.blockedDemand = 20971520..<22151168
        let partial = Task { try await s.read(file,range:20054016..<22151168) }
        try await until { b.gate != nil }; partial.cancel(); b.release()
        do { _ = try await partial.value; Issue.record("Cancelled partial demand returned") } catch {}
        try await until { b.outstanding == 0 }
        for (start,count) in [(UInt64(18153472),UInt64(393216)),(18677760,262144),(18939904,262144),(19398656,65536)] {
            try await read(s,b,start..<(start+count))
        }
        // Initial window is earned by synthetic forward priming, not recovered from
        // missing device logs. Prefix pause gates preserve the observed cancellation
        // path; this is a bounded correctness replay, not a NAS throughput benchmark.
        let before = s.metrics, demands = b.demands.count
        let starts: [UInt64] = [15728640,15466496,14745600,14876672,15138816,15400960]
        let lengths: [UInt64] = [65536,65536,65536,196608,131072,131072]
        s.setPrefetchEnabled(true)
        for i in 0..<6 {
            try await read(s,b,starts[i]..<(starts[i]+lengths[i]))
            try await Task.sleep(for:.milliseconds([490,330,5,5,5,5][i]))
        }
        #expect(s.metrics.historyHitBytes-before.historyHitBytes == 655360)
        #expect(s.metrics.missBytes-before.missBytes == 0); #expect(b.demands.count == demands)
        // Build96: explicit enable, not a low history hit, resumes the unspent
        // valid window. Low reads never refresh its cursor, target or two-read quota.
        #expect(b.speculation == [20*m..<22*m,22*m..<24*m])
        #expect(s.metrics.speculativeBytes == 4*m)
        #expect(s.metrics.storageAllocatedBytes == 32*1_048_576)
        #expect(s.metrics.validCacheBytes == 24*1_048_576)
        #expect(b.maxOutstanding == 1)
        try await s.awaitPlaybackCleanup()
    }
}
