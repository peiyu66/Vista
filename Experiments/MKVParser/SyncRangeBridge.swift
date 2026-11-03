// Vista MIT. Dedicated-thread adapter for an asynchronous bounded cache. Never block a Swift executor.
import Foundation
import Dispatch
enum BridgeFailure: Error { case mainThread, busy, closed, timeout, cancelled, invalidRange }
private final class ReadRequest: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Data, Error>?
    private var task: Task<Void, Never>?
    private var invalid = false
    func install(_ task: Task<Void, Never>) {
        lock.lock(); let cancel = invalid; if !cancel { self.task = task }; lock.unlock()
        if cancel { task.cancel() }
    }
    func complete(_ result: Result<Data, Error>) {
        lock.lock()
        guard !invalid && self.result == nil else { lock.unlock(); return }
        self.result = result; task = nil; lock.unlock(); ready.signal()
    }
    func take() throws -> Data {
        lock.lock(); let result = self.result; let invalid = invalid; lock.unlock()
        guard !invalid, let result else { throw BridgeFailure.cancelled }
        return try result.get()
    }
    func invalidate() {
        lock.lock(); invalid = true; result = nil; let old = task; task = nil; lock.unlock()
        old?.cancel(); ready.signal()
    }
}
final class SyncRangeBridge: @unchecked Sendable {
    private let cache: BoundedRangeCache
    private let lock = NSLock()
    private var current: ReadRequest?
    private var closed = false
    private let timeout: Double
    init(cache: BoundedRangeCache, timeout: Double = 1) { self.cache = cache; self.timeout = timeout }
    func read(offset: UInt64, count: Int) throws -> Data {
        guard !Thread.isMainThread else { throw BridgeFailure.mainThread }
        guard count >= 0 && count <= 65536 && offset <= UInt64.max - UInt64(count), timeout.isFinite && timeout > 0 && timeout <= 15 else { throw BridgeFailure.invalidRange }
        lock.lock()
        if closed { lock.unlock(); throw BridgeFailure.closed }
        if current != nil { lock.unlock(); throw BridgeFailure.busy }
        let request = ReadRequest(); current = request; lock.unlock()
        defer { lock.lock(); current = nil; lock.unlock() }
        let cache = cache
        let task = Task.detached {
            do { request.complete(.success(try await cache.read(offset..<(offset + UInt64(count))))) }
            catch { request.complete(.failure(error)) }
        }
        request.install(task)
        if request.ready.wait(timeout: .now() + timeout) == .timedOut {
            cancel(); throw BridgeFailure.timeout
        }
        lock.lock(); let closed = closed; lock.unlock()
        guard !closed else { throw BridgeFailure.cancelled }
        return try request.take()
    }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return !closed }
    func cancel() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true; let request = current; lock.unlock()
        request?.invalidate()
        let cache = cache
        Task.detached { await cache.cancel(close: true) }
    }
}
// C callback owns no pointer beyond this call. The caller retains the bridge until parsing returns.
@_cdecl("vista_experiment_read")
func vistaExperimentRead(_ context: UnsafeMutableRawPointer?, _ offset: Int64, _ count: Int32, _ out: UnsafeMutablePointer<UInt8>?) -> Int32 {
    guard let context, let out, offset >= 0, count >= 0, count <= 65536 else { return -1 }
    let bridge = Unmanaged<SyncRangeBridge>.fromOpaque(context).takeUnretainedValue()
    do {
        let data = try bridge.read(offset: UInt64(offset), count: Int(count))
        guard data.count == count else { return -1 }
        data.copyBytes(to: out, count: Int(count)); return 0
    } catch { return -1 }
}

@_cdecl("vista_experiment_cancelled")
func vistaExperimentCancelled(_ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 1 }
    return Unmanaged<SyncRangeBridge>.fromOpaque(context).takeUnretainedValue().isOpen ? 0 : 1
}
