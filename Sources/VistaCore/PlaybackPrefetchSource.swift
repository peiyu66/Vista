import Foundation

/// One-file, memory-only read ahead. Admission cancellation never claims that an already
/// started transport read was preempted: the pump waits for its actual completion.
@MainActor public final class PlaybackPrefetchSource: PlaybackRecoveryControlling {
    public struct Configuration: Sendable {
        /// Forward admission target; it is not a separately allocated cache.
        public let capacityBytes: Int
        public let chunkBytes: Int
        public let totalCapacityBytes: Int
        public let historyCapacityBytes: Int
        public init(capacityBytes: Int = 4 * 1_048_576, chunkBytes: Int = 2 * 1_048_576,
                    totalCapacityBytes: Int = 160 * 1_048_576) {
            precondition(capacityBytes > 0 && capacityBytes <= 4 * 1_048_576 && chunkBytes > 0
                && UInt64(chunkBytes) <= MediaReadPlan.maximumChunkBytes && chunkBytes <= capacityBytes
                && totalCapacityBytes >= capacityBytes && totalCapacityBytes <= 160 * 1_048_576)
            self.capacityBytes = capacityBytes; self.chunkBytes = chunkBytes
            self.totalCapacityBytes = totalCapacityBytes; self.historyCapacityBytes = totalCapacityBytes
        }
        /// Compatibility for explicit small fixed-history callers. Production uses the
        /// shared-budget initializer above; both configurations use the same circular storage.
        public init(capacityBytes: Int, chunkBytes: Int, historyCapacityBytes: Int) {
            precondition(capacityBytes > 0 && capacityBytes <= 4 * 1_048_576 && chunkBytes > 0
                && UInt64(chunkBytes) <= MediaReadPlan.maximumChunkBytes && chunkBytes <= capacityBytes
                && historyCapacityBytes >= 0 && historyCapacityBytes <= 160 * 1_048_576 - capacityBytes)
            self.capacityBytes = capacityBytes; self.chunkBytes = chunkBytes
            self.totalCapacityBytes = capacityBytes + historyCapacityBytes
            self.historyCapacityBytes = historyCapacityBytes
        }
    }
    /// Byte counters describe bytes returned at this wrapper boundary, not SMB wire traffic.
    /// Durations are cumulative wall time, including source waits, not throughput estimates.
    public struct Metrics: Sendable {
        public fileprivate(set) var hitBytes: UInt64 = 0
        /// Demand bytes that waited for an already-running speculative read. Not ready-cache hits.
        public fileprivate(set) var joinedBytes: UInt64 = 0
        public fileprivate(set) var historyHitBytes: UInt64 = 0
        public fileprivate(set) var missBytes: UInt64 = 0
        public fileprivate(set) var speculativeBytes: UInt64 = 0
        public fileprivate(set) var discardedBytes: UInt64 = 0
        /// Unused speculative credit retired to general retained cache to bound
        /// classification metadata. Bytes remain valid, so this is not eviction.
        public fileprivate(set) var retiredSpeculativeBytes: UInt64 = 0
        /// Unused speculative credit only, across all retained ranges. Not the
        /// current forward admission budget, which is measured in its own window.
        public fileprivate(set) var residentBytes = 0
        /// General retained bytes: delivered demand plus unused speculation retired
        /// solely to bound classification metadata. Every byte remains readable.
        public fileprivate(set) var historyBytes = 0
        public fileprivate(set) var totalCacheBytes = 0
        public fileprivate(set) var inFlightReservedBytes = 0
        public fileprivate(set) var maxTotalCacheBytes = 0
        /// Valid arena bytes, excluding the single temporary source read and snapshots.
        public fileprivate(set) var validCacheBytes = 0
        public fileprivate(set) var cacheQuarantined = false
        public fileprivate(set) var cacheMetadataEntries = 0
        public fileprivate(set) var maxCacheMetadataEntries = 0
        public fileprivate(set) var cacheMetadataAllocatedBytes = 0
        public fileprivate(set) var maxCacheMetadataAllocatedBytes = 0
        public static let cacheMetadataEntryLimit = 1024
        /// Physical cache payload allocation, separate from temporary demand snapshots,
        /// source transport/assembly and caller-owned replies (each request is <= 2 MiB).
        public fileprivate(set) var storageAllocatedBytes = 0
        public fileprivate(set) var maxStorageAllocatedBytes = 0
        /// Deterministic copy-cost evidence: extending history copies new bytes only.
        public fileprivate(set) var storageWrittenBytes: UInt64 = 0
        /// Independent snapshots passed to the current demand; never views of storage.
        public fileprivate(set) var demandSnapshotBytes = 0
        public fileprivate(set) var maxDemandSnapshotBytes = 0
        public fileprivate(set) var speculativeWaitCount: UInt64 = 0
        public fileprivate(set) var speculativeWaitSeconds: TimeInterval = 0
        public fileprivate(set) var maxResidentBytes = 0
        public fileprivate(set) var maxInFlightBytes = 0
        public fileprivate(set) var demandSeconds: TimeInterval = 0
        public fileprivate(set) var speculativeSeconds: TimeInterval = 0
        public fileprivate(set) var demandWaitSeconds: TimeInterval = 0
        public fileprivate(set) var diagnostics = PrefetchDiagnosticsSnapshot()
    }
    private enum Operation { case size, read(Range<UInt64>) }
    private enum Response { case size(UInt64), bytes(Data) }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var cancelled: Bool { lock.withLock { value } }
        func cancel() { lock.withLock { value = true } }
    }
    private final class Request {
        let id: UInt64, generation: UInt64, operation: Operation, cancellation: Cancellation
        let submitted: TimeInterval
        var rangeDiagnostic: PlaybackRangeDiagnostics.Work
        let continuation: CheckedContinuation<Response, any Error>
        let waitedForPrefetch: Bool
        var waitStarted: TimeInterval?
        var speculativeWaitSeconds: TimeInterval = 0
        var usedCachedBytes = 0, sourceCallCount: UInt64 = 0
        var forwardCancellationHandled = false
        var sourceCallSeconds: Double = 0
        /// Candidate only. The serial pump commits progress at its one final
        /// success decision, after all source/cache diagnostic callbacks finish.
        var forwardEpoch: UInt64?
        init(id: UInt64, generation: UInt64, operation: Operation, cancellation: Cancellation, submitted: TimeInterval,
             continuation: CheckedContinuation<Response, any Error>, waitedForPrefetch: Bool) {
            self.id = id; self.generation = generation; self.operation = operation; self.cancellation = cancellation
            self.submitted = submitted; self.continuation = continuation; self.waitedForPrefetch = waitedForPrefetch
            waitStarted = waitedForPrefetch ? submitted : nil
            let kind: PlaybackSupplyDiagnostics.Kind, range: Range<UInt64>?
            switch operation { case .size: kind = .size; range = nil; case .read(let value): kind = .demand; range = value }
            // Capture at enqueue: the existing serial pump may belong to an older Task.
            rangeDiagnostic = .init(kind: kind, id: id, generation: generation, queued: submitted,
                range: range, correlation: PlaybackReadDiagnosticContext.correlation)
        }
        var diagnostic: PrefetchDemandObservation {
            if case .read(let range) = operation { return .init(id: id, range: range) }
            return .init(id: id, range: nil)
        }
    }
    private struct PrefetchContext {
        let id: UInt64, range: Range<UInt64>, generation: UInt64, epoch: UInt64
        let previousDelta: Int64?
    }
    private struct Block {
        let start: UInt64
        let count: Int
        let diagnostic: PrefetchContext
        var end: UInt64 { start + UInt64(count) }
    }
    private struct PrefixPiece {
        let range: Range<UInt64>
        let diagnostic: PrefetchContext
    }
    private static var nextDiagnosticSession: UInt64 = 0
    /// The sink must remain lightweight and observational. No identifiers or absolute
    /// offsets are exposed. At most 256 records are delivered over this wrapper's life.
    public var diagnosticSink: (@MainActor @Sendable (PrefetchDiagnosticRecord) -> Void)?
    /// One terminal observation after the original drain/cleanup, separate from the
    /// detail cap. Arguments are final wrapper metrics and cleanup success.
    public var cleanupDiagnosticSink: (@MainActor @Sendable (Metrics, Bool) -> Void)?
    private var cleanupDiagnosticsReported = false
    private var nextPrefetchID: UInt64 = 0
    private var lastPrefetch: PrefetchContext?, inFlight: PrefetchContext?
    private var demandOwnedPrefix: [PrefixPiece] = []
    // Only a safety flush transfers outstanding snapshot credit out of the arena.
    private var detachedPrefix: [PrefixPiece] = []
    private var demandOwnedHistoryBytes = 0
    private var demandReadReservedBytes = 0
    private var lastInvalidationReason: PrefetchInvalidationReason = .explicit
    /// The completed speculative block is ready data now. This tag attributes only the
    /// first waiting demand's overlap as joined; remaining bytes become ordinary cache.
    private struct Handoff {
        let requestID: UInt64, epoch: UInt64, generation: UInt64, prefetchID: UInt64
        let range: Range<UInt64>
    }
    private var handoff: Handoff?
    private let file: MediaFile
    private let source: any PlaybackCacheSource
    private let configuration: Configuration
    private let storage: CircularStorage
    public private(set) var metrics = Metrics()
    private var enabled = false, paused = false, disabledForMemoryPressure = false, stopped = false
    // Seek stops speculation, but current-generation formal demand bytes still belong to this file.
    private var retainsSeekDemand = false
    private var quarantined = false
    private var generation: UInt64 = 0, admission: UInt64 = 0, nextID: UInt64 = 0
    private var epoch: UInt64?, size: UInt64?, lastEnd: UInt64?
    /// A bounded window earned by a completed sequential demand, not by the greatest
    /// retained offset. Ordinary demand cancellation preserves unspent valid credit.
    private struct ForwardWindow {
        let cursor: UInt64, target: UInt64, epoch: UInt64, generation: UInt64
        // Explicit no-history callers may still prefetch while active. Only a
        // completed range actually stored in the arena can back a resumable checkpoint.
        let evidence: Range<UInt64>?
        var reads = 0
    }
    private var forwardWindow: ForwardWindow?
    /// One consecutive higher-location candidate. No independent speculative lane.
    private var pendingRebaseEnd: UInt64?
    private var forwardWindowID: UInt64 = 0
    private func noteForward(_ reason: PrefetchForwardTransition) {
        metrics.diagnostics.forwardTransitionID &+= 1
        metrics.diagnostics.forwardTransition = reason
        switch reason {
        case .create: metrics.diagnostics.forwardCreateCount &+= 1
        case .advance: metrics.diagnostics.forwardAdvanceCount &+= 1
        case .backreadPreserved: metrics.diagnostics.forwardBackreadPreservedCount &+= 1
        case .suspend: metrics.diagnostics.forwardSuspendCount &+= 1
        case .cancelPreserved: metrics.diagnostics.forwardCancelPreservedCount &+= 1
        case .rebase: metrics.diagnostics.forwardRebaseCount &+= 1
        case .distantPending: metrics.diagnostics.forwardDistantPendingCount &+= 1
        case .lifecycleRetired: metrics.diagnostics.forwardLifecycleRetiredCount &+= 1
        case .epochRetired: metrics.diagnostics.forwardEpochRetiredCount &+= 1
        case .evidenceRetired: metrics.diagnostics.forwardEvidenceRetiredCount &+= 1
        case .demandFailureRetired: metrics.diagnostics.forwardDemandFailureRetiredCount &+= 1
        case .prefetchFailureRetired: metrics.diagnostics.forwardPrefetchFailureRetiredCount &+= 1
        case .none: break
        }
    }
    private func retireForward(_ reason: PrefetchForwardTransition) {
        if forwardWindow != nil || lastEnd != nil || pendingRebaseEnd != nil { noteForward(reason) }
        forwardWindow = nil; lastEnd = nil; pendingRebaseEnd = nil
    }
    private func completeForwardDemand(_ range: Range<UInt64>, token: UInt64, version: UInt64) {
        guard !range.isEmpty, enabled || paused else { return }
        let reason: PrefetchForwardTransition
        if let window = forwardWindow {
            guard window.epoch == token, window.generation == version else { retireForward(.epochRetired); return }
            if range.upperBound <= window.cursor {
                // Full, partial and zero-cache backreads all preserve the independent
                // frontier and its spent quota. They never grant fresh credit.
                pendingRebaseEnd = nil; noteForward(.backreadPreserved); return
            }
            let near = range.lowerBound <= window.cursor || range.lowerBound - window.cursor <= UInt64(configuration.chunkBytes / 4)
            if near { reason = .advance }
            else if pendingRebaseEnd == range.lowerBound { reason = .rebase }
            else {
                pendingRebaseEnd = range.upperBound; noteForward(.distantPending); return
            }
        } else {
            let adjacent = lastEnd == range.lowerBound
            lastEnd = range.upperBound
            guard adjacent else { return }
            reason = .create
        }
        guard let size else { return }
        pendingRebaseEnd = nil; lastEnd = nil
        // The target is still contiguous retained end + one bounded window, not a
        // rolling coverage promise. Only this successful demand earns new credit.
        let anchor = contiguousEnd(from: range.upperBound)
        let target = anchor + min(UInt64(configuration.capacityBytes), size - min(size, anchor))
        let retained = PrefetchRangeObservation.measure(range, spans: readySpans + historySpans).overlapBytes == range.count
        if !retained { metrics.diagnostics.forwardUnretainedEvidenceCount &+= 1 }
        forwardWindowID &+= 1
        forwardWindow = ForwardWindow(cursor: range.upperBound, target: target,
            epoch: token, generation: version, evidence: retained ? range : nil)
        noteForward(reason)
    }
    private var canResumeForward: Bool { forwardWindow != nil }
    private func cancelForwardDemand(_ request: Request) {
        guard !request.forwardCancellationHandled else { return }
        request.forwardCancellationHandled = true
        idleGrace?.cancel(); lastEnd = nil; pendingRebaseEnd = nil
        // Ordinary AV cancellation is not a seek. An already valid window may
        // spend its remaining credit after the serial source drains and FIFO empties.
        // Cancellation creates no window, advances no cursor and renews no quota.
        if let window = forwardWindow {
            if window.evidence != nil, window.epoch == epoch, window.generation == generation {
                noteForward(.cancelPreserved)
            } else { retireForward(.evidenceRetired) }
        }
    }
    private var blocks: [Block] { storage.entries.compactMap { entry in
        entry.diagnostic.map { Block(start: entry.range.lowerBound, count: entry.range.count, diagnostic: $0) }
    }.sorted { $0.start < $1.start } }
    private var requests: [Request] = []
    private var supplyDiagnostics = PlaybackSupplyDiagnostics()
    private var rangeDiagnostics = PlaybackRangeDiagnostics()
    /// Wait-boundary only: no payload copy, source getter, await or admission mutation.
    public func rangeDiagnosticSnapshot() -> PlaybackRangeDiagnostics.Snapshot {
        let window = forwardWindow
        let reason: Int
        if stopped || !enabled { reason = 1 }
        else if quarantined || epoch == nil { reason = 2 }
        else if !requests.isEmpty || rangeDiagnostics.current != nil { reason = 3 }
        else if window == nil { reason = 4 }
        else if window?.epoch != epoch || window?.generation != generation { reason = 6 }
        else if window!.reads >= 2 || contiguousEnd(from: window!.cursor) >= window!.target { reason = 7 }
        else { reason = 8 }
        let forward = PlaybackRangeDiagnostics.Forward(cursor: window?.cursor, target: window?.target,
            epoch: window?.epoch, generation: window?.generation, evidence: window?.evidence,
            reads: window?.reads ?? 0, suspended: false, enabled: enabled,
            paused: paused, quarantined: quarantined, reason: reason, invalidation: lastInvalidationReason.rawValue,
            windowID: window == nil ? nil : forwardWindowID, transitionID: metrics.diagnostics.forwardTransitionID,
            transition: metrics.diagnostics.forwardTransition.rawValue)
        let cache = storage.entries.map { entry in
            PlaybackRangeDiagnostics.CacheEntry(range: entry.range, producer: entry.diagnostic?.id,
                generation: entry.diagnostic?.generation, epoch: entry.diagnostic?.epoch)
        }
        return rangeDiagnostics.snapshot(session: metrics.diagnostics.sessionID, generation: generation, epoch: epoch,
            now: ProcessInfo.processInfo.systemUptime, queued: requests.map(\.rangeDiagnostic), cache: cache, forward: forward)
    }
    /// Lightweight read-only snapshot. Current source availability/recovery is
    /// separate from the last validated wrapper epoch. No transport call is made.
    public var diagnosticObservedEpoch: UInt64? { epoch }
    public func supplyDiagnosticSnapshot() -> PlaybackSupplyDiagnostics.Snapshot {
        supplyDiagnostics.snapshot(session: metrics.diagnostics.sessionID, generation: generation, epoch: epoch,
            queueDepth: requests.count, oldestQueuedAt: requests.first?.submitted)
    }
    private func observedSourceCall<T>(kind: PlaybackSupplyDiagnostics.CallKind,
                                      bytes: (T) -> Int, operation: () async throws -> T) async throws -> T {
        let callStart = ProcessInfo.processInfo.systemUptime
        let demand = rangeDiagnostics.current?.kind == .demand ? activeRequest : nil
        defer {
            demand?.sourceCallCount &+= 1
            demand?.sourceCallSeconds += max(0, ProcessInfo.processInfo.systemUptime - callStart)
        }
        supplyDiagnostics.beginCall(kind: kind, now: callStart, observedEpoch: epoch, generation: generation)
        rangeDiagnostics.current?.callKind = kind; rangeDiagnostics.current?.callStarted = callStart
        do {
            let value = try await operation()
            let finished = ProcessInfo.processInfo.systemUptime
            supplyDiagnostics.endCall(result: .returned, bytes: bytes(value), now: finished)
            rangeDiagnostics.current?.callFinished = finished; rangeDiagnostics.current?.callResult = .returned
            rangeDiagnostics.current?.callBytes = bytes(value)
            return value
        } catch {
            let finished = ProcessInfo.processInfo.systemUptime
            supplyDiagnostics.endCall(result: error is CancellationError ? .cancelled : .failed, bytes: 0, now: finished)
            rangeDiagnostics.current?.callFinished = finished
            rangeDiagnostics.current?.callResult = error is CancellationError ? .cancelled : .failed
            rangeDiagnostics.current?.callBytes = 0
            throw error
        }
    }
    /// Authoritative O(1) ownership for a bounded player-recovery decision.
    /// No cache traversal, diagnostic history, source getter or scheduling mutation.
    public struct RecoveryActivity: Equatable, Sendable {
        public let available: Bool, queued: Int, busy: Int
        public let generation: UInt64, admission: UInt64, requests: UInt64, prefetches: UInt64
        public let epoch: UInt64?
        public var idle: Bool { available && queued == 0 && busy == 0 }
    }
    public var recoveryActivity: RecoveryActivity {
        var busy = 0
        if activeRequest != nil { busy |= 1 }; if activeDemand != nil { busy |= 2 }
        if inFlight != nil { busy |= 4 }; if pump != nil { busy |= 8 }
        if idleGrace != nil { busy |= 16 }; if handoff != nil { busy |= 32 }
        return .init(available: !stopped && !quarantined && epoch != nil,
                     queued: requests.count, busy: busy, generation: generation,
                     admission: admission, requests: nextID, prefetches: nextPrefetchID, epoch: epoch)
    }
    private var activeRequest: Request?
    private var activeDemand: Task<Response, any Error>?
    private var pump: Task<Void, Never>?
    private var idleGrace: Task<Void, any Error>?
    public init(file: MediaFile, source: any PlaybackCacheSource, configuration: Configuration = .init(),
                diagnosticSink: (@MainActor @Sendable (PrefetchDiagnosticRecord) -> Void)? = nil) {
        self.file = file; self.source = source; self.configuration = configuration
        self.storage = CircularStorage(capacity: configuration.totalCapacityBytes)
        self.diagnosticSink = diagnosticSink
        Self.nextDiagnosticSession &+= 1
        metrics.diagnostics.sessionID = Self.nextDiagnosticSession
    }
    public var isPlaybackRecovering: Bool { source.isPlaybackRecovering }
    public var recoveryActiveStartedAt: TimeInterval? { source.recoveryActiveStartedAt }
    public var recoveryActiveElapsed: TimeInterval { source.recoveryActiveElapsed }
    public func setPrefetchEnabled(_ enabled: Bool, reason: PrefetchInvalidationReason = .disabled) {
        let wasEnabled = self.enabled
        self.enabled = enabled && !stopped && !disabledForMemoryPressure
        retainsSeekDemand = !self.enabled && reason == .seek && !stopped && !disabledForMemoryPressure
        if !self.enabled, reason == .pause, !stopped, !disabledForMemoryPressure {
            // A normal pause stops admission, not same-file data ownership. An already
            // running read may finish, but cannot admit its successor until resume.
            paused = true; idleGrace?.cancel(); lastInvalidationReason = .pause
            if wasEnabled, forwardWindow != nil { noteForward(.suspend) }
            if hasSpeculativeContext { record(.admissionPaused, reason: .pauseRetained) }
        } else if !self.enabled {
            paused = false; invalidatePrefetch(reason: reason)
        } else {
            paused = false
            if pump == nil, canResumeForward { pump = Task(priority: .low) { await self.run() } }
        }
    }
    /// Retires scheduling work. Seek keeps completed same-source bytes; background
    /// quarantines capable sources; consistency and memory/lifetime boundaries clear.
    public func invalidatePrefetch(reason: PrefetchInvalidationReason = .explicit) {
        idleGrace?.cancel()
        if reason != .seek { retainsSeekDemand = false }
        generation &+= 1; admission &+= 1; retireForward(.lifecycleRetired)
        lastInvalidationReason = reason
        if hasSpeculativeContext { record(.flush, reason: .flush) }
        if reason == .seek {
            // A same-file seek retires scheduling, not a still-live AV request.
            // AV/Task cancellation remains the only formal-request cancellation.
            handoff = nil
        } else if reason == .sceneInactive, source.supportsRetainedCacheRevalidation,
                  epoch != nil, !stopped, !disabledForMemoryPressure {
            // Keep payload but never serve it directly until the source validates
            // the original identity inside the next demand's recovery budget.
            if !quarantined {
                quarantined = true; metrics.diagnostics.quarantineEnteredCount &+= 1
                updateResident(); record(.quarantineEntered, reason: .backgroundRetained)
            }
            handoff = nil; updateResident()
        } else { discardCache(reason: .flush) }
    }
    public func handleMemoryPressure() { disabledForMemoryPressure = true; setPrefetchEnabled(false, reason: .memoryPressure) }
    public func setPlaybackSceneActive(_ active: Bool) {
        source.setPlaybackSceneActive(active)
        if !active { setPrefetchEnabled(false, reason: .sceneInactive) }
    }
    public func cancelPlayback() {
        guard !stopped else { return }
        stopped = true; setPrefetchEnabled(false, reason: .stop); source.cancelPlayback()
        if let id = supplyDiagnostics.work?.id { supplyDiagnostics.cancelWork(id: id) }
        activeDemand?.cancel()
        for request in requests {
            settleWait(request)
            if hasSpeculativeContext { record(.demandCancelled, reason: .stopped, request: request) }
            var diagnostic = request.rangeDiagnostic
            diagnostic.finished = ProcessInfo.processInfo.systemUptime; diagnostic.result = .cancelled
            diagnostic.completionEpoch = epoch; diagnostic.bytes = 0; rangeDiagnostics.append(diagnostic)
            if case .read(let range) = request.operation, !range.isEmpty { metrics.diagnostics.demandCancelledCount &+= 1 }
            request.continuation.resume(throwing: CancellationError())
        }
        requests.removeAll()
    }
    public func awaitPlaybackCleanup() async throws {
        cancelPlayback()
        if let pump { await pump.value }
        do {
            try await source.awaitPlaybackCleanup()
            record(.cleanup, reason: .cleanupSucceeded)
            reportCleanup(succeeded: true)
        } catch {
            record(.cleanup, reason: .cleanupFailed)
            reportCleanup(succeeded: false)
            throw error
        }
    }
    private func reportCleanup(succeeded: Bool) {
        guard !cleanupDiagnosticsReported else { return }
        cleanupDiagnosticsReported = true
        cleanupDiagnosticSink?(metrics, succeeded)
    }
    public func fileSize(for file: MediaFile) async throws -> UInt64 {
        guard file == self.file else { throw PlaybackSourceRecoveryError.invalidRange }
        guard case .size(let value) = try await enqueue(.size) else { throw PlaybackSourceRecoveryError.invalidResponse }
        return value
    }
    public func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        guard file == self.file, range.upperBound - range.lowerBound <= MediaReadPlan.maximumChunkBytes else { throw PlaybackSourceRecoveryError.invalidRange }
        guard case .bytes(let data) = try await enqueue(.read(range)) else { throw PlaybackSourceRecoveryError.invalidResponse }
        return data
    }
    private func enqueue(_ operation: Operation) async throws -> Response {
        try Task.checkCancellation()
        guard !stopped else { _ = try source.playbackCacheEpoch(); throw CancellationError() }
        nextID &+= 1
        let id = nextID, cancellation = Cancellation()
        // Stop further speculative admission/publication immediately. Its actual read drains.
        idleGrace?.cancel()
        admission &+= 1
        // Demand owns admission immediately; only its qualified completion may retain
        // the forward cursor. Keeping this state does not bypass grace or the queue.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requests.append(Request(id: id, generation: generation, operation: operation,
                    cancellation: cancellation, submitted: ProcessInfo.processInfo.systemUptime,
                    continuation: continuation, waitedForPrefetch: inFlight != nil))
                if inFlight != nil {
                    metrics.speculativeWaitCount &+= 1; metrics.diagnostics.waitingDemandCount &+= 1
                }
                if hasSpeculativeContext { record(.demandEnqueued, reason: .requestQueued, request: requests.last) }
                if pump == nil { pump = Task(priority: .low) { await self.run() } }
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor in self.cancelRequest(id) }
        }
    }
    private func cancelRequest(_ id: UInt64) {
        supplyDiagnostics.cancelWork(id: id)
        let request = requests.first { $0.id == id } ?? (activeRequest?.id == id ? activeRequest : nil)
        if let request {
            // A cancellation callback that arrives after its request completed must
            // not alter another request's subsequently established window.
            cancelForwardDemand(request)
            settleWait(request)
        }
        if hasSpeculativeContext { record(.demandCancelled, reason: .requestCancelled, request: request, requestID: id) }
        if handoff?.requestID == id {
            handoff = nil
        }
        if let index = requests.firstIndex(where: { $0.id == id }) {
            let removed = requests.remove(at: index)
            settleWait(removed)
            var diagnostic = removed.rangeDiagnostic
            diagnostic.finished = ProcessInfo.processInfo.systemUptime; diagnostic.result = .cancelled
            diagnostic.completionEpoch = epoch; diagnostic.bytes = 0; rangeDiagnostics.append(diagnostic)
            if case .read(let range) = removed.operation, !range.isEmpty { metrics.diagnostics.demandCancelledCount &+= 1 }
            removed.continuation.resume(throwing: CancellationError())
        } else if let activeRequest, activeRequest.id == id {
            self.activeRequest = nil
            activeRequest.continuation.resume(throwing: CancellationError())
            activeDemand?.cancel()
        }
    }
    private func run() async {
        while true {
            if !requests.isEmpty {
                let request = requests.removeFirst()
                if request.cancellation.cancelled || stopped {
                    cancelForwardDemand(request)
                    if hasSpeculativeContext { record(.demandCancelled, reason: stopped ? .stopped : .requestCancelled, request: request) }
                    if handoff?.requestID == request.id {
                        handoff = nil
                    }
                    var diagnostic = request.rangeDiagnostic
                    diagnostic.finished = ProcessInfo.processInfo.systemUptime; diagnostic.result = .cancelled
                    diagnostic.completionEpoch = epoch; diagnostic.bytes = 0; rangeDiagnostics.append(diagnostic)
                    if case .read(let range) = request.operation, !range.isEmpty { metrics.diagnostics.demandCancelledCount &+= 1 }
                    request.continuation.resume(throwing: CancellationError()); continue
                }
                settleWait(request)
                rangeDiagnostics.current = request.rangeDiagnostic
                rangeDiagnostics.current?.started = ProcessInfo.processInfo.systemUptime
                activeRequest = request
                let diagnosticKind: PlaybackSupplyDiagnostics.Kind
                switch request.operation { case .size: diagnosticKind = .size; case .read: diagnosticKind = .demand }
                supplyDiagnostics.beginWork(kind: diagnosticKind, id: request.id, generation: request.generation,
                    epoch: epoch, now: ProcessInfo.processInfo.systemUptime)
                if request.waitedForPrefetch { record(.demandDequeued, reason: .none, request: request) }
                metrics.demandWaitSeconds += max(0, ProcessInfo.processInfo.systemUptime - request.submitted)
                let task = Task(priority: .userInitiated) {
                    try await PlaybackReadDiagnosticContext.$correlation.withValue(request.rangeDiagnostic.correlation) { try await self.perform(request) }
                }
                activeDemand = task
                let result = await task.result
                // Completion acceptance is this single synchronous outcome decision.
                // Cancellation observed here wins. Cancellation arriving afterwards
                // is late: no await or external callback separates acceptance,
                // progress publication and resuming the wrapper continuation.
                let outcome: PlaybackSupplyDiagnostics.Result, returnedBytes: Int
                switch result {
                case .success(let response):
                    outcome = request.cancellation.cancelled || stopped ? .cancelled : .returned
                    if case .bytes(let data) = response { returnedBytes = data.count } else { returnedBytes = 0 }
                case .failure(let error): outcome = error is CancellationError || request.cancellation.cancelled || stopped ? .cancelled : .failed; returnedBytes = 0
                }
                if case .read(let range) = request.operation, !range.isEmpty {
                    switch outcome {
                    case .returned:
                        if let token = request.forwardEpoch, request.generation == generation,
                           token == epoch, !quarantined {
                            completeForwardDemand(range, token: token, version: request.generation)
                        }
                        if request.usedCachedBytes == range.count { metrics.diagnostics.demandFullCacheCount &+= 1 }
                        else if request.usedCachedBytes > 0 { metrics.diagnostics.demandPartialCacheCount &+= 1 }
                        else { metrics.diagnostics.demandZeroCacheCount &+= 1 }
                        if request.sourceCallCount > 0 {
                            metrics.diagnostics.demandSourceWaitCount &+= 1
                            metrics.diagnostics.demandSourceCallCount += request.sourceCallCount
                            metrics.diagnostics.demandSourceWaitSeconds += request.sourceCallSeconds
                        }
                    case .cancelled: metrics.diagnostics.demandCancelledCount &+= 1
                    case .failed: metrics.diagnostics.demandFailedCount &+= 1
                    }
                }
                rangeDiagnostics.finish(result: outcome, bytes: returnedBytes, epoch: epoch, now: ProcessInfo.processInfo.systemUptime)
                supplyDiagnostics.endWork()
                activeDemand = nil
                if activeRequest?.id == request.id {
                    activeRequest = nil
                    if outcome == .cancelled {
                        cancelForwardDemand(request)
                        request.continuation.resume(throwing: CancellationError())
                    } else { request.continuation.resume(with: result) }
                }
            } else if await prefetchOne() {
                continue
            } else if requests.isEmpty { break }
        }
        pump = nil
    }
    private func refreshEpoch() throws -> UInt64? {
        let value: UInt64?
        do { value = try source.playbackCacheEpoch() }
        catch { epoch = nil; retireForward(.epochRetired); discardCache(reason: .epochError); throw error }
        if quarantined, value == nil {
            // A capable source uses nil while inactive or awaiting fresh metadata.
            // This is quarantined availability, not proof the identity changed.
            return epoch
        }
        if value != epoch || value == nil {
            epoch = value
            retireForward(.epochRetired)
            discardCache(reason: value == nil ? .epochUnavailable : .epochChanged)
        }
        if value != nil, quarantined {
            quarantined = false; metrics.diagnostics.quarantineValidatedCount &+= 1
            updateResident(); record(.quarantineValidated, reason: .backgroundValidated)
        }
        return value
    }
    private func perform(_ request: Request) async throws -> Response {
        let version = request.generation
        let started = ProcessInfo.processInfo.systemUptime
        defer { metrics.demandSeconds += max(0, ProcessInfo.processInfo.systemUptime - started) }
        try Task.checkCancellation()
        switch request.operation {
        case .size:
            let value = try await observedSourceCall(kind: .size, bytes: { _ in 0 }) { try await source.fileSize(for: file) }
            try Task.checkCancellation()
            size = value; _ = try refreshEpoch()
            return .size(value)
        case .read(let range):
            let token = quarantined ? epoch : try refreshEpoch()
            let requiresValidation = quarantined
            let joinedRange: Range<UInt64>?
            if let handoff, handoff.requestID == request.id,
               handoff.epoch == token, handoff.generation == version {
                joinedRange = handoff.range
                rangeDiagnostics.current?.joinedPrefetch = handoff.prefetchID
                rangeDiagnostics.current?.joinedRange = .init(handoff.range)
            } else { joinedRange = nil }
            handoff = nil
            // Copy bounded sparse logical segments into independent snapshots
            // before suspension: no returned Data aliases the mutable circular buffer.
            // The source fills holes inside one request and its existing recovery budget.
            let available = token == nil ? [] : cachedSegments(in: range)
            // The recovering source accepts at most eight logical islands. A sparse
            // full hit can be assembled here; a fragmented partial hit uses one full
            // demand without invalidating qualified cache merely for fragmentation.
            let tooFragmented = available.count > 8 && available.reduce(0, { $0 + $1.data.count }) < range.count
            let segments = tooFragmented ? [] : available
            let cachedBytes = segments.reduce(0) { $0 + $1.data.count }
            rangeDiagnostics.current?.select(available: available.map(\.range),
                selected: cachedBytes == range.count && !range.isEmpty ? [range] : segments.map(\.range),
                epoch: token, fragmented: tooFragmented, validation: requiresValidation)
            metrics.demandSnapshotBytes = available.reduce(0) { $0 + $1.data.count }
            metrics.maxDemandSnapshotBytes = max(metrics.maxDemandSnapshotBytes, metrics.demandSnapshotBytes)
            defer { metrics.demandSnapshotBytes = 0 }
            let historyBytes = tooFragmented ? 0 : PrefetchRangeObservation.measure(range, spans: historySpans).overlapBytes
            demandOwnedPrefix = prefixPieces(in: range)
            demandOwnedHistoryBytes = historyBytes
            defer { demandOwnedPrefix.removeAll(); demandOwnedHistoryBytes = 0; updateResident() }
            if cachedBytes > 0 { record(.prefixDetached, reason: .none, request: request) }
            metrics.missBytes += UInt64(range.count)
            let data: Data
            let usedCached: Int
            demandReadReservedBytes = cachedBytes == range.count && !requiresValidation ? 0 : range.count
            updateResident()
            defer { demandReadReservedBytes = 0; updateResident() }
            var checkingCompletedEpoch = false
            do {
                try Task.checkCancellation()
                guard !request.cancellation.cancelled else { throw CancellationError() }
                if token != nil, cachedBytes == range.count, !requiresValidation {
                    var assembled = Data(capacity: cachedBytes)
                    for segment in segments { assembled.append(segment.data) }
                    data = assembled; usedCached = cachedBytes
                } else if let token, cachedBytes > 0 {
                    let completed = try await observedSourceCall(kind: .cachedSegments, bytes: { $0.data.count }) {
                        try await source.readCompletingCachedSegments(file, range: range, segments: segments, epoch: token)
                    }
                    data = completed.data; usedCached = completed.usedCachedBytes
                } else {
                    data = try await observedSourceCall(kind: .read, bytes: { $0.count }) { try await source.read(file, range: range) }; usedCached = 0
                }
                try Task.checkCancellation()
                guard !request.cancellation.cancelled else { throw CancellationError() }
                guard data.count == range.count, usedCached == 0 || usedCached == cachedBytes else {
                    throw PlaybackSourceRecoveryError.invalidResponse
                }
                checkingCompletedEpoch = true
                _ = try refreshEpoch()
                // A capable source must discard every old segment on recovery. Never
                // publish an assembly that claims old-epoch cache after that boundary.
                if usedCached > 0, epoch != token, !(epoch == nil && version != generation) {
                    throw PlaybackSourceRecoveryError.invalidResponse
                }
            } catch {
                let reason: PrefetchDiagnosticReason = error is CancellationError || request.cancellation.cancelled
                    ? .demandCancelled : (checkingCompletedEpoch ? .epochError : .suffixError)
                // A cancelled request owns only immutable snapshots. It never removed
                // completed arena data, so there is nothing to restore or discard.
                if reason != .demandCancelled {
                    // Read failure alone does not revoke completed bytes. The source
                    // epoch remains the authority for consistency and availability.
                    let current = try? refreshEpoch()
                    if checkingCompletedEpoch || error is PlaybackSourceRecoveryError || current != token {
                        discardCache(reason: reason, request: request)
                    }
                }
                discardPieces(detachedPrefix, reason: reason, request: request)
                detachedPrefix.removeAll()
                if reason == .demandCancelled { cancelForwardDemand(request) }
                else { retireForward(.demandFailureRetired) }
                throw error
            }
            rangeDiagnostics.current?.usedCachedBytes = usedCached
            request.usedCachedBytes = usedCached
            var joined = 0
            if usedCached > 0, let joinedRange {
                joined = PrefetchRangeObservation.measure(joinedRange, spans: demandOwnedPrefix.map(\.range)).overlapBytes
            }
            let usedHistory = usedCached > 0 ? historyBytes : 0
            metrics.historyHitBytes += UInt64(usedHistory)
            metrics.hitBytes += UInt64(usedCached - usedHistory - joined)
            metrics.joinedBytes += UInt64(joined)
            if joined > 0 { metrics.diagnostics.joinedDemandCount &+= 1 }
            metrics.missBytes -= UInt64(usedCached)
            if usedCached == 0, epoch == token, !quarantined {
                // A source may decline partial assembly while retaining its epoch.
                // Only this fresh request is authoritative; unrelated cache stays valid.
                discardPieces(demandOwnedPrefix, reason: .sourcePrefixRejected, request: request)
            } else if usedCached == 0 {
                discardPieces(detachedPrefix, reason: .epochChanged, request: request)
            } else if usedCached > 0 {
                recordPrefixUse(request: request, joinedRange: joinedRange)
                if usedHistory > 0 { record(.historyUsed, reason: .none, request: request, usedHistory: usedHistory) }
            }
            detachedPrefix.removeAll()
            if epoch == token, usedCached > 0 || !quarantined {
                metrics.retiredSpeculativeBytes += UInt64(storage.markHistory(range))
            }
            demandOwnedPrefix.removeAll(); demandOwnedHistoryBytes = 0; updateResident()
            // A flush must not re-arm the old location or retain its result. A source
            // recovery also prevents attaching an unqualified result to its new epoch.
            guard version == generation, !quarantined else { return .bytes(data) }
            // Retention grants neither forward credit nor speculative admission.
            if token != nil, epoch == token, enabled || paused || retainsSeekDemand {
                retainHistory(range: range, data: data, request: request, reusedCache: usedCached > 0)
            }
            // A changed/unknown epoch cannot seed scheduling. This is only a
            // candidate: a synchronous cache diagnostic may have cancelled this
            // request, or cancellation may win while run awaits this Task's result.
            if let token, epoch == token, !requiresValidation { request.forwardEpoch = token }
            return .bytes(data)
        }
    }
    private func cachedSegments(in range: Range<UInt64>) -> [PlaybackCachedSegment] {
        let spans = (readySpans + historySpans).sorted { $0.lowerBound < $1.lowerBound }
        var candidates: [Range<UInt64>] = []
        for span in spans {
            if let last = candidates.last, last.upperBound >= span.lowerBound {
                candidates[candidates.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else { candidates.append(span) }
        }
        var cursor = range.lowerBound
        return candidates.compactMap { candidate in
            let lower = max(cursor, candidate.lowerBound), upper = min(range.upperBound, candidate.upperBound)
            guard lower < upper else { return nil }
            cursor = upper
            return PlaybackCachedSegment(range: lower..<upper, data: storage.copy(lower..<upper))
        }
    }
    private func accountEviction(_ entries: [CircularStorage.Entry], reason: PrefetchDiagnosticReason,
                                 request: Request? = nil) {
        if let evidence = forwardWindow?.evidence, entries.contains(where: {
            $0.range.overlaps(evidence)
        }) { retireForward(.evidenceRetired) }
        for entry in entries {
            if let context = entry.diagnostic {
                discard(entry.range.count, reason: reason, context: context, request: request)
            } else {
                metrics.diagnostics.historyEvictedBytes += UInt64(entry.range.count)
                record(.historyEvicted, reason: reason, request: request, historyEvicted: entry.range.count)
            }
        }
    }
    private func retainHistory(range: Range<UInt64>, data: Data, request: Request, reusedCache: Bool) {
        guard !data.isEmpty else { return }
        // Credit is settled before any new write can overwrite these delivered bytes.
        metrics.retiredSpeculativeBytes += UInt64(storage.markHistory(range))
        // A declined segment assembly is a full authoritative read for this range.
        // Refresh overlap in its existing slots without replacing unrelated bytes.
        if !reusedCache { metrics.storageWrittenBytes += UInt64(storage.overwriteExisting(range, data: data)) }
        let result = storage.insert(range, data: data, diagnostic: nil)
        metrics.storageWrittenBytes += UInt64(result.written)
        accountEviction(result.evicted, reason: .historyWindow, request: request)
        accountEviction(storage.trimHistory(to: configuration.historyCapacityBytes), reason: .historyWindow, request: request)
        updateResident()
    }
    private func retainForward(_ range: Range<UInt64>, data: Data, context: PrefetchContext) {
        let result = storage.insert(range, data: data, diagnostic: context)
        metrics.storageWrittenBytes += UInt64(result.written)
        // Already retained overlap is not a second speculative credit.
        if result.written < data.count {
            discard(data.count - result.written, reason: .rangeRemainder, context: context)
        }
        accountEviction(result.evicted, reason: .historyWindow)
        updateResident()
    }
    private func discardCache(reason: PrefetchDiagnosticReason, request: Request? = nil) {
        if quarantined {
            quarantined = false; metrics.diagnostics.quarantineClearedCount &+= 1
            updateResident(); record(.quarantineCleared, reason: reason, request: request)
        }
        handoff = nil
        let removed = storage.entries
        storage.clear()
        updateResident()
        // A live demand already copied these bytes. A safety flush releases the
        // arena, but its credit follows the independent snapshot until completion.
        // seek does not enter this path; AV controls formal request cancellation.
        var unowned: [CircularStorage.Entry] = []
        for entry in removed {
            guard entry.diagnostic != nil, let activeRequest,
                  !activeRequest.cancellation.cancelled, !stopped else { unowned.append(entry); continue }
            var fragments = [entry]
            for owned in demandOwnedPrefix {
                fragments = fragments.flatMap { fragment -> [CircularStorage.Entry] in
                    let lower = max(fragment.range.lowerBound, owned.range.lowerBound)
                    let upper = min(fragment.range.upperBound, owned.range.upperBound)
                    guard lower < upper else { return [fragment] }
                    detachedPrefix.append(PrefixPiece(range: lower..<upper, diagnostic: owned.diagnostic))
                    var remaining: [CircularStorage.Entry] = []
                    if fragment.range.lowerBound < lower { remaining.append(fragment.slice(fragment.range.lowerBound..<lower)) }
                    if upper < fragment.range.upperBound { remaining.append(fragment.slice(upper..<fragment.range.upperBound)) }
                    return remaining
                }
            }
            unowned.append(contentsOf: fragments)
        }
        accountEviction(unowned, reason: reason, request: request)
    }
    private func contiguousEnd(from start: UInt64) -> UInt64 {
        var end = start
        for range in (readySpans + historySpans).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if range.lowerBound <= end { end = max(end, range.upperBound) }
        }
        return end
    }
    private func updateResident() {
        metrics.residentBytes = blocks.reduce(0) { $0 + $1.count }
        metrics.maxResidentBytes = max(metrics.maxResidentBytes, metrics.residentBytes)
        metrics.historyBytes = historySpans.reduce(0) { $0 + $1.count }
        metrics.inFlightReservedBytes = (inFlight?.range.count ?? 0) + demandReadReservedBytes
        metrics.validCacheBytes = metrics.residentBytes + metrics.historyBytes
        metrics.cacheQuarantined = quarantined
        metrics.totalCacheBytes = metrics.validCacheBytes + metrics.inFlightReservedBytes
        metrics.maxTotalCacheBytes = max(metrics.maxTotalCacheBytes, metrics.totalCacheBytes)
        metrics.storageAllocatedBytes = storage.allocatedBytes
        metrics.maxStorageAllocatedBytes = max(metrics.maxStorageAllocatedBytes, storage.allocatedBytes)
        metrics.cacheMetadataEntries = storage.entries.count
        metrics.cacheMetadataAllocatedBytes = storage.metadataAllocatedBytes
        metrics.maxCacheMetadataAllocatedBytes = max(metrics.maxCacheMetadataAllocatedBytes, storage.metadataAllocatedBytes)
        metrics.maxCacheMetadataEntries = max(metrics.maxCacheMetadataEntries, storage.entries.count)
        assert(metrics.validCacheBytes <= configuration.totalCapacityBytes)
        assert(metrics.totalCacheBytes <= configuration.totalCapacityBytes + Int(MediaReadPlan.maximumChunkBytes))
        assert(metrics.cacheMetadataEntries <= Metrics.cacheMetadataEntryLimit)
    }

    private var readySpans: [Range<UInt64>] { blocks.map { $0.start..<$0.end } }
    private var historySpans: [Range<UInt64>] { storage.entries.filter { $0.diagnostic == nil }.map(\.range) }
    private var hasSpeculativeContext: Bool { !storage.entries.isEmpty || inFlight != nil || !demandOwnedPrefix.isEmpty || demandOwnedHistoryBytes > 0 }

    private func settleWait(_ request: Request) {
        guard let started = request.waitStarted else { return }
        request.waitStarted = nil
        request.speculativeWaitSeconds = max(0, ProcessInfo.processInfo.systemUptime - started)
        metrics.speculativeWaitSeconds += request.speculativeWaitSeconds
    }

    private func prefixPieces(in range: Range<UInt64>) -> [PrefixPiece] {
        blocks.compactMap { block in
            let lower = max(range.lowerBound, block.start), upper = min(range.upperBound, block.end)
            return lower < upper ? PrefixPiece(range: lower..<upper, diagnostic: block.diagnostic) : nil
        }
    }

    private func discardPieces(_ pieces: [PrefixPiece], reason: PrefetchDiagnosticReason, request: Request) {
        for piece in pieces {
            discard(piece.range.count, reason: reason, context: piece.diagnostic, request: request)
        }
    }

    /// The only discardedBytes mutation site. Each unused speculative byte reaches
    /// this once on eviction/rejection. Safety-flushed live snapshots settle later.
    private func discard(_ count: Int, reason: PrefetchDiagnosticReason,
                         event: PrefetchDiagnosticEvent = .discarded,
                         context: PrefetchContext, request: Request? = nil) {
        let bytes = UInt64(count)
        metrics.discardedBytes += bytes
        switch reason {
        case .flush, .generationChanged, .disabled, .stopped:
            metrics.diagnostics.discardedFlushBytes += bytes
        case .epochUnavailable, .epochChanged, .epochError:
            metrics.diagnostics.discardedEpochBytes += bytes
        case .firstRequestMetadata, .firstRequestCancelled, .noFirstRequest, .noOverlap, .prefixGap:
            metrics.diagnostics.discardedNoPrefixOrFIFOBytes += bytes
        case .requestCancelled, .demandCancelled:
            metrics.diagnostics.discardedCancellationBytes += bytes
        case .sourceError, .suffixError, .sourcePrefixRejected, .shortRead:
            metrics.diagnostics.discardedSourceBytes += bytes
        default:
            metrics.diagnostics.discardedOtherBytes += bytes
        }
        record(event, reason: reason, context: context, request: request, discarded: count)
    }

    private func recordPrefixUse(request: Request, joinedRange: Range<UInt64>?) {
        for piece in demandOwnedPrefix {
            let joined = PrefetchRangeObservation.measure(joinedRange, spans: [piece.range]).overlapBytes
            record(.prefixUsed, reason: .none, context: piece.diagnostic, request: request,
                   usedReady: piece.range.count - joined, usedJoined: joined)
        }
    }

    private func record(_ event: PrefetchDiagnosticEvent, reason: PrefetchDiagnosticReason,
                        context: PrefetchContext? = nil, request: Request? = nil, requestID: UInt64? = nil,
                        usedReady: Int = 0, usedJoined: Int = 0, discarded: Int = 0,
                        usedHistory: Int = 0, historyEvicted: Int = 0) {
        metrics.diagnostics.generatedRecords &+= 1
        // History churn cannot exhaust the speculative lifecycle budget. A historical
        // lastPrefetch reference alone is not evidence of current speculative activity.
        let historyOnly = event == .historyUsed || event == .historyEvicted
            || (event != .cleanup && context == nil && inFlight == nil && blocks.isEmpty
                && demandOwnedPrefix.isEmpty && !(request?.waitedForPrefetch ?? false))
        let admitted: Bool
        if historyOnly {
            metrics.diagnostics.historyGeneratedRecords &+= 1
            admitted = metrics.diagnostics.historyGeneratedRecords <= PrefetchDiagnosticRecord.historyDetailLimit
            if !admitted { metrics.diagnostics.historySuppressedRecords &+= 1 }
        } else {
            admitted = metrics.diagnostics.prefetchGeneratedRecords <= PrefetchDiagnosticRecord.prefetchDetailLimit
        }
        guard admitted else {
            metrics.diagnostics.suppressedRecords &+= 1
            return
        }
        // No unbounded detail buffer: a late sink receives future records only.
        guard let diagnosticSink else { return }
        let reference = historyOnly ? nil : (context ?? inFlight ?? demandOwnedPrefix.first?.diagnostic ?? blocks.first?.diagnostic ?? lastPrefetch)
        let waiter: Request?
        if let requestID {
            waiter = [request, activeRequest, requests.first].compactMap { $0 }.first { $0.id == requestID }
        } else { waiter = request ?? activeRequest ?? requests.first }
        let request = PrefetchDemandObservation.resolve(requestID: requestID, explicit: request?.diagnostic,
            active: activeRequest?.diagnostic, first: requests.first?.diagnostic)
        let demand = request?.range
        let ready = PrefetchRangeObservation.measure(demand, spans: readySpans)
        let extra = inFlight.map { [$0.range] } ?? []
        let flight = PrefetchRangeObservation.measure(demand, spans: extra)
        let combined = PrefetchRangeObservation.measure(demand, spans: readySpans + extra)
        let prefetch = PrefetchRangeObservation.measure(demand, spans: reference.map { [$0.range] } ?? [])
        var bits: UInt16 = 0
        if enabled { bits |= 1 }; if stopped { bits |= 2 }; if disabledForMemoryPressure { bits |= 4 }
        if handoff != nil { bits |= 8 }; if activeDemand != nil { bits |= 16 }; if inFlight != nil { bits |= 32 }
        if paused { bits |= 512 }; if !historySpans.isEmpty { bits |= 1024 }
        if epoch != nil { bits |= 64 }; if !blocks.isEmpty { bits |= 128 }; if !demandOwnedPrefix.isEmpty || demandOwnedHistoryBytes > 0 { bits |= 256 }
        diagnosticSink(PrefetchDiagnosticRecord(
            sessionID: metrics.diagnostics.sessionID, sequence: metrics.diagnostics.generatedRecords,
            prefetchID: reference?.id ?? 0, requestID: requestID ?? request?.id ?? 0,
            generation: generation, epoch: epoch, prefetchGeneration: reference?.generation, prefetchEpoch: reference?.epoch,
            event: event, reason: reason, invalidationReason: lastInvalidationReason,
            prefetchBytes: reference?.range.count ?? 0, previousPrefetchDelta: reference?.previousDelta,
            prefetchPrefixBytes: prefetch.prefixBytes, prefetchOverlapBytes: prefetch.overlapBytes,
            demandBytes: demand?.count ?? 0,
            demandDelta: demand.flatMap { value in reference.flatMap { PrefetchRangeObservation.delta(value.lowerBound, from: $0.range.lowerBound) } },
            readyBytes: metrics.residentBytes, readyPrefixBytes: ready.prefixBytes, readyOverlapBytes: ready.overlapBytes,
            inFlightBytes: inFlight?.range.count ?? 0,
            inFlightPrefixBytes: max(0, combined.prefixBytes - ready.prefixBytes), inFlightOverlapBytes: flight.overlapBytes,
            queueDepth: requests.count, usedReadyBytes: usedReady, usedJoinedBytes: usedJoined,
            discardedBytes: discarded, stateBits: bits,
            historyBytes: metrics.historyBytes,
            historyOverlapBytes: PrefetchRangeObservation.measure(demand, spans: historySpans).overlapBytes,
            totalCacheBytes: metrics.totalCacheBytes, inFlightReservedBytes: metrics.inFlightReservedBytes,
            demandOwnedBytes: demandOwnedHistoryBytes + demandOwnedPrefix.reduce(0) { $0 + $1.range.count }, usedHistoryBytes: usedHistory,
            waitedForPrefetch: waiter?.waitedForPrefetch ?? false,
            waitMilliseconds: Int((waiter?.speculativeWaitSeconds ?? 0) * 1_000), historyEvictedBytes: historyEvicted,
            historyDelta: demand.flatMap { value in
                historySpans.map(\.lowerBound).min().flatMap { PrefetchRangeObservation.delta(value.lowerBound, from: $0) }
            }))
    }

    private func prefetchOne() async -> Bool {
        // One terminal reason per pump admission attempt, not per request or elapsed time.
        guard enabled, !stopped else { metrics.diagnostics.noAdmissionDisabledOrEpoch &+= 1; return false }
        guard requests.isEmpty else { metrics.diagnostics.noAdmissionDemandOrGrace &+= 1; return false }
        guard canResumeForward else { metrics.diagnostics.noAdmissionWindow &+= 1; return false }
        let token: UInt64
        do { guard let value = try refreshEpoch() else {
            metrics.diagnostics.noAdmissionDisabledOrEpoch &+= 1; return false
        }; token = value }
        catch { metrics.diagnostics.noAdmissionDisabledOrEpoch &+= 1; return false }
        guard let window = forwardWindow,
              window.epoch == token, window.generation == generation else {
            metrics.diagnostics.noAdmissionDisabledOrEpoch &+= 1; return false
        }
        let lastEnd = window.cursor, target = window.target
        let start = contiguousEnd(from: lastEnd)
        // Retained spans can advance start beyond the target. Validate before
        // constructing a Range (or subtracting its bounds), not afterwards.
        guard start < target else {
            metrics.diagnostics.noAdmissionFilledOrBudget &+= 1; return false
        }
        let ahead = lastEnd..<target
        let room = configuration.capacityBytes - PrefetchRangeObservation.measure(ahead, spans: readySpans).overlapBytes
        guard room > 0, window.reads < 2 else {
            metrics.diagnostics.noAdmissionFilledOrBudget &+= 1; return false
        }
        let length = min(configuration.chunkBytes, room, Int(target - start))
        // Do not repeatedly top up tiny holes at every short demand boundary. The
        // second full read needs a real idle window and enough budget; EOF may be short.
        guard length == configuration.chunkBytes || start + UInt64(length) == size else {
            metrics.diagnostics.noAdmissionFilledOrBudget &+= 1; return false
        }
        let range = start..<(start + UInt64(length))
        let admitted = admission, version = generation
        // ResourceLoader often submits its next chunk immediately after the prior completion.
        // A cancellable, production idle grace lets that real demand win admission rather
        // than manufacturing an extra speculative read on each actor scheduling boundary.
        let grace = Task(priority: .low) { try await Task.sleep(for: .milliseconds(2)) }
        idleGrace = grace
        let graceResult = await grace.result
        idleGrace = nil
        guard version == generation, enabled, !stopped else {
            metrics.diagnostics.noAdmissionDisabledOrEpoch &+= 1; return false
        }
        guard case .success = graceResult, requests.isEmpty, admitted == admission else {
            metrics.diagnostics.noAdmissionDemandOrGrace &+= 1
            // The sole queued demand can be cancelled while this grace is asleep.
            // Keep the pump alive to retry a NEW full grace for still-valid credit,
            // rather than orphaning an idle frontier or admitting with no grace.
            if case .failure = graceResult, requests.isEmpty, admitted != admission, canResumeForward { return true }
            return false
        }
        do { guard try refreshEpoch() == token, canResumeForward else {
            metrics.diagnostics.noAdmissionDisabledOrEpoch &+= 1; return false
        } }
        catch { metrics.diagnostics.noAdmissionDisabledOrEpoch &+= 1; return false }
        forwardWindow?.reads += 1
        nextPrefetchID &+= 1
        let context = PrefetchContext(id: nextPrefetchID, range: range, generation: version, epoch: token,
            previousDelta: lastPrefetch.flatMap { PrefetchRangeObservation.delta(start, from: $0.range.lowerBound) })
        // The one temporary read is separate from the arena. No completed byte is
        // evicted until a successful same-epoch completion actually commits.
        lastPrefetch = context; inFlight = context; updateResident()
        record(.begin, reason: .none, context: context)
        let started = ProcessInfo.processInfo.systemUptime
        metrics.maxInFlightBytes = max(metrics.maxInFlightBytes, length)
        var returnedBytes = 0
        var sourceReturned = false
        var diagnosticResult: PlaybackSupplyDiagnostics.Result = .failed
        rangeDiagnostics.current = .init(kind: .prefetch, id: context.id, generation: version, queued: started, range: range, correlation: nil)
        rangeDiagnostics.current?.started = started; rangeDiagnostics.current?.selectionEpoch = token
        supplyDiagnostics.beginWork(kind: .prefetch, id: context.id, generation: version, epoch: token, now: started)
        defer {
            rangeDiagnostics.finish(result: diagnosticResult, bytes: returnedBytes, epoch: epoch, now: ProcessInfo.processInfo.systemUptime)
            supplyDiagnostics.endWork()
            metrics.speculativeSeconds += max(0, ProcessInfo.processInfo.systemUptime - started)
            inFlight = nil
            for request in requests { settleWait(request) }
            updateResident()
        }
        do {
            let data = try await observedSourceCall(kind: .prefetch, bytes: { $0.count }) { try await source.readForPrefetch(file, range: range) }
            inFlight = nil; updateResident()
            sourceReturned = true
            diagnosticResult = .returned
            returnedBytes = data.count
            metrics.speculativeBytes += UInt64(data.count)
            let currentToken = try refreshEpoch()
            guard version == generation, enabled || paused, !stopped,
                  currentToken == token, data.count == length else {
                let reason: PrefetchDiagnosticReason
                if version != generation { reason = .generationChanged }
                else if stopped { reason = .stopped }
                else if !enabled && !paused { reason = .disabled }
                else if currentToken == nil { reason = .epochUnavailable }
                else if currentToken != token { reason = .epochChanged }
                else { reason = .shortRead }
                diagnosticResult = reason == .generationChanged || reason == .stopped || reason == .disabled ? .cancelled : .failed
                rangeDiagnostics.current?.publicationRejectedReason = reason.rawValue
                discard(data.count, reason: reason, event: .rejected, context: context, request: requests.first)
                return false
            }
            retainForward(range, data: data, context: context)
            if admitted != admission, let request = requests.first,
               !request.cancellation.cancelled, case .read(let needed) = request.operation,
               PrefetchRangeObservation.measure(needed, spans: [range]).overlapBytes > 0 {
                handoff = Handoff(requestID: request.id, epoch: token, generation: version, prefetchID: context.id, range: range)
                record(.retained, reason: .retainedForDemand, context: context, request: request)
                return true
            }
            record(.retained, reason: .retainedReady, context: context)
            return true
        } catch {
            diagnosticResult = error is CancellationError ? .cancelled : .failed
            inFlight = nil; updateResident()
            let reason: PrefetchDiagnosticReason = sourceReturned ? .epochError : .sourceError
            rangeDiagnostics.current?.publicationRejectedReason = reason.rawValue
            discard(returnedBytes, reason: reason, event: .rejected, context: context, request: requests.first)
            let current = try? refreshEpoch()
            if sourceReturned || current != token { discardCache(reason: reason) }
            retireForward(.prefetchFailureRetired)
            return false
        }
    }

    /// Physical insertion-order ring. Logical file position never chooses a slot.
    /// Entries have no Data ownership. Splitting preserves insertion age; only writes
    /// evict physical collisions. Metadata is explicitly bounded even for tiny seeks.
    private final class CircularStorage {
        struct Entry {
            let range: Range<UInt64>
            let slot: Int
            let diagnostic: PrefetchContext?
            func slice(_ subrange: Range<UInt64>, diagnostic: PrefetchContext? = nil, history: Bool = false) -> Entry {
                Entry(range: subrange, slot: slot + Int(subrange.lowerBound - range.lowerBound),
                      diagnostic: history ? nil : (diagnostic ?? self.diagnostic))
            }
        }
        let capacity: Int
        private var bytes: UnsafeMutableRawPointer?
        private var cursor = 0
        private(set) var entries: [Entry] = []
        var allocatedBytes: Int { bytes == nil ? 0 : capacity }
        var metadataAllocatedBytes: Int { entries.capacity * MemoryLayout<Entry>.stride }
        init(capacity: Int) { self.capacity = capacity }
        deinit { bytes?.deallocate() }
        func clear() { bytes?.deallocate(); bytes = nil; cursor = 0; entries.removeAll() }
        func insert(_ range: Range<UInt64>, data: Data, diagnostic: PrefetchContext?) -> (written: Int, evicted: [Entry]) {
            precondition(range.count <= data.count)
            var gaps: [Range<UInt64>] = []
            var position = range.lowerBound
            for entry in entries.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                let lower = max(range.lowerBound, entry.range.lowerBound)
                let upper = min(range.upperBound, entry.range.upperBound)
                guard lower < upper else { continue }
                if position < lower { gaps.append(position..<lower) }
                position = max(position, upper)
            }
            if position < range.upperBound { gaps.append(position..<range.upperBound) }
            var evicted: [Entry] = [], written = 0
            var planned = entries, writeCursor = cursor
            var writes: [(range: Range<UInt64>, slot: Int)] = []
            for gap in gaps {
                var offset = gap.lowerBound
                while offset < gap.upperBound {
                    let count = min(Int(gap.upperBound - offset), capacity - writeCursor)
                    let physical = writeCursor..<(writeCursor + count)
                    var survivors: [Entry] = []
                    for entry in planned {
                        let lower = max(entry.slot, physical.lowerBound)
                        let upper = min(entry.slot + entry.range.count, physical.upperBound)
                        if lower >= upper { survivors.append(entry); continue }
                        let removed = (entry.range.lowerBound + UInt64(lower - entry.slot))..<(entry.range.lowerBound + UInt64(upper - entry.slot))
                        if entry.range.lowerBound < removed.lowerBound { survivors.append(entry.slice(entry.range.lowerBound..<removed.lowerBound)) }
                        evicted.append(entry.slice(removed))
                        if removed.upperBound < entry.range.upperBound { survivors.append(entry.slice(removed.upperBound..<entry.range.upperBound)) }
                    }
                    let added = offset..<(offset + UInt64(count))
                    survivors.append(Entry(range: added, slot: writeCursor, diagnostic: diagnostic))
                    writes.append((added, writeCursor))
                    planned = coalesced(survivors)
                    // Admission may be skipped, but metadata pressure never evicts
                    // completed payload. Nothing has been written at this point.
                    guard planned.count <= Metrics.cacheMetadataEntryLimit else { return (0, []) }
                    offset += UInt64(count); written += count; writeCursor = (writeCursor + count) % capacity
                }
            }
            if !writes.isEmpty, bytes == nil { bytes = .allocate(byteCount: capacity, alignment: 16) }
            data.withUnsafeBytes { input in
                for write in writes {
                    bytes!.advanced(by: write.slot).copyMemory(
                        from: input.baseAddress!.advanced(by: Int(write.range.lowerBound - range.lowerBound)), byteCount: write.range.count)
                }
            }
            entries = planned; cursor = writeCursor
            return (written, evicted)
        }
        func overwriteExisting(_ range: Range<UInt64>, data: Data) -> Int {
            var written = 0
            for entry in entries {
                let lower = max(range.lowerBound, entry.range.lowerBound), upper = min(range.upperBound, entry.range.upperBound)
                guard lower < upper else { continue }
                let count = Int(upper - lower)
                data.withUnsafeBytes { input in
                    bytes!.advanced(by: entry.slot + Int(lower - entry.range.lowerBound)).copyMemory(
                        from: input.baseAddress!.advanced(by: Int(lower - range.lowerBound)), byteCount: count)
                }
                written += count
            }
            return written
        }
        /// Ordinary history means general retained bytes in Build85, including
        /// exceptionally retired unused speculation. Return that retired credit.
        func markHistory(_ range: Range<UInt64>) -> Int {
            let previous = entries
            let split = entries.flatMap { entry -> [Entry] in
                let lower = max(range.lowerBound, entry.range.lowerBound), upper = min(range.upperBound, entry.range.upperBound)
                guard lower < upper, entry.diagnostic != nil else { return [entry] }
                var pieces: [Entry] = []
                if entry.range.lowerBound < lower { pieces.append(entry.slice(entry.range.lowerBound..<lower)) }
                pieces.append(entry.slice(lower..<upper, history: true))
                if upper < entry.range.upperBound { pieces.append(entry.slice(upper..<entry.range.upperBound)) }
                return pieces
            }
            let proposed = coalesced(split)
            if proposed.count <= Metrics.cacheMetadataEntryLimit { entries = proposed; return 0 }
            var retired = 0
            entries = coalesced(previous.map { entry in
                let lower = max(range.lowerBound, entry.range.lowerBound), upper = min(range.upperBound, entry.range.upperBound)
                guard lower < upper, entry.diagnostic != nil else { return entry }
                retired += entry.range.count - Int(upper - lower)
                return entry.slice(entry.range, history: true)
            })
            return retired
        }
        private func coalesced(_ values: [Entry]) -> [Entry] {
            var result: [Entry] = []
            for entry in values {
                if let last = result.last, last.range.upperBound == entry.range.lowerBound,
                   last.slot + last.range.count == entry.slot, last.diagnostic?.id == entry.diagnostic?.id {
                    result[result.count - 1] = Entry(range: last.range.lowerBound..<entry.range.upperBound, slot: last.slot, diagnostic: last.diagnostic)
                } else { result.append(entry) }
            }
            return result
        }
        func trimHistory(to capacity: Int) -> [Entry] {
            var excess = entries.filter { $0.diagnostic == nil }.reduce(0) { $0 + $1.range.count } - capacity
            var removed: [Entry] = [], survivors: [Entry] = []
            for entry in entries {
                guard excess > 0, entry.diagnostic == nil else { survivors.append(entry); continue }
                let count = min(excess, entry.range.count)
                let end = entry.range.lowerBound + UInt64(count)
                removed.append(entry.slice(entry.range.lowerBound..<end)); excess -= count
                if end < entry.range.upperBound { survivors.append(entry.slice(end..<entry.range.upperBound)) }
            }
            entries = survivors
            return removed
        }
        func copy(_ range: Range<UInt64>) -> Data {
            var result = Data(count: range.count), copied = 0
            result.withUnsafeMutableBytes { output in
                for entry in entries {
                    let lower = max(range.lowerBound, entry.range.lowerBound), upper = min(range.upperBound, entry.range.upperBound)
                    guard lower < upper else { continue }
                    let count = Int(upper - lower)
                    output.baseAddress!.advanced(by: Int(lower - range.lowerBound)).copyMemory(
                        from: bytes!.advanced(by: entry.slot + Int(lower - entry.range.lowerBound)), byteCount: count)
                    copied += count
                }
            }
            precondition(copied == range.count)
            return result
        }
    }
}
