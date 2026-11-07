import Foundation

/// Anonymous boundaries only. Paths, credentials and errors belong outside diagnostics.
public enum DirectoryRecoveryStage: Sendable, Equatable {
    case started, retired, connected, succeeded, failed, discarded
}

public enum DirectoryRecoveryError: Error, Sendable, Equatable {
    case busy
    /// Cleanup did not prove that the old work had drained. Do not create another session.
    case quarantined
}

public struct DirectoryReadResult<Session: AnyObject & Sendable>: Sendable {
    public let page: DirectoryPage
    public let session: Session
    /// A fresh first page must replace, rather than append to, the old listing snapshot.
    public let restarted: Bool
}

/// Owns directory session publication and the one-attempt recovery boundary used by the UI.
/// All decisions run on the UI actor; transport closures can await their own provider actors.
@MainActor public final class DirectoryReadRecovery<Session: AnyObject & Sendable> {
    private final class Reservation {
        var quarantined = false
    }

    private var sessions: [String: Session] = [:]
    private var reservations: [String: Reservation] = [:]

    public init() {}

    public var keys: [String] { Array(sessions.keys) }

    public func existingSession(for key: String) -> Session? { sessions[key] }

    public func containsSession(_ session: Session, for key: String) -> Bool {
        sessions[key] === session
    }

    /// Removal never frees a creation, draining or quarantined reservation. The caller owns
    /// retirement of the returned session; stale owners cannot remove another session.
    @discardableResult
    public func removeSession(for key: String, matching session: Session? = nil) -> Session? {
        guard let existing = sessions[key], session == nil || existing === session else { return nil }
        return sessions.removeValue(forKey: key)
    }

    /// A failed initial connect is not retried. Only an eligible original directory read can
    /// retire its session, connect once and read once more (always at offset zero).
    /// Factories must drain any partially created transport before throwing, since no session
    /// is returned for this owner to retire. Retirement must await real completion even if the
    /// navigation task is cancelled; a thrown retirement permanently quarantines this key.
    public func readPage(
        key: String,
        offset: Int,
        isCurrent: @MainActor () -> Bool,
        makeInitial: @MainActor () async throws -> Session,
        makeRecovery: @MainActor () async throws -> Session,
        read: @MainActor (Session, Int) async throws -> DirectoryPage,
        retire: @MainActor (Session) async throws -> Void,
        shouldRecover: @MainActor (any Error) -> Bool,
        onRecoveryStage: @MainActor (DirectoryRecoveryStage) -> Void = { _ in }
    ) async throws -> DirectoryReadResult<Session> {
        try checkCurrent(isCurrent)
        try checkAvailable(key)
        let session: Session
        if let existing = sessions[key] {
            session = existing
        } else {
            session = try await createInitial(
                key: key, isCurrent: isCurrent, make: makeInitial, retire: retire
            )
        }

        do {
            try checkCurrentSession(session, key: key, isCurrent: isCurrent)
            let page = try await read(session, offset)
            try checkCurrentSession(session, key: key, isCurrent: isCurrent)
            return DirectoryReadResult(page: page, session: session, restarted: false)
        } catch {
            // A stale completion must neither remove nor reconnect a newer owner's session.
            try checkCurrentSession(session, key: key, isCurrent: isCurrent)
            guard !(error is CancellationError), shouldRecover(error) else { throw error }
            try checkCurrentSession(session, key: key, isCurrent: isCurrent)
            try checkAvailable(key)
        }

        return try await recover(
            session, key: key, isCurrent: isCurrent, make: makeRecovery,
            read: read, retire: retire, onStage: onRecoveryStage
        )
    }

