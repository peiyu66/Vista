import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

/// Synthetic Data-only source. Never opens media, SMB, sockets, or devices.
@Suite(.serialized) @MainActor struct CompleteCacheReplyTests {
    @MainActor private final class Source: PlaybackCacheSource, PlaybackSourceRevisionProviding {
        var bytes = Data((0..<256).map { UInt8($0) })
        var token: UInt64? = 1
        var active = true, stopped = false
        var isPlaybackRecovering: Bool { false }
        var recoveryActiveStartedAt: TimeInterval? { nil }
        var recoveryActiveElapsed: TimeInterval { 0 }
        var supportsRetainedCacheRevalidation: Bool { true }
        var reads: [Range<UInt64>] = [], speculative: [Range<UInt64>] = []
        var gate: CheckedContinuation<Void, Never>?
        var blockDemand = false, blockIdentity = false
        var blockPrefetchAt: Int?
        var outstanding = 0, maxOutstanding = 0, identityCount = 0
        var epochHook: (() -> Void)?
        func playbackCacheEpoch() throws -> UInt64? {
            epochHook?()
            if stopped { throw CancellationError() }
            return active ? token : nil
        }
        func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(bytes.count) }
        func freshPlaybackIdentity() async throws -> PlaybackSourceIdentity {
            identityCount += 1
            if blockIdentity { await withCheckedContinuation { gate = $0 } }
            return .init(size: UInt64(bytes.count), modificationDate: Date(timeIntervalSince1970: 1), creationDate: Date(timeIntervalSince1970: 1))
        }
        func validatePlaybackRevision(_ baseline: PlaybackSourceIdentity) throws {}
        func awaitSourceOperationsDrained() async throws {}
        func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            reads.append(range); outstanding += 1; maxOutstanding = max(maxOutstanding, outstanding)
            defer { outstanding -= 1 }
            if blockDemand { await withCheckedContinuation { gate = $0 } }
            return bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        func readForPrefetch(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            speculative.append(range); outstanding += 1; maxOutstanding = max(maxOutstanding, outstanding)
            defer { outstanding -= 1 }
            if blockPrefetchAt == speculative.count { await withCheckedContinuation { gate = $0 } }
            return bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        func readCompletingCachedSegments(_ file: MediaFile, range: Range<UInt64>, segments: [PlaybackCachedSegment], epoch: UInt64) async throws -> PlaybackCachedReadResult {
            guard active, token == epoch else { return .init(data: try await read(file, range: range), usedCachedBytes: 0) }
            var data = Data(), cursor = range.lowerBound, used = 0
            for segment in segments {
                if cursor < segment.range.lowerBound { data.append(try await read(file, range: cursor..<segment.range.lowerBound)) }
                data.append(segment.data); used += segment.data.count; cursor = segment.range.upperBound
            }
            if cursor < range.upperBound { data.append(try await read(file, range: cursor..<range.upperBound)) }
            return .init(data: data, usedCachedBytes: used)
        }
        func release() { let saved = gate; gate = nil; saved?.resume() }
        func setPlaybackSceneActive(_ active: Bool) { self.active = active }
        func cancelPlayback() { stopped = true }
        func awaitPlaybackCleanup() async throws {}
    }
    private func file(_ suffix: String = "mp4") -> MediaFile { try! MediaFile(components: ["generated.\(suffix)"]) }
    private func make(_ base: Source, _ file: MediaFile) -> PlaybackPrefetchSource {
        .init(file: file, source: base, configuration: .init(capacityBytes: 16, chunkBytes: 8, totalCapacityBytes: 128))
    }
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<20_000 { if condition() { return }; await Task.yield() }
        Issue.record("Synthetic gate timed out")
    }
    private func prime(_ wrapper: PlaybackPrefetchSource, _ file: MediaFile, ranges: [Range<UInt64>] = [0..<16]) async throws {
        _ = try await wrapper.fileSize(for: file); wrapper.setPrefetchEnabled(true)
        for range in ranges { _ = try await wrapper.read(file, range: range) }
        wrapper.invalidatePrefetch(reason: .seek)
        await until { wrapper.recoveryActivity.idle }
    }
    private func conserved(_ wrapper: PlaybackPrefetchSource) {
        let m = wrapper.metrics
        #expect(m.speculativeBytes == m.hitBytes + m.joinedBytes + m.discardedBytes + m.retiredSpeculativeBytes + UInt64(m.residentBytes))
        #expect(m.diagnostics.discardedBytes == m.discardedBytes)
    }

    @Test func fullHistoryBeatsBlockedSourceWhilePartialAndZeroStaySerial() async throws {
        for suffix in ["mp4", "mkv"] {
            let f = file(suffix), base = Source(), wrapper: PlaybackPrefetchSource
            wrapper = make(base, f); try await prime(wrapper, f)
            base.blockDemand = true
            let blocked = Task { try await wrapper.read(f, range: 64..<72) }
            await until { base.gate != nil }
            let current = wrapper.rangeDiagnosticSnapshot().current
            let supply = wrapper.supplyDiagnosticSnapshot()
            let before = wrapper.metrics
            let hit = try await wrapper.read(f, range: 0..<8)
            #expect(hit == Data(0..<8)); #expect(base.gate != nil && base.outstanding == 1)
            #expect(wrapper.rangeDiagnosticSnapshot().current == current)
            #expect(wrapper.supplyDiagnosticSnapshot().work == supply.work)
            #expect(wrapper.metrics.demandSnapshotBytes == before.demandSnapshotBytes)
            #expect(wrapper.metrics.directCacheReplyCount == 1)
            let logged=wrapper.metrics.directCacheReplyLogValues
            #expect(logged[.directCacheReplyCount] == Double(wrapper.metrics.directCacheReplyCount))
            #expect(logged[.directCacheReplyBytes] == Double(wrapper.metrics.directCacheReplyBytes))
            #expect(logged.count == 2)
            #expect(wrapper.metrics.directCacheSnapshotBytes == 0 && wrapper.metrics.maxDirectCacheSnapshotBytes == 8)
            #expect(wrapper.metrics.diagnostics.demandFullCacheCount == before.diagnostics.demandFullCacheCount + 1)
            #expect(wrapper.metrics.historyHitBytes == before.historyHitBytes + 8)
            #expect(wrapper.metrics.speculativeWaitCount == before.speculativeWaitCount)
            #expect(wrapper.metrics.demandWaitSeconds == before.demandWaitSeconds)
            let partial = Task { try await wrapper.read(f, range: 8..<24) }
            await until { wrapper.recoveryActivity.queued == 1 }
            let zero = Task { try await wrapper.read(f, range: 96..<104) }
            await until { wrapper.recoveryActivity.queued == 2 }
            #expect(base.reads == [0..<16, 64..<72])
            base.blockDemand = false; base.release()
            #expect(try await blocked.value == Data(64..<72))
            #expect(try await partial.value == Data(8..<24))
            #expect(try await zero.value == Data(96..<104))
            #expect(base.reads == [0..<16, 64..<72, 16..<24, 96..<104])
            #expect(base.maxOutstanding == 1)
            wrapper.handleMemoryPressure() // Returned payload is independent of the freed arena.
            #expect(hit == Data(0..<8)); conserved(wrapper)
            try await wrapper.awaitPlaybackCleanup()
        }
    }

    @Test func readyPrefetchBeatsUnrelatedPrefetchWithoutDoubleCreditOrWait() async throws {
        let f = file(), base = Source()
        let w = make(base, f); _ = try await w.fileSize(for: f); w.setPrefetchEnabled(true)
        base.blockPrefetchAt = 2
        _ = try await w.read(f, range: 0..<8); _ = try await w.read(f, range: 8..<16)
        await until { base.gate != nil && base.speculative.count == 2 }
        let current = w.rangeDiagnosticSnapshot().current, before = w.metrics
        #expect(try await w.read(f, range: 16..<24) == Data(16..<24))
        #expect(base.gate != nil && base.outstanding == 1)
        #expect(w.rangeDiagnosticSnapshot().current == current)
        #expect(w.metrics.hitBytes == before.hitBytes + 8)
        #expect(w.metrics.directCacheReplyCount == before.directCacheReplyCount + 1)
        #expect(w.metrics.joinedBytes == before.joinedBytes)
        #expect(w.metrics.speculativeWaitCount == before.speculativeWaitCount)
        conserved(w)
        w.setPrefetchEnabled(false, reason: .pause); base.release()
        await until { w.recoveryActivity.busy == 0 }
        #expect(base.maxOutstanding == 1); conserved(w)
        try await w.awaitPlaybackCleanup()
    }

    @Test func legacySmallHistorySpeculativeHitKeepsSerialTrimming() async throws {
        let f = file(), base = Source()
        // Same total budget as the shared-budget fixture, but an explicit smaller
        // history cap. No metadata-limit stress or synthetic fragmentation needed.
        let w = PlaybackPrefetchSource(file: f, source: base,
            configuration: .init(capacityBytes: 16, chunkBytes: 8, historyCapacityBytes: 112))
        _ = try await w.fileSize(for: f); w.setPrefetchEnabled(true)
        base.blockPrefetchAt = 2
        _ = try await w.read(f, range: 0..<8); _ = try await w.read(f, range: 8..<16)
        await until { base.gate != nil && base.speculative.count == 2 }
        let before = w.metrics.directCacheReplyCount
        let hit = Task { try await w.read(f, range: 16..<24) }
        await until { w.recoveryActivity.queued == 1 }
        #expect(base.gate != nil && base.outstanding == 1)
        #expect(w.metrics.directCacheReplyCount == before)
        base.release()
        #expect(try await hit.value == Data(16..<24))
        #expect(w.metrics.directCacheReplyCount == before && w.metrics.historyBytes <= 112)
        w.invalidatePrefetch(reason: .seek)
        await until { w.recoveryActivity.idle }
        // The eligibility narrowing excludes speculative conversion only.
        #expect(try await w.read(f, range: 16..<24) == Data(16..<24))
        #expect(w.metrics.directCacheReplyCount == before + 1)
        #expect(base.maxOutstanding == 1); conserved(w)
        try await w.awaitPlaybackCleanup()
    }

    @Test func forwardCreditSettlesFIFOForNoWindowDistantPairNearAndBackread() async throws {
        // The second row is near advance then backread; neither response may move
        // the cursor before the earlier source read finishes. Distant pair rebases.
        for later in [[32..<40, 40..<48], [16..<24, 0..<8]] as [[Range<UInt64>]] {
            let f = file(), base = Source(), w: PlaybackPrefetchSource
            w = make(base, f)
            try await prime(w, f, ranges: [32..<40, 0..<8, 40..<48, 16..<24])
            _ = try await w.read(f, range: 0..<8)
            await until { w.metrics.pendingCacheCompletions == 0 }
            base.blockDemand = true; base.blockPrefetchAt = base.speculative.count + 1
            let older = Task { try await w.read(f, range: 8..<16) }
            await until { base.gate != nil }
            for range in later { _ = try await w.read(f, range: range) }
            #expect(w.rangeDiagnosticSnapshot().forward.cursor == nil)
            #expect(w.metrics.pendingCacheCompletions == 2)
            base.blockDemand = false; base.release(); _ = try await older.value
            await until { w.metrics.pendingCacheCompletions == 0 }
            let forward = w.rangeDiagnosticSnapshot().forward
            #expect(forward.cursor == (later[0].lowerBound == 32 ? 48 : 24))
            #expect(forward.target == (later[0].lowerBound == 32 ? 64 : 40))
            #expect(forward.reads <= 1)
            w.setPrefetchEnabled(false, reason: .pause)
            base.release(); await until { w.recoveryActivity.busy == 0 }
            #expect(base.maxOutstanding == 1); conserved(w)
            try await w.awaitPlaybackCleanup()
        }
    }

    @Test func finalAcceptanceRejectsCancellationGenerationEpochAndLifecycleChanges() async throws {
        for boundary in ["cancel", "seek", "epoch", "nil", "background", "stop", "memory"] {
            let f = file(), base = Source(), w: PlaybackPrefetchSource
            w = make(base, f); try await prime(w, f)
            var hit: Task<Data, any Error>?
            var changed = false
            w.diagnosticSink = { record in
                guard record.event == .prefixDetached, !changed else { return }
                changed = true
                switch boundary {
                case "cancel": hit?.cancel()
                case "seek": w.invalidatePrefetch(reason: .seek)
                case "epoch": base.token = 2; base.bytes = Data(repeating: 0xaa, count: 256)
                case "nil": base.token = nil; base.bytes = Data(repeating: 0xbb, count: 256)
                case "background": w.setPlaybackSceneActive(false)
                case "stop": w.cancelPlayback()
                default: w.handleMemoryPressure()
                }
            }
            hit = Task { try await w.read(f, range: 0..<8) }
            let result = await hit!.result
            #expect(changed && w.metrics.directCacheReplyCount == 0)
            if boundary == "cancel" || boundary == "stop" {
                if case .success = result { Issue.record("Cancelled cache snapshot escaped") }
            }
            if boundary == "epoch" || boundary == "nil" {
                #expect(try result.get() == Data(repeating: boundary == "epoch" ? 0xaa : 0xbb, count: 8))
            }
            w.diagnosticSink = nil
            try await w.awaitPlaybackCleanup()
        }
    }

    @Test func alreadyInvalidOrCancelledRequestsCannotEnterBypassAndLateCancelCannotRevoke() async throws {
        let f = file(), base = Source(), w: PlaybackPrefetchSource
        w = make(base, f); try await prime(w, f)
        base.blockDemand = true
        let older = Task { try await w.read(f, range: 64..<72) }
        await until { base.gate != nil }
        let hit = Task { try await w.read(f, range: 0..<8) }
        #expect(try await hit.value == Data(0..<8)); hit.cancel()
        for _ in 0..<20 { await Task.yield() }
        #expect(w.metrics.pendingCacheCompletions == 1 && w.metrics.directCacheReplyCount == 1)
        #expect(w.metrics.diagnostics.demandCancelledCount == 0)
        let cancelled = Task { try await w.read(f, range: 0..<8) }; cancelled.cancel()
        if case .success = await cancelled.result { Issue.record("Pre-cancelled demand succeeded") }
        #expect(w.metrics.directCacheReplyCount == 1)
        // Existing background quarantine must not be treated as same-epoch availability.
        w.setPlaybackSceneActive(false)
        let background = Task { try await w.read(f, range: 0..<8) }
        await until { w.recoveryActivity.queued == 1 }
        #expect(w.metrics.directCacheReplyCount == 1)
        background.cancel(); base.blockDemand = false; base.release()
        _ = await older.result; _ = await background.result
        try await w.awaitPlaybackCleanup()
    }

    @Test func cancelledActiveSourceMustDrainBeforeAcceptedHitSettlesCredit() async throws {
        let f = file(), base = Source(), w: PlaybackPrefetchSource
        w = make(base, f); try await prime(w, f, ranges: [0..<8, 32..<40])
        _ = try await w.read(f, range: 0..<8)
        await until { w.metrics.pendingCacheCompletions == 0 }
        base.blockDemand = true
        let older = Task { try await w.read(f, range: 64..<72) }
        await until { base.gate != nil }
        older.cancel(); _ = await older.result
        #expect(w.recoveryActivity.busy & 1 == 0 && w.recoveryActivity.busy & 2 != 0)
        #expect(try await w.read(f, range: 32..<40) == Data(32..<40))
        #expect(w.metrics.pendingCacheCompletions == 1 && base.outstanding == 1)
        #expect(w.rangeDiagnosticSnapshot().forward.cursor == nil)
        // Generation changes invalidate the accepted reply's later credit, not its bytes.
        w.invalidatePrefetch(reason: .seek)
        #expect(w.metrics.pendingCacheCompletions == 0)
        base.blockDemand = false; base.release()
        await until { w.recoveryActivity.busy == 0 }
        #expect(w.rangeDiagnosticSnapshot().forward.cursor == nil)
        #expect(w.metrics.diagnostics.demandCancelledCount == 1 && base.maxOutstanding == 1)
        try await w.awaitPlaybackCleanup()
    }

    @Test func queuedIdentityIsABarrierEvenBeforeSourceSeesIt() async throws {
        let f = file(), base = Source(), w: PlaybackPrefetchSource
        w = make(base, f); try await prime(w, f)
        base.blockDemand = true
        let older = Task { try await w.read(f, range: 64..<72) }; await until { base.gate != nil }
        let identity = Task { try await w.freshPlaybackIdentity() }
        await until { w.recoveryActivity.queued == 1 }
        let hit = Task { try await w.read(f, range: 0..<8) }
        await until { w.recoveryActivity.queued == 2 }
        #expect(base.identityCount == 0 && w.metrics.directCacheReplyCount == 0)
        base.blockDemand = false; base.release(); _ = try await older.value
        _ = try await identity.value; #expect(try await hit.value == Data(0..<8))
        #expect(base.identityCount == 1 && base.maxOutstanding == 1)
        try await w.awaitPlaybackCleanup()
    }

    @Test func markerCapFallsBackWithoutRetainingReplyPayloads() async throws {
        let f = file(), base = Source(), w: PlaybackPrefetchSource
        w = make(base, f); try await prime(w, f)
        base.blockDemand = true
        let older = Task { try await w.read(f, range: 64..<72) }; await until { base.gate != nil }
        for _ in 0..<64 { _ = try await w.read(f, range: 0..<8) }
        let capped = Task { try await w.read(f, range: 0..<8) }
        await until { w.recoveryActivity.queued == 1 }
        #expect(w.metrics.directCacheReplyCount == 64 && w.metrics.pendingCacheCompletions == 64)
        #expect(w.metrics.directCacheSnapshotBytes == 0 && w.metrics.maxDirectCacheSnapshotBytes == 8)
        base.blockDemand = false; base.release(); _ = try await older.value; _ = try await capped.value
        await until { w.metrics.pendingCacheCompletions == 0 }
        #expect(w.metrics.maxPendingCacheCompletions == 64)
        #expect(w.metrics.diagnostics.demandFullCacheCount == 65)
        #expect(w.metrics.historyHitBytes == 65 * 8)
        try await w.awaitPlaybackCleanup()
    }
}
