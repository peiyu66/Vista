import Foundation
import Darwin

struct AdapterEvent: Codable, Sendable {
    let sequence: Int; let kind: String; let stamp: BridgeStamp?
    let readID: UInt64?; let offset: UInt64?; let bytes: Int?; let detail: String?
    let threadID: UInt64; let isMainThread: Bool
}
final class AdapterJournal: @unchecked Sendable {
    private let lock = NSLock(); private var rows: [AdapterEvent] = []; private var sequence = 0, dropped = 0
    func add(_ kind: String, stamp: BridgeStamp? = nil, readID: UInt64? = nil, offset: UInt64? = nil, bytes: Int? = nil, detail: String? = nil) {
        lock.lock(); defer { lock.unlock() }; if rows.count == 2048 { rows.removeFirst(); dropped += 1 }
        var thread: UInt64 = 0; pthread_threadid_np(nil, &thread)
        rows.append(AdapterEvent(sequence: sequence, kind: kind, stamp: stamp, readID: readID, offset: offset, bytes: bytes, detail: detail, threadID: thread, isMainThread: Thread.isMainThread)); sequence += 1
    }
    func events() -> [AdapterEvent] { lock.lock(); defer { lock.unlock() }; return rows }
}
enum AdapterFailure: Error { case rejected(String); case system(String, Int32) }
final class LocalSecurityScopeLease: @unchecked Sendable {
    private let root: URL, lock = NSLock()
    private var acquired: Bool
    init(root: URL, acquired: Bool) { self.root = root; self.acquired = acquired }
    func release() { lock.lock(); defer { lock.unlock() }; if acquired { acquired = false; root.stopAccessingSecurityScopedResource() } }
    deinit { release() }
}
struct LocalSourceSnapshot: Codable, Sendable {
    let sourceReadCalls: Int; let completedReadCalls: Int; let preadCalls: Int
    let readBytes: Int; let maxReadBytes: Int; let outstandingOperations: Int; let peakOperations: Int
    let activeWindow: BridgeStamp?; let revisionValid: Bool; let closed: Bool
}
// Anonymous cumulative measurements of completed calls, including failures.
// Coordination includes its accessor, so identity/pread times are nested, not additive.
struct LocalSourcePerformance: Codable, Sendable {
    var coordinationCalls: UInt64 = 0, coordinationNS: UInt64 = 0, coordinationWaitNS: UInt64 = 0
    var identityCalls: UInt64 = 0, identityNS: UInt64 = 0
    var preadCalls: UInt64 = 0, preadNS: UInt64 = 0
}
private final class LocalSourcePerformanceObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var value = LocalSourcePerformance()
    static func elapsed(from start: UInt64, to end: UInt64) -> UInt64 { end >= start ? end - start : 0 }
    private static func sum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }
    func coordination(elapsed: UInt64, wait: UInt64) {
        lock.lock(); defer { lock.unlock() }
        value.coordinationCalls = Self.sum(value.coordinationCalls, 1)
        value.coordinationNS = Self.sum(value.coordinationNS, elapsed)
        value.coordinationWaitNS = Self.sum(value.coordinationWaitNS, wait)
    }
    func identity(elapsed: UInt64) {
        lock.lock(); defer { lock.unlock() }
        value.identityCalls = Self.sum(value.identityCalls, 1)
        value.identityNS = Self.sum(value.identityNS, elapsed)
    }
    func pread(elapsed: UInt64) {
        lock.lock(); defer { lock.unlock() }
        value.preadCalls = Self.sum(value.preadCalls, 1)
        value.preadNS = Self.sum(value.preadNS, elapsed)
    }
    func snapshot() -> LocalSourcePerformance { lock.lock(); defer { lock.unlock() }; return value }
}
// A new research local operation owner, not the product's existing bookmark /
// NSFileCoordinator LocalDirectoryProvider. All fd IO runs on this serial queue.
final class LocalOperationSource: SourceOperationOwner, @unchecked Sendable {
    let playbackID: UUID; let contentRevision: UUID; let knownSize: UInt64; let file: MediaFile
    let journal: AdapterJournal
    private let performance = LocalSourcePerformanceObserver()
    private let queue = DispatchQueue(label: "research.local.source.operation-owner")
    private var fd: Int32
    private let original: stat
    private let coordinatedURL: URL
    private let scopeLease: LocalSecurityScopeLease
    private var active: BridgeStamp?, retired = false, revisionValid = true, closed = false
    private var reads = 0, completed = 0, preads = 0, bytes = 0, maxBytes = 0, operations = 0, peak = 0
    private init(fd: Int32, original: stat, file: MediaFile, playbackID: UUID, coordinatedURL: URL, scopeLease: LocalSecurityScopeLease, journal: AdapterJournal) {
        self.fd = fd; self.original = original; self.file = file; self.playbackID = playbackID
        self.coordinatedURL = coordinatedURL; self.scopeLease = scopeLease
        contentRevision = UUID(); knownSize = UInt64(original.st_size); self.journal = journal
    }
    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) } }
        }
    }
    static func adoptCoordinatedURL(_ url: URL, file: MediaFile, playbackID: UUID, scopeLease: LocalSecurityScopeLease, journal: AdapterJournal) throws -> LocalOperationSource {
        guard url.isFileURL else { throw AdapterFailure.rejected("local file URL required") }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AdapterFailure.system("open", errno) }
        var original = stat()
        guard fstat(fd, &original) == 0, (original.st_mode & S_IFMT) == S_IFREG, original.st_size > 0, original.st_size <= Int64.max else {
            Darwin.close(fd); throw AdapterFailure.rejected("positive regular file with Int64 offsets required")
        }
        let source = LocalOperationSource(fd: fd, original: original, file: file, playbackID: playbackID, coordinatedURL: url, scopeLease: scopeLease, journal: journal)
        journal.add("local_fd_identity_validated", detail: "dev/inode/size/mtime/ctime/birthtime; coordinated open fd binding; metadata fingerprint not atomic filesystem snapshot")
        return source
    }
    private func coordinated<T>(_ body: () throws -> T) throws -> T {
        let started = DispatchTime.now().uptimeNanoseconds
        var accessorStarted: UInt64?
        defer {
            let finished = DispatchTime.now().uptimeNanoseconds
            // If coordination fails before an accessor, all elapsed time was pre-accessor.
            performance.coordination(elapsed: LocalSourcePerformanceObserver.elapsed(from: started, to: finished),
                                     wait: LocalSourcePerformanceObserver.elapsed(from: started, to: accessorStarted ?? finished))
        }
        var failure: NSError?, outcome: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: coordinatedURL, options: [], error: &failure) { _ in
            if accessorStarted == nil { accessorStarted = DispatchTime.now().uptimeNanoseconds }
            outcome = Result { try body() }
        }
        if let failure { throw failure }
        guard let outcome else { throw LocalFolderFailure.unavailable }
        return try outcome.get()
    }
    private func validateIdentity() throws {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { performance.identity(elapsed: LocalSourcePerformanceObserver.elapsed(from: started, to: DispatchTime.now().uptimeNanoseconds)) }
        guard !closed && revisionValid else { throw AdapterFailure.rejected("closed or revoked source revision") }
        var s = stat(), path = stat()
        guard lstat(coordinatedURL.path, &path) == 0, (path.st_mode & S_IFMT) == S_IFREG, path.st_dev == original.st_dev, path.st_ino == original.st_ino,
              fstat(fd, &s) == 0,
              (s.st_mode & S_IFMT) == S_IFREG,
              s.st_dev == original.st_dev, s.st_ino == original.st_ino, s.st_size == original.st_size,
              s.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec, s.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              s.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec, s.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec,
              s.st_birthtimespec.tv_sec == original.st_birthtimespec.tv_sec, s.st_birthtimespec.tv_nsec == original.st_birthtimespec.tv_nsec else {
            revisionValid = false; journal.add("local_content_revision_revoked", stamp: active)
            throw AdapterFailure.rejected("fd metadata changed")
        }
    }
    private func requireWindow(_ stamp: BridgeStamp) throws {
        guard active == stamp, !retired, stamp.playbackID == playbackID, stamp.contentRevision == contentRevision else { throw AdapterFailure.rejected("window admission closed or wrong full stamp") }
    }
    private func measuredPread(_ buffer: UnsafeMutableRawPointer?, count: Int, offset: off_t) -> Int {
        let started = DispatchTime.now().uptimeNanoseconds
        let result = Darwin.pread(fd, buffer, count, offset)
        let operationErrno = errno
        defer {
            performance.pread(elapsed: LocalSourcePerformanceObserver.elapsed(from: started, to: DispatchTime.now().uptimeNanoseconds))
            errno = operationErrno // Observation must not change the caller's EINTR/error handling.
        }
        return result
    }
    nonisolated func performanceSnapshot() -> LocalSourcePerformance { performance.snapshot() }
    func beginWindow(generation: UInt64) async throws -> LocalWindowByteSource {
        try await perform {
            guard self.active == nil, self.operations == 0, generation > 0 else { throw AdapterFailure.rejected("previous window not drained") }
            try self.validateIdentity()
            let stamp = BridgeStamp(playbackID: self.playbackID, contentRevision: self.contentRevision, windowGeneration: generation)
            self.active = stamp; self.retired = false
            self.journal.add("local_window_admitted", stamp: stamp)
            return LocalWindowByteSource(owner: self, stamp: stamp)
        }
    }
    func validate(stamp: BridgeStamp) async throws {
        try await perform { try self.coordinated { try self.requireWindow(stamp); try self.validateIdentity() } }
    }
    func read(stamp: BridgeStamp, file: MediaFile, range: Range<UInt64>) async throws -> Data {
        try await readDemand(stamp: stamp, file: file, range: range, maximumBytes: 262_144)
    }
    func readVLCInput(stamp: BridgeStamp, file: MediaFile, range: Range<UInt64>) async throws -> Data {
        #if VISTA_READ_PHASE216
        try await readDemand(stamp: stamp, file: file, range: range, maximumBytes: Int(PlaybackReadReference216.continuousBytes))
        #else
        try await readDemand(stamp: stamp, file: file, range: range, maximumBytes: 524_288)
        #endif
    }
    private func readDemand(stamp: BridgeStamp, file: MediaFile, range: Range<UInt64>, maximumBytes: Int) async throws -> Data {
        try await perform { try self.coordinated {
            try self.requireWindow(stamp); try self.validateIdentity()
            guard file == self.file, range.upperBound <= self.knownSize, range.count <= maximumBytes else { throw AdapterFailure.rejected("read range or file") }
            if range.isEmpty { return Data() }
            self.operations += 1; self.peak = max(self.peak, self.operations); self.reads += 1
            precondition(self.operations == 1)
            let readID = UInt64(self.reads)
            self.journal.add("local_pread_operation_started", stamp: stamp, readID: readID, offset: range.lowerBound, bytes: range.count)
            defer { self.operations -= 1; self.completed += 1; self.journal.add("local_pread_operation_completed", stamp: stamp, readID: readID, bytes: self.operations) }
            var result = Data(count: range.count)
            try result.withUnsafeMutableBytes { buffer in
                var done = 0
                while done < range.count {
                    let n = self.measuredPread(buffer.baseAddress!.advanced(by: done), count: range.count - done, offset: off_t(range.lowerBound) + off_t(done))
                    self.preads += 1
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw AdapterFailure.rejected("short pread inside known source") }
                    done += n
                }
            }
            try self.validateIdentity()
            self.bytes += result.count; self.maxBytes = max(self.maxBytes, result.count)
            return result
        } }
    }
    func verifyEOF(stamp: BridgeStamp) async throws {
        try await perform { try self.coordinated {
            try self.requireWindow(stamp); try self.validateIdentity()
            self.operations += 1; self.peak = max(self.peak, self.operations); precondition(self.operations == 1)
            defer { self.operations -= 1 }
            var byte: UInt8 = 0
            var n: Int
            repeat { n = self.measuredPread(&byte, count: 1, offset: off_t(self.knownSize)); self.preads += 1 } while n < 0 && errno == EINTR
            guard n == 0 else { throw AdapterFailure.rejected("known end is not physical EOF") }
            try self.validateIdentity(); self.journal.add("local_physical_eof_verified", stamp: stamp, offset: self.knownSize)
        } }
    }
    func retireAndDrain(stamp: BridgeStamp) async throws -> BridgeSourceQuiescenceWitness {
        try await perform {
            guard self.active == stamp else { throw AdapterFailure.rejected("drain wrong full stamp") }
            // This queue barrier executes after all actual synchronous pread bodies.
            // Caller cancellation cannot skip an operation or manufacture this witness.
            self.retired = true
            guard self.operations == 0 && self.reads == self.completed else { throw AdapterFailure.rejected("source operation still active") }
            self.active = nil
            self.journal.add("local_actual_operation_drain_confirmed", stamp: stamp, bytes: self.operations)
            return BridgeSourceQuiescenceWitness(stamp: stamp, outstandingSourceOperations: 0, confirmedBySourceOwner: true, provider: "real local fd operation-owner serial queue after all actual pread completions")
        }
    }
    func snapshot() async throws -> LocalSourceSnapshot {
        try await perform { LocalSourceSnapshot(sourceReadCalls: self.reads, completedReadCalls: self.completed, preadCalls: self.preads, readBytes: self.bytes, maxReadBytes: self.maxBytes, outstandingOperations: self.operations, peakOperations: self.peak, activeWindow: self.active, revisionValid: self.revisionValid, closed: self.closed) }
    }
    func closeAfterDrain() async throws {
        try await perform {
            guard self.active == nil && self.operations == 0 else { throw AdapterFailure.rejected("close before window drain") }
            guard !self.closed else { return }
            let result = Darwin.close(self.fd); self.fd = -1; self.closed = true
            guard result == 0 else { throw AdapterFailure.system("close", errno) }
            self.scopeLease.release()
            self.journal.add("local_fd_closed_after_drain")
        }
    }
    deinit { if fd >= 0 { Darwin.close(fd) }; scopeLease.release(); journal.add("local_source_deinitialized") }
}
final class LocalWindowByteSource: MediaByteSource, @unchecked Sendable {
    let owner: any SourceOperationOwner; let stamp: BridgeStamp
    init(owner: any SourceOperationOwner, stamp: BridgeStamp) { self.owner = owner; self.stamp = stamp }
    func fileSize(for file: MediaFile) async throws -> UInt64 {
        guard file == owner.file else { throw AdapterFailure.rejected("wrong file") }
        try await owner.validate(stamp: stamp); return owner.knownSize
    }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data { try await owner.read(stamp: stamp, file: file, range: range) }
}