    private func createInitial(
        key: String,
        isCurrent: @MainActor () -> Bool,
        make: @MainActor () async throws -> Session,
        retire: @MainActor (Session) async throws -> Void
    ) async throws -> Session {
        let ticket = Reservation()
        reservations[key] = ticket
        defer { release(key, ticket: ticket) }
        var candidate: Session?
        do {
            try checkCurrentReservation(ticket, key: key, isCurrent: isCurrent)
            let created = try await make()
            candidate = created
            try checkCurrentReservation(ticket, key: key, isCurrent: isCurrent)
            sessions[key] = created
            return created
        } catch {
            // Cleanup is the one intentional exception to cancellation guards: the key stays
            // reserved until this candidate really drains, even after navigation has changed.
            if let candidate { try await retireOwned(candidate, key: key, ticket: ticket, retire: retire) }
            try checkCurrent(isCurrent)
            throw error
        }
    }

    private func recover(
        _ old: Session,
        key: String,
        isCurrent: @MainActor () -> Bool,
        make: @MainActor () async throws -> Session,
        read: @MainActor (Session, Int) async throws -> DirectoryPage,
        retire: @MainActor (Session) async throws -> Void,
        onStage: @MainActor (DirectoryRecoveryStage) -> Void
    ) async throws -> DirectoryReadResult<Session> {
        try checkCurrentSession(old, key: key, isCurrent: isCurrent)
        try checkAvailable(key)
        let ticket = Reservation()
        reservations[key] = ticket
        removeSession(for: key, matching: old)
        defer { release(key, ticket: ticket) }
        var candidate: Session?
        onStage(.started)
        do {
            // Once detached, old must be drained even if the observer cancels navigation.
            try await retireOwned(old, key: key, ticket: ticket, retire: retire)
            try checkCurrentReservation(ticket, key: key, isCurrent: isCurrent)
            onStage(.retired)
            try checkCurrentReservation(ticket, key: key, isCurrent: isCurrent)
            let created = try await make()
            candidate = created
            try checkCurrentReservation(ticket, key: key, isCurrent: isCurrent)
            onStage(.connected)
            try checkCurrentReservation(ticket, key: key, isCurrent: isCurrent)
            let page = try await read(created, 0)
            try checkCurrentReservation(ticket, key: key, isCurrent: isCurrent)
            onStage(.succeeded)
            try checkCurrentReservation(ticket, key: key, isCurrent: isCurrent)
            sessions[key] = created
            return DirectoryReadResult(page: page, session: created, restarted: true)
        } catch {
            var failure = error
            if let candidate {
                do { try await retireOwned(candidate, key: key, ticket: ticket, retire: retire) }
                catch { failure = error }
            }
            let discarded = Task.isCancelled || !isCurrent() || failure is CancellationError
            onStage(discarded ? .discarded : .failed)
            try checkCurrent(isCurrent)
            throw failure
        }
    }

    private func retireOwned(
        _ session: Session,
        key: String,
        ticket: Reservation,
        retire: @MainActor (Session) async throws -> Void
    ) async throws {
        removeSession(for: key, matching: session)
        do { try await retire(session) }
        catch {
            // Never release a reservation on an assumed timeout/cancellation completion.
            if reservations[key] === ticket { ticket.quarantined = true }
            throw error
        }
    }

    private func checkCurrent(_ isCurrent: @MainActor () -> Bool) throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
    }

    private func checkCurrentSession(
        _ session: Session, key: String, isCurrent: @MainActor () -> Bool
    ) throws {
        try checkCurrent(isCurrent)
        guard containsSession(session, for: key) else { throw CancellationError() }
    }

    private func checkCurrentReservation(
        _ ticket: Reservation, key: String, isCurrent: @MainActor () -> Bool
    ) throws {
        try checkCurrent(isCurrent)
        guard reservations[key] === ticket, !ticket.quarantined, sessions[key] == nil else {
            throw CancellationError()
        }
    }

    private func checkAvailable(_ key: String) throws {
        if let ticket = reservations[key] {
            throw ticket.quarantined ? DirectoryRecoveryError.quarantined : .busy
        }
    }

    private func release(_ key: String, ticket: Reservation) {
        if reservations[key] === ticket, !ticket.quarantined { reservations[key] = nil }
    }
}
