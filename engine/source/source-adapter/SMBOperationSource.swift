import Foundation

/// Owns parser generations, not another transport/cache. The existing recovery
/// source owns identity/reconnection and the existing 160 MiB ring owns raw bytes.
@MainActor final class SMBOperationSource: SourceOperationOwner {
    nonisolated let playbackID: UUID, contentRevision: UUID, knownSize: UInt64
    nonisolated let file: MediaFile
    nonisolated let journal: AdapterJournal
    private let cache: PlaybackPrefetchSource
    private let baseline: PlaybackSourceIdentity
    private let identity: @MainActor () async throws -> PlaybackSourceIdentity
    private let readRevision: @MainActor (PlaybackSourceIdentity) throws -> Void
    private let transportDrain: @MainActor () async throws -> Void
    private var active: BridgeStamp?
    private var operations = 0
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastGeneration: UInt64 = 0
    private var closed = false, retiring = false
    // VLC-only bounded candidate. Other parser owners retain exact demand reads.
    private let vlcReadAheadEnabled: Bool
    #if VISTA_READ_PHASE216
    func setReadReference216(_ bytes:UInt64) {cache.setReadReference216(bytes)}
    #endif
    private var previousVLC: (end: UInt64, epoch: UInt64, generation: UInt64, count: Int)?
    private var adjacentVLCCount = 0
    private var readAheadEnd: UInt64?
    private(set) var vlcReadAheadRequests = 0
    private(set) var vlcReadAheadRequestedExtra = 0
    private(set) var vlcReadAheadRequestFailures = 0


