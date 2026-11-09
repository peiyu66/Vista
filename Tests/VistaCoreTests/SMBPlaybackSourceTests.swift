import Foundation
import Testing
@testable import AMSMB2
@testable import VistaCore
@testable import VistaSMB

private func playbackAttributes() -> [URLResourceKey: any Sendable] {
    [.fileResourceTypeKey: URLFileResourceType.regular,
     .fileSizeKey: NSNumber(value: UInt64(8_000_000_000)),
     .contentModificationDateKey: Date(timeIntervalSince1970: 1_700_000_000),
     .attributeModificationDateKey: Date(timeIntervalSince1970: 1_700_000_001),
     .creationDateKey: Date(timeIntervalSince1970: 1_600_000_000),
     .documentIdentifierKey: NSNumber(value: UInt64.max)]
}

/// Sequential in-memory transport. No library manager, socket, file or remote request.
private actor PlaybackRangeFixture: SMBRangeTransport {
    let metadata: Result<[URLResourceKey: any Sendable], any Error>
    let bytes: Result<Data, any Error>
    var attributeCalls = 0
    var ranges: [Range<UInt64>] = []
    init(metadata: Result<[URLResourceKey: any Sendable], any Error> = .success(playbackAttributes()),
         bytes: Result<Data, any Error> = .success(Data([1, 2, 3, 4]))) {
        self.metadata = metadata; self.bytes = bytes
    }
    func attributes(at path: String) async throws -> [URLResourceKey: any Sendable] {
        attributeCalls += 1
        return try metadata.get()
    }
    func read(at path: String, range: Range<UInt64>) async throws -> Data {
        ranges.append(range)
        return try bytes.get()
    }
}

private actor PlaybackManagerState {
    var localRetires = 0, normalDisconnects = 0, drained = false
    var normalFailure: (any Error)?
    func beginLocal() { localRetires += 1 }
    func beginNormal() { normalDisconnects += 1 }
    func finishDrain() { drained = true }
    func failNormal(with error: any Error) { normalFailure = error }
}

/// Overrides every operation used here. The barrier is a manually released in-memory gate,
/// not the real library queue. Tests assert ordering, not SMB concurrency or NAS behavior.
private final class PlaybackManagerFixture: SMB2Manager, @unchecked Sendable {
    let state = PlaybackManagerState()
    let queueDrain = SMBOperationLeases()

    override func openReadOnlyHandle(atPath path: String) async throws -> any SMB2ReadOnlyHandle {
        throw SMB2ReadOnlyHandleError.unsupportedCapability
    }
    override func attributesOfItem(atPath path: String) async throws -> [URLResourceKey: any Sendable] {
        playbackAttributes()
    }
    override func contents<R: RangeExpression>(atPath path: String, range: R? = Range<UInt64>?.none,
        progress: ReadProgressHandler = nil) async throws -> Data where R.Bound: FixedWidthInteger {
        throw SMB2OperationFailure(origin: .serviceInvalidated, result: -1)
    }
    override func contentsOfDirectory(atPath path: String, recursive: Bool = false,
        completionHandler: @Sendable @escaping (Result<[[URLResourceKey: any Sendable]], any Error>) -> Void) {
        completionHandler(.failure(SMBDirectoryReadFailure.serverRejected))
    }
    override func retireLocallyAfterDraining() async {
        await state.beginLocal()
        await queueDrain.waitForDrain()
        await state.finishDrain()
    }
    override func disconnectShare(gracefully: Bool = false) async throws {
        await state.beginNormal()
        await queueDrain.waitForDrain()
        if let failure = await state.normalFailure { throw failure }
        await state.finishDrain()
    }
}

@Suite(.serialized)
struct SMBPlaybackSourceTests {
    private func diagnostics() -> LifecycleDiagnostics {
        LifecycleDiagnostics(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("vista-playback-adapter-\(UUID().uuidString)"),
            mirror: false, criticalDurability: false)
    }

