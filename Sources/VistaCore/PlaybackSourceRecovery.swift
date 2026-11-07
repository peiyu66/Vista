import Foundation

/// In-memory metadata fingerprint, never diagnostic payload. This detects observed changes;
/// it is not a server-side snapshot and cannot prove that bytes never changed between stats.
public struct PlaybackSourceIdentity: Sendable, Equatable {
    public let size: UInt64
    public let modificationDate: Date?
    public let creationDate: Date?
    public let changeDate: Date?
    public let stableIdentifier: String?

    public init(size: UInt64, modificationDate: Date?, creationDate: Date?, changeDate: Date? = nil, stableIdentifier: String? = nil) {
        self.size = size; self.modificationDate = modificationDate; self.creationDate = creationDate
        self.changeDate = changeDate; self.stableIdentifier = stableIdentifier
    }

    public var isComplete: Bool {
        guard let modificationDate, let creationDate else { return false }
        // An absent SMB FILETIME may surface as 1601. Do not accept that sentinel as identity.
        let dates = [modificationDate, creationDate] + (changeDate.map { [$0] } ?? [])
        return dates.allSatisfy { $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 } &&
            (stableIdentifier == nil || stableIdentifier?.isEmpty == false)
    }
}

public enum PlaybackSourceRecoveryError: Error, Sendable, Equatable {
    case incompleteIdentity, identityChanged, invalidRange, invalidResponse, unavailable, recoveryTimedOut
}

/// Numeric low-frequency boundaries. No media names, paths, identifiers or error descriptions.
public enum PlaybackSourceRecoveryStage: Int, Sendable, Equatable {
    case started = 1, waitingForActive, retiringOld, oldRetired, connecting, connected
    case checkingIdentity, identityAccepted, retrying, returned, cancelled, failed
    case retiringOwned, ownedRetired, waitingForDemand
}

public enum PlaybackSourceRecoveryPolicy {
    public static let activeBudget: TimeInterval = 45
}

/// Invoke synchronously on scene/stop/file-generation changes, before scheduling other work.
@MainActor public protocol PlaybackRecoveryControlling: MediaByteSource {
    var isPlaybackRecovering: Bool { get }
    /// System uptime equivalent start, accounting for this episode's accumulated active time.
    /// Nil while inactive or not recovering. Going inactive does not reset the 45-second budget.
    var recoveryActiveStartedAt: TimeInterval? { get }
    var recoveryActiveElapsed: TimeInterval { get }
    func setPlaybackSceneActive(_ active: Bool)
    func cancelPlayback()
    /// Cancel synchronously, then wait for real teardown. Cleanup errors are not cancellation.
    func awaitPlaybackCleanup() async throws
}

/// One fresh connection per failed session episode and at most one recovery per public call.
/// Initial metadata may establish a baseline on a fresh connection only before any identity
/// or bytes have been delivered. Incomplete initial metadata still permits ordinary playback,
/// but disables subsequent connection recovery. On recovery all identity fields must match, including optional
/// fields: an old field cannot disappear. A recovered range is checked by another stat before
/// publication. This is still a metadata fingerprint, not an atomic snapshot.
///
/// Initial session is borrowed; normal stop must not retire a healthy directory session.
/// A confirmed failed borrowed session is retired by its owner-supplied closure. Fresh sessions
/// are private and retired on stop/failure. No directory-map mutation happens in this wrapper.
///
/// Inactive recovery/retry waits only for scene active or cancellation, without a timer, polling
/// or background reconnect. The owner must call cancelPlayback on stop/file change; isCurrent
/// also rejects stale completions, but cannot wake an inactive continuation by itself. At most
/// 45 seconds of cumulative active recovery are eligible for publication. Boundary checks stop
/// late connect/metadata/read completions; the controller can use the grace properties to stop
/// an outstanding operation sooner. Neither expiry nor cancellation claims transport drain.
///
/// Each caller has cancellable waiters. Losing all live callers parks the same unfinished
/// episode until new demand or whole-source stop; cancelling one caller never cancels another.
/// No-demand time is excluded from active grace, even while already-started transport/teardown
/// finishes. Previously consumed grace and the one-connect budget never reset. Already-started teardown finishes independently
/// before any replacement. Factory must drain partial sessions before throwing; retirement must
/// close admission, await actual operation/callback drain and finish local teardown. A failed
/// retirement remains terminal; cleanup is never retried on an assumption that it completed.
@MainActor public final class PlaybackRecoveringSource<Session: AnyObject & MediaByteSource>: PlaybackRecoveryControlling {
    private enum ReadStateError: Error { case superseded }

