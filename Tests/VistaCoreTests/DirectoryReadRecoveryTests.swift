import Foundation
import Testing
@testable import VistaCore

/// These are in-memory runner tests. No SMB provider, socket, NAS or device is instantiated.
/// Suspended operations advance only when the test manually completes their callback.
@Suite(.serialized)
@MainActor struct DirectoryReadRecoveryTests {
    private final class Session: Sendable {
        let number: Int
        init(_ number: Int) { self.number = number }
    }

    private enum Failure: Error, Equatable { case transport, denied, connect, cleanup }

    @MainActor private final class Completion<Value: Sendable> {
        private var entered = false
        private var arrival: CheckedContinuation<Void, Never>?
        private var result: CheckedContinuation<Value, any Error>?

        func wait() async throws -> Value {
            entered = true
            arrival?.resume()
            arrival = nil
            return try await withCheckedThrowingContinuation { result = $0 }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { arrival = $0 }
        }

        func complete(_ value: Value) {
            precondition(result != nil)
            result?.resume(returning: value)
            result = nil
        }

        func fail(_ error: any Error) {
            precondition(result != nil)
            result?.resume(throwing: error)
            result = nil
        }
    }

    @MainActor private final class Harness {
        let runner = DirectoryReadRecovery<Session>()
        let old = Session(1)
        let fresh = Session(2)
        var current = true
        var initialCount = 0
        var recoveryCount = 0
        var reads: [(Int, Int)] = []
        var retired: [Int] = []
        var stages: [DirectoryRecoveryStage] = []
        var initialBody: (@MainActor () async throws -> Session)?
        var recoveryBody: (@MainActor () async throws -> Session)?
        var readBody: (@MainActor (Session, Int) async throws -> DirectoryPage)?
        var retireBody: (@MainActor (Session) async throws -> Void)?
        var stageBody: (@MainActor (DirectoryRecoveryStage) -> Void)?
        var classifier: @MainActor (any Error) -> Bool = { ($0 as? Failure) == .transport }

        func run(key: String = "share", offset: Int = 0) async throws -> DirectoryReadResult<Session> {
            try await runner.readPage(
                key: key, offset: offset, isCurrent: { self.current },
                makeInitial: {
                    self.initialCount += 1
                    if let body = self.initialBody { return try await body() }
                    return self.old
                },
                makeRecovery: {
                    self.recoveryCount += 1
                    if let body = self.recoveryBody { return try await body() }
                    return self.fresh
                },
                read: { session, offset in
                    self.reads.append((session.number, offset))
                    if let body = self.readBody { return try await body(session, offset) }
                    return Self.page("page-\(session.number)")
                },
                retire: { session in
                    self.retired.append(session.number)
                    try await self.retireBody?(session)
                },
                shouldRecover: { self.classifier($0) },
                onRecoveryStage: {
                    self.stages.append($0)
                    self.stageBody?($0)
                }
            )
        }

        static func page(_ name: String) -> DirectoryPage {
            DirectoryPage(entries: [FileEntry(name, .directory)], nextOffset: 100)
        }

        func failOldRead() {
            readBody = { session, _ in
                if session.number == 1 { throw Failure.transport }
                return Self.page("fresh-first-page")
            }
        }
    }

