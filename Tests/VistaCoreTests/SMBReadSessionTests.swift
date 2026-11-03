import Foundation
import Testing
@testable import VistaSMB

private let initialVersion = SMBObservedVersion(size: 100, identifier: 7,
    modified: Date(timeIntervalSince1970: 100), changed: Date(timeIntervalSince1970: 100))
private actor SessionSource: SMBSessionTransport {
    enum Mode: Sendable { case normal, disconnected, short, changedDuringRead, sameMetadataChange }
    enum Stall: Sendable { case none, metadata, read }
    nonisolated let versionGuarantee: SMBVersionGuarantee
    var current = initialVersion
    var mode: Mode
    var stall: Stall
    var versions = 0, reads = 0, outstanding = 0, peakOutstanding = 0
    var pending: CheckedContinuation<Void, Never>?
    var entered: CheckedContinuation<Void, Never>?
    var blocked = false
    var lastCancellation: SMBReadCancellation?
    init(mode: Mode = .normal, stall: Stall = .none, guarantee: SMBVersionGuarantee = .observedMetadata) {
        self.mode = mode; self.stall = stall; versionGuarantee = guarantee
    }
    func block() async {
        blocked = true; entered?.resume(); entered = nil
        await withCheckedContinuation { pending = $0 } // Intentionally uncooperative transport.
    }
    func waitUntilBlocked() async { if !blocked { await withCheckedContinuation { entered = $0 } } }
    func release() { stall = .none; pending?.resume(); pending = nil }
    func version(at path: String) async throws -> SMBObservedVersion {
        versions += 1; outstanding += 1; peakOutstanding = max(peakOutstanding, outstanding)
        defer { outstanding -= 1 }
        if stall == .metadata { await block() }
        return current
    }
    func read(at path: String, range: Range<UInt64>, cancellation: SMBReadCancellation) async throws -> Data {
        reads += 1; lastCancellation = cancellation
        outstanding += 1; peakOutstanding = max(peakOutstanding, outstanding)
        defer { outstanding -= 1 }
        if stall == .read { await block() }
        switch mode {
        case .disconnected: throw NSError(domain: "synthetic-private-error", code: 1)
        case .short: return Data(count: max(0, Int(range.count) - 1))
        case .changedDuringRead:
            current = SMBObservedVersion(size: 100, identifier: 8, modified: current.modified, changed: current.changed)
        default: break
        }
        return Data(repeating: mode == .sameMetadataChange ? 2 : 1, count: Int(range.count))
    }
    func replaceVersion(_ value: SMBObservedVersion) { current = value }
    func useMode(_ value: Mode) { mode = value }
}
private func waitForRelease(_ gate: SMBReadAdmission) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await gate.occupied {
        guard ContinuousClock.now < deadline else { Issue.record("Admission did not release"); return }
        try await Task.sleep(for: .milliseconds(2))
    }
}
private struct SMBReadSessionTests {
    @Test func strictPolicyRejectsObservedMetadataBeforeAnyIO() async throws {
        let source = SessionSource(), gate = SMBReadAdmission()
        await #expect(throws: SMBSessionFailure.snapshotUnavailable) {
            try await SMBReadSession.open(transport: source, path: "synthetic.mkv", admission: gate)
        }
        #expect(await source.versions == 0)
        #expect(await source.reads == 0)
        #expect(await !gate.occupied)
    }
    @Test func observedVersionChecksBeforeAndAfterEveryRange() async throws {
        let source = SessionSource(), gate = SMBReadAdmission()
        let session = try await SMBReadSession.open(transport: source, path: "synthetic.mkv", policy: .detectObservableChanges, admission: gate)
        #expect(try await session.read(0..<8) == Data(repeating: 1, count: 8))
        #expect(try await session.read(8..<16).count == 8)
        #expect(await source.versions == 4)
        #expect(await source.peakOutstanding == 1)
        await session.close(); try await waitForRelease(gate)
    }
    @Test(arguments: [SessionSource.Stall.metadata, .read])
    func timeoutKeepsGlobalAdmissionUntilBackendReturns(stall: SessionSource.Stall) async throws {
        let source = SessionSource(stall: stall), gate = SMBReadAdmission()
        let session = try await SMBReadSession.open(transport: source, path: "synthetic.mkv", policy: .detectObservableChanges, admission: gate, timeout: .milliseconds(200))
        let task = Task { try await session.read(0..<8) }
        await source.waitUntilBlocked()
        await #expect(throws: SMBSessionFailure.busy) { try await session.read(8..<16) }
        await #expect(throws: SMBSessionFailure.timeout) { try await task.value }
        #expect(await session.draining)
        #expect(await gate.occupied)
        let other = SessionSource()
        for _ in 0..<100 {
            await #expect(throws: SMBSessionFailure.busy) {
                try await SMBReadSession.open(transport: other, path: "other.mkv", policy: .detectObservableChanges, admission: gate)
            }
        }
        #expect(await other.versions == 0)
        await source.release(); try await waitForRelease(gate)
        #expect(await source.outstanding == 0)
        #expect(await source.peakOutstanding == 1)
        let next = try await SMBReadSession.open(transport: other, path: "next.mkv", policy: .detectObservableChanges, admission: gate)
        #expect(try await next.read(0..<1).count == 1)
        await next.close()
    }
    @Test func simultaneousCloseAndCallerCancellationResumeOnlyOnce() async throws {
        let source = SessionSource(stall: .read), gate = SMBReadAdmission()
        let session = try await SMBReadSession.open(transport: source, path: "synthetic.mkv", policy: .detectObservableChanges, admission: gate)
        let read = Task { try await session.read(0..<8) }
        await source.waitUntilBlocked()
        read.cancel()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { await session.close() } }
        }
        await #expect(throws: SMBSessionFailure.cancelled) { try await read.value }
        #expect(await source.lastCancellation?.isCancelled == true)
        #expect(await gate.occupied)
        await source.release(); try await waitForRelease(gate)
    }
    @Test(arguments: [SessionSource.Mode.disconnected, .short, .changedDuringRead])
    func failedOrChangedReadDoesNotReturnBytes(mode: SessionSource.Mode) async throws {
        let source = SessionSource(mode: mode), gate = SMBReadAdmission()
        let session = try await SMBReadSession.open(transport: source, path: "synthetic.mkv", policy: .detectObservableChanges, admission: gate)
        await #expect(throws: mode == .changedDuringRead ? SMBSessionFailure.changed : .readFailed) { try await session.read(0..<8) }
        try await waitForRelease(gate)
        await #expect(throws: SMBSessionFailure.closed) { try await session.read(0..<8) }
    }
    @Test func replacementBetweenReadsFailsBeforePayloadIO() async throws {
        let source = SessionSource(), gate = SMBReadAdmission()
        let session = try await SMBReadSession.open(transport: source, path: "synthetic.mkv", policy: .detectObservableChanges, admission: gate)
        _ = try await session.read(0..<8)
        await source.replaceVersion(SMBObservedVersion(size: 100, identifier: 9, modified: initialVersion.modified, changed: initialVersion.changed))
        await #expect(throws: SMBSessionFailure.changed) { try await session.read(8..<16) }
        #expect(await source.reads == 1)
        try await waitForRelease(gate)
    }
    @Test func equalMetadataDoesNotProveSnapshotAndStrictModeRefusesIt() async throws {
        let source = SessionSource(), gate = SMBReadAdmission()
        let session = try await SMBReadSession.open(transport: source, path: "synthetic.mkv", policy: .detectObservableChanges, admission: gate)
        #expect(try await session.read(0..<1) == Data([1]))
        await source.useMode(.sameMetadataChange)
        #expect(try await session.read(0..<1) == Data([2])) // Deliberately demonstrate the limitation.
        await session.close()
        await #expect(throws: SMBSessionFailure.snapshotUnavailable) {
            try await SMBReadSession.open(transport: source, path: "synthetic.mkv", admission: gate)
        }
    }
    @Test func missingIdentityAndInvalidMetadataAreRejected() throws {
        var values: [URLResourceKey: any Sendable] = [.fileResourceTypeKey: URLFileResourceType.regular,
            .fileSizeKey: NSNumber(value: 100), .documentIdentifierKey: NSNumber(value: 7),
            .contentModificationDateKey: initialVersion.modified, .attributeModificationDateKey: initialVersion.changed]
        #expect(try SMBObservedVersion.parse(values) == initialVersion)
        values.removeValue(forKey: .documentIdentifierKey)
        #expect(throws: SMBSessionFailure.insufficientVersion) { try SMBObservedVersion.parse(values) }
        values[.documentIdentifierKey] = NSNumber(value: 0)
        #expect(throws: SMBSessionFailure.insufficientVersion) { try SMBObservedVersion.parse(values) }
    }
    @Test func staleReleaseCannotFreeNewOwnerAndIdleDeinitReleasesLease() async throws {
        let gate = SMBReadAdmission()
        let first = try await gate.acquire(); await gate.release(first)
        let second = try await gate.acquire(); await gate.release(first)
        #expect(await gate.occupied); await gate.release(second)
        var session: SMBReadSession? = try await SMBReadSession.open(transport: SessionSource(), path: "synthetic.mkv", policy: .detectObservableChanges, admission: gate)
        #expect(try await session?.read(0..<1).count == 1)
        session = nil
        try await waitForRelease(gate)
    }
    @Test func immutableFixtureCanUseStrictPolicyAndBudgetIsBounded() async throws {
        let source = SessionSource(guarantee: .immutableSnapshot), gate = SMBReadAdmission()
        await source.replaceVersion(SMBObservedVersion(size: 1048576, identifier: 7, modified: initialVersion.modified, changed: initialVersion.changed))
        let session = try await SMBReadSession.open(transport: source, path: "synthetic.mkv", admission: gate)
        await #expect(throws: SMBSessionFailure.invalidRange) { try await session.read(0..<65537) }
        await #expect(throws: SMBSessionFailure.invalidRange) { try await session.read(UInt64.max-1..<UInt64.max) }
        for _ in 0..<16 { #expect(try await session.read(0..<65536).count == 65536) }
        await #expect(throws: SMBSessionFailure.invalidRange) { try await session.read(0..<1) }
        #expect(await source.reads == 16)
        await session.close(); try await waitForRelease(gate)
    }

}
