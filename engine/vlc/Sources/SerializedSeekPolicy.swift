// Generic observational policy. No LibVLC, renderer, or source-owner dependency.
// All state transitions must be called on one serialized controller executor.
struct SeekPolicy: Sendable {
    let durationUS: Int64
    let halfWindowUS: Int64
    let observationPolls: Int
    init(durationUS: Int64, halfWindowUS: Int64 = 250_000, observationPolls: Int = 200) {
        precondition(durationUS > 0 && halfWindowUS > 0 && observationPolls > 0)
        self.durationUS = durationUS; self.halfWindowUS = halfWindowUS; self.observationPolls = observationPolls
    }
    func matchesProducer(_ observed: UInt64, expected: UInt64) -> Bool { observed == expected }
    func acceptsTarget(_ target: Int64) -> Bool { target >= 0 && target <= durationUS }
    func permitsFrame(ptsUS: Int64, clockUS: Int64) -> Bool {
        ptsUS >= 0 && clockUS >= 0 && abs(ptsUS-clockUS) <= halfWindowUS
    }
    func observedTarget(_ target: Int64, ptsUS: Int64, clockUS: Int64,
                        watchUpdates: UInt64, updatesBeforeDispatch: UInt64) -> Bool {
        acceptsTarget(target) && permitsFrame(ptsUS: ptsUS, clockUS: clockUS) &&
        watchUpdates > updatesBeforeDispatch && abs(ptsUS-target) <= halfWindowUS &&
        abs(clockUS-target) <= halfWindowUS
    }
    // A paused target preview is not an audio-clock acknowledgement. The caller
    // separately validates live pause intent, source/session and frame ownership.
    func observedPausedTarget(_ target:Int64,ptsUS:Int64,displayUS:Int64,
                              commandID:UInt64,witness:PausedSeekWitness)->Bool {
        acceptsTarget(target) && ptsUS>=0 && abs(ptsUS-target)<=halfWindowUS &&
        commandID>0 && witness.commandID==commandID && witness.targetUS==target &&
        witness.startMatched && witness.ended && !witness.ambiguous &&
        witness.startSequence>0 && witness.endSequence>witness.startSequence &&
        witness.beginUS>0 && witness.endUS>=witness.beginUS && displayUS>=witness.endUS
    }
}

struct PausedSeekWitness:Sendable {
    let commandID:UInt64,targetUS:Int64,beginUS:Int64,endUS:Int64
    let startSequence:UInt64,endSequence:UInt64
    let startMatched:Bool,ended:Bool,ambiguous:Bool
}

// Reusable UI-target coalescing state; callbacks and source identity are NOT tagged
// or relabelled with these nonces. A nonce labels only our own request/report.
struct SerializedSeekGate: Sendable {
    struct Request: Equatable, Sendable { let nonce: UInt64; let targetUS: Int64 }
    private(set) var nextNonce: UInt64 = 0
    private(set) var active: Request?
    private(set) var pending: Request?
    private(set) var suppressed = false
    private(set) var blocked = false
    private(set) var stopped = false
    let policy: SeekPolicy

    mutating func request(_ target: Int64) -> (request: Request, replaced: Request?)? {
        guard !stopped, !blocked, policy.acceptsTarget(target), nextNonce < UInt64.max else { return nil }
        nextNonce += 1
        let request = Request(nonce: nextNonce, targetUS: target)
        let old = pending
        pending = request; suppressed = true
        return (request, old)
    }
    // Call after suppressing/clearing snapshots, before awaiting external renderer drain.
    // Calling again while a native operation is active returns nil.
    mutating func begin() -> Request? {
        guard !stopped, !blocked, active == nil, let request = pending else { return nil }
        pending = nil; active = request
        return request
    }
    // Optional before native dispatch: newer target arrived while awaiting drain.
    mutating func supersedeUndispatched(nonce: UInt64) -> Bool {
        guard active?.nonce == nonce, pending != nil else { return false }
        active = nil; return true
    }
    // observed=true is the bounded policy decision, NOT an upstream flush acknowledgement.
    mutating func finish(nonce: UInt64, observed: Bool) -> Bool {
        guard !stopped, active?.nonce == nonce else { return false }
        active = nil
        if !observed { blocked = true; suppressed = true }
        else { suppressed = pending != nil }
        return true
    }
    // Only for an operation known not to have been accepted by native VLC.
    // Never clears a blocked/stopped gate or claims observation success.
    mutating func cancelUnaccepted(nonce: UInt64) -> Bool {
        guard !stopped, !blocked else { return false }
        var changed=false
        if active?.nonce == nonce { active=nil; changed=true }
        if pending?.nonce == nonce { pending=nil; changed=true }
        if changed { suppressed = active != nil || pending != nil }
        return changed
    }
    // A newer explicit user seek supersedes only the driver's automatic recovery
    // observation. Presentation remains suppressed until the NEW target is observed.
    mutating func supersedeRecovery(nonce: UInt64) -> Bool {
        guard !stopped, !blocked, active?.nonce == nonce, pending != nil else { return false }
        active=nil; suppressed=true; return true
    }
    mutating func retargetRecovery(nonce: UInt64, targetUS: Int64) -> Bool {
        guard !stopped, !blocked, active?.nonce == nonce, policy.acceptsTarget(targetUS) else { return false }
        active=Request(nonce:nonce,targetUS:targetUS); return true
    }
    mutating func stop() { stopped = true; suppressed = true; pending = nil; active = nil }
}
