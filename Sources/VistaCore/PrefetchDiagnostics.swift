import Foundation

/// Numeric, anonymous diagnostics only. These reasons do not change invalidation policy.
public enum PrefetchInvalidationReason: Int, Sendable {
    case explicit = 0, disabled, pause, seek, sceneInactive, memoryPressure, stop, notReady, playbackInactive
}

public enum PrefetchDiagnosticEvent: Int, Sendable {
    case begin = 1, retained, rejected, demandEnqueued, demandCancelled, prefixDetached, prefixUsed, discarded, flush, cleanup
    case admissionPaused, demandDequeued, historyUsed, historyEvicted
    case quarantineEntered, quarantineValidated, quarantineCleared
}

public enum PrefetchDiagnosticReason: Int, Sendable {
    case none = 0, retainedReady, retainedForDemand, requestQueued, requestCancelled, flush
    case epochUnavailable, epochChanged, epochError, generationChanged, disabled, stopped, shortRead
    case firstRequestMetadata, firstRequestCancelled, noFirstRequest, noOverlap, prefixGap
    case sourceError, suffixError, sourcePrefixRejected, rangeLeadingBytes, rangeRemainder
    case cleanupSucceeded, cleanupFailed, demandCancelled
    case pauseRetained, historyWindow, retainedAhead, metadataLimit, backgroundRetained, backgroundValidated
}

/// Bounded forward-state reasons. These describe wrapper demand progress, not tracks.
public enum PrefetchForwardTransition: Int, Sendable {
    case none = 0, create, advance, backreadPreserved, suspend, rebase, distantPending
    case lifecycleRetired, epochRetired, evidenceRetired, demandFailureRetired, prefetchFailureRetired, cancelPreserved
}

/// The sum of the six discard groups always matches Metrics.discardedBytes, including
/// after detailed records are suppressed. These are wrapper bytes, not network traffic.
public struct PrefetchDiagnosticsSnapshot: Sendable, Equatable {
    /// Successful, nonempty wrapper demands only, classified by actual usedCachedBytes.
    /// These are not AVPlayer respond counts. A later bridge cancellation is separate.
    public internal(set) var demandFullCacheCount: UInt64 = 0
    public internal(set) var demandPartialCacheCount: UInt64 = 0
    public internal(set) var demandZeroCacheCount: UInt64 = 0
    public internal(set) var demandCancelledCount: UInt64 = 0
    public internal(set) var demandFailedCount: UInt64 = 0
    /// Successful nonempty demands that entered a wrapper-to-source call, and total
    /// calls/time within those demands. Excludes cancelled/failed demands, size and
    /// speculative work; cached-segment validation counts even if it reads no bytes.
    /// Not SMB RPCs, wire I/O, AVPlayer callbacks or proof of a playback stall.
    public internal(set) var demandSourceWaitCount: UInt64 = 0
    public internal(set) var demandSourceCallCount: UInt64 = 0
    public internal(set) var demandSourceWaitSeconds: Double = 0
    public internal(set) var forwardCreateCount: UInt64 = 0
    public internal(set) var forwardAdvanceCount: UInt64 = 0
    public internal(set) var forwardBackreadPreservedCount: UInt64 = 0
    /// Explicit pause transitions, not ordinary AV demand cancellation.
    public internal(set) var forwardSuspendCount: UInt64 = 0
    public internal(set) var forwardCancelPreservedCount: UInt64 = 0
    public internal(set) var forwardRebaseCount: UInt64 = 0
    public internal(set) var forwardDistantPendingCount: UInt64 = 0
    public internal(set) var forwardLifecycleRetiredCount: UInt64 = 0
    public internal(set) var forwardEpochRetiredCount: UInt64 = 0
    public internal(set) var forwardEvidenceRetiredCount: UInt64 = 0
    public internal(set) var forwardDemandFailureRetiredCount: UInt64 = 0
    public internal(set) var forwardPrefetchFailureRetiredCount: UInt64 = 0
    public internal(set) var forwardUnretainedEvidenceCount: UInt64 = 0
    public internal(set) var forwardTransitionID: UInt64 = 0
    public internal(set) var forwardTransition: PrefetchForwardTransition = .none
    public internal(set) var sessionID: UInt64 = 0
    public internal(set) var generatedRecords: UInt64 = 0
    public internal(set) var suppressedRecords: UInt64 = 0
    /// Independent detail quotas; suppressed events still count in all byte aggregates.
    public internal(set) var historyGeneratedRecords: UInt64 = 0
    public internal(set) var historySuppressedRecords: UInt64 = 0
    public var prefetchGeneratedRecords: UInt64 { generatedRecords - historyGeneratedRecords }
    public var prefetchSuppressedRecords: UInt64 { suppressedRecords - historySuppressedRecords }
    /// Fixed-size cumulative counters of unsuccessful prefetchOne admission attempts.
    /// Each attempt increments exactly one category at its first failed gate:
    /// absent sequential window; pending demand/interrupted idle grace;
    /// disabled/stopped/generation/epoch; or filled/read-count/fragment/chunk budget.
    /// Filled/budget is a normal stop, not an error. Counts depend on pump scheduling.
    /// Not time samples, skipped bytes, per-demand counts, or proof of network idleness.
    /// No detailed events are emitted and admission policy/timing is unchanged.
    public internal(set) var noAdmissionWindow: UInt64 = 0
    public internal(set) var noAdmissionDemandOrGrace: UInt64 = 0
    public internal(set) var noAdmissionDisabledOrEpoch: UInt64 = 0
    public internal(set) var noAdmissionFilledOrBudget: UInt64 = 0
    public internal(set) var waitingDemandCount: UInt64 = 0
    public internal(set) var joinedDemandCount: UInt64 = 0
    /// Wrapper state transitions, not metadata calls or automatic playback resumes.
    public internal(set) var quarantineEnteredCount: UInt64 = 0
    public internal(set) var quarantineValidatedCount: UInt64 = 0
    public internal(set) var quarantineClearedCount: UInt64 = 0
    /// Evicted general retained bytes, including delivered demand and speculative
    /// credit retired for metadata bounds. Retiring credit itself is not eviction.
    public internal(set) var historyEvictedBytes: UInt64 = 0
    public internal(set) var discardedFlushBytes: UInt64 = 0
    public internal(set) var discardedEpochBytes: UInt64 = 0
    public internal(set) var discardedNoPrefixOrFIFOBytes: UInt64 = 0
    public internal(set) var discardedCancellationBytes: UInt64 = 0
    public internal(set) var discardedSourceBytes: UInt64 = 0
    public internal(set) var discardedOtherBytes: UInt64 = 0
    public var discardedBytes: UInt64 {
        discardedFlushBytes + discardedEpochBytes + discardedNoPrefixOrFIFOBytes
        + discardedCancellationBytes + discardedSourceBytes + discardedOtherBytes
    }
    public var detailedRecords: UInt64 { generatedRecords - suppressedRecords }
}

