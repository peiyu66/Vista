import Foundation

private struct CallbackResult: Sendable { let data: Data; let success: Bool }
struct AdapterBridgeSnapshot: Codable, Sendable {
    let accepting: Bool; let calls: Int; let returns: Int; let inFlight: Int
    let peakInFlight: Int; let returnedBytes: Int; let staleBytesDiscarded: Int
}
// Context lifetime spans C++ start through actual std::thread/pthread join.
// Callback only waits on that single C++ parser owner; never MainActor.
private final class SourceCallbackContext: @unchecked Sendable {
    let window: LocalWindowByteSource; let journal: AdapterJournal
    private let condition = NSCondition()
    private var accepting = true, inFlight = 0, calls = 0, returns = 0, peak = 0, returned = 0, discarded = 0
    private var result: CallbackResult?
    private var lastTask: Task<Void, Never>?
    init(window: LocalWindowByteSource) { self.window = window; journal = window.owner.journal }
    func invalidate() {
        condition.lock(); accepting = false; condition.broadcast(); condition.unlock()
        journal.add("adapter_new_reads_and_publication_invalidated", stamp: window.stamp)
    }
    func perform(_ operation: @escaping @Sendable () async throws -> Data) -> CallbackResult {
        precondition(!Thread.isMainThread)
        condition.lock(); defer { condition.unlock() }
        guard accepting else { return CallbackResult(data: Data(), success: false) }
        precondition(inFlight == 0 && result == nil)
        calls += 1; inFlight = 1; peak = max(peak, inFlight)
        let id = UInt64(calls)
        journal.add("adapter_async_call_issued", stamp: window.stamp, readID: id)
        let previous = lastTask
        lastTask = Task.detached { [self, previous] in
            if let previous { await previous.value }
            do { complete(try await operation(), error: nil, id: id) }
            catch { complete(Data(), error: String(describing: error), id: id) }
        }
        while result == nil { condition.wait() }
        let out = result!; result = nil
        return out
    }
    private func complete(_ data: Data, error: String?, id: UInt64) {
        condition.lock(); defer { condition.unlock() }
        precondition(inFlight == 1); inFlight = 0; returns += 1
        if !accepting { discarded += data.count; result = CallbackResult(data: Data(), success: false) }
        else { returned += data.count; result = CallbackResult(data: data, success: error == nil) }
        journal.add("adapter_async_call_actually_returned", stamp: window.stamp, readID: id, bytes: data.count, detail: error ?? (accepting ? "accepted" : "stale discarded"))
        condition.broadcast()
    }
    func read(offset: UInt64, count: UInt32, output: UnsafeMutablePointer<UInt8>) -> Int32 {
        guard count <= 262_144, offset <= window.owner.knownSize, UInt64(count) <= window.owner.knownSize - offset else { return -1 }
        let out = perform { [window] in try await window.read(window.owner.file, range: offset..<(offset + UInt64(count))) }
        guard out.success && out.data.count == Int(count) else { return -2 }
        out.data.copyBytes(to: output, count: Int(count)); return 0
    }
    func validate() -> Int32 { perform { [window] in try await window.owner.validate(stamp: window.stamp); return Data() }.success ? 1 : 0 }
    func eof() -> Int32 { perform { [window] in try await window.owner.verifyEOF(stamp: window.stamp); return Data() }.success ? 1 : 0 }
    func tasksAfterJoin() -> [Task<Void, Never>] { condition.lock(); defer { condition.unlock() }; return lastTask.map { [$0] } ?? [] }
    func clearTasksAfterCompletion() { condition.lock(); lastTask = nil; condition.unlock() }
    func snapshot() -> AdapterBridgeSnapshot {
        condition.lock(); defer { condition.unlock() }
        return AdapterBridgeSnapshot(accepting: accepting, calls: calls, returns: returns, inFlight: inFlight, peakInFlight: peak, returnedBytes: returned, staleBytesDiscarded: discarded)
    }
}
private let adapterReadCallback: @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt32, UnsafeMutablePointer<UInt8>?) -> Int32 = { context, offset, count, output in
    guard let context, let output else { return -1 }
    return Unmanaged<SourceCallbackContext>.fromOpaque(context).takeUnretainedValue().read(offset: offset, count: count, output: output)
}
private let adapterValidateCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
    guard let context else { return 0 }
    return Unmanaged<SourceCallbackContext>.fromOpaque(context).takeUnretainedValue().validate()
}
private let adapterEOFCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
    guard let context else { return 0 }
    return Unmanaged<SourceCallbackContext>.fromOpaque(context).takeUnretainedValue().eof()
}
private final class ProducerHandle: @unchecked Sendable {
    let value: OpaquePointer
    init(_ value: OpaquePointer) { self.value = value }
}
@MainActor final class SourceAdapterSession {
    let stamp: BridgeStamp
    private let owner: any SourceOperationOwner
    private let performanceBaseline: LocalSourcePerformance
    private let context: SourceCallbackContext
    private var handle: ProducerHandle?
    private var drainTask: Task<BridgeDrainAck, Error>?
    private var drained = false
    private init(owner: any SourceOperationOwner, context: SourceCallbackContext, handle: OpaquePointer, performanceBaseline: LocalSourcePerformance) {
        self.owner = owner; self.context = context; self.handle = ProducerHandle(handle); stamp = context.window.stamp
        self.performanceBaseline = performanceBaseline
    }
    static func create(owner: any SourceOperationOwner, output: URL, receipt: URL, generation: UInt64, requestedGlobalNS: Int64, maxUnackedSegments: UInt32) async throws -> SourceAdapterSession {
        // The source observer is lifetime-monotonic. Include beginWindow's identity
        // observation in this generation without resetting any source/IO state.
        let performanceBaseline = owner.performanceSnapshot()
        let window = try await owner.beginWindow(generation: generation)
        let context = SourceCallbackContext(window: window)
        let callbacks = SAPSourceCallbacks(context: Unmanaged.passUnretained(context).toOpaque(), knownSize: owner.knownSize, readExact: adapterReadCallback, validate: adapterValidateCallback, verifyEOF: adapterEOFCallback, readExactChecksRevision: 1)
        guard let handle = sap_create(callbacks, output.path, receipt.path, generation, requestedGlobalNS, maxUnackedSegments) else {
            _ = try await owner.retireAndDrain(stamp: window.stamp); throw AdapterFailure.rejected("producer create")
        }
        return SourceAdapterSession(owner: owner, context: context, handle: handle, performanceBaseline: performanceBaseline)
    }
    func start() -> Bool { guard let handle else { return false }; return sap_start(handle.value) == 1 }
    // Copy while the owner still exists, before cancellation/drain/destroy removes it.
    func diagnosticSnapshot() throws -> SAPDiagnostics {
        guard let handle else { throw AdapterFailure.rejected("producer destroyed") }
        var value = SAPDiagnostics()
        guard sap_diagnostics(handle.value, &value) == 1 else { throw AdapterFailure.rejected("producer diagnostics") }
        return value
    }
    // Synchronous scalar copy only: no IO, source-queue barrier or revision check.
    // A saturated or nonmonotonic source counter remains explicitly out of range.
    func performanceSnapshot() -> LocalSourcePerformance {
        let current = owner.performanceSnapshot(), baseline = performanceBaseline
        func delta(_ value: UInt64, _ start: UInt64) -> UInt64 {
            value == UInt64.max || value < start ? UInt64.max : value - start
        }
        return LocalSourcePerformance(
            coordinationCalls: delta(current.coordinationCalls, baseline.coordinationCalls),
            coordinationNS: delta(current.coordinationNS, baseline.coordinationNS),
            coordinationWaitNS: delta(current.coordinationWaitNS, baseline.coordinationWaitNS),
            identityCalls: delta(current.identityCalls, baseline.identityCalls),
            identityNS: delta(current.identityNS, baseline.identityNS),
            preadCalls: delta(current.preadCalls, baseline.preadCalls),
            preadNS: delta(current.preadNS, baseline.preadNS))
    }
    nonisolated static func diagnosticReason(_ code: UInt32) -> String {
        var bytes = [CChar](repeating: 0, count: 512)
        _ = sap_reason_message(code, &bytes, UInt32(bytes.count))
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    func status() -> Int32 { guard let handle else { return -1 }; return sap_status(handle.value) }
    func snapshot() throws -> SAPSnapshot {
        guard let handle else { throw AdapterFailure.rejected("producer destroyed") }
        var snapshot = SAPSnapshot(); guard sap_snapshot(handle.value, &snapshot) == 1 else { throw AdapterFailure.rejected("producer snapshot") }; return snapshot
    }
    // Validate before importing staging into a publicly leased store. This fresh
    // metadata observation is not a global atomic publication transaction.
    func validateRevision() async throws { try await owner.validate(stamp: stamp) }
    func cancel() {
        context.invalidate()
        if let handle { sap_cancel(handle.value) }
    }
    func lastError() -> String { guard let handle else{return "producer destroyed"};var bytes=[CChar](repeating:0,count:512);_ = sap_error(handle.value,&bytes,UInt32(bytes.count));return String(cString:bytes) }
    func acknowledgeImported(index: UInt32) async throws { guard let handle, sap_ack_imported(handle.value,index) == 1 else { throw AdapterFailure.rejected("import acknowledgement order") } }
    func segmentInfo(index: UInt32) throws -> SAPSegmentInfo { guard let handle else { throw AdapterFailure.rejected("destroyed") }; var info=SAPSegmentInfo();guard sap_segment_info(handle.value,index,&info)==1 else { throw AdapterFailure.rejected("segment unavailable") };return info }
    func bridgeSnapshot() -> AdapterBridgeSnapshot { context.snapshot() }
    func drain() async throws -> BridgeDrainAck {
        if let task = drainTask { return try await task.value }
        guard let handle else { throw AdapterFailure.rejected("producer destroyed") }
        let context = self.context, owner = self.owner, stamp = self.stamp
        let task = Task<BridgeDrainAck, Error> {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    precondition(!Thread.isMainThread)
                    sap_join(handle.value)
                    owner.journal.add("adapter_actual_producer_thread_joined", stamp: stamp)
                    continuation.resume()
                }
            }
            // Natural completion can be joined without cancel. From now on close
            // callback admission and prove actual task + source operation drain.
            context.invalidate()
            for task in context.tasksAfterJoin() { await task.value }
            context.clearTasksAfterCompletion()
            let witness = try await owner.retireAndDrain(stamp: stamp)
            let snapshot = context.snapshot()
            guard snapshot.inFlight == 0 && snapshot.calls == snapshot.returns else { throw AdapterFailure.rejected("callback invocation not drained") }
            let ack = BridgeDrainAck(stamp: stamp, sourceReadInvocationsReturned: true, parserOwnerPthreadJoined: true, uncancelledSourceTasksCompleted: true, sourceQuiescenceConfirmed: true, sourceWitness: witness, sourceReadCalls: snapshot.calls, sourceReturnCalls: snapshot.returns, coversUnobservedSourceBackgroundTransport: false)
            owner.journal.add("adapter_full_drain_ack", stamp: stamp)
            self.drained = true
            return ack
        }
        drainTask = task
        return try await task.value
    }
    func destroy() throws {
        guard drained, let handle else { throw AdapterFailure.rejected("destroy before actual drain") }
        sap_destroy(handle.value); self.handle = nil
        owner.journal.add("adapter_producer_destroyed", stamp: stamp)
    }
}
