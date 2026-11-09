import Foundation
import Testing
@testable import AMSMB2
@testable import VistaCore
@testable import VistaSMB

private func persistentAttributes(_ identity: UInt64 = 41) -> [URLResourceKey: any Sendable] {
    [.fileResourceTypeKey: URLFileResourceType.regular,
     .fileSizeKey: NSNumber(value: UInt64(8_000_000_000)),
     .contentModificationDateKey: Date(timeIntervalSince1970: 1_700_000_000),
     .attributeModificationDateKey: Date(timeIntervalSince1970: 1_700_000_001),
     .creationDateKey: Date(timeIntervalSince1970: 1_600_000_000),
     .documentIdentifierKey: NSNumber(value: identity)]
}

/// Explicit suspension only; no socket, NAS, media file, timer or library operation.
private actor PersistentGate {
    var started = false, released = false
    var startWaiter: CheckedContinuation<Void, Never>?
    var completion: CheckedContinuation<Void, Never>?
    func enter() async {
        started = true; startWaiter?.resume(); startWaiter = nil
        if released { return }
        await withCheckedContinuation { completion = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { released = true; completion?.resume(); completion = nil }
}

private actor PersistentHandleFixture: SMB2ReadOnlyHandle {
    let gate: PersistentGate?
    let identity: UInt64
    let readFailure: (any Error)?
    var invalidated = false
    var attributesCalls = 0, closeCalls = 0
    var ranges: [Range<UInt64>] = []
    var events: [String] = []
    init(identity: UInt64 = 41, gate: PersistentGate? = nil, readFailure: (any Error)? = nil) {
        self.identity = identity; self.gate = gate; self.readFailure = readFailure
    }
    func invalidate() { invalidated = true }
    func attributes() async throws -> [URLResourceKey: any Sendable] {
        attributesCalls += 1; events.append("metadata")
        return persistentAttributes(identity)
    }
    func read(range: Range<UInt64>) async throws -> Data {
        ranges.append(range); events.append("read-start")
        await gate?.enter()
        events.append("read-end")
        if let readFailure { throw readFailure }
        return Data(range.map { UInt8(truncatingIfNeeded: $0) })
    }
    func close() async throws {
        closeCalls += 1; events.append("close")
        if invalidated { throw SMB2OperationFailure(origin: .contextUnavailable, posixCode: ENOTCONN) }
    }
}

private actor PersistentManagerState {
    var opens = 0, pathAttributes = 0, legacyReads = 0, localRetires = 0
    var handles: [PersistentHandleFixture] = []
    func open(_ handle: PersistentHandleFixture) { opens += 1; handles.append(handle) }
    func pathStat() { pathAttributes += 1 }
    func legacyRead() { legacyReads += 1 }
    func retired() { localRetires += 1 }
}

/// Every called SMB operation is replaced. The manager never connects.
private final class PersistentManagerFixture: SMB2Manager, @unchecked Sendable {
    let state = PersistentManagerState()
    let openFailure: (any Error)?
    let openGate: PersistentGate?
    let readGate: PersistentGate?
    let readFailure: (any Error)?
    let identity: UInt64
    init(openFailure: (any Error)? = nil, openGate: PersistentGate? = nil,
         readGate: PersistentGate? = nil, identity: UInt64 = 41, readFailure: (any Error)? = nil) {
        self.openFailure = openFailure; self.openGate = openGate
        self.readGate = readGate; self.identity = identity; self.readFailure = readFailure
        super.init(url: URL(string: "smb://synthetic.invalid")!, credential: nil)!
    }
    required init(from decoder: any Decoder) throws { fatalError("No persisted fixture") }
    required init?(coder: NSCoder) { fatalError("No persisted fixture") }
    override func openReadOnlyHandle(atPath path: String) async throws -> any SMB2ReadOnlyHandle {
        let handle = PersistentHandleFixture(identity: identity, gate: readGate, readFailure: readFailure)
        await state.open(handle)
        await openGate?.enter()
        if let openFailure { throw openFailure }
        return handle
    }
    override func attributesOfItem(atPath path: String) async throws -> [URLResourceKey: any Sendable] {
        await state.pathStat(); return persistentAttributes(identity)
    }
    override func contents<R: RangeExpression>(atPath path: String, range: R? = Range<UInt64>?.none,
        progress: ReadProgressHandler = nil) async throws -> Data where R.Bound: FixedWidthInteger {
        await state.legacyRead(); return Data([0, 1, 2, 3])
    }
    override func retireLocallyAfterDraining() async {
        await state.retired()
        for handle in await state.handles { await handle.invalidate() }
    }
}

@Suite(.serialized) struct SMBPersistentPlaybackTests {
    private func provider(_ manager: PersistentManagerFixture) -> SMBDirectoryProvider {
        let diagnostics = LifecycleDiagnostics(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("vista-persistent-fixture-\(UUID().uuidString)"),
            mirror: false, criticalDurability: false)
        return SMBDirectoryProvider(manager: manager, diagnostics: diagnostics, session: 1)
    }
    private func file(_ name: String = "synthetic.mp4") throws -> MediaFile { try MediaFile(components: [name]) }

    @Test func playbackReusesHandleAndNormalStopPreservesBrowser() async throws {
        let manager = PersistentManagerFixture(), browser = provider(manager)
        let movie = try file(), session = SMBPlaybackSession(provider: browser)
        #expect(try await session.metadata(for: movie).stableIdentifier == "41")
        for offset: UInt64 in [0, 4, 8, 4_294_967_299] {
            #expect(try await session.read(movie, range: offset..<(offset + 4)) == Data((offset..<(offset + 4)).map { UInt8(truncatingIfNeeded: $0) }))
        }
        let handle = try #require(await manager.state.handles.first)
        #expect(await manager.state.opens == 1)
        #expect(await manager.state.pathAttributes == 0)
        #expect(await handle.attributesCalls == 1)
        #expect(await handle.ranges.count == 4)
        await #expect(throws: SMBPlaybackReadFailure.invalidRange) { try await session.read(file("other.mp4"), range: 0..<4) }
        try await session.finishPlayback(); try await session.finishPlayback()
        #expect(await handle.closeCalls == 1)
        #expect(await manager.state.localRetires == 0)
        #expect(try await browser.fileSize(for: movie) == 8_000_000_000)
        let second = SMBPlaybackSession(provider: browser)
        #expect(try await second.fileSize(for: movie) == 8_000_000_000)
        #expect(await manager.state.opens == 2)
        try await second.finishPlayback()
    }

    @Test func unsupportedCapabilityUsesOriginalRangePathWithoutRestrictiveHandle() async throws {
        let manager = PersistentManagerFixture(openFailure: SMB2ReadOnlyHandleError.unsupportedCapability)
        let session = SMBPlaybackSession(provider: provider(manager)), movie = try file()
        #expect(try await session.fileSize(for: movie) == 8_000_000_000)
        #expect(try await session.read(movie, range: 0..<4) == Data([0, 1, 2, 3]))
        #expect(try await session.read(movie, range: 4..<8) == Data([0, 1, 2, 3]))
        #expect(await manager.state.opens == 1)
        #expect(await manager.state.pathAttributes == 1)
        #expect(await manager.state.legacyReads == 2)
        try await session.finishPlayback()
    }

    @Test func permissionAndTransportErrorsNeverBecomeCapabilityFallback() async throws {
        for failure in [SMB2OperationFailure(origin: .response, posixCode: EACCES),
                        SMB2OperationFailure(origin: .contextUnavailable)] {
            let manager = PersistentManagerFixture(openFailure: failure)
            let session = SMBPlaybackSession(provider: provider(manager)), movie = try file()
            do { _ = try await session.fileSize(for: movie); Issue.record("Unexpected success") } catch {}
            do { _ = try await session.fileSize(for: movie); Issue.record("Unexpected retry") } catch {}
            #expect(await manager.state.opens == 1)
            #expect(await manager.state.pathAttributes == 0)
            #expect(await manager.state.legacyReads == 0)
            try await session.retireForPlaybackRecovery()
        }
    }

    @Test func cancellationAndSeekDrainOldReadWithoutReopening() async throws {
        let gate = PersistentGate(), manager = PersistentManagerFixture(readGate: gate)
        let session = SMBPlaybackSession(provider: provider(manager)), movie = try file()
        _ = try await session.fileSize(for: movie)
        let old = Task { try await session.read(movie, range: 0..<4) }
        await gate.waitUntilStarted(); old.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(try await session.read(movie, range: 100..<104) == Data([100, 101, 102, 103]))
        #expect(await manager.state.opens == 1)
        try await session.finishPlayback()
    }

    @Test func stopDuringOpenOrReadClosesOnlyAfterRealCompletion() async throws {
        for blockOpen in [true, false] {
            let gate = PersistentGate()
            let manager = PersistentManagerFixture(openGate: blockOpen ? gate : nil, readGate: blockOpen ? nil : gate)
            let session = SMBPlaybackSession(provider: provider(manager)), movie = try file()
            let pending = Task { try await session.read(movie, range: 0..<4) }
            await gate.waitUntilStarted(); pending.cancel()
            let finish = Task { try await session.finishPlayback() }
            let handle = try #require(await manager.state.handles.first)
            #expect(await handle.closeCalls == 0)
            await gate.release()
            await #expect(throws: CancellationError.self) { try await pending.value }
            try await finish.value
            #expect(await handle.closeCalls == 1)
            #expect(await manager.state.localRetires == 0)
        }
    }

    @MainActor @Test func recoveryWrapperNormalStopClosesBorrowedFileAndJoinsOnce() async throws {
        let manager = PersistentManagerFixture(), browser = provider(manager), movie = try file()
        let session = SMBPlaybackSession(provider: browser)
        let source = PlaybackRecoveringSource(file: movie, initial: session,
            metadata: { try await $0.metadata(for: $1) }, makeFresh: { throw PlaybackSourceRecoveryError.unavailable },
            retire: { try await $0.retireForPlaybackRecovery() }, finish: { try await $0.finishPlayback() },
            shouldRecover: { SMBPlaybackSession.recoveryDisposition(for: $0).allowsFreshRecovery }, isCurrent: { true }, diagnostics: nil)
        _ = try await source.fileSize(for: movie)
        source.cancelPlayback()
        try await source.awaitPlaybackCleanup(); try await source.awaitPlaybackCleanup()
        #expect(await manager.state.localRetires == 0)
        let handle = try #require(await manager.state.handles.first)
        #expect(await handle.closeCalls == 1)
        #expect(try await browser.fileSize(for: movie) == 8_000_000_000)
    }

    @MainActor @Test func backgroundRecoveryReopensFreshHandleAndChecksIdentity() async throws {
        for freshIdentity: UInt64 in [41, 99] {
            let oldManager = PersistentManagerFixture(readFailure: SMB2OperationFailure(origin: .serviceInvalidated, result: -1))
            let freshManager = PersistentManagerFixture(identity: freshIdentity)
            let movie = try file(), initial = SMBPlaybackSession(provider: provider(oldManager))
            let fresh = SMBPlaybackSession(provider: provider(freshManager))
            var connects = 0, awaitingForeground = false
            let source = PlaybackRecoveringSource(file: movie, initial: initial,
                metadata: { try await $0.metadata(for: $1) }, makeFresh: { connects += 1; return fresh },
                retire: { try await $0.retireForPlaybackRecovery() }, finish: { try await $0.finishPlayback() },
                shouldRecover: { SMBPlaybackSession.recoveryDisposition(for: $0).allowsFreshRecovery },
                isCurrent: { true }, diagnostics: nil,
                onRecoveryStage: { if $0 == .waitingForActive { awaitingForeground = true } })
            _ = try await source.fileSize(for: movie)
            source.setPlaybackSceneActive(false)
            let pending = Task { try await source.read(movie, range: 0..<4) }
            defer { pending.cancel(); source.cancelPlayback() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !awaitingForeground, ContinuousClock.now < deadline { await Task.yield() }
            try #require(awaitingForeground)
            let backgroundHandle = try #require(await oldManager.state.handles.first)
            #expect(connects == 0 && !source.isPlaybackRecovering)
            #expect(await backgroundHandle.ranges.isEmpty)
            #expect(await backgroundHandle.attributesCalls == 1)
            #expect(await oldManager.state.localRetires == 0)
            #expect(await freshManager.state.opens == 0)
            source.setPlaybackSceneActive(true)
            if freshIdentity == 41 {
                #expect(try await pending.value == Data([0, 1, 2, 3]))
                let handle = try #require(await freshManager.state.handles.first)
                #expect(await handle.attributesCalls == 2) // pre- and post-retry same-handle metadata
                #expect(await handle.ranges == [0..<4])
            } else {
                await #expect(throws: PlaybackSourceRecoveryError.identityChanged) { try await pending.value }
                let handle = try #require(await freshManager.state.handles.first)
                #expect(await handle.ranges.isEmpty)
            }
            #expect(connects == 1)
            #expect(await oldManager.state.localRetires == 1)
            let oldHandle = try #require(await oldManager.state.handles.first)
            // Initial metadata plus one fresh foreground stat before the failed read.
            #expect(await oldHandle.attributesCalls == 2)
            #expect(await oldHandle.ranges == [0..<4])
            #expect(await oldHandle.closeCalls == 1) // local abandonment does not block recovery
            try await source.awaitPlaybackCleanup()
            #expect(await freshManager.state.localRetires == 1)
        }
    }

}