/// Every position is relative to this record's prefetch, never an absolute file offset.
/// Zero prefetchID/requestID means no corresponding operation. Nil deltas mean absent
/// context or a difference outside Int64; nil epoch means unavailable, never epoch zero.
/// generation/epoch are current observations; prefetchGeneration/prefetchEpoch identify
/// the original admission. The last explicit flush reason survives late completion.
public struct PrefetchDiagnosticRecord: Sendable, Equatable {
    public static let historyDetailLimit: UInt64 = 64
    public static let prefetchDetailLimit: UInt64 = 192
    public static let detailLimit = historyDetailLimit + prefetchDetailLimit
    public let sessionID, sequence, prefetchID, requestID: UInt64
    public let generation: UInt64
    public let epoch: UInt64?
    public let prefetchGeneration: UInt64?
    public let prefetchEpoch: UInt64?
    public let event: PrefetchDiagnosticEvent
    public let reason: PrefetchDiagnosticReason
    public let invalidationReason: PrefetchInvalidationReason
    public let prefetchBytes: Int
    public let previousPrefetchDelta: Int64?
    /// Reference read's geometry remains available after that read has completed.
    public let prefetchPrefixBytes, prefetchOverlapBytes: Int
    public let demandBytes: Int
    public let demandDelta: Int64?
    public let readyBytes, readyPrefixBytes, readyOverlapBytes: Int
    /// inFlightPrefixBytes is the additional contiguous prefix made possible by the
    /// running read after existing ready blocks; overlap alone does not imply usability.
    public let inFlightBytes, inFlightPrefixBytes, inFlightOverlapBytes: Int
    public let queueDepth: Int
    public let usedReadyBytes, usedJoinedBytes, discardedBytes: Int
    /// Bits: enabled=1, stopped=2, memoryPressure=4, handoff=8, activeDemand=16,
    /// inFlight=32, epochAvailable=64, ready=128, demandOwnedPrefix=256, paused=512, history=1024.
    public let stateBits: UInt16
    public let historyBytes, historyOverlapBytes, totalCacheBytes, inFlightReservedBytes, demandOwnedBytes: Int
    public let usedHistoryBytes, historyEvictedBytes: Int
    public let waitedForPrefetch: Bool
    public let waitMilliseconds: Int
    /// Demand start relative to the lowest retained general-cache range, even when
    /// sparse. This delta does not imply the intervening bytes are cached.
    public let historyDelta: Int64?

