import Foundation
import Dispatch
private enum Failure: Error { case assertion }
private func check(_ value: Bool) throws { if !value { throw Failure.assertion } }
private actor Source: PrototypeRangeSource {
    let bytes: Data
    var gate: Bool
    var calls = 0
    var pending: CheckedContinuation<Void, Never>?
    var entered: CheckedContinuation<Void, Never>?
    init(_ data: Data, gate: Bool = false) { bytes = data; self.gate = gate }
    func read(range: Range<UInt64>) async throws -> Data {
        calls += 1; entered?.resume(); entered = nil
        if gate { await withCheckedContinuation { pending = $0 } }
        return bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
    func waitForRead() async { if calls == 0 { await withCheckedContinuation { entered = $0 } } }
    func release() { gate = false; pending?.resume(); pending = nil }
}
private func parse(_ bridge: SyncRangeBridge, size: Int) async -> Int32 {
    await withCheckedContinuation { continuation in
        DispatchQueue(label: "vista.experiment.parser").async {
            let retained = Unmanaged.passRetained(bridge)
            defer { retained.release() }
            let result = vista_experiment_parse(retained.toOpaque(), Int64(size))
            continuation.resume(returning: bridge.isOpen ? result : -1)
        }
    }
}
@main struct BridgeTests {
    static func main() async throws {
        try check(CommandLine.arguments.count == 3)
        for path in CommandLine.arguments.dropFirst() {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let source = Source(data)
            let cache = BoundedRangeCache(source: source, size: UInt64(data.count))
            let bridge = SyncRangeBridge(cache: cache)
            try check(await parse(bridge, size: data.count) == 24)
            try check(await source.calls == 1)
            bridge.cancel()
            let stalled = Source(data, gate: true)
            let stalledCache = BoundedRangeCache(source: stalled, size: UInt64(data.count))
            let timed = SyncRangeBridge(cache: stalledCache, timeout: 0.05)
            let timedResult = Task { await parse(timed, size: data.count) }
            await stalled.waitForRead()
            try check(await timedResult.value == -1)
            try check(await stalledCache.stats().active) // The backend ignored cancellation; slot stays occupied.
            try check(await parse(timed, size: data.count) == -1)
            await stalled.release()
            let cancellationSource = Source(data, gate: true)
            let cancellationCache = BoundedRangeCache(source: cancellationSource, size: UInt64(data.count))
            let cancelled = SyncRangeBridge(cache: cancellationCache, timeout: 5)
            let cancelledResult = Task { await parse(cancelled, size: data.count) }
            await cancellationSource.waitForRead()
            // A concurrent synchronous parser call fails instead of reentering this bridge.
            try check(await parse(cancelled, size: data.count) == -1)
            cancelled.cancel()
            try check(await cancelledResult.value == -1)
            await cancellationSource.release()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while true {
                let first = await stalledCache.stats()
                let second = await cancellationCache.stats()
                if !first.active && !second.active { break }
                try check(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(5))
            }
            try check(await stalledCache.stats().blocks == 0)
            try check(await cancellationCache.stats().blocks == 0)
        }
        print("SYNC_ASYNC_BRIDGE_VERIFIED: actual-parser, one-backend-read, timeout, cancel, concurrent-reject, late-reply, cleanup")
    }
}
