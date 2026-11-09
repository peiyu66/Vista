import Foundation
import Testing
@testable import VistaCore

/// Pure Data and callback gates only. No SMB, network, media playback or device work.
@Suite(.serialized)
@MainActor struct PrefetchDiagnosticsTests {
    private enum Failure: Error { case epoch, read, cleanup }
    private let file = try! MediaFile(components: ["anonymous-generated.mp4"])

    @MainActor private final class Records {
        var values: [PrefetchDiagnosticRecord] = []
        var cleanups: [(metrics: PlaybackPrefetchSource.Metrics, succeeded: Bool)] = []
    }
    @MainActor private final class Source: PlaybackCacheSource {
        let bytes = Data((0..<128).map(UInt8.init))
        var token: UInt64? = 1
        var epochFails = false, readFails = false, cleanupFails = false
        var rejectPrefix = false, shortPrefetch = false
        var holdPrefetch = false, holdDemand = false
        var gate: CheckedContinuation<Void, Never>?
        var stopped = false
        var reads: [Range<UInt64>] = []
        var speculative: [Range<UInt64>] = []
        var isPlaybackRecovering: Bool { false }
        var recoveryActiveStartedAt: TimeInterval? { nil }
        var recoveryActiveElapsed: TimeInterval { 0 }
        func playbackCacheEpoch() throws -> UInt64? {
            if epochFails { throw Failure.epoch }
            if stopped { throw CancellationError() }
            return token
        }
        func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(bytes.count) }
        func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            reads.append(range)
            if holdDemand { await withCheckedContinuation { gate = $0 } }
            if readFails { throw Failure.read }
            return bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        func readForPrefetch(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            speculative.append(range)
            if holdPrefetch { await withCheckedContinuation { gate = $0 } }
            if readFails { throw Failure.read }
            let end = shortPrefetch ? range.upperBound - 1 : range.upperBound
            return bytes.subdata(in: Int(range.lowerBound)..<Int(end))
        }
        func readCompletingPrefix(_ file: MediaFile, range: Range<UInt64>, prefix: Data, epoch: UInt64) async throws -> PlaybackPrefixReadResult {
            if rejectPrefix { return .init(data: try await read(file, range: range), usedPrefixBytes: 0) }
            let suffix = try await read(file, range: (range.lowerBound + UInt64(prefix.count))..<range.upperBound)
            var data = prefix; data.append(suffix)
            return .init(data: data, usedPrefixBytes: prefix.count)
        }
        func readCompletingCachedSegments(_ file: MediaFile, range: Range<UInt64>, segments: [PlaybackCachedSegment], epoch: UInt64) async throws -> PlaybackCachedReadResult {
            if rejectPrefix || token != epoch { return .init(data: try await read(file, range: range), usedCachedBytes: 0) }
            var cursor = range.lowerBound, data = Data(), used = 0
            for segment in segments {
                if cursor < segment.range.lowerBound { data.append(try await read(file, range: cursor..<segment.range.lowerBound)) }
                data.append(segment.data); used += segment.data.count; cursor = segment.range.upperBound
            }
            if cursor < range.upperBound { data.append(try await read(file, range: cursor..<range.upperBound)) }
            try Task.checkCancellation()
            return .init(data: data, usedCachedBytes: used)
        }
        func release() { let saved = gate; gate = nil; saved?.resume() }
        func setPlaybackSceneActive(_ active: Bool) {}
        func cancelPlayback() { stopped = true }
        func awaitPlaybackCleanup() async throws { if cleanupFails { throw Failure.cleanup } }
    }
    private func make(_ base: Source, _ records: Records) -> PlaybackPrefetchSource {
        let source = PlaybackPrefetchSource(file: file, source: base, configuration: .init(capacityBytes: 16, chunkBytes: 8, historyCapacityBytes: 0))
        // Also exercises the post-construction sink used by NativePlaybackSession.
        source.diagnosticSink = { records.values.append($0) }
        source.cleanupDiagnosticSink = { records.cleanups.append(($0, $1)) }
        return source
    }
    private func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        Issue.record("Data-only diagnostic callback did not reach expected state")
    }
    private func prime(_ source: PlaybackPrefetchSource) async throws {
        _ = try await source.fileSize(for: file)
        source.setPrefetchEnabled(true)
        _ = try await source.read(file, range: 0..<8)
        _ = try await source.read(file, range: 8..<16)
    }
    private func expectConserved(_ source: PlaybackPrefetchSource, _ records: Records) {
        let metrics = source.metrics
        #expect(metrics.diagnostics.discardedBytes == metrics.discardedBytes)
        if metrics.diagnostics.suppressedRecords == 0 {
            #expect(records.values.reduce(0) { $0 + UInt64($1.discardedBytes) } == metrics.discardedBytes)
            #expect(records.values.reduce(0) { $0 + UInt64($1.usedReadyBytes) } == metrics.hitBytes)
            #expect(records.values.reduce(0) { $0 + UInt64($1.usedJoinedBytes) } == metrics.joinedBytes)
        }
        #expect(metrics.speculativeBytes == metrics.hitBytes + metrics.joinedBytes + metrics.discardedBytes + metrics.retiredSpeculativeBytes + UInt64(metrics.residentBytes))
    }

    @Test func observationDistinguishesMiddleOverlapFromPrefixGap() {
        #expect(PrefetchRangeObservation.measure(20..<40, spans: [16..<24, 24..<32]) == .init(prefixBytes: 12, overlapBytes: 12))
        #expect(PrefetchRangeObservation.measure(12..<28, spans: [16..<24]) == .init(prefixBytes: 0, overlapBytes: 8))
        #expect(PrefetchRangeObservation.measure(40..<48, spans: [16..<24]) == .init(prefixBytes: 0, overlapBytes: 0))
        #expect(PrefetchRangeObservation.measure(20..<40, spans: [16..<24, 28..<32]) == .init(prefixBytes: 4, overlapBytes: 8))
        #expect(PrefetchRangeObservation.delta(12, from: 16) == -4)
        #expect(PrefetchRangeObservation.delta(UInt64.max, from: 0) == nil)
    }

    @Test func targetedRequestObservationNeverBorrowsNextRequestGeometry() {
        let original = PrefetchDemandObservation(id: 4, range: 16..<24)
        let active = PrefetchDemandObservation(id: 5, range: 40..<48)
        let first = PrefetchDemandObservation(id: 6, range: 80..<96)
        #expect(PrefetchDemandObservation.resolve(requestID: 4, explicit: nil, active: active, first: first) == nil)
        #expect(PrefetchDemandObservation.resolve(requestID: 4, explicit: original, active: active, first: first) == original)
        #expect(PrefetchDemandObservation.resolve(requestID: nil, explicit: nil, active: active, first: first) == active)
        let metadata = PrefetchDemandObservation(id: 4, range: nil)
        #expect(PrefetchDemandObservation.resolve(requestID: 4, explicit: metadata, active: active, first: first)?.range == nil)
    }

    @Test func readyMiddlePrefixAttributesEachPrefetchWithoutDetachingMapping() async throws {
        let base = Source(), records = Records(), source = make(base, records)
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        #expect(try await source.read(file, range: 20..<40) == Data(20..<40))
        #expect(base.reads == [0..<8, 8..<16, 32..<40])
        let queued = try #require(records.values.first { $0.event == .demandEnqueued })
        #expect(queued.demandDelta == 4 && queued.demandBytes == 20)
        #expect(queued.readyPrefixBytes == 12 && queued.readyOverlapBytes == 12)
        let snapshot = try #require(records.values.first { $0.event == .prefixDetached })
        #expect(snapshot.readyBytes == 16 && snapshot.readyPrefixBytes == 12 && snapshot.readyOverlapBytes == 12)
        #expect(snapshot.stateBits & 128 != 0 && snapshot.stateBits & 256 != 0)
        let uses = records.values.filter { $0.event == .prefixUsed }
        #expect(uses.map(\.prefetchID) == [1, 2])
        #expect(uses.map(\.usedReadyBytes) == [4, 8])
        #expect(!records.values.contains { $0.reason == .rangeLeadingBytes && $0.discardedBytes > 0 })
        #expect(records.values.first { $0.prefetchID == 2 && $0.event == .begin }?.previousPrefetchDelta == 8)
        try await source.awaitPlaybackCleanup()
        expectConserved(source, records)
    }

    @Test func inflightMiddlePrefixUsesSamePrefixGeometryAndJoinCounters() async throws {
        let base = Source(), records = Records(); base.holdPrefetch = true
        let source = make(base, records)
        try await prime(source)
        await until { base.gate != nil }
        let demand = Task { try await source.read(file, range: 20..<40) }
        await until { records.values.contains { $0.event == .demandEnqueued } }
        let queued = try #require(records.values.first { $0.event == .demandEnqueued })
        #expect(queued.demandDelta == 4 && queued.inFlightPrefixBytes == 4 && queued.inFlightOverlapBytes == 4)
        base.holdPrefetch = false; base.release()
        #expect(try await demand.value == Data(20..<40))
        #expect(base.reads == [0..<8, 8..<16, 24..<40])
        #expect(records.values.contains { $0.event == .retained && $0.reason == .retainedForDemand && $0.requestID == queued.requestID })
        #expect(records.values.contains { $0.event == .prefixUsed && $0.usedJoinedBytes == 4 && $0.usedReadyBytes == 0 })
        try await source.awaitPlaybackCleanup()
        expectConserved(source, records)
    }

    @Test func readyAndInflightHeadGapReusesIntersectionsWithoutNoOverlapEviction() async throws {
        let ranges: [Range<UInt64>] = [12..<28, 40..<48]
        for inFlight in [false, true] {
            for range in ranges {
                let base = Source(), records = Records(); base.holdPrefetch = inFlight
                let source = make(base, records)
                try await prime(source)
                await until { inFlight ? base.gate != nil : source.metrics.residentBytes == 16 }
                let demand = Task { try await source.read(file, range: range) }
                await until { records.values.contains { $0.event == .demandEnqueued } }
                if inFlight { base.holdPrefetch = false; base.release() }
                #expect(try await demand.value == base.bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)))
                if range.lowerBound == 12 {
                    #expect(base.reads.contains(12..<16))
                    #expect(source.metrics.hitBytes == (inFlight ? 0 : 12))
                    #expect(source.metrics.joinedBytes == (inFlight ? 8 : 0))
                    #expect(!records.values.contains { $0.reason == .prefixGap })
                } else {
                    #expect(!records.values.contains { $0.reason == .noOverlap && $0.discardedBytes > 0 })
                    #expect(source.metrics.hitBytes == 0 && source.metrics.joinedBytes == 0)
                    if inFlight {
                        #expect(source.metrics.speculativeWaitCount == 1 && source.metrics.speculativeWaitSeconds > 0)
                        #expect(records.values.contains { $0.event == .demandDequeued && $0.waitedForPrefetch && $0.usedJoinedBytes == 0 })
                    }
                }
                try await source.awaitPlaybackCleanup()
                expectConserved(source, records)
            }
        }
    }

    @Test func lateCompletionRecordsSceneGenerationAndLastFlushReason() async throws {
        let base = Source(), records = Records(); base.holdPrefetch = true
        let source = make(base, records)
        try await prime(source)
        await until { base.gate != nil }
        source.setPrefetchEnabled(false, reason: .sceneInactive)
        base.holdPrefetch = false; base.release()
        await until { records.values.contains { $0.event == .rejected } }
        let rejected = try #require(records.values.first { $0.event == .rejected })
        #expect(rejected.reason == .generationChanged && rejected.invalidationReason == .sceneInactive)
        #expect(rejected.prefetchGeneration == 0 && rejected.generation == 1)
        #expect(source.metrics.diagnostics.discardedFlushBytes == 8)
        try await source.awaitPlaybackCleanup()
        expectConserved(source, records)
    }

    @Test func epochUnavailableChangedAndErrorKeepSeparateReasons() async throws {
        for reason in [PrefetchDiagnosticReason.epochUnavailable, .epochChanged, .epochError] {
            let base = Source(), records = Records(); base.holdPrefetch = true
            let source = make(base, records)
            try await prime(source)
            await until { base.gate != nil }
            if reason == .epochUnavailable { base.token = nil }
            else if reason == .epochChanged { base.token = 2 }
            else { base.epochFails = true }
            base.holdPrefetch = false; base.release()
            await until { records.values.contains { $0.event == .rejected } }
            #expect(records.values.contains { $0.event == .rejected && $0.reason == reason && $0.discardedBytes == 8 })
            #expect(source.metrics.diagnostics.discardedEpochBytes == 8)
            base.epochFails = false
            try await source.awaitPlaybackCleanup()
            expectConserved(source, records)
        }
    }

    @Test func readyCacheEpochDiscardReportsNewObservationAndAvailability() async throws {
        for reason in [PrefetchDiagnosticReason.epochUnavailable, .epochChanged, .epochError] {
            let base = Source(), records = Records(), source = make(base, records)
            try await prime(source)
            await until { source.metrics.residentBytes == 16 }
            if reason == .epochUnavailable { base.token = nil }
            else if reason == .epochChanged { base.token = 2 }
            else { base.epochFails = true }
            do {
                #expect(try await source.fileSize(for: file) == 128)
                #expect(reason != .epochError)
            } catch {
                #expect(reason == .epochError && error is Failure)
            }
            let discarded = records.values.filter { $0.event == .discarded && $0.reason == reason }
            #expect(discarded.count == 2)
            let expectedEpoch: UInt64? = reason == .epochChanged ? 2 : nil
            #expect(discarded.allSatisfy { $0.epoch == expectedEpoch && $0.prefetchEpoch == 1 })
            #expect(discarded.allSatisfy { ($0.stateBits & 64 != 0) == (expectedEpoch != nil) })
            #expect(source.metrics.diagnostics.discardedEpochBytes == 16)
            base.epochFails = false
            try await source.awaitPlaybackCleanup()
            expectConserved(source, records)
        }
    }

    @Test func cancelledSuffixRetainsCompletedPrefixUntilCleanupFlush() async throws {
        let base = Source(), records = Records(), source = make(base, records)
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        base.holdDemand = true
        let demand = Task { try await source.read(file, range: 16..<40) }
        await until { base.gate != nil }
        demand.cancel()
        do { _ = try await demand.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        source.invalidatePrefetch(reason: .seek)
        base.holdDemand = false; base.release()
        try await source.awaitPlaybackCleanup()
        #expect(source.metrics.diagnostics.discardedCancellationBytes == 0)
        #expect(source.metrics.diagnostics.discardedFlushBytes == 16)
        #expect(records.values.contains { $0.event == .demandCancelled && $0.stateBits & 256 != 0 })
        expectConserved(source, records)
    }

    @Test func pausePreservesValidDemandOwnedPrefix() async throws {
        let base = Source(), records = Records(), source = make(base, records)
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        base.holdDemand = true
        let demand = Task { try await source.read(file, range: 16..<40) }
        await until { base.gate != nil }
        source.setPrefetchEnabled(false, reason: .pause)
        base.holdDemand = false; base.release()
        #expect(try await demand.value == Data(16..<40))
        #expect(source.metrics.hitBytes == 16 && source.metrics.discardedBytes == 0)
        try await source.awaitPlaybackCleanup()
        expectConserved(source, records)
    }

    @Test func sourcePrefixRejectionAndShortReadHaveSourceDiscardTotals() async throws {
        let base = Source(), records = Records(), source = make(base, records)
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        base.rejectPrefix = true
        #expect(try await source.read(file, range: 20..<40) == Data(20..<40))
        #expect(source.metrics.diagnostics.discardedSourceBytes == 12)
        #expect(source.metrics.diagnostics.discardedOtherBytes == 4)
        #expect(records.values.contains { $0.reason == .sourcePrefixRejected })
        try await source.awaitPlaybackCleanup()
        expectConserved(source, records)

        let shortBase = Source(), shortRecords = Records(); shortBase.shortPrefetch = true
        let shortSource = make(shortBase, shortRecords)
        try await prime(shortSource)
        await until { shortRecords.values.contains { $0.event == .rejected } }
        #expect(shortRecords.values.contains { $0.reason == .shortRead && $0.discardedBytes == 7 })
        #expect(shortSource.metrics.diagnostics.discardedSourceBytes == 7)
        try await shortSource.awaitPlaybackCleanup()
        expectConserved(shortSource, shortRecords)
    }

    @Test func fifoMetadataAndRemovedCancelledRequestRetainSameEpochCompletion() async throws {
        for metadata in [true, false] {
            let base = Source(), records = Records(); base.holdPrefetch = true
            let source = make(base, records)
            try await prime(source)
            await until { base.gate != nil }
            let request = Task { () async throws -> UInt64 in
                if metadata { return try await source.fileSize(for: file) }
                return UInt64(try await source.read(file, range: 16..<24).count)
            }
            await until { records.values.contains { $0.event == .demandEnqueued } }
            if !metadata {
                request.cancel()
                do { _ = try await request.value; Issue.record("Expected cancellation") }
                catch { #expect(error is CancellationError) }
            }
            base.holdPrefetch = false; base.release()
            if metadata { #expect(try await request.value == 128) }
            await until { source.metrics.residentBytes >= 8 }
            #expect(records.values.contains { $0.event == .retained && $0.reason == .retainedReady })
            #expect(!records.values.contains { $0.event == .rejected && ($0.reason == .firstRequestMetadata || $0.reason == .noFirstRequest) })
            #expect(source.metrics.discardedBytes == 0)
            try await source.awaitPlaybackCleanup()
            expectConserved(source, records)
        }
    }

    @Test func detailLimitKeepsAggregateCountingAndAnonymousSessionMonotonic() async throws {
        let base = Source(), records = Records(), source = make(base, records)
        for _ in 0..<270 { source.invalidatePrefetch(reason: .explicit) }
        #expect(records.values.isEmpty)
        #expect(source.metrics.diagnostics.generatedRecords == 0)
        for _ in 0..<40 {
            try await prime(source)
            await until { source.metrics.residentBytes == 16 }
            source.invalidatePrefetch(reason: .explicit)
        }
        // A stop-time snapshot cannot yet include this still-running read's bytes.
        base.holdPrefetch = true
        try await prime(source)
        await until { base.gate != nil }
        source.cancelPlayback()
        let stoppedDiscardedBytes = source.metrics.discardedBytes
        let cleanup = Task { try await source.awaitPlaybackCleanup() }
        #expect(records.cleanups.isEmpty)
        base.holdPrefetch = false; base.release()
        try await cleanup.value
        try await source.awaitPlaybackCleanup()
        #expect(records.values.count == 256)
        #expect(source.metrics.diagnostics.suppressedRecords > 0)
        #expect(source.metrics.diagnostics.detailedRecords == 256)
        #expect(source.metrics.diagnostics.discardedFlushBytes == 640)
        #expect(records.cleanups.count == 1)
        let terminal = try #require(records.cleanups.first)
        #expect(terminal.succeeded)
        #expect(terminal.metrics.discardedBytes == stoppedDiscardedBytes + 8)
        #expect(terminal.metrics.diagnostics.discardedBytes == terminal.metrics.discardedBytes)
        #expect(terminal.metrics.diagnostics.suppressedRecords > 0)
        #expect(Set(records.values.map(\.sequence)).count == 256)
        #expect(records.values.map(\.sequence) == records.values.map(\.sequence).sorted())
        #expect(source.metrics.diagnostics.historyGeneratedRecords - source.metrics.diagnostics.historySuppressedRecords == 64)
        #expect(source.metrics.diagnostics.prefetchGeneratedRecords - source.metrics.diagnostics.prefetchSuppressedRecords == 192)
        #expect(records.values.allSatisfy { $0.sessionID == source.metrics.diagnostics.sessionID })
        expectConserved(source, records)
        let next = make(Source(), Records())
        #expect(next.metrics.diagnostics.sessionID == source.metrics.diagnostics.sessionID + 1)
        try await next.awaitPlaybackCleanup()
    }

    @Test func cleanupFailureHasNumericTerminalRecordWithoutErrorText() async throws {
        let base = Source(), records = Records(); base.cleanupFails = true
        let source = make(base, records)
        do { try await source.awaitPlaybackCleanup(); Issue.record("Expected cleanup failure") }
        catch { #expect(error is Failure) }
        do { try await source.awaitPlaybackCleanup(); Issue.record("Expected repeated cleanup failure") }
        catch { #expect(error is Failure) }
        #expect(records.values.last?.event == .cleanup && records.values.last?.reason == .cleanupFailed)
        #expect(records.cleanups.count == 1 && records.cleanups.first?.succeeded == false)
        #expect(records.cleanups.first?.metrics.diagnostics.discardedBytes == source.metrics.discardedBytes)
        expectConserved(source, records)
    }
}
