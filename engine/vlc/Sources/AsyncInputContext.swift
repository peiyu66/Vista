import Foundation
import Darwin

// Derived from the previously tested seam; admission, serial task chaining, publication lock and actual-task join retained.
private struct Reply: Sendable { let data: Data; let valid: Bool }
struct ReadMetrics: Codable { let accepting: Bool; let calls: Int; let returns: Int; let inFlight: Int; let peakInFlight: Int; let publishedBytes: Int; let discardedBytes: Int; let sourceFailures: Int }
final class AsyncInputContext: @unchecked Sendable {
    let window: LocalWindowByteSource
    let source: any SourceOperationOwner
    let file: MediaFile
    let stamp: BridgeStamp
    private let condition = NSCondition()
    private var accepting = true, inFlight = 0, calls = 0, returns = 0, peak = 0, published = 0, discarded = 0, failures = 0
    private var reply: Reply?
    private var lastTask: Task<Void, Never>?
    init(window: LocalWindowByteSource) { self.window = window; self.source = window.owner; self.file = window.owner.file; self.stamp = window.stamp }
    func invalidate() { condition.lock(); accepting = false; condition.broadcast(); condition.unlock() }
    private func perform(_ operation: @escaping @Sendable () async -> Reply) -> Reply {
        let flow=PlaybackFlowTrace.begin(.asyncRead,parent:PlaybackFlowTrace.nativeParent)
        defer{PlaybackFlowTrace.end(flow,.asyncRead)}
        precondition(!Thread.isMainThread)
        let flowLock=PlaybackFlowTrace.begin(.condition,parent:PlaybackFlowTrace.nativeParent)
        condition.lock();PlaybackFlowTrace.end(flowLock,.condition); defer { condition.unlock() }
        guard accepting else { return Reply(data: Data(), valid: false) }
        precondition(inFlight == 0 && reply == nil)
        inFlight = 1; calls += 1; peak = max(peak, inFlight)
        let previous = lastTask
        lastTask = Task.detached { [self] in
            PlaybackFlowTrace.point(flow,.taskStart)
            await PlaybackFlowTrace.$parent.withValue(flow) {
                if let previous {let join=PlaybackFlowTrace.begin(.previousJoin);await previous.value;PlaybackFlowTrace.end(join,.previousJoin)}
                let work=PlaybackFlowTrace.begin(.windowRead)
                let value=await operation()
                PlaybackFlowTrace.end(work,.windowRead,a:value.valid ? 0:1,b:Int64(value.data.count))
                complete(value)
            }
        }
        // Invalidation closes admission/publication, but never pretends an in-flight read returned.
        while reply == nil { let wait=PlaybackFlowTrace.begin(.condition,parent:flow,a:1);condition.wait();PlaybackFlowTrace.end(wait,.condition) }
        let value = reply!; reply = nil; return value
    }
    private func complete(_ value: Reply) {
        let flowLock=PlaybackFlowTrace.begin(.condition,parent:PlaybackFlowTrace.nativeParent)
        condition.lock();PlaybackFlowTrace.end(flowLock,.condition); defer { condition.unlock() }
        inFlight = 0; returns += 1
        if !value.valid { failures += 1 }
        if !accepting || !value.valid { discarded += value.data.count; reply = Reply(data: Data(), valid: false) }
        else { reply = value }
        condition.broadcast()
    }
    func validate() -> Int32 {
        let value = perform { [source, stamp] in
            do { try await source.validate(stamp: stamp); return Reply(data: Data(), valid: true) }
            catch { return Reply(data: Data(), valid: false) }
        }
        return value.valid ? 0 : -1
    }
    func verifyEOF() -> Int32 {
        let value = perform { [source, stamp] in
            do { try await source.verifyEOF(stamp: stamp); return Reply(data: Data(), valid: true) }
            catch { return Reply(data: Data(), valid: false) }
        }
        return value.valid ? 0 : -1
    }
    func read(offset: UInt64, count: Int, output: UnsafeMutablePointer<UInt8>) -> Int {
        guard count >= 0, count <= 524_288, offset <= UInt64.max - UInt64(count) else { return -1 }
        let value = perform { [source, stamp, file] in
            var data = Data()
            do {
                // Exact source owners already validate identity/revision before and after actual IO.
                // Do not add a fresh SMB metadata roundtrip around every tiny VLC read.
                data = try await source.readVLCInput(stamp: stamp, file: file, range: offset..<(offset + UInt64(count)))
                return Reply(data: data, valid: data.count == count)
            } catch { return Reply(data: data, valid: false) }
        }
        guard value.valid else { return -1 }
        let flowLock=PlaybackFlowTrace.begin(.condition,parent:PlaybackFlowTrace.nativeParent)
        condition.lock();PlaybackFlowTrace.end(flowLock,.condition); defer { condition.unlock() }
        // Serialize actual callback publication with invalidate(), not just task completion.
        guard accepting else { discarded += value.data.count; return -1 }
        PlaybackFlowTrace.measure(.callbackCopy,parent:PlaybackFlowTrace.nativeParent){value.data.copyBytes(to: output, count: value.data.count)}
        published += value.data.count; return value.data.count
    }
    func taskAfterJoin() -> Task<Void, Never>? { condition.lock(); defer { condition.unlock() }; return lastTask }
    func clearTaskAfterDrain() { condition.lock(); lastTask = nil; condition.unlock() }
    func snapshot() -> ReadMetrics {
        let flowLock=PlaybackFlowTrace.begin(.condition,parent:PlaybackFlowTrace.nativeParent)
        condition.lock();PlaybackFlowTrace.end(flowLock,.condition); defer { condition.unlock() }
        return ReadMetrics(accepting: accepting, calls: calls, returns: returns, inFlight: inFlight, peakInFlight: peak, publishedBytes: published, discardedBytes: discarded, sourceFailures: failures)
    }
}