    @MainActor private final class Slot {
        let session: Session, owned: Bool, epoch: UInt64
        var retirement: Task<Void, any Error>?
        init(_ session: Session, owned: Bool, epoch: UInt64) {
            self.session = session; self.owned = owned; self.epoch = epoch
        }
    }

    /// Cancellation is marked synchronously outside MainActor; a queued actor callback must
    /// not permit a connect after the final caller was already cancelled.
    private final class Request: @unchecked Sendable {
        let identifier: UInt64
        private let lock = NSLock()
        private var cancelled = false
        @MainActor var usedRecovery = false
        init(_ identifier: UInt64) { self.identifier = identifier }
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    @MainActor private final class Episode {
        let old: Slot, generation: UInt64
        var result: Result<Slot, any Error>?
        var waiters: [UInt64: CheckedContinuation<Slot, any Error>] = [:]
        var task: Task<Void, Never>?
        var delivered = false
        var demandWaiter: CheckedContinuation<Void, any Error>?
        var activeElapsed: TimeInterval = 0
        var activeSince: TimeInterval?
        init(old: Slot, generation: UInt64, activeSince: TimeInterval?) {
            self.old = old; self.generation = generation; self.activeSince = activeSince
        }
    }

    private let file: MediaFile
    private let metadata: @MainActor (Session, MediaFile) async throws -> PlaybackSourceIdentity
    private let makeFresh: @MainActor () async throws -> Session
    private let retire: @MainActor (Session) async throws -> Void
    private let shouldRecover: @MainActor (any Error) -> Bool
    private let shouldJoinExistingRecovery: @MainActor (any Error) -> Bool
    private let isCurrent: @MainActor () -> Bool
    private let diagnostics: LifecycleDiagnostics?
    private let diagnosticTrace: UInt64
    private let onRecoveryStage: @MainActor (PlaybackSourceRecoveryStage) -> Void
    private let uptime: @MainActor () -> TimeInterval
    private var current: Slot
    private var identity: PlaybackSourceIdentity?
    private var episode: Episode?
    private var sceneActive = true, stopped = false
    private var terminalFailure: (any Error)?
    private var cleanupFailure: (any Error)?
    private var stopRetirement: Task<Void, any Error>?
    private var generation: UInt64 = 1, nextIdentifier: UInt64 = 0
    private var requests: [UInt64: Request] = [:]
    private var activeWaiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]

    public init(
        file: MediaFile, initial: Session,
        metadata: @escaping @MainActor (Session, MediaFile) async throws -> PlaybackSourceIdentity,
        makeFresh: @escaping @MainActor () async throws -> Session,
        retire: @escaping @MainActor (Session) async throws -> Void,
        shouldRecover: @escaping @MainActor (any Error) -> Bool,
        shouldJoinExistingRecovery: @escaping @MainActor (any Error) -> Bool = { _ in false },
        isCurrent: @escaping @MainActor () -> Bool,
        diagnostics: LifecycleDiagnostics? = .shared,
        onRecoveryStage: @escaping @MainActor (PlaybackSourceRecoveryStage) -> Void = { _ in },
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.file = file; self.current = Slot(initial, owned: false, epoch: 0)
        self.metadata = metadata; self.makeFresh = makeFresh; self.retire = retire
        self.shouldRecover = shouldRecover; self.shouldJoinExistingRecovery = shouldJoinExistingRecovery
        self.isCurrent = isCurrent
        self.diagnostics = diagnostics; self.diagnosticTrace = diagnostics?.nextID() ?? 0
        self.onRecoveryStage = onRecoveryStage; self.uptime = uptime
    }

