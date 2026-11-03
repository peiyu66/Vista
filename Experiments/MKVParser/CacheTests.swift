import Foundation
private enum TestFailure: Error { case assertion }
private func check(_ value: Bool) throws { if !value { throw TestFailure.assertion } }
private actor Source: PrototypeRangeSource {
    var calls = 0
    var gate = false
    var truncate = false
    var pending: CheckedContinuation<Void, Never>?
    var entered: CheckedContinuation<Void, Never>?
    init(gate: Bool = false, truncate: Bool = false) { self.gate = gate; self.truncate = truncate }
    func read(range: Range<UInt64>) async throws -> Data {
        calls += 1
        entered?.resume(); entered = nil
        if gate { await withCheckedContinuation { pending = $0 } } // Deliberately ignore cancellation to exercise late replies.
        let count = Int(range.upperBound - range.lowerBound) - (truncate ? 1 : 0)
        return Data((0..<count).map { UInt8((range.lowerBound + UInt64($0)) % 251) })
    }
    func waitForRead() async { if calls == 0 { await withCheckedContinuation { entered = $0 } } }
    func release() { gate = false; pending?.resume(); pending = nil }
}
@main struct CacheTests {
    static func main() async throws {
        let source = Source()
        let cache = BoundedRangeCache(source: source, size: 524288)
        for offset in 0..<700 { let byte = try await cache.read(UInt64(offset)..<UInt64(offset + 1)); try check(byte.first == UInt8(offset % 251)) }
        try check(await source.calls == 1)
        let crossing = try await cache.read(65530..<65550)
        try check(crossing == Data((65530..<65550).map { UInt8($0 % 251) }))
        try check(await source.calls == 2)
        for block in 2...5 { _ = try await cache.read(UInt64(block * 65536)..<UInt64(block * 65536 + 1)) }
        let stats = await cache.stats(); try check(stats.blocks == 4 && stats.bytes == 262144)
        _ = try await cache.read(0..<1); try check(await source.calls == 7)
        do { _ = try await cache.read(0..<65537); throw TestFailure.assertion } catch CacheFailure.invalidRange {}
        do { _ = try await cache.read(UInt64.max-1..<UInt64.max); throw TestFailure.assertion } catch CacheFailure.invalidRange {}
        let limited = BoundedRangeCache(source: Source(), size: 524288, budget: 65536)
        _ = try await limited.read(0..<1)
        do { _ = try await limited.read(65536..<65537); throw TestFailure.assertion } catch CacheFailure.budget {}
        let short = BoundedRangeCache(source: Source(truncate: true), size: 100)
        do { _ = try await short.read(0..<1); throw TestFailure.assertion } catch CacheFailure.truncated {}
        try check(await short.stats().blocks == 0)
        let gated = Source(gate: true)
        let cancelled = BoundedRangeCache(source: gated, size: 100)
        let operation = Task { try await cancelled.read(0..<1) }
        await gated.waitForRead()
        do { _ = try await cancelled.read(1..<2); throw TestFailure.assertion } catch CacheFailure.busy {}
        await cancelled.cancel()
        try check(await cancelled.stats().active)
        await gated.release()
        do { _ = try await operation.value; throw TestFailure.assertion } catch CacheFailure.stale {}
        let afterCancel = await cancelled.stats()
        try check(afterCancel.blocks == 0 && !afterCancel.active)
        _ = try await cancelled.read(0..<1)
        await cancelled.cancel(close: true)
        do { _ = try await cancelled.read(0..<1); throw TestFailure.assertion } catch CacheFailure.closed {}
        let callerSource = Source(gate: true)
        let callerCache = BoundedRangeCache(source: callerSource, size: 100)
        let caller = Task { try await callerCache.read(0..<1) }
        await callerSource.waitForRead(); caller.cancel(); await callerSource.release()
        do { _ = try await caller.value; throw TestFailure.assertion } catch is CancellationError {}
        try check(await callerCache.stats().blocks == 0)
        print("CACHE_VERIFIED: coalescing, LRU cap, crossing, bounds, budget, truncation, busy, cancel, late-reply, close")
    }
}