    private func expectFailure<E: Error & Equatable>(
        _ expected: E, _ action: @MainActor () async throws -> Void
    ) async {
        do { try await action(); Issue.record("Expected failure") }
        catch { #expect((error as? E) == expected) }
    }

    private func expectCancellation(_ action: @MainActor () async throws -> Void) async {
        do { try await action(); Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }

    @Test func healthyReadDoesNotReconnectAndRegistryUsesIdentity() async throws {
        let h = Harness()
        let first = try await h.run()
        let second = try await h.run(offset: 100)
        #expect(first.session === h.old)
        #expect(second.session === h.old)
        #expect(!first.restarted && !second.restarted)
        #expect(h.initialCount == 1 && h.recoveryCount == 0)
        #expect(h.reads.map(\.1) == [0, 100])
        #expect(h.retired.isEmpty && h.stages.isEmpty)
        #expect(h.runner.keys == ["share"])
        #expect(h.runner.containsSession(h.old, for: "share"))
        #expect(h.runner.removeSession(for: "share", matching: h.fresh) == nil)
        #expect(h.runner.removeSession(for: "share", matching: h.old) === h.old)
        #expect(h.runner.keys.isEmpty)
    }

    @Test func eligibleFailureReconnectsOnceAndRestartsPagination() async throws {
        let h = Harness()
        h.failOldRead()
        let result = try await h.run(offset: 300)
        #expect(result.restarted)
        #expect(result.session === h.fresh)
        #expect(result.page.entries.map(\.name) == ["fresh-first-page"])
        #expect(result.page.nextOffset == 100)
        #expect(h.initialCount == 1 && h.recoveryCount == 1)
        #expect(h.reads.map(\.0) == [1, 2])
        #expect(h.reads.map(\.1) == [300, 0])
        #expect(h.retired == [1])
        #expect(h.runner.existingSession(for: "share") === h.fresh)
        #expect(h.stages == [.started, .retired, .connected, .succeeded])
    }

    @Test func initialConnectFailureNeverRetriesAndReleasesCreationTicket() async throws {
        let h = Harness()
        h.initialBody = { throw Failure.connect }
        await expectFailure(Failure.connect) { _ = try await h.run() }
        #expect(h.initialCount == 1 && h.recoveryCount == 0)
        #expect(h.reads.isEmpty && h.retired.isEmpty && h.stages.isEmpty)
        #expect(h.runner.keys.isEmpty)
        h.initialBody = nil
        _ = try await h.run()
        #expect(h.initialCount == 2)
    }

    @Test func recoveryConnectFailureIsFinalWithoutAnotherReadOrConnect() async {
        let h = Harness()
        h.failOldRead()
        h.recoveryBody = { throw Failure.connect }
        await expectFailure(Failure.connect) { _ = try await h.run() }
        #expect(h.initialCount == 1 && h.recoveryCount == 1)
        #expect(h.reads.count == 1 && h.retired == [1])
        #expect(h.runner.keys.isEmpty)
        #expect(h.stages == [.started, .retired, .failed])
    }

    @Test func secondReadFailureRetiresOnlyCandidateAndDoesNotRecurse() async {
        let h = Harness()
        h.readBody = { _, _ in throw Failure.transport }
        await expectFailure(Failure.transport) { _ = try await h.run() }
        #expect(h.initialCount == 1 && h.recoveryCount == 1)
        #expect(h.reads.count == 2 && h.retired == [1, 2])
        #expect(h.runner.keys.isEmpty)
        #expect(h.stages == [.started, .retired, .connected, .failed])
    }

    @Test func terminalFailurePreservesHealthySession() async throws {
        let h = Harness()
        h.readBody = { _, _ in throw Failure.denied }
        await expectFailure(Failure.denied) { _ = try await h.run() }
        #expect(h.recoveryCount == 0 && h.retired.isEmpty)
        #expect(h.runner.existingSession(for: "share") === h.old)
        h.readBody = nil
        _ = try await h.run()
        #expect(h.initialCount == 1 && h.recoveryCount == 0)
    }

    @Test func cancellationErrorIsNeverRecoverableEvenWithPermissiveClassifier() async {
        let h = Harness()
        h.classifier = { _ in true }
        h.readBody = { _, _ in throw CancellationError() }
        await expectCancellation { _ = try await h.run() }
        #expect(h.recoveryCount == 0 && h.retired.isEmpty)
        #expect(h.runner.existingSession(for: "share") === h.old)
    }

    @Test func invalidGenerationAtEntryDoesNoWork() async {
        let h = Harness()
        h.current = false
        await expectCancellation { _ = try await h.run() }
        #expect(h.initialCount == 0 && h.recoveryCount == 0 && h.reads.isEmpty)
    }

    @Test func cancelledTaskAtEntryDoesNoWork() async {
        let h = Harness()
        let enter = Completion<Void>()
        let task = Task { @MainActor in
            try await enter.wait()
            return try await h.run()
        }
        await enter.waitUntilEntered()
        task.cancel()
        enter.complete(())
        await expectCancellation { _ = try await task.value }
        #expect(h.initialCount == 0 && h.recoveryCount == 0 && h.reads.isEmpty)
    }

    @Test func generationChangeDuringInitialConnectDiscardsAndDrainsCandidate() async {
        let h = Harness()
        let connect = Completion<Session>()
        h.initialBody = { try await connect.wait() }
        let task = Task { @MainActor in try await h.run() }
        await connect.waitUntilEntered()
        h.current = false
        connect.complete(h.old)
        await expectCancellation { _ = try await task.value }
        #expect(h.initialCount == 1 && h.recoveryCount == 0)
        #expect(h.reads.isEmpty && h.retired == [1] && h.runner.keys.isEmpty)
    }

    @Test func creationTicketRejectsSecondConnectAndRemovalDoesNotReleaseIt() async throws {
        let h = Harness()
        let connect = Completion<Session>()
        h.initialBody = { try await connect.wait() }
        let task = Task { @MainActor in try await h.run() }
        await connect.waitUntilEntered()
        #expect(h.runner.removeSession(for: "share") == nil)
        await expectFailure(DirectoryRecoveryError.busy) { _ = try await h.run() }
        #expect(h.initialCount == 1 && h.recoveryCount == 0)
        connect.complete(h.old)
        _ = try await task.value
        #expect(h.runner.existingSession(for: "share") === h.old)
    }

    @Test func generationChangeDuringRetirementPreventsRecoveryConnect() async {
        let h = Harness()
        h.failOldRead()
        let drain = Completion<Void>()
        h.retireBody = { _ in try await drain.wait() }
        let task = Task { @MainActor in try await h.run() }
        await drain.waitUntilEntered()
        h.current = false
        drain.complete(())
        await expectCancellation { _ = try await task.value }
        #expect(h.recoveryCount == 0 && h.reads.count == 1)
        #expect(h.retired == [1] && h.runner.keys.isEmpty)
        #expect(h.stages == [.started, .discarded])
    }

    @Test func cancellationKeepsRetiringKeyBusyUntilActualCompletion() async throws {
        let h = Harness()
        h.failOldRead()
        let drain = Completion<Void>()
        h.retireBody = { _ in try await drain.wait() }
        let task = Task { @MainActor in try await h.run() }
        await drain.waitUntilEntered()
        task.cancel()
        #expect(h.runner.removeSession(for: "share") == nil)
        await expectFailure(DirectoryRecoveryError.busy) { _ = try await h.run() }
        await expectFailure(DirectoryRecoveryError.busy) { _ = try await h.run() }
        #expect(h.initialCount == 1 && h.recoveryCount == 0)
        drain.complete(())
        await expectCancellation { _ = try await task.value }
        h.retireBody = nil
        h.readBody = nil
        _ = try await h.run()
        #expect(h.initialCount == 2 && h.recoveryCount == 0)
    }

    @Test func generationChangeDuringRecoveryConnectRetiresUnpublishedCandidate() async {
        let h = Harness()
        h.failOldRead()
        let connect = Completion<Session>()
        h.recoveryBody = { try await connect.wait() }
        let task = Task { @MainActor in try await h.run() }
        await connect.waitUntilEntered()
        #expect(h.runner.existingSession(for: "share") == nil)
        h.current = false
        connect.complete(h.fresh)
        await expectCancellation { _ = try await task.value }
        #expect(h.recoveryCount == 1 && h.reads.count == 1)
        #expect(h.retired == [1, 2] && h.runner.keys.isEmpty)
        #expect(h.stages == [.started, .retired, .discarded])
    }

    @Test func generationChangeDuringRecoveredListDiscardsPageAndCandidate() async {
        let h = Harness()
        let list = Completion<DirectoryPage>()
        h.readBody = { session, _ in
            if session.number == 1 { throw Failure.transport }
            return try await list.wait()
        }
        let task = Task { @MainActor in try await h.run(offset: 200) }
        await list.waitUntilEntered()
        #expect(h.runner.existingSession(for: "share") == nil)
        h.current = false
        list.complete(Harness.page("stale"))
        await expectCancellation { _ = try await task.value }
        #expect(h.recoveryCount == 1 && h.reads.map(\.1) == [200, 0])
        #expect(h.retired == [1, 2] && h.runner.keys.isEmpty)
        #expect(h.stages == [.started, .retired, .connected, .discarded])
    }

    @Test func originalLateSuccessCannotOverwriteNewerSession() async throws {
        let h = Harness()
        let list = Completion<DirectoryPage>()
        h.readBody = { _, _ in try await list.wait() }
        let task = Task { @MainActor in try await h.run() }
        await list.waitUntilEntered()
        #expect(h.runner.removeSession(for: "share", matching: h.old) === h.old)
        h.initialBody = { h.fresh }
        h.readBody = nil
        let newer = try await h.run()
        list.complete(Harness.page("old-response"))
        await expectCancellation { _ = try await task.value }
        #expect(newer.session === h.fresh)
        #expect(h.runner.existingSession(for: "share") === h.fresh)
        #expect(h.recoveryCount == 0 && h.retired.isEmpty)
    }

    @Test func originalLateFailureCannotRemoveOrRecoverNewerSession() async throws {
        let h = Harness()
        let list = Completion<DirectoryPage>()
        h.readBody = { _, _ in try await list.wait() }
        let task = Task { @MainActor in try await h.run() }
        await list.waitUntilEntered()
        h.runner.removeSession(for: "share", matching: h.old)
        h.initialBody = { h.fresh }
        h.readBody = nil
        _ = try await h.run()
        list.fail(Failure.transport)
        await expectCancellation { _ = try await task.value }
        #expect(h.runner.existingSession(for: "share") === h.fresh)
        #expect(h.recoveryCount == 0 && h.retired.isEmpty && h.stages.isEmpty)
    }

    @Test func oldCleanupFailureQuarantinesKeyEvenAfterRemovalOrCancellation() async throws {
        let h = Harness()
        h.failOldRead()
        h.retireBody = { _ in throw Failure.cleanup }
        await expectFailure(Failure.cleanup) { _ = try await h.run() }
        #expect(h.recoveryCount == 0 && h.reads.count == 1 && h.retired == [1])
        #expect(h.runner.removeSession(for: "share") == nil)
        await expectFailure(DirectoryRecoveryError.quarantined) { _ = try await h.run() }
        await expectFailure(DirectoryRecoveryError.quarantined) { _ = try await h.run() }
        #expect(h.initialCount == 1 && h.recoveryCount == 0)
        // Quarantine is scoped to this key, not an unrelated source/share.
        h.readBody = nil
        _ = try await h.run(key: "other-share")
        #expect(h.runner.keys == ["other-share"])
    }

    @Test func failedCandidateCleanupAlsoQuarantinesKey() async {
        let h = Harness()
        h.readBody = { _, _ in throw Failure.transport }
        h.retireBody = { session in if session.number == 2 { throw Failure.cleanup } }
        await expectFailure(Failure.cleanup) { _ = try await h.run() }
        await expectFailure(DirectoryRecoveryError.quarantined) { _ = try await h.run() }
        #expect(h.initialCount == 1 && h.recoveryCount == 1)
        #expect(h.retired == [1, 2] && h.runner.keys.isEmpty)
    }

    @Test func discardedInitialCandidateCleanupFailureQuarantinesKey() async {
        let h = Harness()
        h.initialBody = { h.current = false; return h.old }
        h.retireBody = { _ in throw Failure.cleanup }
        await expectFailure(Failure.cleanup) { _ = try await h.run() }
        h.current = true
        await expectFailure(DirectoryRecoveryError.quarantined) { _ = try await h.run() }
        #expect(h.initialCount == 1 && h.recoveryCount == 0 && h.reads.isEmpty)
    }

    @Test func stageObserverNavigationChangeCannotBeginNextOperation() async {
        for stop: DirectoryRecoveryStage in [.retired, .connected, .succeeded] {
            let h = Harness()
            h.failOldRead()
            h.stageBody = { if $0 == stop { h.current = false } }
            await expectCancellation { _ = try await h.run() }
            #expect(h.runner.keys.isEmpty)
            #expect(h.recoveryCount == (stop == .retired ? 0 : 1))
            #expect(h.reads.count == (stop == .succeeded ? 2 : 1))
            #expect(h.retired == (stop == .retired ? [1] : [1, 2]))
            #expect(h.stages.last == .discarded)
        }
    }
}
