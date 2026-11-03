import Foundation
import AMSMB2

/// Prospective MKV transport contract. Not yet wired into the App's playback path.
enum SMBSessionFailure: Error, Equatable {
    case busy, closed, timeout, cancelled, invalidRange, changed, insufficientVersion, snapshotUnavailable, readFailed
}
enum SMBVersionGuarantee: Sendable { case observedMetadata, immutableSnapshot }
enum SMBVersionPolicy: Sendable { case requireSnapshot, detectObservableChanges }
struct SMBObservedVersion: Sendable, Equatable {
    let size: UInt64
    let identifier: UInt64
    let modified: Date
    let changed: Date
    static func parse(_ values: [URLResourceKey: any Sendable]) throws -> Self {
        guard values[.fileResourceTypeKey] as? URLFileResourceType == .regular,
              let size = values[.fileSizeKey] as? UInt64, size <= Int64.max,
              let identifier = values[.documentIdentifierKey] as? UInt64, identifier != 0,
              let modified = values[.contentModificationDateKey] as? Date,
              let changed = values[.attributeModificationDateKey] as? Date,
              modified.timeIntervalSinceReferenceDate.isFinite,
              changed.timeIntervalSinceReferenceDate.isFinite else { throw SMBSessionFailure.insufficientVersion }
        return Self(size: size, identifier: identifier, modified: modified, changed: changed)
    }
}
final class SMBReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
protocol SMBSessionTransport: Sendable {
    var versionGuarantee: SMBVersionGuarantee { get }
    func version(at path: String) async throws -> SMBObservedVersion
    func read(at path: String, range: Range<UInt64>, cancellation: SMBReadCancellation) async throws -> Data
}
struct AMSMBSessionTransport: SMBSessionTransport {
    let manager: SMB2Manager
    var versionGuarantee: SMBVersionGuarantee { .observedMetadata }
    func version(at path: String) async throws -> SMBObservedVersion {
        try SMBObservedVersion.parse(await manager.attributesOfItem(atPath: path))
    }
    func read(at path: String, range: Range<UInt64>, cancellation: SMBReadCancellation) async throws -> Data {
        guard !cancellation.isCancelled else { throw SMBSessionFailure.cancelled }
        let data = try await manager.contents(atPath: path, range: range, progress: { _, _ in !cancellation.isCancelled })
        guard !cancellation.isCancelled else { throw SMBSessionFailure.cancelled }
        return data
    }
}

/// One shared admission slot across all prospective MKV playback sessions, no waiting queue.
actor SMBReadAdmission {
    static let shared = SMBReadAdmission()
    private var owner: UUID?
    func acquire() throws -> UUID {
        guard owner == nil else { throw SMBSessionFailure.busy }
        let token = UUID(); owner = token; return token
    }
    func release(_ token: UUID) { if owner == token { owner = nil } }
    var occupied: Bool { owner != nil }
}

