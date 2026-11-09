import Foundation
import Testing
@testable import VistaCore

/// Data-only gates. This suite never opens files, network connections or devices.
@Suite(.serialized)
@MainActor struct PlaybackSlidingCacheTests {
    private let file = try! MediaFile(components: ["generated-sliding.mp4"])
    @MainActor private final class Source: PlaybackCacheSource {
        var bytes: Data
        var token: UInt64? = 1
        var reads: [Range<UInt64>] = [], speculative: [Range<UInt64>] = []
        var rejectSegments = false, changeEpochOnDemand = false
        var gate: CheckedContinuation<Void, Never>?
        var blockPrefetchAt: Int?, blockDemand = false
        var active = true, stopped = false, outstanding = 0, maxOutstanding = 0
        var isPlaybackRecovering: Bool { false }
        var recoveryActiveStartedAt: TimeInterval? { nil }
        var recoveryActiveElapsed: TimeInterval { 0 }
        init(count: Int = 256) {
            if count == 256 { bytes = Data(0...255) }
            else { bytes = Data(repeating: 0x5a, count: count) }
        }
        func playbackCacheEpoch() throws -> UInt64? {
            try Task.checkCancellation()
            if stopped { throw CancellationError() }
            return active ? token : nil
        }
        func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(bytes.count) }
        func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            reads.append(range); outstanding += 1; maxOutstanding = max(maxOutstanding, outstanding)
            defer { outstanding -= 1 }
            if blockDemand { await withCheckedContinuation { gate = $0 } }
            if changeEpochOnDemand { token = 2 }
            return bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        func readForPrefetch(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            speculative.append(range); outstanding += 1; maxOutstanding = max(maxOutstanding, outstanding)
            defer { outstanding -= 1 }
            if blockPrefetchAt == speculative.count { await withCheckedContinuation { gate = $0 } }
            return bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        func readCompletingCachedSegments(_ file: MediaFile, range: Range<UInt64>, segments: [PlaybackCachedSegment], epoch: UInt64) async throws -> PlaybackCachedReadResult {
            if rejectSegments || token != epoch {
                return .init(data: try await read(file, range: range), usedCachedBytes: 0)
            }
            var cursor = range.lowerBound, result = Data(), used = 0
            for segment in segments {
                if cursor < segment.range.lowerBound { result.append(try await read(file, range: cursor..<segment.range.lowerBound)) }
                result.append(segment.data); used += segment.data.count; cursor = segment.range.upperBound
            }
            if cursor < range.upperBound { result.append(try await read(file, range: cursor..<range.upperBound)) }
            try Task.checkCancellation()
            return .init(data: result, usedCachedBytes: used)
        }
        func release() { let saved = gate; gate = nil; saved?.resume() }
        func setPlaybackSceneActive(_ active: Bool) { self.active = active }
        func cancelPlayback() { stopped = true }
        func awaitPlaybackCleanup() async throws {}
    }
    @MainActor private final class Records { var values: [PrefetchDiagnosticRecord] = [] }
    private func make(_ base: Source, _ records: Records = Records()) -> PlaybackPrefetchSource {
        PlaybackPrefetchSource(file: file, source: base,
            configuration: .init(capacityBytes: 16, chunkBytes: 8, historyCapacityBytes: 8),
            diagnosticSink: { records.values.append($0) })
    }
    private func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        Issue.record("Sliding-cache Data gate did not reach expected state")
    }
    private func prime(_ source: PlaybackPrefetchSource, unit: UInt64 = 8) async throws {
        _ = try await source.fileSize(for: file)
        source.setPrefetchEnabled(true)
        _ = try await source.read(file, range: 0..<unit)
        _ = try await source.read(file, range: unit..<(2 * unit))
    }
    private func conserved(_ source: PlaybackPrefetchSource) {
        let metrics = source.metrics
        #expect(metrics.speculativeBytes == metrics.hitBytes + metrics.joinedBytes + metrics.discardedBytes + metrics.retiredSpeculativeBytes + UInt64(metrics.residentBytes))
        #expect(metrics.diagnostics.discardedBytes == metrics.discardedBytes)
    }

    @Test func adjacentMissSlidesHistoryAndBackwardReadReusesOldTail() async throws {
        // First use distinct bytes to detect incorrect assembly, then the real 2 MiB + 704 KiB shape.
        for (capacity, added) in [(8, 3), (2 * 1_048_576, 704 * 1024)] {
            let base = Source(count: capacity == 8 ? 256 : 4 * capacity), records = Records()
            let source = PlaybackPrefetchSource(file: file, source: base,
                configuration: .init(capacityBytes: 2 * capacity, chunkBytes: capacity, historyCapacityBytes: capacity),
                diagnosticSink: { records.values.append($0) })
            source.setPrefetchEnabled(true)
            _ = try await source.read(file, range: 0..<UInt64(capacity))
            source.setPrefetchEnabled(false, reason: .pause) // No speculative intersection can mask the miss.
            let adjacent = UInt64(capacity)..<UInt64(capacity + added)
            #expect(try await source.read(file, range: adjacent) == base.bytes.subdata(in: capacity..<(capacity + added)))
            #expect(source.metrics.historyBytes == capacity)
            #expect(source.metrics.diagnostics.historyEvictedBytes == UInt64(added))
            let backward = UInt64(added)..<UInt64(capacity + added)
            #expect(try await source.read(file, range: backward) == base.bytes.subdata(in: added..<(capacity + added)))
            #expect(base.reads == [0..<UInt64(capacity), adjacent])
            #expect(source.metrics.historyHitBytes == UInt64(capacity))
            #expect(source.metrics.maxTotalCacheBytes <= 3 * capacity && base.maxOutstanding == 1)
            #expect(!records.values.contains { $0.event == .historyEvicted && $0.reason == .noOverlap })
            conserved(source)
            try await source.awaitPlaybackCleanup()
        }
    }

    @Test func adjacentHistorySurvivesSeekCancellationAndDisjointJumpButNotEpochChange() async throws {
        for boundary in 0..<4 {
            let base = Source(), source = make(base)
            source.setPrefetchEnabled(true)
            _ = try await source.read(file, range: 0..<8)
            source.setPrefetchEnabled(false, reason: .pause)
            if boundary == 3 {
                #expect(try await source.read(file, range: 10..<13) == Data(10..<13))
                #expect(source.metrics.historyBytes == 8)
            } else {
                base.blockDemand = true
                let demand = Task { try await source.read(file, range: 8..<11) }
                await until { base.gate != nil }
                if boundary == 0 { base.changeEpochOnDemand = true }
                if boundary == 1 { source.invalidatePrefetch(reason: .seek) }
                if boundary == 2 {
                    source.setPrefetchEnabled(true) // Non-paused cancellation also retains completed bytes.
                    demand.cancel()
                }
                base.blockDemand = false; base.release()
                if boundary == 2 {
                    do { _ = try await demand.value; Issue.record("Expected cancellation") }
                    catch { #expect(error is CancellationError) }
                } else { #expect(try await demand.value == Data(8..<11)) }
                #expect(source.metrics.historyBytes == (boundary == 0 ? 0 : 8))
            }
            #expect(source.metrics.maxTotalCacheBytes <= 56 && base.maxOutstanding == 1)
            try await source.awaitPlaybackCleanup()
        }
    }

    @Test func historyChurnReservesPrefetchDetailsEvenAfterLastPrefetchExists() async throws {
        let base = Source(), records = Records(), source = make(base, records)
        _ = try await source.fileSize(for: file)
        source.setPrefetchEnabled(true)
        _ = try await source.read(file, range: 0..<8)
        source.setPrefetchEnabled(false, reason: .pause)
        for _ in 0..<150 { _ = try await source.read(file, range: 0..<8) }
        #expect(records.values.count == 64)
        #expect(source.metrics.diagnostics.prefetchGeneratedRecords == 0)
        source.setPrefetchEnabled(true)
        _ = try await source.read(file, range: 8..<16)
        await until { source.metrics.residentBytes == 16 }
        #expect(records.values.contains { $0.event == .begin })
        #expect(records.values.contains { $0.event == .retained })
        source.setPrefetchEnabled(false, reason: .pause)
        _ = try await source.read(file, range: 16..<32)
        #expect(records.values.contains { $0.event == .prefixUsed })
        let before = source.metrics.diagnostics
        for _ in 0..<150 { _ = try await source.read(file, range: 24..<32) }
        #expect(source.metrics.diagnostics.prefetchGeneratedRecords == before.prefetchGeneratedRecords)
        #expect(source.metrics.diagnostics.historySuppressedRecords > before.historySuppressedRecords)
        try await source.awaitPlaybackCleanup()
        let final = source.metrics.diagnostics
        #expect(records.values.contains { $0.event == .cleanup })
        #expect(final.historyGeneratedRecords - final.historySuppressedRecords == 64)
        #expect(final.detailedRecords == UInt64(records.values.count))
        #expect(final.suppressedRecords == final.historySuppressedRecords + final.prefetchSuppressedRecords)
        #expect(final.detailedRecords <= PrefetchDiagnosticRecord.detailLimit)
        #expect(source.metrics.historyHitBytes == 2400)
        conserved(source)
    }

    @Test func productionHistorySharesThirtyTwoMiBWithTwoSuccessiveReads() async throws {
        let unit = 2 * 1_048_576
        let base = Source(count: 8 * unit), records = Records()
        base.blockPrefetchAt = 2
        let source = PlaybackPrefetchSource(file: file, source: base, diagnosticSink: { records.values.append($0) })
        try await prime(source, unit: UInt64(unit))
        await until { base.gate != nil }
        #expect(base.speculative == [UInt64(2 * unit)..<UInt64(3 * unit), UInt64(3 * unit)..<UInt64(4 * unit)])
        #expect(source.metrics.historyBytes == 2 * unit && source.metrics.residentBytes == unit)
        #expect(source.metrics.inFlightReservedBytes == unit && source.metrics.totalCacheBytes == 4 * unit)
        #expect(source.metrics.maxTotalCacheBytes == 4 * unit && base.maxOutstanding == 1)
        #expect(records.values.allSatisfy { $0.totalCacheBytes <= 4 * unit })
        base.blockPrefetchAt = nil; base.release()
        await until { source.metrics.residentBytes == 2 * unit }
        #expect(source.metrics.historyBytes == 2 * unit && source.metrics.totalCacheBytes == 4 * unit)
        #expect(source.metrics.inFlightReservedBytes == 0)
        conserved(source)
        try await source.awaitPlaybackCleanup()
        #expect(source.metrics.totalCacheBytes == 0)
        conserved(source)
    }

    @Test func deliveredPrefetchBecomesHistoryAndRepeatedUseIsNotAnotherPrefetchHit() async throws {
        let base = Source(), records = Records(), source = make(base, records)
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        source.setPrefetchEnabled(false, reason: .pause)
        #expect(try await source.read(file, range: 16..<24) == Data(16..<24))
        #expect(source.metrics.hitBytes == 8 && source.metrics.historyBytes == 8)
        #expect(try await source.read(file, range: 16..<24) == Data(16..<24))
        #expect(source.metrics.hitBytes == 8 && source.metrics.historyHitBytes == 8)
        #expect(base.reads == [0..<8, 8..<16])
        #expect(records.values.contains { $0.event == .historyUsed && $0.usedHistoryBytes == 8 })
        #expect(source.metrics.diagnostics.historyEvictedBytes == 16 && source.metrics.discardedBytes == 0)
        conserved(source)
        try await source.awaitPlaybackCleanup()
        conserved(source)
    }

    @Test func earlierDemandIntersectionsReuseHistoryAndReadyOrInflightBytes() async throws {
        // Scaled Build80 shapes: [0,2MiB) prefetched with demand starting 0.5,
        // 0.625, or 0.75MiB earlier; the final demand arrives while read is in flight.
        for (range, inFlight) in [(12..<28, false), (11..<27, false), (10..<20, true)] as [(Range<UInt64>, Bool)] {
            let base = Source(), records = Records()
            if inFlight { base.blockPrefetchAt = 1 }
            let source = make(base, records)
            try await prime(source)
            await until { inFlight ? base.gate != nil : source.metrics.residentBytes == 16 }
            let demand = Task { try await source.read(file, range: range) }
            if inFlight {
                await until { source.metrics.speculativeWaitCount == 1 }
                #expect(base.reads.count == 2)
                base.blockPrefetchAt = nil; base.release()
            }
            #expect(try await demand.value == base.bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)))
            #expect(base.reads == [0..<8, 8..<16])
            #expect(source.metrics.historyHitBytes == UInt64(16 - range.lowerBound))
            #expect(source.metrics.hitBytes == (inFlight ? 0 : UInt64(range.upperBound - 16)))
            #expect(source.metrics.joinedBytes == (inFlight ? 4 : 0))
            #expect(source.metrics.diagnostics.joinedDemandCount == (inFlight ? 1 : 0))
            if inFlight { #expect(source.metrics.speculativeWaitSeconds > 0) }
            #expect(base.maxOutstanding == 1 && source.metrics.maxTotalCacheBytes <= 56)
            conserved(source)
            try await source.awaitPlaybackCleanup()
            conserved(source)
        }
    }

    @Test func backwardThenAdjacentDemandStartsPrefetchBeyondRetainedHistory() async throws {
        let base = Source(), records = Records(); base.blockPrefetchAt = 1
        let source = make(base, records)
        _ = try await source.fileSize(for: file)
        source.setPrefetchEnabled(true)
        #expect(try await source.read(file, range: 0..<8) == Data(0..<8))
        #expect(try await source.read(file, range: 2..<4) == Data(2..<4))
        #expect(records.values.contains {
            $0.event == .demandEnqueued && $0.prefetchID == 0 && $0.demandDelta == nil && $0.historyDelta == 2
        })
        #expect(try await source.read(file, range: 4..<6) == Data(4..<6))
        await until { base.gate != nil }
        #expect(source.metrics.historyBytes == 8)
        #expect(base.speculative == [8..<16]) // History still ends at 8, not at demand end 6.
        let demand = Task { try await source.read(file, range: 6..<14) }
        await until { source.metrics.speculativeWaitCount == 1 }
        source.setPrefetchEnabled(false, reason: .pause)
        base.blockPrefetchAt = nil; base.release()
        #expect(try await demand.value == Data(6..<14))
        #expect(base.reads == [0..<8] && base.maxOutstanding == 1)
        #expect(source.metrics.historyHitBytes == 6) // Two earlier hits plus this demand's two bytes.
        #expect(source.metrics.joinedBytes == 6 && source.metrics.hitBytes == 0)
        #expect(source.metrics.residentBytes == 2 && source.metrics.discardedBytes == 0)
        #expect(source.metrics.maxTotalCacheBytes <= 56)
        conserved(source)
        try await source.awaitPlaybackCleanup()
        conserved(source)
    }

    @Test func headAndTailGapsUseSingleCachedCompletionAndNoRepeatedHistoryCredit() async throws {
        let base = Source(), source = make(base)
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        source.setPrefetchEnabled(false, reason: .pause)
        #expect(try await source.read(file, range: 4..<36) == Data(4..<36))
        #expect(base.reads == [0..<8, 8..<16, 4..<8, 32..<36])
        #expect(source.metrics.historyHitBytes == 8 && source.metrics.hitBytes == 16)
        #expect(source.metrics.missBytes == 24 && source.metrics.discardedBytes == 0)
        #expect(source.metrics.historyBytes == 8 && source.metrics.maxTotalCacheBytes <= 56)
        conserved(source)
        try await source.awaitPlaybackCleanup()
    }

    @Test func pauseRetainsReadyAndLateCompletionThenResumeUsesThem() async throws {
        let base = Source(), records = Records(); base.blockPrefetchAt = 2
        let source = make(base, records)
        try await prime(source)
        await until { base.gate != nil }
        source.setPrefetchEnabled(false, reason: .pause)
        #expect(source.metrics.historyBytes == 8 && source.metrics.residentBytes == 8)
        base.blockPrefetchAt = nil; base.release()
        await until { source.metrics.residentBytes == 16 }
        for _ in 0..<30 { await Task.yield() }
        #expect(base.speculative.count == 2 && source.metrics.discardedBytes == 0)
        #expect(records.values.contains { $0.event == .admissionPaused && $0.reason == .pauseRetained })
        source.setPrefetchEnabled(true)
        #expect(try await source.read(file, range: 12..<28) == Data(12..<28))
        #expect(source.metrics.historyHitBytes == 4 && source.metrics.hitBytes == 12)
        #expect(base.reads == [0..<8, 8..<16] && source.metrics.discardedBytes == 0)
        conserved(source)
        try await source.awaitPlaybackCleanup()
        conserved(source)
    }

    @Test func cancelledPausedDemandStillKeepsLatePrefetchCompletion() async throws {
        let base = Source(); base.blockPrefetchAt = 2
        let source = make(base)
        try await prime(source)
        await until { base.gate != nil }
        let demand = Task { try await source.read(file, range: 24..<32) }
        await until { source.metrics.speculativeWaitCount == 1 }
        source.setPrefetchEnabled(false, reason: .pause)
        demand.cancel()
        do { _ = try await demand.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        base.blockPrefetchAt = nil; base.release()
        await until { source.metrics.residentBytes == 16 }
        #expect(source.metrics.historyBytes == 8 && source.metrics.totalCacheBytes == 24)
        #expect(source.metrics.discardedBytes == 0 && source.metrics.joinedBytes == 0)
        #expect(source.metrics.speculativeWaitCount == 1 && source.metrics.speculativeWaitSeconds > 0)
        conserved(source)
        try await source.awaitPlaybackCleanup()
    }

    @Test func cancelledPausedGapDemandRestoresItsSlicesAndUnrelatedHistory() async throws {
        let base = Source(), source = make(base)
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        base.blockDemand = true
        let demand = Task { try await source.read(file, range: 4..<36) }
        await until { base.gate != nil }
        source.setPrefetchEnabled(false, reason: .pause)
        demand.cancel()
        do { _ = try await demand.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        base.blockDemand = false; base.release()
        await until { source.metrics.residentBytes == 16 && source.metrics.inFlightReservedBytes == 0 }
        #expect(source.metrics.historyBytes == 8 && source.metrics.totalCacheBytes == 24)
        #expect(source.metrics.discardedBytes == 0 && source.metrics.hitBytes == 0 && source.metrics.historyHitBytes == 0)
        #expect(try await source.read(file, range: 12..<28) == Data(12..<28))
        #expect(source.metrics.historyHitBytes == 4 && source.metrics.hitBytes == 12)
        #expect(source.metrics.maxTotalCacheBytes <= 56 && base.maxOutstanding == 1)
        conserved(source)
        try await source.awaitPlaybackCleanup()
    }

    @Test func pauseFollowedBySeekSceneOrStopStillRejectsLateOldBytes() async throws {
        for reason in [PrefetchInvalidationReason.seek, .sceneInactive, .stop] {
            let base = Source(); base.blockPrefetchAt = 2
            let source = make(base)
            try await prime(source)
            await until { base.gate != nil }
            source.setPrefetchEnabled(false, reason: .pause)
            if reason == .stop { source.cancelPlayback() }
            else if reason == .sceneInactive { source.setPlaybackSceneActive(false) }
            else { source.invalidatePrefetch(reason: reason) }
            #expect(source.metrics.historyBytes == (reason == .seek ? 8 : 0))
            #expect(source.metrics.residentBytes == (reason == .seek ? 8 : 0))
            #expect(source.metrics.totalCacheBytes == (reason == .seek ? 24 : 8))
            base.blockPrefetchAt = nil; base.release()
            await until { source.metrics.inFlightReservedBytes == 0 }
            #expect(source.metrics.totalCacheBytes == (reason == .seek ? 16 : 0))
            #expect(source.metrics.discardedBytes == (reason == .seek ? 8 : 16))
            conserved(source)
            try await source.awaitPlaybackCleanup()
        }
    }

    @Test func epochChangeFlushesHistoryAndSourceFallbackHasNoCacheCredit() async throws {
        let base = Source(), source = make(base)
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        source.setPrefetchEnabled(false, reason: .pause)
        base.rejectSegments = true; base.changeEpochOnDemand = true
        #expect(try await source.read(file, range: 4..<36) == Data(4..<36))
        #expect(base.reads == [0..<8, 8..<16, 4..<36])
        #expect(source.metrics.historyHitBytes == 0 && source.metrics.hitBytes == 0 && source.metrics.joinedBytes == 0)
        #expect(source.metrics.historyBytes == 0 && source.metrics.residentBytes == 0)
        #expect(source.metrics.discardedBytes == 16)
        #expect(source.metrics.diagnostics.discardedEpochBytes == 16)
        conserved(source)
        try await source.awaitPlaybackCleanup()
    }

    @Test func sceneFlushAllowsAlreadyAdmittedGapDemandWithoutRetainingOrRearmingIt() async throws {
        let base = Source(), records = Records(), source = make(base, records)
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        base.blockDemand = true
        let demand = Task { try await source.read(file, range: 12..<36) }
        await until { base.gate != nil }
        source.setPlaybackSceneActive(false)
        #expect(source.metrics.historyBytes == 0 && source.metrics.residentBytes == 0)
        #expect(source.metrics.totalCacheBytes == 24) // The active 24-byte source reservation is separate from snapshots.
        #expect(records.values.last?.demandOwnedBytes == 20)
        #expect(records.values.last?.totalCacheBytes == 24)
        base.blockDemand = false; base.release()
        #expect(try await demand.value == Data(12..<36))
        #expect(source.metrics.historyHitBytes == 4 && source.metrics.hitBytes == 16)
        #expect(source.metrics.totalCacheBytes == 0 && base.speculative.count == 2)
        conserved(source)
        try await source.awaitPlaybackCleanup()
    }

    @Test func cancelledGapDemandDoesNotRetainOrCreditItsDetachedSpeculation() async throws {
        let base = Source(), source = make(base)
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        base.blockDemand = true
        let demand = Task { try await source.read(file, range: 4..<36) }
        await until { base.gate != nil }
        #expect(source.metrics.totalCacheBytes <= 56)
        demand.cancel()
        do { _ = try await demand.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        source.invalidatePrefetch(reason: .seek)
        base.blockDemand = false; base.release()
        try await source.awaitPlaybackCleanup()
        #expect(source.metrics.historyHitBytes == 0 && source.metrics.hitBytes == 0)
        #expect(source.metrics.totalCacheBytes == 0 && source.metrics.discardedBytes == 16)
        #expect(base.maxOutstanding == 1)
        conserved(source)
    }
    @Test func retainedRingMatchesBothBuild84Counterexamples() async throws {
        let mib = 1_048_576
        for cancelled in [false, true] {
            let base = Source(count: 40 * mib)
            let source = PlaybackPrefetchSource(file: file, source: base)
            source.setPrefetchEnabled(true) // No fileSize: no speculative admission.
            let retained = (cancelled ? 22 : 20) * mib
            for start in stride(from: 0, to: retained, by: 2 * mib) {
                _ = try await source.read(file, range: UInt64(start)..<UInt64(start + 2 * mib))
            }
            if cancelled {
                base.blockDemand = true
                let old = Task { try await source.read(file, range: UInt64(30 * mib)..<UInt64(32 * mib)) }
                await until { base.gate != nil }
                let next = Task { try await source.read(file, range: UInt64(16 * mib)..<UInt64(16 * mib + 576 * 1024)) }
                for _ in 0..<20 { await Task.yield() }
                old.cancel()
                do { _ = try await old.value; Issue.record("Expected cancellation") }
                catch { #expect(error is CancellationError) }
                #expect(source.metrics.historyBytes == retained)
                base.blockDemand = false; base.release()
                #expect(try await next.value == Data(repeating: 0x5a, count: 576 * 1024))
                #expect(base.reads.count == 12) // Eleven initial reads plus cancelled miss.
                #expect(source.metrics.historyBytes == retained)
            } else {
                _ = try await source.read(file, range: UInt64(16 * mib + 64 * 1024)..<UInt64(16 * mib + 128 * 1024))
                _ = try await source.read(file, range: UInt64(20 * mib)..<UInt64(20 * mib + 576 * 1024))
                #expect(source.metrics.historyBytes == retained + 576 * 1024)
                #expect(source.metrics.diagnostics.historyEvictedBytes == 0)
                let before = base.reads.count
                _ = try await source.read(file, range: 0..<UInt64(2 * mib))
                #expect(base.reads.count == before)
            }
            #expect(base.maxOutstanding == 1)
            conserved(source)
            try await source.awaitPlaybackCleanup()
        }
    }

    @Test func physicalRingRetainsDisjointSeekAndWrapsWithoutAliasingReplies() async throws {
        let base = Source()
        let source = PlaybackPrefetchSource(file: file, source: base,
            configuration: .init(capacityBytes: 16, chunkBytes: 8, totalCapacityBytes: 24))
        source.setPrefetchEnabled(true)
        let first = try await source.read(file, range: 0..<8)
        _ = try await source.read(file, range: 48..<56) // Same old modulo slots.
        source.invalidatePrefetch(reason: .seek)
        source.setPrefetchEnabled(false, reason: .seek) // Actual Native seek double path.
        source.setPrefetchEnabled(true)
        #expect(try await source.read(file, range: 0..<8) == first)
        #expect(base.reads == [0..<8, 48..<56])
        _ = try await source.read(file, range: 100..<108)
        #expect(source.metrics.validCacheBytes == 24)
        _ = try await source.read(file, range: 104..<112) // Only four new bytes commit.
        #expect(source.metrics.storageWrittenBytes == 28)
        #expect(source.metrics.diagnostics.historyEvictedBytes == 4)
        #expect(try await source.read(file, range: 4..<8) == Data(4..<8))
        #expect(try await source.read(file, range: 48..<56) == Data(48..<56))
        #expect(try await source.read(file, range: 100..<112) == Data(100..<112))
        #expect(first == Data(0..<8))
        #expect(base.reads == [0..<8, 48..<56, 100..<108, 108..<112])
        #expect(source.metrics.storageAllocatedBytes == 24 && source.metrics.validCacheBytes == 24)
        try await source.awaitPlaybackCleanup()
        #expect(source.metrics.storageAllocatedBytes == 0 && source.metrics.cacheMetadataEntries == 0)
    }

    @Test func fullArenaSurvivesInFlightCancellationAndOnlySuccessfulWriteReplacesOldest() async throws {
        let mib = 1_048_576
        let base = Source(count: 40 * mib)
        let source = PlaybackPrefetchSource(file: file, source: base,
            configuration: .init(totalCapacityBytes: 32 * mib))
        source.setPrefetchEnabled(true)
        for start in stride(from: 0, to: 32 * mib, by: 2 * mib) {
            _ = try await source.read(file, range: UInt64(start)..<UInt64(start + 2 * mib))
        }
        base.blockDemand = true
        let cancelled = Task { try await source.read(file, range: UInt64(32 * mib)..<UInt64(34 * mib)) }
        await until { base.gate != nil }
        #expect(source.metrics.validCacheBytes == 32 * mib)
        #expect(source.metrics.inFlightReservedBytes == 2 * mib)
        #expect(source.metrics.totalCacheBytes == 34 * mib)
        #expect(source.metrics.diagnostics.historyEvictedBytes == 0)
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        base.blockDemand = false; base.release()
        _ = try await source.read(file, range: 0..<UInt64(2 * mib))
        #expect(source.metrics.validCacheBytes == 32 * mib && source.metrics.diagnostics.historyEvictedBytes == 0)
        _ = try await source.read(file, range: UInt64(32 * mib)..<UInt64(34 * mib))
        #expect(source.metrics.validCacheBytes == 32 * mib)
        #expect(source.metrics.diagnostics.historyEvictedBytes == UInt64(2 * mib))
        let before = base.reads.count
        _ = try await source.read(file, range: UInt64(2 * mib)..<UInt64(4 * mib))
        #expect(base.reads.count == before)
        #expect(source.metrics.maxTotalCacheBytes == 34 * mib && base.maxOutstanding == 1)
        try await source.awaitPlaybackCleanup()
    }

    @Test func sparseMetadataIsBoundedAndPartialIslandFallbackIsOneFullRead() async throws {
        let base = Source(count: 8192)
        let source = PlaybackPrefetchSource(file: file, source: base,
            configuration: .init(capacityBytes: 16, chunkBytes: 8, totalCapacityBytes: 4096))
        source.setPrefetchEnabled(true)
        for index in 0..<1030 {
            _ = try await source.read(file, range: UInt64(index * 4)..<UInt64(index * 4 + 1))
        }
        #expect(source.metrics.cacheMetadataEntries <= PlaybackPrefetchSource.Metrics.cacheMetadataEntryLimit)
        #expect(source.metrics.maxCacheMetadataEntries <= PlaybackPrefetchSource.Metrics.cacheMetadataEntryLimit)
        #expect(source.metrics.validCacheBytes == 1024)
        #expect(source.metrics.diagnostics.historyEvictedBytes == 0)
        let before = base.reads.count
        #expect(try await source.read(file, range: 100..<180) == Data(repeating: 0x5a, count: 80))
        #expect(base.reads.count == before + 1 && base.reads.last == 100..<180)
        #expect(source.metrics.maxStorageAllocatedBytes == 4096)
        try await source.awaitPlaybackCleanup()
    }

    @Test func sameEpochSourceRejectionRefreshesCachedOverlap() async throws {
        let base = Source()
        let source = PlaybackPrefetchSource(file: file, source: base,
            configuration: .init(capacityBytes: 16, chunkBytes: 8, totalCapacityBytes: 24))
        source.setPrefetchEnabled(true)
        let old = try await source.read(file, range: 0..<8)
        base.bytes = Data(repeating: 0xa5, count: 256); base.rejectSegments = true
        #expect(try await source.read(file, range: 4..<12) == Data(repeating: 0xa5, count: 8))
        let before = base.reads.count
        #expect(try await source.read(file, range: 4..<12) == Data(repeating: 0xa5, count: 8))
        #expect(base.reads.count == before && old == Data(0..<8))
        #expect(source.metrics.historyHitBytes == 8)
        try await source.awaitPlaybackCleanup()
    }

    @Test func metadataLimitPureHitRetiresCreditWithoutEvictingAnyBytes() async throws {
        let base = Source(count: 8192)
        let source = PlaybackPrefetchSource(file: file, source: base,
            configuration: .init(capacityBytes: 16, chunkBytes: 8, totalCapacityBytes: 4096))
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        source.setPrefetchEnabled(false, reason: .pause)
        for index in 0..<1021 {
            _ = try await source.read(file, range: UInt64(64 + index * 4)..<UInt64(65 + index * 4))
        }
        #expect(source.metrics.cacheMetadataEntries == 1024)
        let valid = source.metrics.validCacheBytes, writes = source.metrics.storageWrittenBytes, before = base.reads.count
        _ = try await source.read(file, range: 18..<19)
        #expect(source.metrics.validCacheBytes == valid && source.metrics.storageWrittenBytes == writes)
        #expect(base.reads.count == before && source.metrics.cacheMetadataEntries <= 1024)
        #expect(source.metrics.hitBytes == 1 && source.metrics.retiredSpeculativeBytes == 7)
        #expect(source.metrics.diagnostics.historyEvictedBytes == 0 && source.metrics.discardedBytes == 0)
        _ = try await source.read(file, range: 16..<24)
        #expect(source.metrics.historyHitBytes == 8 && source.metrics.validCacheBytes == valid)
        conserved(source)
        try await source.awaitPlaybackCleanup()
        conserved(source)
    }

    @Test func newGapOverwriteDoesNotDiscardPrefetchAlreadyCreditedToSameDemand() async throws {
        let base = Source()
        let source = PlaybackPrefetchSource(file: file, source: base,
            configuration: .init(capacityBytes: 16, chunkBytes: 8, totalCapacityBytes: 32))
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        source.setPrefetchEnabled(false, reason: .pause)
        _ = try await source.read(file, range: 100..<116)
        #expect(try await source.read(file, range: 14..<24) == Data(14..<24))
        #expect(source.metrics.hitBytes == 8 && source.metrics.discardedBytes == 0)
        #expect(source.metrics.residentBytes == 8 && source.metrics.validCacheBytes == 32)
        conserved(source)
        try await source.awaitPlaybackCleanup()
        conserved(source)
    }

}
