import Foundation
import Testing
#if os(macOS)
import Darwin
#endif
@testable import VistaCore

/// Synthetic range-generated Data only; no whole movie fixture, SMB or device work.
@Suite(.serialized)
@MainActor struct PlaybackSharedRingTests {
    private let file = try! MediaFile(components: ["generated-ring.mp4"])
    private let mib = 1_048_576
    // Shared lazy generator for the explicit 32 MiB baseline and 64 MiB capacity checks.
    @MainActor final class Source: PlaybackCacheSource {
        var reads: [Range<UInt64>] = [], speculative: [Range<UInt64>] = []
        var blockedPrefetch: Set<Int> = [], blockedDemand: Range<UInt64>?
        var gate: CheckedContinuation<Void, Never>?
        var token: UInt64? = 1, stopped = false
        var outstanding = 0, maxOutstanding = 0, maxGeneratedBytes = 0
        var largestSegmentCount = 0
        var isPlaybackRecovering: Bool { false }
        var recoveryActiveStartedAt: TimeInterval? { nil }
        var recoveryActiveElapsed: TimeInterval { 0 }
        func playbackCacheEpoch() throws -> UInt64? { try Task.checkCancellation(); return stopped ? nil : token }
        func fileSize(for file: MediaFile) async throws -> UInt64 { 128 * 1_048_576 }
        // Both page and within-page positions differ after the 32 MiB ring wraps.
        static func data(_ range: Range<UInt64>) -> Data {
            var data = Data(count: range.count)
            data.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for i in bytes.indices {
                    let position = range.lowerBound + UInt64(i)
                    bytes[i] = UInt8(truncatingIfNeeded: position &+ (position >> 12) &+ (position >> 20))
                }
            }
            return data
        }
        func produce(_ range: Range<UInt64>) -> Data {
            maxGeneratedBytes = max(maxGeneratedBytes, range.count)
            return Self.data(range)
        }
        func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            reads.append(range); outstanding += 1; maxOutstanding = max(maxOutstanding, outstanding)
            defer { outstanding -= 1 }
            if blockedDemand == range { await withCheckedContinuation { gate = $0 } }
            try Task.checkCancellation()
            return produce(range)
        }
        func readForPrefetch(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            speculative.append(range); outstanding += 1; maxOutstanding = max(maxOutstanding, outstanding)
            defer { outstanding -= 1 }
            if blockedPrefetch.contains(speculative.count) { await withCheckedContinuation { gate = $0 } }
            return produce(range)
        }
        func readCompletingCachedSegments(_ file: MediaFile, range: Range<UInt64>, segments: [PlaybackCachedSegment], epoch: UInt64) async throws -> PlaybackCachedReadResult {
            largestSegmentCount = max(largestSegmentCount, segments.count)
            guard epoch == token else { return .init(data: try await read(file, range: range), usedCachedBytes: 0) }
            var cursor = range.lowerBound, result = Data(capacity: range.count), used = 0
            for segment in segments {
                if cursor < segment.range.lowerBound { result.append(try await read(file, range: cursor..<segment.range.lowerBound)) }
                result.append(segment.data); used += segment.data.count; cursor = segment.range.upperBound
            }
            if cursor < range.upperBound { result.append(try await read(file, range: cursor..<range.upperBound)) }
            return .init(data: result, usedCachedBytes: used)
        }
        func release() { let saved = gate; gate = nil; saved?.resume() }
        func setPlaybackSceneActive(_ active: Bool) { if !active { token = nil } }
        func cancelPlayback() { stopped = true }
        func awaitPlaybackCleanup() async throws {}
    }
    private func until(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate(), "Synthetic ring gate did not reach expected state")
    }
    private func conserved(_ source: PlaybackPrefetchSource) {
        let m = source.metrics
        #expect(m.speculativeBytes == m.hitBytes + m.joinedBytes + m.discardedBytes + m.retiredSpeculativeBytes + UInt64(m.residentBytes))
        #expect(m.diagnostics.discardedBytes == m.discardedBytes)
    }
    static func footprint() -> UInt64? {
        #if os(macOS)
        var value = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? value.phys_footprint : nil
        #else
        return nil
        #endif
    }

    @Test func multipleWrapsPreserveRepliesAndCopyOnlyNewHistoryBytes() async throws {
        let base = Source(), source = PlaybackPrefetchSource(file: file, source: base,
            configuration: .init(capacityBytes: 16, chunkBytes: 8, totalCapacityBytes: 32))
        source.setPrefetchEnabled(true)
        _ = try await source.read(file, range: 0..<8)
        let saved = try await source.read(file, range: 0..<8) // Keep an actual ring-hit reply.
        #expect(base.reads.count == 1 && source.metrics.historyHitBytes == 8)
        source.setPrefetchEnabled(false, reason: .pause)
        for offset in stride(from: 8, to: 80, by: 8) {
            #expect(try await source.read(file, range: UInt64(offset)..<UInt64(offset + 8)) == Source.data(UInt64(offset)..<UInt64(offset + 8)))
        }
        #expect(source.metrics.historyBytes == 32 && source.metrics.maxTotalCacheBytes == 40)
        #expect(source.metrics.storageAllocatedBytes == 32 && source.metrics.storageWrittenBytes == 80)
        #expect(saved == Source.data(0..<8))
        let before = base.reads.count
        #expect(try await source.read(file, range: 54..<70) == Source.data(54..<70))
        #expect(try await source.read(file, range: 60..<68) == Source.data(60..<68))
        #expect(base.reads.count == before && source.metrics.storageWrittenBytes == 80)
        #expect(try await source.read(file, range: 46..<54) == Source.data(46..<54))
        #expect(base.reads.last == 46..<48 && source.metrics.historyHitBytes == 38)
        #expect(base.largestSegmentCount <= 4 && source.metrics.maxDemandSnapshotBytes <= 16)
        #expect(try await source.read(file, range: 128..<136) == Source.data(128..<136))
        #expect(source.metrics.historyBytes == 32 && source.metrics.totalCacheBytes == 32)
        #expect(base.maxOutstanding == 1)
        conserved(source)
        try await source.awaitPlaybackCleanup()
        #expect(source.metrics.storageAllocatedBytes == 0 && source.metrics.totalCacheBytes == 0)
        #expect(saved == Source.data(0..<8))
    }

    @Test func fullThirtyTwoMiBHistorySurvivesReservationsUntilCompletedWrites() async throws {
        let base = Source(), source = PlaybackPrefetchSource(file: file, source: base,
            configuration: .init(totalCapacityBytes: 32 * mib))
        var observations: [[String: Any]] = []
        func observe(_ stage: String) {
            let m = source.metrics
            observations.append(["stage": stage, "processPhysFootprintBytes": Self.footprint() as Any? ?? NSNull(),
                "ringAllocatedBytes": m.storageAllocatedBytes, "cacheAndReservationBytes": m.totalCacheBytes,
                "historyBytes": m.historyBytes, "readyBytes": m.residentBytes,
                "reservationBytes": m.inFlightReservedBytes, "snapshotBytes": m.demandSnapshotBytes,
                "ringWrittenBytes": m.storageWrittenBytes])
        }
        observe("before")
        source.setPrefetchEnabled(true)
        _ = try await source.read(file, range: 0..<UInt64(2 * mib))
        let saved = try await source.read(file, range: 0..<UInt64(2 * mib)) // Independent cache-hit reply.
        #expect(base.reads.count == 1 && source.metrics.historyHitBytes == 2 * mib)
        source.setPrefetchEnabled(false, reason: .pause)
        for offset in stride(from: 2 * mib, to: 32 * mib, by: 2 * mib) {
            _ = try await source.read(file, range: UInt64(offset)..<UInt64(offset + 2 * mib))
        }
        #expect(source.metrics.historyBytes == 32 * mib && source.metrics.totalCacheBytes == 32 * mib)
        #expect(source.metrics.storageWrittenBytes == 32 * mib)
        observe("filled32MiB")
        _ = try await source.fileSize(for: file)
        base.blockedPrefetch = [1, 2]
        source.setPrefetchEnabled(true)
        _ = try await source.read(file, range: UInt64(32 * mib)..<UInt64(34 * mib))
        try await until { base.gate != nil }
        #expect(base.speculative == [UInt64(34 * mib)..<UInt64(36 * mib)])
        #expect(source.metrics.historyBytes == 32 * mib && source.metrics.inFlightReservedBytes == 2 * mib)
        #expect(source.metrics.totalCacheBytes == 34 * mib)
        observe("firstReserved")
        base.release()
        try await until { base.speculative.count == 2 && base.gate != nil }
        #expect(source.metrics.historyBytes == 30 * mib && source.metrics.residentBytes == 2 * mib)
        #expect(source.metrics.totalCacheBytes == 34 * mib && source.metrics.inFlightReservedBytes == 2 * mib)
        observe("secondReserved")
        source.setPrefetchEnabled(false, reason: .pause)
        base.release()
        try await until { source.metrics.residentBytes == 4 * mib }
        #expect(source.metrics.storageWrittenBytes == 38 * mib)
        let reads = base.reads.count
        // Start 22.7 MiB behind the current history end, matching the observed distance.
        let backward = UInt64(34 * mib - 23_802_675)..<UInt64(36 * mib - 23_802_675)
        #expect(try await source.read(file, range: backward) == Source.data(backward))
        #expect(try await source.read(file, range: UInt64(31 * mib)..<UInt64(33 * mib)) == Source.data(UInt64(31 * mib)..<UInt64(33 * mib)))
        #expect(base.reads.count == reads && source.metrics.storageWrittenBytes == 38 * mib)
        base.blockedDemand = UInt64(5 * mib)..<UInt64(6 * mib)
        let gap = Task { try await source.read(file, range: UInt64(5 * mib)..<UInt64(7 * mib)) }
        try await until { base.gate != nil }
        #expect(source.metrics.demandSnapshotBytes == mib)
        observe("partialGapSuspended")
        base.blockedDemand = nil; base.release()
        #expect(try await gap.value == Source.data(UInt64(5 * mib)..<UInt64(7 * mib)))
        #expect(source.metrics.maxTotalCacheBytes == 34 * mib && source.metrics.maxStorageAllocatedBytes == 32 * mib)
        #expect(source.metrics.maxDemandSnapshotBytes == 2 * mib && base.maxGeneratedBytes == 2 * mib)
        #expect(base.maxOutstanding == 1 && base.speculative.count == 2)
        #expect(saved == Source.data(0..<UInt64(2 * mib)))
        observe("wrappedAndFilledGap")
        // A 36 MiB backward distance remains outside this 32 MiB shared window.
        let outside = UInt64(2 * mib)..<UInt64(4 * mib)
        let beforeOutside = base.reads.count
        #expect(try await source.read(file, range: outside) == Source.data(outside))
        #expect(base.reads.count == beforeOutside + 1 && base.reads.last == outside)
        conserved(source)
        try await source.awaitPlaybackCleanup()
        #expect(source.metrics.storageAllocatedBytes == 0 && source.metrics.totalCacheBytes == 0)
        observe("cleaned")
        let summary: [String: Any] = ["scope": "one synthetic wrapper in test process, not Vista or AVPlayer", "observations": observations,
            "externallyHeldReplyBytes": saved.count, "maximumSnapshotPayloadBytes": source.metrics.maxDemandSnapshotBytes,
            "maximumGeneratedSourcePayloadBytes": base.maxGeneratedBytes, "maximumRingPayloadBytes": source.metrics.maxStorageAllocatedBytes,
            "maximumArenaPlusReadReservationBytes": source.metrics.maxTotalCacheBytes,
            "maximumMetadataEntries": source.metrics.maxCacheMetadataEntries,
            "maximumRetainedMetadataAllocationBytes": source.metrics.maxCacheMetadataAllocatedBytes]
        print("SHARED_RING_MEMORY_JSON " + String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self))
    }

    @Test(arguments: ["pauseCancel", "sceneFlush"])
    func wrappedDemandSnapshotsSurvivePauseCancellationOrSceneFlush(boundary: String) async throws {
        let base = Source(), source = PlaybackPrefetchSource(file: file, source: base,
            configuration: .init(capacityBytes: 16, chunkBytes: 8, totalCapacityBytes: 32))
        source.setPrefetchEnabled(true)
        for offset in stride(from: 0, to: 80, by: 8) {
            _ = try await source.read(file, range: UInt64(offset)..<UInt64(offset + 8))
        }
        _ = try await source.fileSize(for: file)
        _ = try await source.read(file, range: 80..<88)
        try await until { source.metrics.residentBytes == 16 }
        source.setPrefetchEnabled(false, reason: .pause)
        #expect(source.metrics.historyBytes == 16 && source.metrics.totalCacheBytes == 32)
        base.blockedDemand = 68..<72
        let demand = Task { try await source.read(file, range: 68..<108) }
        try await until { base.gate != nil }
        #expect(source.metrics.demandSnapshotBytes == 32)
        if boundary == "pauseCancel" {
            demand.cancel()
            do { _ = try await demand.value; Issue.record("Expected cancellation") }
            catch { #expect(error is CancellationError) }
        } else {
            source.setPlaybackSceneActive(false)
            #expect(source.metrics.storageAllocatedBytes == 0)
        }
        base.blockedDemand = nil; base.release()
        if boundary == "pauseCancel" {
            try await until { source.metrics.residentBytes == 16 && source.metrics.demandSnapshotBytes == 0 }
            #expect(source.metrics.storageAllocatedBytes == 32 && source.metrics.storageWrittenBytes == 104)
            #expect(try await source.read(file, range: 80..<100) == Source.data(80..<100))
            #expect(source.metrics.historyHitBytes == 8 && source.metrics.hitBytes == 12)
        } else {
            #expect(try await demand.value == Source.data(68..<108))
            #expect(source.metrics.storageAllocatedBytes == 0 && source.metrics.totalCacheBytes == 0)
            #expect(source.metrics.historyHitBytes == 16 && source.metrics.hitBytes == 16)
        }
        #expect(base.maxOutstanding == 1 && source.metrics.maxTotalCacheBytes == 72)
        conserved(source)
        try await source.awaitPlaybackCleanup()
    }

    @Test(arguments: ["seek", "epoch", "inactive", "stop", "memory"])
    func wrappedHistoryAndInflightBytesRejectInvalidation(boundary: String) async throws {
        let base = Source(), source = PlaybackPrefetchSource(file: file, source: base,
            configuration: .init(capacityBytes: 16, chunkBytes: 8, totalCapacityBytes: 32))
        source.setPrefetchEnabled(true)
        for offset in stride(from: 0, to: 64, by: 8) {
            _ = try await source.read(file, range: UInt64(offset)..<UInt64(offset + 8))
        }
        _ = try await source.fileSize(for: file)
        base.blockedPrefetch = [1]
        _ = try await source.read(file, range: 64..<72)
        try await until { base.gate != nil }
        source.setPrefetchEnabled(false, reason: .pause)
        #expect(source.metrics.storageAllocatedBytes == 32)
        switch boundary {
        case "seek": source.invalidatePrefetch(reason: .seek)
        case "epoch": base.token = 2
        case "inactive": source.setPlaybackSceneActive(false)
        case "stop": source.cancelPlayback()
        default: source.handleMemoryPressure()
        }
        if boundary == "seek" {
            #expect(source.metrics.storageAllocatedBytes == 32 && source.metrics.historyBytes == 32)
            #expect(source.metrics.inFlightReservedBytes == 8)
        } else if boundary != "epoch" {
            #expect(source.metrics.storageAllocatedBytes == 0 && source.metrics.inFlightReservedBytes == 8)
        }
        base.release()
        try await until { source.metrics.inFlightReservedBytes == 0 }
        #expect(source.metrics.historyBytes == (boundary == "seek" ? 32 : 0) && source.metrics.residentBytes == 0)
        #expect(source.metrics.storageAllocatedBytes == (boundary == "seek" ? 32 : 0) && source.metrics.discardedBytes == 8)
        if boundary == "seek" {
            let reads = base.reads.count
            #expect(try await source.read(file, range: 40..<48) == Source.data(40..<48))
            #expect(base.reads.count == reads)
        }
        conserved(source)
        try await source.awaitPlaybackCleanup()
    }
}