actor SMBReadSession {
    private let transport: any SMBSessionTransport
    private let path: String
    private let admission: SMBReadAdmission
    private let lease: UUID
    private let timeout: Duration
    private var expected: SMBObservedVersion?
    private var closed = false
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var cancellation: SMBReadCancellation?
    private var pending: CheckedContinuation<Data, Error>?
    private var operation: UUID?
    private var bytesCharged: UInt64 = 0
    private var reads = 0

    static func open(transport: any SMBSessionTransport, path: String,
                     policy: SMBVersionPolicy = .requireSnapshot,
                     admission: SMBReadAdmission = .shared, timeout: Duration = .seconds(15)) async throws -> SMBReadSession {
        // Current AMSMB2 adapter cannot satisfy strict consistency. Reject before network I/O.
        guard policy != .requireSnapshot || transport.versionGuarantee == .immutableSnapshot else { throw SMBSessionFailure.snapshotUnavailable }
        guard timeout > .zero && timeout <= .seconds(15) else { throw SMBSessionFailure.invalidRange }
        try Task.checkCancellation()
        let lease = try await admission.acquire()
        if Task.isCancelled { await admission.release(lease); throw CancellationError() }
        return SMBReadSession(transport: transport, path: path, admission: admission, lease: lease, timeout: timeout)
    }
    private init(transport: any SMBSessionTransport, path: String, admission: SMBReadAdmission, lease: UUID, timeout: Duration) {
        self.transport = transport; self.path = path; self.admission = admission; self.lease = lease; self.timeout = timeout
    }
    deinit {
        let admission = admission, lease = lease
        Task { await admission.release(lease) }
    }
    func read(_ range: Range<UInt64>) async throws -> Data {
        guard !closed else { throw SMBSessionFailure.closed }
        guard worker == nil else { throw SMBSessionFailure.busy }
        try Task.checkCancellation()
        guard range.upperBound <= Int64.max, range.upperBound - range.lowerBound <= 65_536 else { throw SMBSessionFailure.invalidRange }
        if range.isEmpty { return Data() }
        guard reads < 4096, range.upperBound - range.lowerBound <= 1_048_576 - bytesCharged else { throw SMBSessionFailure.invalidRange }
        reads += 1; bytesCharged += range.upperBound - range.lowerBound
        let id = UUID(); let signal = SMBReadCancellation()
        operation = id; cancellation = signal
        let transport = transport, path = path, expected = expected, deadline = timeout
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                worker = Task { [self] in
                    let result: Result<(Data, SMBObservedVersion), SMBSessionFailure>
                    do { result = .success(try await Self.fetch(transport: transport, path: path, expected: expected, range: range, signal: signal)) }
                    catch let error as SMBSessionFailure { result = .failure(error) }
                    catch { result = .failure(signal.isCancelled ? .cancelled : .readFailed) }
                    await complete(id, result: result)
                }
                timer = Task { [self] in
                    do { try await Task.sleep(for: deadline) } catch { return }
                    await expire(id, reason: .timeout)
                }
            }
        }, onCancel: {
            signal.cancel()
            Task { await self.expire(id, reason: .cancelled) }
        })
    }
    private static func fetch(transport: any SMBSessionTransport, path: String, expected: SMBObservedVersion?,
                              range: Range<UInt64>, signal: SMBReadCancellation) async throws -> (Data, SMBObservedVersion) {
        func check() throws { if signal.isCancelled || Task.isCancelled { throw SMBSessionFailure.cancelled } }
        try check()
        let before = try await transport.version(at: path)
        try check()
        guard expected == nil || before == expected else { throw SMBSessionFailure.changed }
        guard range.upperBound <= before.size else { throw SMBSessionFailure.invalidRange }
        let data = try await transport.read(at: path, range: range, cancellation: signal)
        try check()
        guard UInt64(data.count) == range.upperBound - range.lowerBound else { throw SMBSessionFailure.readFailed }
        let after = try await transport.version(at: path)
        try check()
        guard after == before else { throw SMBSessionFailure.changed }
        return (data, before)
    }
    private func expire(_ id: UUID, reason: SMBSessionFailure) async {
        guard operation == id, worker != nil, !closed else { return }
        closed = true; cancellation?.cancel(); worker?.cancel(); timer?.cancel(); timer = nil
        let waiter = pending; pending = nil
        waiter?.resume(throwing: reason)
        // Do not release admission: metadata, read, or remote handle cleanup may still be running.
    }
    private func complete(_ id: UUID, result: Result<(Data, SMBObservedVersion), SMBSessionFailure>) async {
        guard operation == id else { return }
        timer?.cancel(); timer = nil
        let wasCancelled = cancellation?.isCancelled == true
        cancellation = nil; worker = nil; operation = nil
        let waiter = pending; pending = nil
        if closed || wasCancelled {
            closed = true; waiter?.resume(throwing: SMBSessionFailure.cancelled)
        } else {
            switch result {
            case .success(let (data, version)): expected = version; waiter?.resume(returning: data)
            case .failure(let error): closed = true; waiter?.resume(throwing: error)
            }
        }
        if closed { await admission.release(lease) }
    }
    func close() async {
        closed = true; cancellation?.cancel(); worker?.cancel(); timer?.cancel(); timer = nil
        let waiter = pending; pending = nil; waiter?.resume(throwing: SMBSessionFailure.cancelled)
        if worker == nil { await admission.release(lease) }
    }
    var draining: Bool { closed && worker != nil }
}