    public init(sessionID: UInt64, sequence: UInt64, prefetchID: UInt64, requestID: UInt64,
                generation: UInt64, epoch: UInt64?, prefetchGeneration: UInt64?, prefetchEpoch: UInt64?,
                event: PrefetchDiagnosticEvent, reason: PrefetchDiagnosticReason, invalidationReason: PrefetchInvalidationReason,
                prefetchBytes: Int, previousPrefetchDelta: Int64?, prefetchPrefixBytes: Int, prefetchOverlapBytes: Int,
                demandBytes: Int, demandDelta: Int64?, readyBytes: Int, readyPrefixBytes: Int, readyOverlapBytes: Int,
                inFlightBytes: Int, inFlightPrefixBytes: Int, inFlightOverlapBytes: Int, queueDepth: Int,
                usedReadyBytes: Int, usedJoinedBytes: Int, discardedBytes: Int, stateBits: UInt16,
                historyBytes: Int = 0, historyOverlapBytes: Int = 0, totalCacheBytes: Int = 0,
                inFlightReservedBytes: Int = 0, demandOwnedBytes: Int = 0, usedHistoryBytes: Int = 0,
                waitedForPrefetch: Bool = false, waitMilliseconds: Int = 0, historyEvictedBytes: Int = 0, historyDelta: Int64? = nil) {
        self.sessionID = sessionID; self.sequence = sequence; self.prefetchID = prefetchID; self.requestID = requestID
        self.generation = generation; self.epoch = epoch; self.prefetchGeneration = prefetchGeneration; self.prefetchEpoch = prefetchEpoch
        self.event = event; self.reason = reason; self.invalidationReason = invalidationReason
        self.prefetchBytes = prefetchBytes; self.previousPrefetchDelta = previousPrefetchDelta
        self.prefetchPrefixBytes = prefetchPrefixBytes; self.prefetchOverlapBytes = prefetchOverlapBytes
        self.demandBytes = demandBytes; self.demandDelta = demandDelta; self.readyBytes = readyBytes
        self.readyPrefixBytes = readyPrefixBytes; self.readyOverlapBytes = readyOverlapBytes
        self.inFlightBytes = inFlightBytes; self.inFlightPrefixBytes = inFlightPrefixBytes; self.inFlightOverlapBytes = inFlightOverlapBytes
        self.queueDepth = queueDepth; self.usedReadyBytes = usedReadyBytes; self.usedJoinedBytes = usedJoinedBytes
        self.discardedBytes = discardedBytes; self.stateBits = stateBits
        self.historyBytes = historyBytes; self.historyOverlapBytes = historyOverlapBytes; self.totalCacheBytes = totalCacheBytes
        self.inFlightReservedBytes = inFlightReservedBytes; self.demandOwnedBytes = demandOwnedBytes
        self.usedHistoryBytes = usedHistoryBytes; self.historyEvictedBytes = historyEvictedBytes
        self.waitedForPrefetch = waitedForPrefetch; self.waitMilliseconds = waitMilliseconds
        self.historyDelta = historyDelta
    }
}

/// A late cancellation may name a request already removed by the pump. Do not attach
/// the next request's geometry to that old ID. Untargeted lifecycle events may use the
/// current active/first request; targeted events require an exact identity match.
struct PrefetchDemandObservation: Equatable {
    let id: UInt64
    let range: Range<UInt64>?

    static func resolve(requestID: UInt64?, explicit: Self?, active: Self?, first: Self?) -> Self? {
        guard let requestID else { return explicit ?? active ?? first }
        if explicit?.id == requestID { return explicit }
        if active?.id == requestID { return active }
        if first?.id == requestID { return first }
        return nil
    }
}

/// Pure numeric geometry: intersections are reusable even when a head gap exists.
/// Prefix remains a separate observation, not an admission requirement.
struct PrefetchRangeObservation: Equatable {
    let prefixBytes: Int
    let overlapBytes: Int

    static func measure(_ demand: Range<UInt64>?, spans: [Range<UInt64>]) -> Self {
        guard let demand else { return Self(prefixBytes: 0, overlapBytes: 0) }
        let sorted = spans.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
        var cursor = demand.lowerBound
        for span in sorted where span.upperBound > cursor && span.lowerBound < demand.upperBound {
            guard span.lowerBound <= cursor else { break }
            cursor = min(span.upperBound, demand.upperBound)
            if cursor == demand.upperBound { break }
        }
        var overlap = 0, coveredThrough = demand.lowerBound
        for span in sorted {
            let lower = max(demand.lowerBound, span.lowerBound, coveredThrough)
            let upper = min(demand.upperBound, span.upperBound)
            if lower < upper { overlap += Int(upper - lower); coveredThrough = upper }
        }
        return Self(prefixBytes: Int(cursor - demand.lowerBound), overlapBytes: overlap)
    }

    static func delta(_ offset: UInt64, from base: UInt64) -> Int64? {
        if offset >= base { return Int64(exactly: offset - base) }
        let distance = base - offset
        if distance == UInt64(Int64.max) + 1 { return Int64.min }
        return Int64(exactly: distance).map { -$0 }
    }
}