    private init(file: MediaFile, playbackID: UUID, cache: PlaybackPrefetchSource,
                 baseline: PlaybackSourceIdentity,
                 identity: @escaping @MainActor () async throws -> PlaybackSourceIdentity,
                 readRevision: @escaping @MainActor (PlaybackSourceIdentity) throws -> Void,
                 drain: @escaping @MainActor () async throws -> Void, journal: AdapterJournal, vlcReadAheadEnabled: Bool) {
        self.file = file; self.playbackID = playbackID; self.cache = cache
        self.baseline = baseline; self.knownSize = baseline.size; self.contentRevision = UUID()
        self.identity = identity; self.readRevision = readRevision; self.transportDrain = drain; self.journal = journal; self.vlcReadAheadEnabled = vlcReadAheadEnabled
    }
    static func create(file: MediaFile, playbackID: UUID, cache: PlaybackPrefetchSource,
                       journal: AdapterJournal, vlcReadAheadEnabled: Bool = false) async throws -> SMBOperationSource {
        try await create(file: file, playbackID: playbackID, cache: cache,
                         identity: { try await cache.freshPlaybackIdentity() },
                         readRevision: { try cache.validatePlaybackRevision($0) },
                         drain: { try await cache.awaitSourceOperationsDrained() }, journal: journal, vlcReadAheadEnabled: vlcReadAheadEnabled)
    }
    static func create(file: MediaFile, playbackID: UUID, cache: PlaybackPrefetchSource,
                       identity: @escaping @MainActor () async throws -> PlaybackSourceIdentity,
                       readRevision: @escaping @MainActor (PlaybackSourceIdentity) throws -> Void,
                       drain: @escaping @MainActor () async throws -> Void,
                       journal: AdapterJournal, vlcReadAheadEnabled: Bool = false) async throws -> SMBOperationSource {
        // Optional VLC read-ahead stays inside the active parser demand and serial
        // pump. The existing ring and source owner retain epoch/recovery ownership.
        await cache.suspendAndDrainForSourceWindow()
        let observed = try await identity()
        guard observed.isComplete, observed.size > 0, observed.size <= UInt64(Int64.max) else {
            throw AdapterFailure.rejected("complete positive SMB identity required")
        }
        return SMBOperationSource(file: file, playbackID: playbackID, cache: cache,
                                  baseline: observed, identity: identity, readRevision: readRevision, drain: drain, journal: journal, vlcReadAheadEnabled: vlcReadAheadEnabled)
    }
    nonisolated func performanceSnapshot() -> LocalSourcePerformance { .init() }
    private func require(_ stamp: BridgeStamp) throws {
        guard !closed, !retiring, active == stamp else { throw AdapterFailure.rejected("SMB generation retired") }
    }
    private func checkIdentity() async throws {
        guard try await identity() == baseline else { throw AdapterFailure.rejected("SMB source revision changed") }
    }
    func beginWindow(generation: UInt64) async throws -> LocalWindowByteSource {
        guard !closed, active == nil, operations == 0, generation > lastGeneration else {
            throw AdapterFailure.rejected("SMB previous generation not drained")
        }
        // Mark admission before awaiting metadata to reject overlapping begins.
        let stamp = BridgeStamp(playbackID: playbackID, contentRevision: contentRevision, windowGeneration: generation)
        active = stamp; retiring = false
        do { try await checkIdentity() }
        catch { active = nil; throw error }
        lastGeneration = generation
        cache.resumeAfterSourceWindowDrain()
        previousVLC = nil; adjacentVLCCount = 0; readAheadEnd = nil
        PlaybackFlowTrace.mark(.sourceReadAhead,a:0,b:vlcReadAheadEnabled ? 1:0,c:Int64(clamping:generation))
        journal.add("smb_window_admitted", stamp: stamp)
        return LocalWindowByteSource(owner: self, stamp: stamp)
    }
    private func acquireOperation() async {
        if operations == 0 { operations = 1; return }
        await withCheckedContinuation { gateWaiters.append($0) }
    }
    private func releaseOperation() {
        if gateWaiters.isEmpty { operations = 0 }
        else { gateWaiters.removeFirst().resume() }
    }
    func validate(stamp: BridgeStamp) async throws {
        await acquireOperation(); defer { releaseOperation() }
        try require(stamp)
        try await checkIdentity(); try require(stamp)
    }
    func read(stamp: BridgeStamp, file: MediaFile, range: Range<UInt64>) async throws -> Data {
        try await readDemand(stamp: stamp, file: file, range: range, maximumBytes: 262_144)
    }
    func readVLCInput(stamp: BridgeStamp, file: MediaFile, range: Range<UInt64>) async throws -> Data {
        #if VISTA_READ_PHASE216
        try await readDemand(stamp: stamp, file: file, range: range, maximumBytes: Int(PlaybackReadReference216.continuousBytes), vlc: true)
        #else
        try await readDemand(stamp: stamp, file: file, range: range, maximumBytes: 524_288, vlc: true)
        #endif
    }
    private func readDemand(stamp: BridgeStamp, file: MediaFile, range: Range<UInt64>, maximumBytes: Int, vlc: Bool = false) async throws -> Data {
        await acquireOperation(); defer { releaseOperation() }
        var accepted = false
        defer { if !accepted { previousVLC = nil; adjacentVLCCount = 0; readAheadEnd = nil } }
        try require(stamp)
        guard file == self.file, range.upperBound <= knownSize, range.count <= maximumBytes else {
            throw AdapterFailure.rejected("SMB read range or file")
        }
        try readRevision(baseline); try require(stamp)
        let scope = cache.recoveryActivity
        let previousMatches = previousVLC.map { $0.end == range.lowerBound && $0.epoch == scope.epoch && $0.generation == scope.generation && $0.count >= 262_144 } ?? false
        if !vlc || !previousMatches { adjacentVLCCount = 0; previousVLC = nil; readAheadEnd = nil }
        let expanded = vlcReadAheadEnabled && vlc && range.count >= 262_144 && previousMatches && adjacentVLCCount >= 2 && scope.available && (readAheadEnd == nil || range.upperBound > readAheadEnd!)
        #if VISTA_READ_PHASE216
        let end = expanded ? min(knownSize, range.lowerBound + cache.readReferenceBytes216) : range.upperBound
        #else
        let end = expanded ? min(knownSize, range.lowerBound + 1_048_576) : range.upperBound
        #endif
        let requested = range.lowerBound..<max(range.upperBound, end)
        if requested != range { vlcReadAheadRequests += 1; vlcReadAheadRequestedExtra += requested.count - range.count }
        let bytes: Data
        do {
            bytes = requested == range ? try await cache.read(file, range: range) : try await cache.readVLCInput(file, range: range, readAheadEnd: requested.upperBound)
        }
        catch {
            if requested != range { vlcReadAheadRequestFailures += 1 }
            // Deliberately no second public recovery budget after a failed expanded read.
            previousVLC = nil; adjacentVLCCount = 0; readAheadEnd = nil
            throw error
        }
        try Task.checkCancellation()
        try readRevision(baseline); try require(stamp)
        guard bytes.count == range.count else { previousVLC = nil; adjacentVLCCount = 0; readAheadEnd = nil; throw AdapterFailure.rejected("short SMB source read") }
        let after = cache.recoveryActivity
        if vlc, range.count >= 262_144, let epoch = after.epoch, after.available,
           after.epoch == scope.epoch, after.generation == scope.generation {
            if requested != range { readAheadEnd = requested.upperBound }
            adjacentVLCCount = min(2, adjacentVLCCount + 1)
            previousVLC = (range.upperBound, epoch, after.generation, range.count)
        } else { previousVLC = nil; adjacentVLCCount = 0; readAheadEnd = nil }
        accepted = true
        return bytes
    }
    func verifyEOF(stamp: BridgeStamp) async throws {
        // Complete fresh server metadata gives this known end. Unlike a local fd,
        // bounded MediaByteSource forbids an out-of-range probe; do not fake one.
        try await validate(stamp: stamp)
        journal.add("smb_metadata_eof_verified", stamp: stamp, offset: knownSize,
                    detail: "fresh complete server identity size, not physical out-of-range read")
    }
    func retireAndDrain(stamp: BridgeStamp) async throws -> BridgeSourceQuiescenceWitness {
        guard active == stamp else { throw AdapterFailure.rejected("SMB drain wrong generation") }
        retiring = true
        // Adapter calls after parser join and callback-task join. The cache joins
        // any actual pump work; the final source barrier also joins C callbacks.
        await cache.suspendAndDrainForSourceWindow()
        await acquireOperation(); releaseOperation()
        guard operations == 0 else { throw AdapterFailure.rejected("SMB source invocation still active") }
        try await transportDrain()
        guard operations == 0, active == stamp else { throw AdapterFailure.rejected("SMB source drain changed") }
        active = nil
        journal.add("smb_actual_operation_drain_confirmed", stamp: stamp)
        return BridgeSourceQuiescenceWitness(stamp: stamp, outstandingSourceOperations: 0,
            confirmedBySourceOwner: true, provider: "closed parser generation, joined raw-cache pump and SMB library callback barrier")
    }
    func closeAfterDrain() async throws {
        guard active == nil, operations == 0 else { throw AdapterFailure.rejected("SMB close before generation drain") }
        guard !closed else { return }
        closed = true
        try await cache.awaitPlaybackCleanup()
        try await transportDrain()
        journal.add("smb_source_closed_after_drain")
    }
}