    @Test func playbackEligibilityRequiresConfirmedRecoverableOrigin() {
        let recoverable: [(any Error, SMBPlaybackReadFailure)] = [
            (SMB2OperationFailure(origin: .serviceInvalidated, result: -1), .serviceInvalidated),
            (SMB2OperationFailure(origin: .contextUnavailable), .contextUnavailable),
            (SMB2OperationFailure(origin: .wait, posixCode: ECONNRESET), .transportFailure),
            (SMB2OperationFailure(origin: .response, ntStatus: 0xC0000203), .contextUnavailable),
            (URLError(.networkConnectionLost), .transportFailure),
            (SMBDirectoryReadFailure.retiredByPlaybackRecovery, .retiredByPlaybackRecovery)
        ]
        for (original, expected) in recoverable {
            let result = SMBPlaybackSession.recoveryDisposition(for: original)
            #expect(result == expected)
            #expect(result.allowsFreshRecovery)
        }
        let terminal: [(any Error, SMBPlaybackReadFailure)] = [
            (CancellationError(), .cancelled),
            (SMBDirectoryReadFailure.retired, .retired),
            (SMB2OperationFailure(origin: .response, posixCode: EACCES), .permissionDenied),
            (SMB2OperationFailure(origin: .response, posixCode: EPERM), .permissionDenied),
            (SMB2OperationFailure(origin: .response, ntStatus: 0xC000006D), .authenticationRequired),
            (SMB2OperationFailure(origin: .response, posixCode: ECONNREFUSED), .authenticationRequired),
            (SMB2OperationFailure(origin: .response, posixCode: ENOENT), .notFound),
            (SMB2OperationFailure(origin: .submission, posixCode: EPERM), .unclassifiedSessionFailure),
            (SMB2OperationFailure(origin: .wait, posixCode: ETIMEDOUT), .unclassifiedSessionFailure),
            (SMB2OperationFailure(origin: .response, posixCode: ECONNRESET), .unclassifiedSessionFailure),
            (SMB2OperationFailure(origin: .response, posixCode: EPIPE), .unclassifiedSessionFailure),
            (NSError(domain: "private-fixture-server-path", code: 123), .unclassifiedSessionFailure),
            (URLError(.badServerResponse), .invalidResponse),
            (MediaInspectionError.invalidResponse, .invalidResponse),
            (PlaybackSourceRecoveryError.identityChanged, .invalidResponse),
            (SMBPlaybackReadFailure.invalidRange, .invalidRange)
        ]
        for (original, expected) in terminal {
            let result = SMBPlaybackSession.recoveryDisposition(for: original)
            #expect(result == expected)
            #expect(!result.allowsFreshRecovery)
            #expect(!String(describing: result).contains("private-fixture"))
        }
        // Directory policy stays unchanged for its existing conservative fresh-list attempt.
        #expect(SMBDirectoryReadFailure.unclassifiedSessionFailure.allowsFreshRecovery)
        #expect(!SMBPlaybackReadFailure.unclassifiedSessionFailure.allowsFreshRecovery)
    }

    @Test func metadataUsesOneStatAndAllAvailableIdentityFields() async throws {
        let transport = PlaybackRangeFixture()
        let reader = SMBMediaReader(transport: transport, diagnostics: diagnostics())
        let file = try MediaFile(components: ["fixture.mp4"])
        let identity = try await reader.playbackMetadata(for: file)
        #expect(identity.size == 8_000_000_000)
        #expect(identity.modificationDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(identity.changeDate == Date(timeIntervalSince1970: 1_700_000_001))
        #expect(identity.creationDate == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(identity.stableIdentifier == String(UInt64.max))
        #expect(identity.isComplete)
        #expect(await transport.attributeCalls == 1)
        #expect(await transport.ranges.isEmpty)
    }

    @Test func absentOrZeroInodeIsNotInventedAsStableIdentifier() async throws {
        let file = try MediaFile(components: ["fixture.mp4"])
        for inode in [UInt64?.none, UInt64(0)] {
            var attributes = playbackAttributes()
            attributes[.documentIdentifierKey] = inode.map { NSNumber(value: $0) }
            let reader = SMBMediaReader(transport: PlaybackRangeFixture(metadata: .success(attributes)),
                diagnostics: diagnostics())
            #expect(try await reader.playbackMetadata(for: file).stableIdentifier == nil)
        }
    }

