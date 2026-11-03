// Vista MIT. Experimental single-consumer byte cache; not wired to the App or SMB.
import Foundation
protocol PrototypeRangeSource: Sendable {
    func read(range: Range<UInt64>) async throws -> Data
}
enum CacheFailure: Error, Equatable { case invalidRange, busy, closed, budget, truncated, stale }
actor BoundedRangeCache {
    private let source: any PrototypeRangeSource
    private let size: UInt64
    private let budget: UInt64
    private let blockSize: UInt64 = 65_536
    private var blocks: [UInt64: Data] = [:]
    private var order: [UInt64] = []
    private var active = false
    private var closed = false
    private var generation: UInt64 = 0
    private var charged: UInt64 = 0
    private var worker: Task<Data, Error>?
    init(source: any PrototypeRangeSource, size: UInt64, budget: UInt64 = 1_048_576) {
        self.source = source; self.size = size; self.budget = budget
    }
    func read(_ range: Range<UInt64>) async throws -> Data {
        guard !closed else { throw CacheFailure.closed }
        try Task.checkCancellation()
        guard range.lowerBound <= range.upperBound, range.upperBound <= size,
              range.upperBound - range.lowerBound <= blockSize else { throw CacheFailure.invalidRange }
        guard !active else { throw CacheFailure.busy }
        active = true
        let token = generation
        defer { active = false; worker = nil }
        var result = Data()
        var position = range.lowerBound
        while position < range.upperBound {
            try Task.checkCancellation()
            guard token == generation && !closed else { throw CacheFailure.stale }
            let offset = position / blockSize * blockSize
            let count = min(blockSize, size - offset)
            let data: Data
            if let cached = blocks[offset] { data = cached }
            else {
                guard charged <= budget && count <= budget - charged else { throw CacheFailure.budget }
                charged += count // Failed/cancelled reads consume budget too; no unbounded retry loop.
                let upstream = source
                let task = Task { try await upstream.read(range: offset..<(offset + count)) }
                worker = task
                let received = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                worker = nil
                try Task.checkCancellation()
                guard token == generation && !closed else { throw CacheFailure.stale }
                guard received.count == count else { throw CacheFailure.truncated }
                data = received
                if order.count == 4, let oldest = order.first { blocks.removeValue(forKey: oldest); order.removeFirst() }
                blocks[offset] = received
            }
            order.removeAll { $0 == offset }; order.append(offset)
            let end = min(range.upperBound, offset + count)
            result.append(data.subdata(in: Int(position - offset)..<Int(end - offset)))
            position = end
        }
        return result
    }
    func cancel(close: Bool = false) {
        generation &+= 1
        closed = closed || close
        blocks.removeAll(); order.removeAll()
        worker?.cancel()
        // Keep the active slot until the backend actually returns; never accumulate orphan I/O.
    }
    func stats() -> (blocks: Int, bytes: Int, charged: UInt64, active: Bool) {
        (blocks.count, blocks.values.reduce(0) { $0 + $1.count }, charged, active)
    }
}