    private var hasLiveRequests: Bool { requests.values.contains { !$0.isCancelled } }
    public var isPlaybackRecovering: Bool {
        guard let episode else { return false }
        return !stopped && !episode.delivered && hasLiveRequests
    }
    public var recoveryActiveElapsed: TimeInterval { episode.map(elapsed) ?? 0 }
    public var recoveryActiveStartedAt: TimeInterval? {
        guard isPlaybackRecovering, sceneActive, let episode else { return nil }
        return uptime() - elapsed(episode)
    }

    public func setPlaybackSceneActive(_ active: Bool) {
        guard !stopped, active != sceneActive else { return }
        if let episode {
            if let since = episode.activeSince { episode.activeElapsed += max(0, uptime() - since) }
            episode.activeSince = active && hasLiveRequests && !episode.delivered ? uptime() : nil
        }
        sceneActive = active
        if active { resumeActiveWaiters() }
    }

    public func cancelPlayback() {
        guard !stopped else { return }
        stopped = true; generation &+= 1
        emit(.cancelled)
        let failure = cancellationFailure
        resumeActiveWaiters(failure)
        if let episode {
            episode.demandWaiter?.resume(throwing: failure)
            episode.demandWaiter = nil
            complete(episode, with: .failure(failure))
        }
        if current.owned {
            let slot = current
            stopRetirement = Task { @MainActor in try await self.retireSlot(slot, stage: .retiringOwned) }
        }
    }

    public func awaitPlaybackCleanup() async throws {
        cancelPlayback()
        // These tasks are never cancelled by their observer. A cancelled caller still waits
        // for actual completion; the next generation must check its own validity afterwards.
        if let running = episode?.task { await running.value }
        if let stopRetirement { try await stopRetirement.value }
        if let cleanupFailure { throw cleanupFailure }
    }

    public func fileSize(for file: MediaFile) async throws -> UInt64 {
        let request = try beginRequest(file)
        defer { endRequest(request) }
        return try await withTaskCancellationHandler {
            let baseline = try await baselineIdentity(request)
            try checkCurrent()
            if request.usedRecovery { episode?.delivered = true }
            return baseline.size
        } onCancel: {
            request.cancel()
            Task { @MainActor in self.endRequest(request) }
        }
    }