    @Test func missingRequiredTypeOrSizeFailsClosed() async throws {
        let file = try MediaFile(components: ["fixture.mp4"])
        let required: [URLResourceKey] = [.fileResourceTypeKey, .fileSizeKey]
        for key in required {
            var attributes = playbackAttributes()
            attributes[key] = nil
            let reader = SMBMediaReader(transport: PlaybackRangeFixture(metadata: .success(attributes)),
                diagnostics: diagnostics())
            await #expect(throws: SMBPlaybackReadFailure.invalidResponse) {
                try await reader.playbackMetadata(for: file)
            }
        }
    }

    @Test func malformedResourceTypeAndSizeAreTerminal() async throws {
        let file = try MediaFile(components: ["fixture.mp4"])
        let changes: [(URLResourceKey, any Sendable)] = [
            (.fileResourceTypeKey, URLFileResourceType.directory),
            (.fileResourceTypeKey, URLFileResourceType.symbolicLink),
            (.fileSizeKey, NSNumber(value: -1)),
            (.fileSizeKey, NSNumber(value: UInt64.max)),
            (.fileSizeKey, NSNumber(value: 1.5)),
            (.fileSizeKey, NSNumber(value: true)),
            (.fileSizeKey, "invalid")
        ]
        for (key, value) in changes {
            var attributes = playbackAttributes()
            attributes[key] = value
            let reader = SMBMediaReader(transport: PlaybackRangeFixture(metadata: .success(attributes)),
                diagnostics: diagnostics())
            await #expect(throws: SMBPlaybackReadFailure.invalidResponse) {
                try await reader.playbackMetadata(for: file)
            }
        }
    }

    @Test func unavailableOrSentinelTimestampsDoNotPreventSameSessionReads() async throws {
        let file = try MediaFile(components: ["fixture.mp4"])
        let timestampKeys: [URLResourceKey] = [.contentModificationDateKey, .attributeModificationDateKey, .creationDateKey]
        for value in [Date?.none, Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: -1),
                      Date(timeIntervalSince1970: .infinity)] {
            var attributes = playbackAttributes()
            for key in timestampKeys { attributes[key] = value }
            let reader = SMBMediaReader(transport: PlaybackRangeFixture(metadata: .success(attributes)),
                diagnostics: diagnostics())
            let identity = try await reader.playbackMetadata(for: file)
            #expect(identity.size == 8_000_000_000)
            #expect(identity.modificationDate == nil)
            #expect(identity.changeDate == nil)
            #expect(identity.creationDate == nil)
            #expect(!identity.isComplete)
            #expect(try await reader.playbackRead(file, range: 0..<4) == Data([1, 2, 3, 4]))
        }
    }

    @Test func typedMetadataAndReadFailuresPreserveCategoriesWithoutServerText() async throws {
        let file = try MediaFile(components: ["fixture.mp4"])
        let failures: [(any Error, SMBPlaybackReadFailure)] = [
            (SMB2OperationFailure(origin: .serviceInvalidated, result: -1), .serviceInvalidated),
            (SMB2OperationFailure(origin: .contextUnavailable), .contextUnavailable),
            (SMB2OperationFailure(origin: .wait, posixCode: ECONNRESET), .transportFailure),
            (SMB2OperationFailure(origin: .response, ntStatus: 0xC0000022), .permissionDenied),
            (SMB2OperationFailure(origin: .response, ntStatus: 0xC000006D), .authenticationRequired),
            (POSIXError(.ENOENT), .notFound),
            (NSError(domain: "private-fixture-server-path", code: 42,
                userInfo: [NSLocalizedDescriptionKey: "private-fixture-error"]), .unclassifiedSessionFailure)
        ]
        for (original, expected) in failures {
            let transport = PlaybackRangeFixture(metadata: .failure(original), bytes: .failure(original))
            let reader = SMBMediaReader(transport: transport, diagnostics: diagnostics())
            await #expect(throws: expected) { try await reader.playbackMetadata(for: file) }
            await #expect(throws: expected) { try await reader.playbackRead(file, range: 0..<4) }
            // Legacy public behavior remains unavailable rather than exposing new typed errors.
            await #expect(throws: MediaInspectionError.unavailable) { try await reader.fileSize(for: file) }
            await #expect(throws: MediaInspectionError.unavailable) { try await reader.read(file, range: 0..<4) }
        }
    }

    @Test func exactRangesEmptyRangesAndMalformedReplies() async throws {
        let file = try MediaFile(components: ["fixture.mp4"])
        let transport = PlaybackRangeFixture()
        let reader = SMBMediaReader(transport: transport, diagnostics: diagnostics())
        let range: Range<UInt64> = 4_294_967_299..<4_294_967_303
        #expect(try await reader.playbackRead(file, range: range) == Data([1, 2, 3, 4]))
        #expect(try await reader.playbackRead(file, range: 5..<5).isEmpty)
        await #expect(throws: SMBPlaybackReadFailure.invalidRange) {
            try await reader.playbackRead(file, range: 0..<(MediaReadPlan.maximumChunkBytes+1))
        }
        await #expect(throws: SMBPlaybackReadFailure.invalidRange) {
            try await reader.playbackRead(file, range: UInt64(Int64.max)..<UInt64(Int64.max) + 1)
        }
        #expect(await transport.ranges == [range])
        for count in [3, 5] {
            let invalid = SMBMediaReader(transport: PlaybackRangeFixture(bytes: .success(Data(count: count))),
                diagnostics: diagnostics())
            await #expect(throws: SMBPlaybackReadFailure.invalidResponse) {
                try await invalid.playbackRead(file, range: 0..<4)
            }
        }
    }

    @Test func cancellationAndClosedReaderNeverBecomeRecoverable() async throws {
        let file = try MediaFile(components: ["fixture.mp4"])
        let transport = PlaybackRangeFixture(metadata: .failure(CancellationError()), bytes: .failure(CancellationError()))
        let reader = SMBMediaReader(transport: transport, diagnostics: diagnostics())
        await #expect(throws: CancellationError.self) { try await reader.playbackMetadata(for: file) }
        await #expect(throws: CancellationError.self) { try await reader.playbackRead(file, range: 0..<4) }
        await reader.close()
        await #expect(throws: SMBPlaybackReadFailure.retired) { try await reader.playbackMetadata(for: file) }
        await #expect(throws: SMBPlaybackReadFailure.retired) { try await reader.playbackRead(file, range: 0..<4) }
        #expect(await transport.attributeCalls == 1)
        #expect(await transport.ranges.count == 1)
    }

    @Test func publicSessionUsesTypedProviderPathAndLeavesLegacyCallsUnchanged() async throws {
        let manager = try #require(PlaybackManagerFixture(url: URL(string: "smb://fixture.invalid")!, credential: nil))
        let provider = SMBDirectoryProvider(manager: manager, diagnostics: diagnostics(), session: 1)
        let session = SMBPlaybackSession(provider: provider)
        let file = try MediaFile(components: ["fixture.mp4"])
        #expect(session.provider === provider)
        #expect(try await session.fileSize(for: file) == 8_000_000_000)
        #expect(try await session.metadata(for: file).changeDate != nil)
        await #expect(throws: SMBPlaybackReadFailure.serviceInvalidated) { try await session.read(file, range: 0..<4) }
        await #expect(throws: MediaInspectionError.unavailable) { try await provider.read(file, range: 0..<4) }
        try await provider.retireForDirectoryRecovery()
    }

    @Test func playbackRetirementPublishesReasonOnlyAfterBothDrainBarriers() async throws {
        let manager = try #require(PlaybackManagerFixture(url: URL(string: "smb://fixture.invalid")!, credential: nil))
        let leases = SMBOperationLeases()
        #expect(leases.acquire()) // One manual pre-existing operation lease, no transport call.
        #expect(manager.queueDrain.acquire())
        let provider = SMBDirectoryProvider(manager: manager, diagnostics: diagnostics(), session: 1, leases: leases)
        let session = SMBPlaybackSession(provider: provider)
        let file = try MediaFile(components: ["fixture.mp4"])
        let retirement = Task { try await session.retireForPlaybackRecovery() }
        while leases.snapshot.accepting { await Task.yield() }
        #expect(await manager.state.localRetires == 0)
        await #expect(throws: SMBDirectoryReadFailure.retired) { try await provider.page(at: DirectoryPath(), offset: 0) }
        await #expect(throws: SMBPlaybackReadFailure.retired) { try await session.metadata(for: file) }
        leases.release()
        while await manager.state.localRetires == 0 { await Task.yield() }
        #expect(await manager.state.drained == false)
        retirement.cancel() // Cancelling the caller never substitutes for the queue drain.
        await #expect(throws: SMBDirectoryReadFailure.retired) { try await provider.page(at: DirectoryPath(), offset: 0) }
        manager.queueDrain.release()
        try await retirement.value
        #expect(await manager.state.drained)
        await #expect(throws: SMBDirectoryReadFailure.retiredByPlaybackRecovery) {
            try await provider.page(at: DirectoryPath(), offset: 0)
        }
        await #expect(throws: SMBPlaybackReadFailure.retiredByPlaybackRecovery) { try await session.metadata(for: file) }
        await #expect(throws: SMBPlaybackReadFailure.retiredByPlaybackRecovery) { try await session.read(file, range: 0..<4) }
        await #expect(throws: MediaInspectionError.unavailable) { try await provider.fileSize(for: file) }
        await #expect(throws: MediaInspectionError.unavailable) { try await provider.read(file, range: 0..<4) }
        try await session.retireForPlaybackRecovery()
        #expect(await manager.state.localRetires == 1)
        #expect(await manager.state.normalDisconnects == 0)
    }

    @Test func ordinaryRetirementIsNeverUpgradedToPlaybackRecovery() async throws {
        let file = try MediaFile(components: ["fixture.mp4"])
        for directoryRecovery in [false, true] {
            let manager = try #require(PlaybackManagerFixture(url: URL(string: "smb://fixture.invalid")!, credential: nil))
            let provider = SMBDirectoryProvider(manager: manager, diagnostics: diagnostics(), session: 1)
            let session = SMBPlaybackSession(provider: provider)
            if directoryRecovery { try await provider.retireForDirectoryRecovery() }
            else { await provider.disconnect() }
            try await session.retireForPlaybackRecovery()
            await #expect(throws: SMBDirectoryReadFailure.retired) { try await provider.page(at: DirectoryPath(), offset: 0) }
            await #expect(throws: SMBPlaybackReadFailure.retired) { try await session.metadata(for: file) }
            #expect(await manager.state.localRetires == (directoryRecovery ? 1 : 0))
            #expect(await manager.state.normalDisconnects == (directoryRecovery ? 0 : 1))
        }
    }

    @Test func failedEarlierRetirementStaysTerminalAndNeverPublishesRecoverableReason() async throws {
        let manager = try #require(PlaybackManagerFixture(url: URL(string: "smb://fixture.invalid")!, credential: nil))
        await manager.state.failNormal(with: NSError(domain: "private-fixture-cleanup", code: 5))
        let provider = SMBDirectoryProvider(manager: manager, diagnostics: diagnostics(), session: 1)
        let session = SMBPlaybackSession(provider: provider)
        await provider.disconnect()
        await #expect(throws: SMBPlaybackReadFailure.unclassifiedSessionFailure) { try await session.retireForPlaybackRecovery() }
        await #expect(throws: SMBDirectoryReadFailure.retired) { try await provider.page(at: DirectoryPath(), offset: 0) }
        let file = try MediaFile(components: ["fixture.mp4"])
        await #expect(throws: SMBPlaybackReadFailure.retired) { try await session.metadata(for: file) }
        #expect(await manager.state.localRetires == 0)
        #expect(await manager.state.normalDisconnects == 1)
        #expect(await manager.state.drained == false)
    }
}
