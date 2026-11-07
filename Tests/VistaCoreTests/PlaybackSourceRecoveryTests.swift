import Foundation
import Testing
@testable import VistaCore

/// Pure memory sessions and manually resumed callbacks. No SMB, sockets, NAS or devices.
@Suite(.serialized)
@MainActor struct PlaybackSourceRecoveryTests {
    private enum Failure: Error, Equatable { case transport, retired, denied, unknown, connect, cleanup }

    @MainActor private final class Session: MediaByteSource {
        let number: Int
        var reads: [Range<UInt64>] = []
        var body: (@MainActor (Range<UInt64>) async throws -> Data)?
        init(_ number: Int) { self.number = number }
        func fileSize(for file: MediaFile) async throws -> UInt64 { 128 }
        func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            reads.append(range)
            if let body { return try await body(range) }
            return Data(repeating: UInt8(number), count: Int(range.upperBound - range.lowerBound))
        }
    }

    @MainActor private final class Completion<Value: Sendable> {
        private var entered = false
        private var arrival: CheckedContinuation<Void, Never>?
        private var result: CheckedContinuation<Value, any Error>?
        func wait() async throws -> Value {
            entered = true; arrival?.resume(); arrival = nil
            return try await withCheckedThrowingContinuation { result = $0 }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { arrival = $0 }
        }
        func complete(_ value: Value) { precondition(result != nil); result?.resume(returning: value); result = nil }
        func fail(_ error: any Error) { precondition(result != nil); result?.resume(throwing: error); result = nil }
    }

    @MainActor private final class Signal {
        private var signalled = false
        private var waiter: CheckedContinuation<Void, Never>?
        func send() { signalled = true; waiter?.resume(); waiter = nil }
        func wait() async { if !signalled { await withCheckedContinuation { waiter = $0 } } }
    }

    @MainActor private final class Harness {
        let file = try! MediaFile(components: ["generated.mp4"])
        let old = Session(1), fresh = Session(2), later = Session(3)
        var current = true, clock: TimeInterval = 100
        var creates = 0, metadataCalls: [Int] = [], retired: [Int] = []
        var stages: [PlaybackSourceRecoveryStage] = []
        var identity = PlaybackSourceIdentity(size: 128, modificationDate: Date(timeIntervalSince1970: 100), creationDate: Date(timeIntervalSince1970: 50), changeDate: Date(timeIntervalSince1970: 101), stableIdentifier: "synthetic")
        var metadataBody: (@MainActor (Session) async throws -> PlaybackSourceIdentity)?
        var makeBody: (@MainActor () async throws -> Session)?
        var retireBody: (@MainActor (Session) async throws -> Void)?
        var stageBody: (@MainActor (PlaybackSourceRecoveryStage) -> Void)?
        lazy var source = PlaybackRecoveringSource(
            file: file, initial: old,
            metadata: { session, _ in
                self.metadataCalls.append(session.number)
                if let body = self.metadataBody { return try await body(session) }
                return self.identity
            },
            makeFresh: {
                self.creates += 1
                if let body = self.makeBody { return try await body() }
                return self.creates == 1 ? self.fresh : self.later
            },
            retire: { session in self.retired.append(session.number); try await self.retireBody?(session) },
            shouldRecover: { ($0 as? Failure) == .transport },
            shouldJoinExistingRecovery: { ($0 as? Failure) == .retired }, isCurrent: { self.current },
            diagnostics: nil,
            onRecoveryStage: { self.stages.append($0); self.stageBody?($0) }, uptime: { self.clock }
        )
        func failOld() { old.body = { _ in throw Failure.transport } }
        func read(_ range: Range<UInt64> = 19..<31) async throws -> Data { try await source.read(file, range: range) }
    }

    private func expectFailure<E: Error & Equatable>(_ expected: E, _ body: @MainActor () async throws -> Void) async {
        do { try await body(); Issue.record("Expected failure") }
        catch { #expect(error as? E == expected) }
    }
    private func expectCancellation(_ body: @MainActor () async throws -> Void) async {
        do { try await body(); Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }

    @Test func recoveredReadKeepsExactRangeAndChecksIdentityBeforeAndAfterBytes() async throws {
        let h = Harness(); h.failOld()
        let data = try await h.read()
        #expect(data == Data(repeating: 2, count: 12))
        #expect(h.old.reads == [19..<31] && h.fresh.reads == [19..<31])
        #expect(h.creates == 1 && h.retired == [1] && h.metadataCalls == [1, 2, 2])
        #expect(h.stages.contains(.identityAccepted) && h.stages.last == .returned)
        #expect(!h.source.isPlaybackRecovering)
    }

    @Test func secondReadFailureDoesNotReconnectAgainWithinTheSameCall() async {
        let h = Harness(); h.failOld(); h.fresh.body = { _ in throw Failure.transport }
        await expectFailure(Failure.transport) { _ = try await h.read() }
        #expect(h.creates == 1 && h.old.reads.count == 1 && h.fresh.reads.count == 1)
        h.source.cancelPlayback()
    }

    @Test func laterIndependentFailureCanCreateAnotherEpisode() async throws {
        let h = Harness(); h.failOld()
        _ = try await h.read()
        h.fresh.body = { _ in throw Failure.transport }
        let data = try await h.read(50..<57)
        #expect(data == Data(repeating: 3, count: 7))
        #expect(h.creates == 2 && h.retired == [1, 2] && h.later.reads == [50..<57])
    }

    @Test func firstMetadataFailureCanEstablishFreshBaselineWithoutRetryLoop() async throws {
        let h = Harness()
        h.metadataBody = { session in if session === h.old { throw Failure.transport }; return h.identity }
        #expect(try await h.source.fileSize(for: h.file) == 128)
        #expect(h.creates == 1 && h.retired == [1] && h.old.reads.isEmpty)
        #expect(try await h.read() == Data(repeating: 2, count: 12))
        let failed = Harness()
        failed.metadataBody = { _ in throw Failure.transport }
        await expectFailure(Failure.transport) { _ = try await failed.read() }
        #expect(failed.creates == 1 && failed.retired == [1, 2] && failed.fresh.reads.isEmpty)
    }

    @Test func metadataRecoveryConsumesTheReadCallsOnlyRecoveryBudget() async {
        let h = Harness()
        h.metadataBody = { session in if session === h.old { throw Failure.transport }; return h.identity }
        h.fresh.body = { _ in throw Failure.transport }
        await expectFailure(Failure.transport) { _ = try await h.read() }
        #expect(h.creates == 1 && h.old.reads.isEmpty && h.fresh.reads.count == 1)
        h.source.cancelPlayback()
    }

    @Test func incompleteInitialIdentityAllowsNormalBytesButPreventsConnectionRecovery() async throws {
        let h = Harness()
        h.identity = PlaybackSourceIdentity(size: 128, modificationDate: nil, creationDate: nil)
        #expect(try await h.read() == Data(repeating: 1, count: 12))
        h.failOld()
        await expectFailure(PlaybackSourceRecoveryError.incompleteIdentity) { _ = try await h.read() }
        #expect(h.creates == 0 && h.retired.isEmpty)
    }

    @Test func firstFreshIncompleteBaselineAlsoAllowsNormalPlaybackOnly() async throws {
        let h = Harness()
        h.identity = PlaybackSourceIdentity(size: 128, modificationDate: nil, creationDate: nil)
        h.metadataBody = { session in if session === h.old { throw Failure.transport }; return h.identity }
        #expect(try await h.read() == Data(repeating: 2, count: 12))
        h.fresh.body = { _ in throw Failure.transport }
        await expectFailure(PlaybackSourceRecoveryError.incompleteIdentity) { _ = try await h.read() }
        #expect(h.creates == 1)
        h.source.cancelPlayback()
    }

    @Test func eachChangedOrMissingIdentityFieldRejectsFreshBytes() async {
        for field in 0..<5 {
            let h = Harness(); h.failOld()
            let original = h.identity
            h.metadataBody = { session in
                if session === h.old { return original }
                return PlaybackSourceIdentity(
                    size: field == 0 ? 127 : 128,
                    modificationDate: field == 1 ? Date(timeIntervalSince1970: 102) : original.modificationDate,
                    creationDate: field == 2 ? nil : original.creationDate,
                    changeDate: field == 3 ? nil : original.changeDate,
                    stableIdentifier: field == 4 ? nil : original.stableIdentifier
                )
            }
            if field == 2 { await expectFailure(PlaybackSourceRecoveryError.incompleteIdentity) { _ = try await h.read() } }
            else { await expectFailure(PlaybackSourceRecoveryError.identityChanged) { _ = try await h.read() } }
            #expect(h.creates == 1 && h.retired == [1, 2] && h.fresh.reads.isEmpty)
        }
    }

    @Test func identityChangedDuringRetryRejectsBytesAndClosesOwnedSession() async {
        let h = Harness(); h.failOld()
        let closed = Signal()
        h.retireBody = { if $0 === h.fresh { closed.send() } }
        h.fresh.body = { range in
            h.identity = PlaybackSourceIdentity(size: 128, modificationDate: Date(timeIntervalSince1970: 103), creationDate: Date(timeIntervalSince1970: 50))
            return Data(repeating: 2, count: Int(range.upperBound - range.lowerBound))
        }
        await expectFailure(PlaybackSourceRecoveryError.identityChanged) { _ = try await h.read() }
        await closed.wait()
        #expect(h.retired == [1, 2])
        await expectFailure(PlaybackSourceRecoveryError.identityChanged) { _ = try await h.read() }
    }

    @Test func shortOrOversizedDataIsNeverReturned() async {
        for count in [11, 13] {
            let h = Harness(); h.old.body = { _ in Data(repeating: 1, count: count) }
            await expectFailure(PlaybackSourceRecoveryError.invalidResponse) { _ = try await h.read() }
            #expect(h.creates == 0)
        }
        let h = Harness()
        await expectFailure(PlaybackSourceRecoveryError.invalidRange) { _ = try await h.read(0..<1_048_577) }
        #expect(h.metadataCalls.isEmpty && h.old.reads.isEmpty)
    }

    @Test func unknownAndPermissionFailuresAreNotRecovered() async {
        for failure in [Failure.denied, .unknown] {
            let h = Harness(); h.old.body = { _ in throw failure }
            await expectFailure(failure) { _ = try await h.read() }
            #expect(h.creates == 0 && h.retired.isEmpty)
        }
    }

    @Test func normalStopNeverRetiresBorrowedHealthySession() async throws {
        let h = Harness(); _ = try await h.read()
        h.source.cancelPlayback(); h.source.cancelPlayback()
        await expectCancellation { _ = try await h.read() }
        #expect(h.retired.isEmpty && h.creates == 0)
    }

    @Test func stopRetiresPrivateFreshSessionExactlyOnce() async throws {
        let h = Harness(); h.failOld(); _ = try await h.read()
        let closed = Signal(); h.retireBody = { if $0 === h.fresh { closed.send() } }
        h.source.cancelPlayback(); h.source.cancelPlayback()
        await closed.wait()
        #expect(h.retired == [1, 2])
    }

    @Test func inactiveWaitHasNoNetworkWorkAndResumesOnlyWhenActive() async throws {
        let h = Harness(); h.failOld(); h.source.setPlaybackSceneActive(false)
        let waiting = Signal(); h.stageBody = { if $0 == .waitingForActive { waiting.send() } }
        let task = Task { @MainActor in try await h.read() }
        await waiting.wait()
        #expect(h.creates == 0 && h.retired.isEmpty && h.source.isPlaybackRecovering)
        #expect(h.source.recoveryActiveStartedAt == nil)
        h.source.setPlaybackSceneActive(true)
        #expect(try await task.value == Data(repeating: 2, count: 12))
    }

    @Test func lastWaitingCallerCancellationPreventsConnectAndReturnsWithoutForeground() async {
        let h = Harness(); h.failOld(); h.source.setPlaybackSceneActive(false)
        let waiting = Signal(); h.stageBody = { if $0 == .waitingForActive { waiting.send() } }
        let task = Task { @MainActor in try await h.read() }
        await waiting.wait(); task.cancel()
        await expectCancellation { _ = try await task.value }
        h.source.setPlaybackSceneActive(true)
        #expect(h.creates == 0 && h.retired.isEmpty && !h.source.isPlaybackRecovering)
        try? await h.source.awaitPlaybackCleanup()
    }

    @Test func oneCancelledWaiterDoesNotCancelOtherLiveCaller() async throws {
        let h = Harness(); h.failOld(); h.source.setPlaybackSceneActive(false)
        let waiting = Signal(); h.stageBody = { if $0 == .waitingForActive { waiting.send() } }
        let first = Task { @MainActor in try await h.read() }
        await waiting.wait()
        let secondEntered = Signal()
        let second = Task { @MainActor in secondEntered.send(); return try await h.read(40..<44) }
        await secondEntered.wait()
        first.cancel()
        await expectCancellation { _ = try await first.value }
        h.source.setPlaybackSceneActive(true)
        #expect(try await second.value == Data(repeating: 2, count: 4))
        #expect(h.creates == 1 && h.retired == [1])
    }

    @Test func cancellationDuringRetireFinishesDrainButCannotConnect() async {
        let h = Harness(); h.failOld(); let drain = Completion<Void>(), retired = Signal()
        h.retireBody = { _ in try await drain.wait() }
        h.stageBody = { if $0 == .oldRetired { retired.send() } }
        let task = Task { @MainActor in try await h.read() }
        await drain.waitUntilEntered(); task.cancel()
        await expectCancellation { _ = try await task.value }
        #expect(h.creates == 0)
        drain.complete(()); await retired.wait()
        #expect(h.retired == [1] && h.creates == 0)
        try? await h.source.awaitPlaybackCleanup()
    }

    @Test func stopDuringConnectDiscardsAndRetiresReturnedCandidate() async {
        let h = Harness(); h.failOld(); let connect = Completion<Session>(), closed = Signal()
        h.makeBody = { try await connect.wait() }
        h.retireBody = { if $0 === h.fresh { closed.send() } }
        let task = Task { @MainActor in try await h.read() }
        await connect.waitUntilEntered(); h.source.cancelPlayback()
        await expectCancellation { _ = try await task.value }
        connect.complete(h.fresh); await closed.wait()
        #expect(h.creates == 1 && h.retired == [1, 2] && h.fresh.reads.isEmpty)
    }

    @Test func staleGenerationDuringRetryCannotPublishBytes() async {
        let h = Harness(); h.failOld(); let bytes = Completion<Data>(), closed = Signal()
        h.fresh.body = { _ in try await bytes.wait() }
        h.retireBody = { if $0 === h.fresh { closed.send() } }
        let task = Task { @MainActor in try await h.read() }
        await bytes.waitUntilEntered(); h.current = false
        bytes.complete(Data(repeating: 2, count: 12))
        await expectCancellation { _ = try await task.value }; await closed.wait()
        #expect(!h.stages.contains(.returned) && h.retired == [1, 2])
    }

    @Test func lateOldFailureCannotRetireNewSessionOrStartAnotherEpisode() async throws {
        let h = Harness(); let oldRead = Completion<Data>()
        h.old.body = { range in if range == 1..<3 { return try await oldRead.wait() }; throw Failure.transport }
        let late = Task { @MainActor in try await h.read(1..<3) }
        await oldRead.waitUntilEntered()
        _ = try await h.read()
        oldRead.fail(Failure.transport)
        #expect(try await late.value == Data(repeating: 2, count: 2))
        #expect(h.creates == 1 && h.retired == [1])
    }

    @Test func retirementFailureIsTerminalAndNeverConnects() async {
        let h = Harness(); h.failOld(); h.retireBody = { _ in throw Failure.cleanup }
        await expectFailure(Failure.cleanup) { _ = try await h.read() }
        await expectFailure(Failure.cleanup) { _ = try await h.read() }
        #expect(h.creates == 0 && h.retired == [1])
    }

    @Test func activeBudgetAccumulatesAcrossInactiveIntervalsAndRejectsLatePublication() async {
        let h = Harness(); h.failOld(); let connect = Completion<Session>(), closed = Signal()
        h.makeBody = { try await connect.wait() }
        h.retireBody = { if $0 === h.fresh { closed.send() } }
        let task = Task { @MainActor in try await h.read() }
        await connect.waitUntilEntered()
        h.clock = 120; h.source.setPlaybackSceneActive(false)
        #expect(h.source.recoveryActiveElapsed == 20 && h.source.recoveryActiveStartedAt == nil)
        h.clock = 500; h.source.setPlaybackSceneActive(true)
        #expect(h.source.recoveryActiveStartedAt == 480)
        h.clock = 526; connect.complete(h.fresh)
        await expectFailure(PlaybackSourceRecoveryError.recoveryTimedOut) { _ = try await task.value }
        await closed.wait()
        #expect(h.retired == [1, 2] && h.fresh.reads.isEmpty)
    }

    @Test func recoveryDiagnosticsAreDurableNumericAndCorrelatedOnlyByAnonymousTrace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VistaSourceRecoveryTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LifecycleDiagnostics(directory: directory, build: "66", mirror: false)
        defer { store.drainForTesting() }
        let file = try MediaFile(components: ["PRIVATE-diagnostic-folder", "PRIVATE-diagnostic-movie.mp4"])
        let fingerprint = PlaybackSourceIdentity(
            size: 9_876_543_234,
            modificationDate: Date(timeIntervalSince1970: 123_456_789),
            creationDate: Date(timeIntervalSince1970: 123_450_000),
            changeDate: Date(timeIntervalSince1970: 123_456_799),
            stableIdentifier: "PRIVATE-stable-identifier"
        )
        func records() throws -> [LifecycleRecord] {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("critical-") }
                .flatMap { try Data(contentsOf: $0).split(separator: 10).map { try JSONDecoder().decode(LifecycleRecord.self, from: Data($0)) } }
                .filter { $0.event == .playbackSourceRecovery }
                .sorted { $0.sequence < $1.sequence }
        }
        @MainActor func source(_ old: Session, _ fresh: Session, closed: Signal) -> PlaybackRecoveringSource<Session> {
            old.body = { _ in throw Failure.transport }
            return PlaybackRecoveringSource(
                file: file, initial: old, metadata: { _, _ in fingerprint },
                makeFresh: { fresh }, retire: { _ in },
                shouldRecover: { ($0 as? Failure) == .transport }, isCurrent: { true },
                diagnostics: store, onRecoveryStage: { if $0 == .ownedRetired { closed.send() } }
            )
        }
        let firstClosed = Signal(), secondClosed = Signal()
        let first = source(Session(1), Session(2), closed: firstClosed)
        let second = source(Session(3), Session(4), closed: secondClosed)
        _ = try await first.read(file, range: 19..<31)
        // No timeline drain: each recovery boundary must already have its critical copy.
        let firstRecords = try records()
        let firstTrace = try #require(firstRecords.first?.fields["trace"])
        #expect(firstTrace > 0 && firstRecords.count > 1)
        #expect(firstRecords.allSatisfy { $0.fields["trace"] == firstTrace })
        _ = try await second.read(file, range: 19..<31)
        let both = try records()
        let secondRecords = Array(both.dropFirst(firstRecords.count))
        let secondTrace = try #require(secondRecords.first?.fields["trace"])
        #expect(secondTrace > 0 && secondTrace != firstTrace && secondRecords.count > 1)
        #expect(secondRecords.allSatisfy { $0.fields["trace"] == secondTrace })

        store.withPausedWriterForTesting {
            first.cancelPlayback()
            // The async timeline is paused; this cancellation record still exists immediately.
            let cancellation = try? records().last
            #expect(cancellation?.fields["phase"] == Double(PlaybackSourceRecoveryStage.cancelled.rawValue))
            #expect(cancellation?.fields["trace"] == firstTrace)
        }
        second.cancelPlayback()
        await firstClosed.wait(); await secondClosed.wait()
        let complete = try records()
        let allowed: Set<String> = ["trace", "phase", "generation", "epoch", "active", "cancelled"]
        #expect(complete.allSatisfy { Set($0.fields.keys) == allowed })
        #expect(complete.allSatisfy { $0.fields.values.allSatisfy { $0.isFinite && abs($0) <= 9_007_199_254_740_991 } })
        #expect(Set(complete.compactMap { $0.fields["trace"] }) == [firstTrace, secondTrace])
        #expect(store.status.syncWrites == UInt64(complete.count + 1) && store.status.syncFailures == 0)
        let encoded = try JSONEncoder().encode(complete)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        #expect(json.allSatisfy { ($0["fields"] as? [String: Any])?.values.allSatisfy { $0 is NSNumber } == true })
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("PRIVATE"))
        let privateNumbers: Set<Double> = [Double(fingerprint.size), 123_456_789, 123_450_000, 123_456_799]
        #expect(complete.allSatisfy { Set($0.fields.values).isDisjoint(with: privateNumbers) })
    }


    @Test func pendingOldSuccessOrTypedRetirementJoinsExistingEpisodeWithoutNewConnect() async throws {
        for retiredResponse in [false, true] {
            let h = Harness(), oldRead = Completion<Data>(), drain = Completion<Void>()
            h.old.body = { range in
                if range == 1..<3 { return try await oldRead.wait() }
                throw Failure.transport
            }
            h.retireBody = { session in if session === h.old { try await drain.wait() } }
            let older = Task { @MainActor in try await h.read(1..<3) }
            await oldRead.waitUntilEntered()
            let recovery = Task { @MainActor in try await h.read() }
            await drain.waitUntilEntered()
            if retiredResponse { oldRead.fail(Failure.retired) } else { oldRead.complete(Data(repeating: 1, count: 2)) }
            drain.complete(())
            #expect(try await older.value == Data(repeating: 2, count: 2))
            #expect(try await recovery.value == Data(repeating: 2, count: 12))
            #expect(h.creates == 1 && h.retired == [1])
            try await h.source.awaitPlaybackCleanup()
        }
    }

    @Test func oldSuccessAndRetirementCanJoinAlreadyCompletedEpisodeButNotHideDenial() async throws {
        for outcome in 0..<3 {
            let h = Harness(), oldRead = Completion<Data>()
            h.old.body = { range in
                if range == 1..<3 { return try await oldRead.wait() }
                throw Failure.transport
            }
            let older = Task { @MainActor in try await h.read(1..<3) }
            await oldRead.waitUntilEntered()
            _ = try await h.read()
            if outcome == 0 { oldRead.complete(Data(repeating: 1, count: 2)) }
            else { oldRead.fail(outcome == 1 ? Failure.retired : Failure.denied) }
            if outcome == 2 { await expectFailure(Failure.denied) { _ = try await older.value } }
            else { #expect(try await older.value == Data(repeating: 2, count: 2)) }
            #expect(h.creates == 1 && h.retired == [1])
            try await h.source.awaitPlaybackCleanup()
        }
    }

    @Test func oldCallbackReceivesExistingEpisodeFailureWithoutStartingAgain() async {
        let h = Harness(), oldRead = Completion<Data>()
        h.old.body = { range in
            if range == 1..<3 { return try await oldRead.wait() }
            throw Failure.transport
        }
        h.makeBody = { throw Failure.connect }
        let older = Task { @MainActor in try await h.read(1..<3) }
        await oldRead.waitUntilEntered()
        await expectFailure(Failure.connect) { _ = try await h.read() }
        oldRead.fail(Failure.retired)
        await expectFailure(Failure.connect) { _ = try await older.value }
        #expect(h.creates == 1 && h.retired == [1])
        try? await h.source.awaitPlaybackCleanup()
    }

    @Test func ordinaryRetirementWithoutExistingEpisodeDoesNotConnect() async {
        let h = Harness(); h.old.body = { _ in throw Failure.retired }
        await expectFailure(Failure.retired) { _ = try await h.read() }
        #expect(h.creates == 0 && h.retired.isEmpty)
    }

    @Test func cancelledOldCallbackCannotJoinRecoveryOrPublishBytes() async throws {
        let h = Harness(), oldRead = Completion<Data>()
        h.old.body = { range in
            if range == 1..<3 { return try await oldRead.wait() }
            throw Failure.transport
        }
        let older = Task { @MainActor in try await h.read(1..<3) }
        await oldRead.waitUntilEntered()
        _ = try await h.read()
        older.cancel(); oldRead.complete(Data(repeating: 1, count: 2))
        await expectCancellation { _ = try await older.value }
        #expect(h.fresh.reads == [19..<31] && h.creates == 1)
        try await h.source.awaitPlaybackCleanup()
    }

    @Test func lastWaiterSeekCancellationThenNewDemandContinuesSameParkedEpisode() async throws {
        let h = Harness(); h.failOld(); h.source.setPlaybackSceneActive(false)
        let waiting = Signal(); h.stageBody = { if $0 == .waitingForActive { waiting.send() } }
        let cancelled = Task { @MainActor in try await h.read() }
        await waiting.wait(); cancelled.cancel()
        await expectCancellation { _ = try await cancelled.value }
        h.clock = 10_000; h.source.setPlaybackSceneActive(true)
        #expect(!h.source.isPlaybackRecovering && h.source.recoveryActiveElapsed == 0)
        #expect(try await h.read(50..<54) == Data(repeating: 2, count: 4))
        #expect(h.creates == 1 && h.retired == [1])
        #expect(h.stages.filter { $0 == .started }.count == 1)
        try await h.source.awaitPlaybackCleanup()
    }

    @Test func newDemandAfterCancelledDrainWaitsForThatDrainAndPreservesSpentBudget() async throws {
        let h = Harness(); h.failOld(); let drain = Completion<Void>()
        h.retireBody = { session in if session === h.old { try await drain.wait() } }
        let cancelled = Task { @MainActor in try await h.read() }
        await drain.waitUntilEntered(); h.clock = 112; cancelled.cancel()
        await expectCancellation { _ = try await cancelled.value }
        #expect(h.source.recoveryActiveElapsed == 12)
        h.clock = 10_000
        let newEntered = Signal()
        let newer = Task { @MainActor in newEntered.send(); return try await h.read(50..<54) }
        await newEntered.wait()
        #expect(h.creates == 0 && h.retired == [1])
        #expect(h.source.recoveryActiveElapsed == 12)
        drain.complete(())
        #expect(try await newer.value == Data(repeating: 2, count: 4))
        #expect(h.creates == 1 && h.stages.filter { $0 == .started }.count == 1)
        try await h.source.awaitPlaybackCleanup()
    }

    @Test func cancelledConnectCanParkPrivateCandidateUntilNewDemandWithoutSecondConnect() async throws {
        let h = Harness(); h.failOld(); let connect = Completion<Session>(), connected = Signal()
        h.makeBody = { try await connect.wait() }
        h.stageBody = { if $0 == .connected { connected.send() } }
        let cancelled = Task { @MainActor in try await h.read() }
        await connect.waitUntilEntered(); cancelled.cancel()
        await expectCancellation { _ = try await cancelled.value }
        connect.complete(h.fresh); await connected.wait()
        #expect(h.metadataCalls == [1] && h.fresh.reads.isEmpty && h.creates == 1)
        #expect(try await h.read(50..<54) == Data(repeating: 2, count: 4))
        #expect(h.creates == 1 && h.retired == [1])
        try await h.source.awaitPlaybackCleanup()
    }

    @Test func cleanupBarrierWaitsForOwnedDrainAndKeepsItsFailureTerminal() async throws {
        let h = Harness(); h.failOld(); _ = try await h.read()
        let drain = Completion<Void>()
        h.retireBody = { session in if session === h.fresh { try await drain.wait() } }
        h.source.cancelPlayback()
        var barrierReturned = false
        let cleanup = Task { @MainActor in try await h.source.awaitPlaybackCleanup(); barrierReturned = true }
        await drain.waitUntilEntered()
        #expect(!barrierReturned && h.retired == [1, 2])
        drain.fail(Failure.cleanup)
        await expectFailure(Failure.cleanup) { try await cleanup.value }
        await expectFailure(Failure.cleanup) { try await h.source.awaitPlaybackCleanup() }
        #expect(!barrierReturned && h.retired == [1, 2])
    }

    @Test func cleanupBarrierWaitsForLateConnectCandidateAndParkedDemandStop() async throws {
        let h = Harness(); h.failOld(); let connect = Completion<Session>(), drain = Completion<Void>()
        h.makeBody = { try await connect.wait() }
        h.retireBody = { session in if session === h.fresh { try await drain.wait() } }
        let request = Task { @MainActor in try await h.read() }
        await connect.waitUntilEntered(); h.source.cancelPlayback()
        var barrierReturned = false
        let cleanup = Task { @MainActor in try await h.source.awaitPlaybackCleanup(); barrierReturned = true }
        await expectCancellation { _ = try await request.value }
        connect.complete(h.fresh); await drain.waitUntilEntered()
        #expect(!barrierReturned && h.retired == [1, 2])
        drain.complete(()); try await cleanup.value
        #expect(barrierReturned)

        let parked = Harness(); parked.failOld(); parked.source.setPlaybackSceneActive(false)
        let waiting = Signal(); parked.stageBody = { if $0 == .waitingForActive { waiting.send() } }
        let cancelled = Task { @MainActor in try await parked.read() }
        await waiting.wait(); cancelled.cancel()
        await expectCancellation { _ = try await cancelled.value }
        try await parked.source.awaitPlaybackCleanup()
        #expect(parked.creates == 0 && parked.retired.isEmpty)
    }


    @Test func firstMetadataFallbackCannotPublishSizeOrStartHeaderReadWhileInactive() async throws {
        let h = Harness(), freshMetadata = Completion<PlaybackSourceIdentity>(), waiting = Signal()
        h.metadataBody = { session in
            if session === h.old { throw Failure.transport }
            return try await freshMetadata.wait()
        }
        h.stageBody = { if $0 == .waitingForActive { waiting.send() } }
        var sizeDelivered = false, bytesDelivered = false
        let task = Task { @MainActor in
            let size = try await h.source.fileSize(for: h.file)
            sizeDelivered = true
            let bytes = try await h.source.read(h.file, range: 0..<min(size, 12))
            bytesDelivered = true
            return bytes
        }
        await freshMetadata.waitUntilEntered()
        h.source.setPlaybackSceneActive(false)
        freshMetadata.complete(h.identity)
        await waiting.wait()
        #expect(!sizeDelivered && !bytesDelivered && h.fresh.reads.isEmpty)
        #expect(h.source.isPlaybackRecovering && !h.stages.contains(.identityAccepted))
        h.source.setPlaybackSceneActive(true)
        #expect(try await task.value == Data(repeating: 2, count: 12))
        #expect(sizeDelivered && bytesDelivered && h.creates == 1 && h.fresh.reads == [0..<12])
        try await h.source.awaitPlaybackCleanup()
    }

    @Test func recoveredRangeMetadataReturningInactiveWaitsBeforePublishingBytes() async throws {
        let h = Harness(), afterReadMetadata = Completion<PlaybackSourceIdentity>(), waiting = Signal()
        h.failOld()
        var freshMetadataCount = 0
        h.metadataBody = { session in
            if session === h.fresh {
                freshMetadataCount += 1
                if freshMetadataCount == 2 { return try await afterReadMetadata.wait() }
            }
            return h.identity
        }
        h.stageBody = { if $0 == .waitingForActive { waiting.send() } }
        var bytesDelivered = false
        let task = Task { @MainActor in
            let bytes = try await h.read()
            bytesDelivered = true
            return bytes
        }
        await afterReadMetadata.waitUntilEntered()
        h.source.setPlaybackSceneActive(false)
        afterReadMetadata.complete(h.identity)
        await waiting.wait()
        #expect(!bytesDelivered && h.source.isPlaybackRecovering && !h.stages.contains(.returned))
        #expect(h.fresh.reads == [19..<31] && freshMetadataCount == 2)
        h.clock = 10_000 // Background duration is not a new grace budget or active timeout.
        h.source.setPlaybackSceneActive(true)
        #expect(try await task.value == Data(repeating: 2, count: 12))
        #expect(bytesDelivered && h.creates == 1 && h.stages.contains(.returned))
        try await h.source.awaitPlaybackCleanup()
    }

}