    public func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        let request = try beginRequest(file)
        defer { endRequest(request) }
        return try await withTaskCancellationHandler {
            guard range.upperBound - range.lowerBound <= 1_048_576 else { throw PlaybackSourceRecoveryError.invalidRange }
            let baseline = try await baselineIdentity(request)
            guard range.upperBound <= baseline.size else { throw PlaybackSourceRecoveryError.invalidRange }
            let slot = try await availableSlot(request)
            do {
                if request.usedRecovery { return try await retryRange(slot, range: range) }
                return try await readRange(slot, range: range, recovered: false)
            }
            catch {
                try checkCurrent()
                guard !request.usedRecovery,
                      eligible(error) || canJoinExisting(error, after: slot) else { throw publicError(error) }
                let fresh = try await recover(after: slot, request: request)
                // No recursion: even an eligible second failure returns to this caller.
                return try await retryRange(fresh, range: range)
            }
        } onCancel: {
            request.cancel()
            Task { @MainActor in self.endRequest(request) }
        }
    }

    private func retryRange(_ slot: Slot, range: Range<UInt64>) async throws -> Data {
        do { return try await readRange(slot, range: range, recovered: true) }
        catch {
            // A late retry failure must not terminate a subsequent episode/newer session.
            do { try checkReadable(slot) } catch { throw publicError(error) }
            if !(error is CancellationError), !Task.isCancelled {
                // The only retry failed: this playback cannot keep using an unvalidated source.
                // A caller cancellation alone must not stop the other live callers.
                terminalFailure = error
                emit(.failed, epoch: slot.epoch)
                cancelPlayback()
            } else { emit(.cancelled, epoch: slot.epoch) }
            throw error
        }
    }

    private func readRange(_ slot: Slot, range: Range<UInt64>, recovered: Bool) async throws -> Data {
        if recovered {
            try await waitUntilActive()
            try checkReadable(slot)
            emit(.retrying, epoch: slot.epoch)
            try await waitUntilActive()
        }
        try checkReadable(slot)
        let data = try await slot.session.read(file, range: range)
        try checkCurrent()
        guard UInt64(data.count) == range.upperBound - range.lowerBound else { throw PlaybackSourceRecoveryError.invalidResponse }
        try checkReadable(slot)
        if recovered {
            try await waitUntilActive()
            try checkReadable(slot)
            let after = try await metadata(slot.session, file)
            try await waitUntilActive(epoch: slot.epoch)
            try checkReadable(slot)
            guard let identity, after == identity else {
                terminalFailure = PlaybackSourceRecoveryError.identityChanged
                cancelPlayback()
                throw PlaybackSourceRecoveryError.identityChanged
            }
            emit(.returned, epoch: slot.epoch)
            try await waitUntilActive(epoch: slot.epoch)
            try checkReadable(slot)
            episode?.delivered = true
        }
        return data
    }

    private func baselineIdentity(_ request: Request) async throws -> PlaybackSourceIdentity {
        try checkCurrent()
        if let identity { return identity }
        let slot = try await availableSlot(request)
        if let identity { return identity }
        do {
            let observed = try await metadata(slot.session, file)
            try checkReadable(slot)
            if let identity, identity != observed { throw PlaybackSourceRecoveryError.identityChanged }
            identity = observed
            return observed
        } catch {
            try checkCurrent()
            guard !request.usedRecovery,
                  eligible(error) || canJoinExisting(error, after: slot) else { throw publicError(error) }
            _ = try await recover(after: slot, request: request)
            try checkCurrent()
            guard let identity else { throw PlaybackSourceRecoveryError.incompleteIdentity }
            return identity
        }
    }

    private func availableSlot(_ request: Request) async throws -> Slot {
        try checkCurrent()
        if let episode, episode.old === current {
            request.usedRecovery = true
            return try await waitForEpisode(episode)
        }
        if let episode, !episode.delivered, current.epoch == episode.old.epoch &+ 1 {
            request.usedRecovery = true
        }
        return current
    }

    private func recover(after old: Slot, request: Request) async throws -> Slot {
        try checkCurrent()
        request.usedRecovery = true
        if let episode, episode.old === old { return try await waitForEpisode(episode) }
        // A callback from a superseded epoch cannot start recovery for the current session.
        guard current === old, old.retirement == nil else { throw PlaybackSourceRecoveryError.unavailable }
        if let identity, !identity.isComplete { throw PlaybackSourceRecoveryError.incompleteIdentity }
        let recovery = Episode(old: old, generation: generation, activeSince: sceneActive ? uptime() : nil)
        episode = recovery
        recovery.task = Task { @MainActor in await self.run(recovery) }
        return try await waitForEpisode(recovery)
    }

    private func run(_ recovery: Episode) async {
        var candidate: Slot?
        emit(.started, epoch: recovery.old.epoch)
        do {
            try await waitForRecoveryAdmission(recovery)
            try await retireSlot(recovery.old, stage: .retiringOld)
            try await waitForRecoveryAdmission(recovery)
            emit(.connecting, epoch: recovery.old.epoch)
            try await waitForRecoveryAdmission(recovery)
            let fresh = try await makeFresh()
            guard fresh !== recovery.old.session else { throw PlaybackSourceRecoveryError.unavailable }
            let created = Slot(fresh, owned: true, epoch: recovery.old.epoch &+ 1)
            candidate = created
            emit(.connected, epoch: created.epoch)
            try await waitForRecoveryAdmission(recovery)
            emit(.checkingIdentity, epoch: created.epoch)
            try await waitForRecoveryAdmission(recovery)
            let observed = try await metadata(fresh, file)
            try await waitForRecoveryAdmission(recovery)
            try checkEpisode(recovery)
            try validateIdentity(observed)
            emit(.identityAccepted, epoch: created.epoch)
            try await waitForRecoveryAdmission(recovery)
            try checkEpisode(recovery)
            identity = observed
            current = created
            complete(recovery, with: .success(created))
        } catch {
            var failure = error
            if let candidate {
                do { try await retireSlot(candidate, stage: .retiringOwned) }
                catch { failure = error }
            }
            let cancelled = terminalFailure == nil && (stopped || !isCurrent() || failure is CancellationError)
            emit(cancelled ? .cancelled : .failed, epoch: recovery.old.epoch)
            if let terminalFailure { complete(recovery, with: .failure(terminalFailure)) }
            else { complete(recovery, with: .failure(cancelled ? CancellationError() : failure)) }
        }
        recovery.task = nil
    }

    private func retireSlot(_ slot: Slot, stage: PlaybackSourceRecoveryStage) async throws {
        if let retirement = slot.retirement { try await retirement.value; return }
        // Deliberately independent of a cancellable resource-loader read or recovery observer.
        let retirement = Task { @MainActor in
            self.emit(stage, epoch: slot.epoch)
            do { try await self.retire(slot.session) }
            catch {
                self.cleanupFailure = error
                self.emit(.failed, epoch: slot.epoch)
                throw error
            }
            self.emit(stage == .retiringOld ? .oldRetired : .ownedRetired, epoch: slot.epoch)
        }
        slot.retirement = retirement
        try await retirement.value
    }

    private func waitForEpisode(_ recovery: Episode) async throws -> Slot {
        try checkCurrent()
        if let result = recovery.result { return try result.get() }
        let identifier = takeIdentifier()
        return try await withTaskCancellationHandler {
            try checkCurrent()
            return try await withCheckedThrowingContinuation { continuation in
                if let result = recovery.result { continuation.resume(with: result) }
                else { recovery.waiters[identifier] = continuation }
            }
        } onCancel: {
            Task { @MainActor in recovery.waiters.removeValue(forKey: identifier)?.resume(throwing: CancellationError()) }
        }
    }

    private func waitUntilActive(epoch: UInt64? = nil) async throws {
        try checkCurrent()
        if !sceneActive, let epoch { emit(.waitingForActive, epoch: epoch) }
        while !sceneActive {
            try checkCurrent()
            let identifier = takeIdentifier()
            try await withTaskCancellationHandler {
                try checkCurrent()
                try await withCheckedThrowingContinuation { continuation in activeWaiters[identifier] = continuation }
            } onCancel: {
                Task { @MainActor in self.activeWaiters.removeValue(forKey: identifier)?.resume(throwing: CancellationError()) }
            }
        }
        try checkCurrent()
    }

    private func resumeActiveWaiters(_ failure: (any Error)? = nil) {
        let waiters = activeWaiters.values
        activeWaiters.removeAll()
        for waiter in waiters {
            if let failure { waiter.resume(throwing: failure) } else { waiter.resume() }
        }
    }

    private func beginRequest(_ requested: MediaFile) throws -> Request {
        try checkCurrent()
        guard requested == file else { throw MediaInspectionError.invalidFile }
        let request = Request(takeIdentifier())
        requests[request.identifier] = request
        if let episode, !episode.delivered {
            if sceneActive, episode.activeSince == nil { episode.activeSince = uptime() }
            episode.demandWaiter?.resume()
            episode.demandWaiter = nil
        }
        return request
    }

    private func endRequest(_ request: Request) {
        requests.removeValue(forKey: request.identifier)
        guard !hasLiveRequests, let episode else { return }
        if let since = episode.activeSince { episode.activeElapsed += max(0, uptime() - since) }
        episode.activeSince = nil
    }

    private func takeIdentifier() -> UInt64 { nextIdentifier &+= 1; return nextIdentifier }
    private func elapsed(_ episode: Episode) -> TimeInterval {
        episode.activeElapsed + (episode.activeSince.map { max(0, uptime() - $0) } ?? 0)
    }

    private func complete(_ recovery: Episode, with result: Result<Slot, any Error>) {
        guard recovery.result == nil else { return }
        recovery.result = result
        let waiters = recovery.waiters.values
        recovery.waiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    private var cancellationFailure: any Error {
        if let terminalFailure { return terminalFailure }
        return CancellationError()
    }

    private func checkCurrent() throws {
        try Task.checkCancellation()
        if isPlaybackRecovering, let episode, elapsed(episode) >= PlaybackSourceRecoveryPolicy.activeBudget {
            terminalFailure = PlaybackSourceRecoveryError.recoveryTimedOut
            cancelPlayback()
        }
        guard !stopped, isCurrent() else {
            cancelPlayback()
            throw cancellationFailure
        }
    }

    private func checkEpisode(_ recovery: Episode) throws {
        try checkCurrent()
        guard episode === recovery, generation == recovery.generation, current === recovery.old,
              !stopped else { throw CancellationError() }
    }

    private func checkReadable(_ slot: Slot) throws {
        try checkCurrent()
        guard current === slot, slot.retirement == nil else { throw ReadStateError.superseded }
        if let episode, episode.old === slot { throw ReadStateError.superseded }
    }

    private func validateIdentity(_ observed: PlaybackSourceIdentity) throws {
        if let identity {
            guard identity.isComplete, observed.isComplete else { throw PlaybackSourceRecoveryError.incompleteIdentity }
            guard observed == identity else { throw PlaybackSourceRecoveryError.identityChanged }
        }
    }


    private func waitForRecoveryAdmission(_ recovery: Episode) async throws {
        // Either condition can change while the other is suspended. Recheck both together.
        repeat {
            try await waitForRecoveryDemand(recovery)
            try await waitUntilActive(epoch: recovery.old.epoch)
            try checkEpisode(recovery)
        } while !hasLiveRequests || !sceneActive
    }

    private func waitForRecoveryDemand(_ recovery: Episode) async throws {
        try checkEpisode(recovery)
        while !hasLiveRequests {
            emit(.waitingForDemand, epoch: recovery.old.epoch)
            try checkEpisode(recovery)
            if hasLiveRequests { continue }
            try await withCheckedThrowingContinuation { continuation in recovery.demandWaiter = continuation }
            try checkEpisode(recovery)
        }
    }

    private func canJoinExisting(_ error: any Error, after slot: Slot) -> Bool {
        guard !(error is CancellationError), let episode, episode.old === slot,
              episode.generation == generation else { return false }
        // A genuine denial/invalid response is not hidden by a simultaneous recovery.
        // The extra classifier admits typed local retirement only into this existing episode.
        return error is ReadStateError || shouldJoinExistingRecovery(error)
    }

    private func publicError(_ error: any Error) -> any Error {
        error is ReadStateError ? PlaybackSourceRecoveryError.unavailable : error
    }

    private func eligible(_ error: any Error) -> Bool {
        guard !(error is CancellationError), !(error is ReadStateError),
              !(error is PlaybackSourceRecoveryError), !(error is MediaInspectionError) else { return false }
        let cocoa = error as NSError
        if cocoa.domain == NSURLErrorDomain && cocoa.code == NSURLErrorCancelled { return false }
        if cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError { return false }
        return shouldRecover(error)
    }

    private func emit(_ stage: PlaybackSourceRecoveryStage, epoch: UInt64? = nil) {
        diagnostics?.record(.playbackSourceRecovery, [
            .trace: Double(diagnosticTrace), .phase: Double(stage.rawValue), .generation: Double(generation),
            .epoch: Double(epoch ?? current.epoch), .active: sceneActive ? 1 : 0,
            .cancelled: stopped ? 1 : 0
        ])
        onRecoveryStage(stage)
    }
}
