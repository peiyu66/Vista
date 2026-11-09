import Foundation
import Testing
@testable import VistaCore

/// Data-only callback gates; no SMB, sockets, NAS or device operations.
@Suite(.serialized)
@MainActor struct PlaybackPrefetchSourceTests {
    private enum Failure: Error { case identity, cleanup, transport }
    private let file = try! MediaFile(components: ["generated.mp4"])
    @MainActor private final class Source: PlaybackCacheSource {
        let bytes: Data
        init(byteCount: Int = 128) { bytes = Data((0..<byteCount).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 10)) }) }
        var token: UInt64? = 1
        var failure: Failure?
        var isPlaybackRecovering = false
        var recoveryActiveStartedAt: TimeInterval? = 12
        var recoveryActiveElapsed: TimeInterval = 3
        var reads: [Range<UInt64>] = [], speculative: [Range<UInt64>] = []
        var active = true, stopped = false, cleaned = false, failCleanup = false
        var gate: CheckedContinuation<Void, Never>?
        var blockSpeculation = false
        var blockSpeculationAt: Int?
        var blockDemand = false
        var outstanding = 0, maxOutstanding = 0
        func playbackCacheEpoch() throws -> UInt64? {
            if let failure { throw failure }
            if stopped { throw CancellationError() }
            return active && !isPlaybackRecovering ? token : nil
        }
        func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(bytes.count) }
        func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            reads.append(range)
            outstanding += 1; maxOutstanding = max(maxOutstanding, outstanding)
            defer { outstanding -= 1 }
            if blockDemand { await withCheckedContinuation { gate = $0 } }
            if let failure { throw failure }
            return bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        func readForPrefetch(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            speculative.append(range)
            outstanding += 1; maxOutstanding = max(maxOutstanding, outstanding)
            defer { outstanding -= 1 }
            if blockSpeculation || speculative.count == blockSpeculationAt { await withCheckedContinuation { gate = $0 } }
            if let failure { throw failure }
            return bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        func readCompletingPrefix(_ file: MediaFile, range: Range<UInt64>, prefix: Data, epoch: UInt64) async throws -> PlaybackPrefixReadResult {
            guard token == epoch else { return .init(data: try await read(file, range: range), usedPrefixBytes: 0) }
            let suffix = try await read(file, range: (range.lowerBound + UInt64(prefix.count))..<range.upperBound)
            try Task.checkCancellation()
            var data = prefix; data.append(suffix)
            return .init(data: data, usedPrefixBytes: prefix.count)
        }
        func readCompletingCachedSegments(_ file: MediaFile, range: Range<UInt64>, segments: [PlaybackCachedSegment], epoch: UInt64) async throws -> PlaybackCachedReadResult {
            if token != epoch { return .init(data: try await read(file, range: range), usedCachedBytes: 0) }
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
        func setPlaybackSceneActive(_ active: Bool) { self.active = active }
        func cancelPlayback() { stopped = true }
        func awaitPlaybackCleanup() async throws { cleaned = true; if failCleanup { throw Failure.cleanup } }
    }
    private func make(_ base: Source) -> PlaybackPrefetchSource {
        PlaybackPrefetchSource(file: file, source: base, configuration: .init(capacityBytes: 16, chunkBytes: 8, historyCapacityBytes: 0))
    }
    private func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        Issue.record("Synthetic callback did not reach expected state")
    }
    private func prime(_ wrapper: PlaybackPrefetchSource) async throws {
        _ = try await wrapper.fileSize(for: file)
        wrapper.setPrefetchEnabled(true)
        _ = try await wrapper.read(file, range: 0..<8)
        _ = try await wrapper.read(file, range: 8..<16)
    }
    @Test func recoveryActivityIncludesCancelledUndrainedDemandAndQueuedWork() async throws {
        let base = Source(), source = make(Source())
        // The fresh wrapper has no validated identity and must fail closed.
        #expect(!source.recoveryActivity.available && !source.recoveryActivity.idle)
        try await source.awaitPlaybackCleanup()
        let wrapper = make(base)
        _ = try await wrapper.fileSize(for: file)
        await until { wrapper.recoveryActivity.idle }
        let first = wrapper.recoveryActivity
        base.blockDemand = true
        let demand = Task { try await wrapper.read(file, range: 0..<8) }
        await until { base.gate != nil }
        let queued = Task { try await wrapper.read(file, range: 16..<24) }
        await until { wrapper.recoveryActivity.queued == 1 }
        #expect(!wrapper.recoveryActivity.idle && wrapper.recoveryActivity.busy & 3 == 3)
        #expect(wrapper.recoveryActivity.requests > first.requests)
        demand.cancel()
        await until { wrapper.recoveryActivity.busy & 1 == 0 }
        // Cancellation resumes the client before the actual source await drains.
        #expect(!wrapper.recoveryActivity.idle && wrapper.recoveryActivity.busy & 2 != 0)
        base.blockDemand = false; base.release()
        _ = try? await demand.value
        #expect(try await queued.value == Data(16..<24))
        await until { wrapper.recoveryActivity.idle }
        #expect(base.maxOutstanding == 1)
        wrapper.cancelPlayback()
        #expect(!wrapper.recoveryActivity.available && !wrapper.recoveryActivity.idle)
        try await wrapper.awaitPlaybackCleanup()
    }
    @Test func recoveryActivityIncludesSpeculativePumpAndChangesOnlyObservedIdentity() async throws {
        let base = Source(), source = make(base)
        base.blockSpeculation = true
        try await prime(source)
        await until { base.gate != nil }
        let busy = source.recoveryActivity
        #expect(!busy.idle && busy.busy & 4 != 0 && busy.busy & 8 != 0)
        #expect(busy.prefetches > 0 && busy.epoch == 1)
        source.setPrefetchEnabled(false, reason: .pause)
        #expect(!source.recoveryActivity.idle) // Source's blocked read still owns work.
        base.blockSpeculation = false; base.release()
        await until { source.recoveryActivity.idle }
        let prior = source.recoveryActivity
        source.invalidatePrefetch(reason: .seek)
        #expect(source.recoveryActivity.generation > prior.generation)
        #expect(source.recoveryActivity.epoch == prior.epoch)
        try await source.awaitPlaybackCleanup()
    }
    /// A delayed demand establishes the frontier before the queued isolated higher
    /// read completes. Build96 preserves that independent window, including when
    /// retained bytes straddle its target; it never constructs an inverted range.
    @Test(arguments: [UInt64(24), 32, 48])
    func queuedIsolatedHigherCompletionPreservesEarlierWindow(end: UInt64) async throws {
        let base = Source()
        let source = PlaybackPrefetchSource(file: file, source: base,
            configuration: .init(capacityBytes: 16, chunkBytes: 8, totalCapacityBytes: 128))
        _ = try await source.fileSize(for: file)
        source.setPrefetchEnabled(true)
        #expect(try await source.read(file, range: 0..<8) == Data(0..<8))
        base.blockDemand = true
        let first = Task { try await source.read(file, range: 8..<16) }
        await until { base.gate != nil }
        var secondQueued = false
        source.diagnosticSink = { record in
            if record.event == .demandEnqueued { secondQueued = true }
        }
        let noBudget = source.metrics.diagnostics.noAdmissionFilledOrBudget
        let secondRange = (end - 4)..<end
        let second = Task { try await source.read(file, range: secondRange) }
        await until { secondQueued }
        #expect(base.reads == [0..<8, 8..<16])
        base.blockDemand = false; base.release()
        #expect(try await first.value == Data(8..<16))
        #expect(try await second.value == base.bytes.subdata(in: Int(end - 4)..<Int(end)))
        // Await the terminal admission attempt, not an arbitrary sleep.
        await until { source.metrics.diagnostics.noAdmissionFilledOrBudget > noBudget }
        #expect(base.speculative == [16..<24,24..<32])
        #expect(base.maxOutstanding == 1)
        let expectedValid = end <= 32 ? 32 : 36
        #expect(source.metrics.validCacheBytes == expectedValid)
        #expect(source.metrics.discardedBytes == (end <= 32 ? 4 : 0))
        #expect(source.rangeDiagnosticSnapshot().forward.cursor == 16)
        #expect(source.rangeDiagnosticSnapshot().forward.target == 32)
        #expect(source.rangeDiagnosticSnapshot().forward.reads == 2)
        let reads = base.reads
        #expect(try await source.read(file, range: 0..<16) == Data(0..<16))
        #expect(base.reads == reads)
        #expect(source.metrics.historyHitBytes == 16)
        #expect(source.metrics.validCacheBytes == expectedValid)
        #expect(base.speculative == [16..<24,24..<32])
        try await source.awaitPlaybackCleanup()
    }
    @Test func stopWinsOverLateOrdinarySourceFailure() async throws {
        let base = Source(), source = make(base)
        _ = try await source.fileSize(for: file)
        base.blockDemand = true
        let pending = Task { try await source.read(file, range: 0..<8) }
        await until { base.gate != nil }
        // This synthetic source deliberately ignores Task cancellation while its
        // gate is held, then throws an ordinary transport error after stop.
        source.cancelPlayback()
        base.failure = .transport
        base.release()
        do { _ = try await pending.value; Issue.record("Stopped demand returned bytes") }
        catch is CancellationError {}
        catch { Issue.record("Stop must dominate the late source error: \(error)") }
        #expect(base.maxOutstanding == 1 && base.outstanding == 0)
        #expect(source.metrics.diagnostics.demandCancelledCount == 1)
        #expect(source.metrics.diagnostics.demandFailedCount == 0)
        #expect(source.metrics.diagnostics.demandSourceWaitCount == 0)
        #expect(source.rangeDiagnosticSnapshot().recent.last?.result == .cancelled)
        #expect(source.rangeDiagnosticSnapshot().forward.cursor == nil)
        try await source.awaitPlaybackCleanup()
    }
    @Test func prefetchStartEqualToEOFTargetDoesNotAdmitEmptyRange() async throws {
        let base = Source(byteCount: 16)
        let source = make(base)
        try await prime(source)
        await until { source.metrics.diagnostics.noAdmissionFilledOrBudget > 0 }
        #expect(base.speculative.isEmpty)
        #expect(base.reads == [0..<8, 8..<16])
        #expect(base.maxOutstanding == 1)
        try await source.awaitPlaybackCleanup()
    }
    @Test func finiteForwardWindowExactHitsAndNumericCosts() async throws {
        let base = Source()
        let source = make(base)
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        #expect(base.speculative == [16..<24, 24..<32])
        #expect(try await source.read(file, range: 16..<24) == Data(16..<24))
        #expect(source.metrics.hitBytes == 8)
        #expect(source.metrics.missBytes == 16)
        #expect(source.metrics.maxResidentBytes <= 16)
        #expect(source.metrics.maxInFlightBytes <= 8)
        #expect(source.metrics.speculativeBytes >= 16)
        #expect(source.metrics.demandSeconds >= 0 && source.metrics.speculativeSeconds >= 0)
        source.invalidatePrefetch()
        #expect(source.metrics.discardedBytes >= 8)
        try await source.awaitPlaybackCleanup()
    }
    @Test func demandJoinsActualSpeculativeCompletionWithoutDuplicateRead() async throws {
        let base = Source(); base.blockSpeculation = true
        let source = make(base)
        try await prime(source)
        await until { base.gate != nil }
        let demand = Task { try await source.read(file, range: 16..<24) }
        for _ in 0..<20 { await Task.yield() }
        #expect(base.reads.count == 2)
        base.blockSpeculation = false; base.release()
        #expect(try await demand.value == Data(16..<24))
        #expect(base.maxOutstanding == 1)
        #expect(base.reads == [0..<8, 8..<16])
        #expect(source.metrics.joinedBytes == 8)
        #expect(source.metrics.hitBytes == 0)
        #expect(source.metrics.discardedBytes == 0)
        #expect(source.metrics.demandWaitSeconds > 0)
        try await source.awaitPlaybackCleanup()
    }
    @Test func differentRangeDemandRetainsCompletedSpeculationWithoutBypassingPriority() async throws {
        let base = Source(); base.blockSpeculation = true
        let source = make(base)
        try await prime(source)
        await until { base.gate != nil }
        let demand = Task { try await source.read(file, range: 40..<48) }
        for _ in 0..<20 { await Task.yield() }
        #expect(base.reads.count == 2)
        base.blockSpeculation = false; base.release()
        #expect(try await demand.value == Data(40..<48))
        #expect(base.reads == [0..<8, 8..<16, 40..<48])
        #expect(base.speculative == [16..<24])
        #expect(source.metrics.joinedBytes == 0)
        #expect(source.metrics.discardedBytes == 0 && source.metrics.residentBytes == 8)
        #expect(base.maxOutstanding == 1)
        try await source.awaitPlaybackCleanup()
    }
    @Test func cancelledDemandReturnsBeforeTransportDrainWithoutOverlap() async throws {
        let base = Source(); base.blockSpeculation = true
        let source = make(base)
        try await prime(source)
        await until { base.gate != nil }
        let demand = Task { try await source.read(file, range: 16..<24) }
        demand.cancel()
        do { _ = try await demand.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(base.gate != nil)
        base.blockSpeculation = false; base.release()
        try await source.awaitPlaybackCleanup()
        #expect(base.maxOutstanding == 1 && base.cleaned)
    }
    @Test func seekBackgroundAndMemoryPressureFlushAndRejectLateBytes() async throws {
        let base = Source(); base.blockSpeculation = true
        let source = make(base)
        try await prime(source)
        await until { base.gate != nil }
        source.invalidatePrefetch()
        source.setPlaybackSceneActive(false)
        #expect(!base.active && source.metrics.residentBytes == 0)
        base.blockSpeculation = false; base.release()
        source.setPlaybackSceneActive(true)
        source.handleMemoryPressure()
        source.setPrefetchEnabled(true)
        _ = try await source.read(file, range: 40..<48)
        _ = try await source.read(file, range: 48..<56)
        #expect(base.speculative.count == 1)
        #expect(source.metrics.residentBytes == 0)
        #expect(source.metrics.discardedBytes == 8)
        try await source.awaitPlaybackCleanup()
    }
    @Test func epochChangeAndIdentityFailureCannotBeHiddenByCache() async throws {
        let base = Source()
        let wrapper = make(base)
        try await prime(wrapper)
        await until { wrapper.metrics.residentBytes == 16 }
        base.token = 2
        #expect(try await wrapper.read(file, range: 16..<24) == Data(16..<24))
        #expect(wrapper.metrics.hitBytes == 0)
        // New identity cannot borrow the old epoch's adjacent demand/cursor.
        #expect(wrapper.metrics.residentBytes == 0)
        #expect(base.speculative.count == 2)
        // Only newly completed sequential progress in epoch 2 earns another window.
        #expect(try await wrapper.read(file, range: 24..<32) == Data(24..<32))
        await until { wrapper.metrics.residentBytes == 16 }
        base.failure = .identity
        do { _ = try await wrapper.read(file, range: 32..<40); Issue.record("Expected identity failure") }
        catch { #expect(error is Failure) }
        #expect(wrapper.metrics.residentBytes == 0)
        base.failure = nil
        try await wrapper.awaitPlaybackCleanup()
    }
    @Test func recoveryProxyAndCleanupAwaitActualReadAndPreserveFailure() async throws {
        let base = Source(); base.blockSpeculation = true; base.failCleanup = true
        let source = make(base)
        try await prime(source)
        await until { base.gate != nil }
        base.isPlaybackRecovering = true
        #expect(source.isPlaybackRecovering)
        #expect(source.recoveryActiveStartedAt == 12 && source.recoveryActiveElapsed == 3)
        source.cancelPlayback()
        let cleanup = Task { try await source.awaitPlaybackCleanup() }
        for _ in 0..<20 { await Task.yield() }
        #expect(!base.cleaned && base.stopped)
        base.release()
        do { try await cleanup.value; Issue.record("Expected cleanup failure") }
        catch { #expect(error is Failure) }
        #expect(base.cleaned && source.metrics.residentBytes == 0)
    }
    @Test func activeDemandCancellationIsPromptWithoutTransportOverlap() async throws {
        let base = Source(); base.blockDemand = true
        let source = make(base)
        let demand = Task { try await source.read(file, range: 0..<8) }
        await until { base.gate != nil }
        demand.cancel()
        do { _ = try await demand.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        source.invalidatePrefetch()
        base.release()
        try await source.awaitPlaybackCleanup()
        #expect(base.maxOutstanding == 1 && source.metrics.residentBytes == 0)
    }
    @Test func cacheInvalidationDoesNotDropAlreadyAdmittedDemand() async throws {
        let base = Source(); base.blockDemand = true
        let source = make(base)
        let demand = Task { try await source.read(file, range: 0..<8) }
        await until { base.gate != nil }
        source.invalidatePrefetch()
        source.setPlaybackSceneActive(false)
        base.release()
        #expect(try await demand.value == Data(0..<8))
        #expect(source.metrics.residentBytes == 0)
        try await source.awaitPlaybackCleanup()
    }

    @Test func partialReadyPrefixOnlyReadsMissingTail() async throws {
        let base = Source(), sourceFile = file
        let source = make(base)
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        #expect(try await source.read(sourceFile, range: 16..<40) == Data(16..<40))
        #expect(base.reads == [0..<8, 8..<16, 32..<40])
        #expect(source.metrics.hitBytes == 16)
        #expect(source.metrics.missBytes == 24)
        #expect(source.metrics.discardedBytes == 0)
        try await source.awaitPlaybackCleanup()
    }


    @Test func partialInflightPrefixOnlyReadsMissingTail() async throws {
        let base = Source(); base.blockSpeculation = true
        let source = make(base)
        try await prime(source)
        await until { base.gate != nil }
        let demand = Task { try await source.read(file, range: 16..<40) }
        for _ in 0..<20 { await Task.yield() }
        #expect(base.reads.count == 2)
        base.blockSpeculation = false; base.release()
        #expect(try await demand.value == Data(16..<40))
        #expect(base.reads == [0..<8, 8..<16, 24..<40])
        #expect(source.metrics.joinedBytes == 8 && source.metrics.hitBytes == 0)
        #expect(source.metrics.missBytes == 32 && source.metrics.discardedBytes == 0)
        #expect(base.maxOutstanding == 1)
        try await source.awaitPlaybackCleanup()
    }

    @Test func readyAndInflightPrefixCombineBeforeSingleTailRead() async throws {
        let base = Source(); base.blockSpeculationAt = 2
        let source = make(base)
        try await prime(source)
        await until { base.gate != nil }
        #expect(source.metrics.residentBytes == 8)
        let demand = Task { try await source.read(file, range: 16..<40) }
        for _ in 0..<20 { await Task.yield() }
        base.blockSpeculationAt = nil; base.release()
        #expect(try await demand.value == Data(16..<40))
        #expect(base.reads == [0..<8, 8..<16, 32..<40])
        #expect(source.metrics.hitBytes == 8 && source.metrics.joinedBytes == 8)
        #expect(source.metrics.missBytes == 24 && source.metrics.discardedBytes == 0)
        #expect(base.maxOutstanding == 1)
        try await source.awaitPlaybackCleanup()
    }

    @Test func overlappingOffsetUsesOnlyContiguousReadyPrefix() async throws {
        let base = Source(), source = make(base)
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        #expect(try await source.read(file, range: 20..<40) == Data(20..<40))
        #expect(base.reads == [0..<8, 8..<16, 32..<40])
        #expect(source.metrics.hitBytes == 12 && source.metrics.discardedBytes == 4)
        try await source.awaitPlaybackCleanup()
    }

    @Test func cancellingPartialDemandDrainsTailBeforeSeek() async throws {
        let base = Source(), source = make(base)
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        base.blockDemand = true
        let demand = Task { try await source.read(file, range: 16..<40) }
        await until { base.gate != nil }
        #expect(base.reads.last == 32..<40)
        demand.cancel()
        do { _ = try await demand.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        source.invalidatePrefetch()
        let seek = Task { try await source.read(file, range: 80..<88) }
        for _ in 0..<20 { await Task.yield() }
        #expect(base.reads.last == 32..<40 && base.outstanding == 1)
        base.blockDemand = false; base.release()
        #expect(try await seek.value == Data(80..<88))
        #expect(base.maxOutstanding == 1 && source.metrics.discardedBytes == 16)
        try await source.awaitPlaybackCleanup()
    }

    @Test func seekCompletesLiveActiveAndQueuedDemandsWithoutRearmingOldWindow() async throws {
        let base = Source(), source = make(base)
        try await prime(source)
        await until { source.metrics.residentBytes == 16 }
        base.blockDemand = true
        let demand = Task { try await source.read(file, range: 16..<40) }
        await until { base.gate != nil }
        let queued = Task { try await source.read(file, range: 40..<48) }
        for _ in 0..<20 { await Task.yield() }
        source.invalidatePrefetch(reason: .seek)
        base.blockDemand = false; base.release()
        #expect(try await demand.value == Data(16..<40))
        #expect(try await queued.value == Data(40..<48))
        #expect(source.metrics.hitBytes == 16 && source.metrics.discardedBytes == 0)
        #expect(source.metrics.residentBytes == 0 && source.metrics.historyBytes == 16)
        for _ in 0..<30 { await Task.yield() }
        #expect(base.speculative.count == 2 && base.maxOutstanding == 1)
        let before = base.reads.count
        #expect(try await source.read(file, range: 16..<32) == Data(16..<32))
        #expect(base.reads.count == before)
        try await source.awaitPlaybackCleanup()
    }

    @Test func changedEpochDiscardsInflightPrefixBeforeDemand() async throws {
        let base = Source(); base.blockSpeculation = true
        let source = make(base)
        try await prime(source)
        await until { base.gate != nil }
        let demand = Task { try await source.read(file, range: 16..<40) }
        for _ in 0..<20 { await Task.yield() }
        base.token = 2; base.blockSpeculation = false; base.release()
        #expect(try await demand.value == Data(16..<40))
        #expect(base.reads == [0..<8, 8..<16, 16..<40])
        #expect(source.metrics.joinedBytes == 0 && source.metrics.hitBytes == 0)
        #expect(source.metrics.discardedBytes == 8 && base.maxOutstanding == 1)
        try await source.awaitPlaybackCleanup()
    }

    // Real Build82 geometry: pf3 [0,2048) KiB, pf4 [2048,4096),
    // request305 [-1216,832), then request306 [832,2752), relative to pf3.
    @Test func earlierHistoryAndReadyDemandRetainsSecondInflightBlock() async throws {
        let kib = 1024, mib = 1_048_576
        let base = Source(byteCount: 10 * mib); base.blockSpeculationAt = 2
        var records: [PrefetchDiagnosticRecord] = []
        let source = PlaybackPrefetchSource(file: file, source: base, diagnosticSink: { records.append($0) })
        _ = try await source.fileSize(for: file); source.setPrefetchEnabled(true)
        _ = try await source.read(file, range: 0..<UInt64(mib))
        _ = try await source.read(file, range: UInt64(mib)..<UInt64(2 * mib))
        await until { base.gate != nil }
        let anchor = 2 * mib
        #expect(source.metrics.totalCacheBytes == 6 * mib)
        let firstRange = UInt64(anchor - 1216 * kib)..<UInt64(anchor + 832 * kib)
        let first = Task { try await source.read(file, range: firstRange) }
        await until { source.metrics.speculativeWaitCount == 1 }
        base.blockSpeculationAt = nil; base.release()
        #expect(try await first.value == base.bytes.subdata(in: Int(firstRange.lowerBound)..<Int(firstRange.upperBound)))
        #expect(base.reads.count == 2 && base.speculative.count == 2)
        #expect(source.metrics.historyHitBytes == 1216 * kib)
        #expect(source.metrics.hitBytes == 832 * kib && source.metrics.joinedBytes == 0)
        #expect(source.metrics.discardedBytes == 0)
        #expect(records.contains { $0.event == .retained && $0.reason == .retainedReady && $0.prefetchOverlapBytes == 0 })
        let nextRange = UInt64(anchor + 832 * kib)..<UInt64(anchor + 2752 * kib)
        #expect(try await source.read(file, range: nextRange) == base.bytes.subdata(in: Int(nextRange.lowerBound)..<Int(nextRange.upperBound)))
        #expect(base.reads.count == 2 && base.speculative.count == 2)
        #expect(source.metrics.hitBytes == 2752 * kib && source.metrics.joinedBytes == 0)
        #expect(source.metrics.missBytes == 2 * mib && source.metrics.discardedBytes == 0)
        #expect(source.metrics.maxTotalCacheBytes == 6 * mib && base.maxOutstanding == 1)
        #expect(source.metrics.diagnostics.joinedDemandCount == 0)
        try await source.awaitPlaybackCleanup()
    }

    @Test(arguments: ["seek", "epoch", "disjoint"])
    func earlierReadyDemandDistinguishesSeekEpochAndDisjointCompletion(mode: String) async throws {
        let base = Source(); base.blockSpeculationAt = 2
        let source = make(base)
        try await prime(source); await until { base.gate != nil }
        let range: Range<UInt64> = mode == "disjoint" ? 0..<8 : 16..<20
        let demand = Task { try await source.read(file, range: range) }
        await until { source.metrics.speculativeWaitCount == 1 }
        if mode == "seek" { source.invalidatePrefetch(reason: .seek) }
        if mode == "epoch" { base.token = 2 }
        base.blockSpeculationAt = nil; base.release()
        if mode == "seek" {
            #expect(try await demand.value == Data(16..<20))
            #expect(base.reads.count == 2)
            #expect(source.metrics.discardedBytes == 8 && source.metrics.residentBytes == 4)
            #expect(source.metrics.hitBytes == 4 && source.metrics.historyBytes == 4)
        } else {
            #expect(try await demand.value == base.bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)))
            #expect(base.reads.count == 3)
            #expect(source.metrics.discardedBytes == (mode == "epoch" ? 16 : 8))
            #expect(source.metrics.residentBytes == (mode == "epoch" ? 0 : 8))
        }
        #expect(source.metrics.joinedBytes == 0)
        #expect(source.metrics.maxTotalCacheBytes <= 24 && base.maxOutstanding == 1)
        try await source.awaitPlaybackCleanup()
    }

    @Test func admissionStopsAreBoundedCountersNotDetailedEvents() async throws {
        let base = Source(), source = make(base)
        _ = try await source.fileSize(for: file)
        await until { source.metrics.diagnostics.noAdmissionDisabledOrEpoch > 0 }
        source.setPrefetchEnabled(true)
        _ = try await source.read(file, range: 0..<8)
        await until { source.metrics.diagnostics.noAdmissionWindow > 0 }
        _ = try await source.read(file, range: 8..<16)
        await until { source.metrics.diagnostics.noAdmissionFilledOrBudget > 0 }
        #expect(base.speculative.count == 2)
        let before = source.metrics.diagnostics.generatedRecords
        try await Task.sleep(for: .milliseconds(5))
        #expect(source.metrics.diagnostics.generatedRecords == before)
        try await source.awaitPlaybackCleanup()
    }

    @MainActor private final class MeasuredSource: PlaybackCacheSource {
        let bytes = Data(repeating: 0x5a, count: 4 * 1_048_576)
        var returnedBytes: UInt64 = 0
        var reads = 0
        var stopped = false
        var isPlaybackRecovering: Bool { false }
        var recoveryActiveStartedAt: TimeInterval? { nil }
        var recoveryActiveElapsed: TimeInterval { 0 }
        func playbackCacheEpoch() throws -> UInt64? {
            if stopped { throw CancellationError() }
            return 1
        }
        func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(bytes.count) }
        func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            try await Task.sleep(for: .milliseconds(2))
            let data = bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
            reads += 1; returnedBytes += UInt64(data.count)
            return data
        }
        func readForPrefetch(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            try await read(file, range: range)
        }
        func setPlaybackSceneActive(_ active: Bool) {}
        func cancelPlayback() { stopped = true }
        func awaitPlaybackCleanup() async throws {}
    }

    /// One controlled Data-only comparison, not a network or throughput benchmark.
    /// Both modes request eight 256 KiB chunks at the same 30 ms target cadence.
    @Test func productionWindowSyntheticCostComparison() async throws {
        var summary: [[String: Double]] = []
        for enabled in [false, true] {
            // Preserve the original 32 MiB cost comparison as an explicit baseline.
            let base = MeasuredSource()
            let source = PlaybackPrefetchSource(file: file, source: base,
                configuration: .init(totalCapacityBytes: 32 * 1_048_576))
            _ = try await source.fileSize(for: file)
            source.setPrefetchEnabled(enabled)
            let clock = ContinuousClock(), start = ContinuousClock.now
            var demandAwaitSeconds: TimeInterval = 0
            for index in 0..<8 {
                try await clock.sleep(until: start.advanced(by: .milliseconds(30 * index)))
                let lower = UInt64(index * 262_144)
                let demandStarted = ProcessInfo.processInfo.systemUptime
                let data = try await source.read(file, range: lower..<(lower + 262_144))
                demandAwaitSeconds += ProcessInfo.processInfo.systemUptime - demandStarted
                #expect(data == Data(repeating: 0x5a, count: 262_144))
            }
            let residentBeforeStop = source.metrics.residentBytes
            try await source.awaitPlaybackCleanup()
            let metrics = source.metrics
            #expect(metrics.residentBytes == 0)
            #expect(metrics.maxResidentBytes <= 4 * 1_048_576)
            #expect(metrics.maxInFlightBytes <= 2 * 1_048_576)
            #expect(metrics.hitBytes + metrics.joinedBytes + metrics.historyHitBytes + metrics.missBytes == 8 * 262_144)
            #expect(base.returnedBytes == metrics.missBytes + metrics.speculativeBytes)
            #expect(metrics.discardedBytes >= UInt64(residentBeforeStop))
            if !enabled { #expect(metrics.hitBytes == 0 && metrics.speculativeBytes == 0) }
            else { #expect(metrics.maxInFlightBytes == 2 * 1_048_576) }
            summary.append([
                "enabled": enabled ? 1 : 0,
                "payloadBytes": Double(base.bytes.count),
                "capacityBytes": 4 * 1_048_576,
                "sharedCapacityBytes": 32 * 1_048_576,
                "chunkBytes": 2 * 1_048_576,
                "readDelayMS": 2,
                "demandCadenceMS": 30,
                "demandCount": 8,
                "hitBytes": Double(metrics.hitBytes),
                "joinedBytes": Double(metrics.joinedBytes),
                "missBytes": Double(metrics.missBytes),
                "speculativeBytes": Double(metrics.speculativeBytes),
                "discardedBytesAfterStop": Double(metrics.discardedBytes),
                "residentBytesBeforeStop": Double(residentBeforeStop),
                "peakResidentBytes": Double(metrics.maxResidentBytes),
                "peakInFlightBytes": Double(metrics.maxInFlightBytes),
                "demandAwaitSeconds": demandAwaitSeconds,
                "demandQueueSeconds": metrics.demandWaitSeconds,
                "demandServiceSeconds": metrics.demandSeconds,
                "speculativeSeconds": metrics.speculativeSeconds,
                "underlyingReturnedBytes": Double(base.returnedBytes),
                "underlyingReadCount": Double(base.reads)
            ])
        }
        let json = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print("PREFETCH_SYNTHETIC_COST_JSON " + String(decoding: json, as: UTF8.self))
    }

}
