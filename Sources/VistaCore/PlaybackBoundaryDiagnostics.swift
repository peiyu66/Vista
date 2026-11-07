import Foundation

/// Fixed numeric call boundaries, not proof of presentation, task drainage, or successful recovery.
/// The value is stored in `phase`; never replace it with an error description or runtime type name.
public enum PlaybackBoundaryStage:Int,CaseIterable,Sendable {
    case generationChanged=1,sceneEntered=2,sceneReturned=3,pauseEntered=4,pauseReturned=5
    case frameObserved=6,submitEntered=7,submitQueued=8,submitReturned=9,workerEntered=10
    case requiresFlushObserved=11,recoveryDecision=12,flushEntered=13,flushReturned=14
    case sampleEntered=15,sampleReturned=16,enqueueEntered=17,enqueueReturned=18
    case resultEnabled=19,discarded=20,failure=21,stopEntered=22,stopReturned=23
    case readinessWaitEntered=24,readinessWaitReturned=25,materialEntered=26,materialReturned=27
    case workerExited=28,upstreamPauseEntered=29,upstreamPauseReturned=30
}

/// A bounded observation window. Only genuine lifecycle/session/settings/recovery boundaries
/// may call `begin`. Normal frames and polling never replenish the budget, even if generation differs.
/// Every admitted record waits for the existing critical journal, or its caught failure, before returning.
@MainActor public final class PlaybackBoundaryTrace {
    /// Retain across an await to keep entry/return observations in their original window.
    /// The trace keeps only its current context; retained work owns any earlier context's lifetime.
    @MainActor public final class Context {
        public let epoch:UInt64
        fileprivate weak var owner:PlaybackBoundaryTrace?
        fileprivate let reason:Int
        fileprivate var remaining=PlaybackBoundaryTrace.eventLimitPerEpoch
        fileprivate var recorded:Set<PlaybackBoundaryStage>=[]
        fileprivate init(owner:PlaybackBoundaryTrace,epoch:UInt64,reason:Int) {
            self.owner=owner;self.epoch=epoch;self.reason=reason
        }
    }
    public static let eventLimitPerEpoch=48
    public let traceID:UInt64
    public private(set) var epoch:UInt64=0
    private let scope:Int,diagnostics:LifecycleDiagnostics
    private var current:Context?

    public init(scope:Int,diagnostics:LifecycleDiagnostics = .shared) {
        self.scope=scope;self.diagnostics=diagnostics;traceID=diagnostics.nextID()
    }

    /// Starts a new low-volume window and records its generation snapshot, even if unchanged.
    /// `reason` is a fixed call-site code, not data derived from a media identifier or error text.
    @discardableResult public func begin(reason:Int,generation:Int)->Context {
        epoch += 1
        let context=Context(owner:self,epoch:epoch,reason:reason);current=context
        record(.generationChanged,generation:generation)
        return context
    }

    public func context()->Context? {current}

    /// Check this before evaluating renderer/player getters on a hot path. Does not consume budget.
    /// There is no reservation across an `await`; `record` checks admission again when actually called.
    public func shouldRecord(_ stage:PlaybackBoundaryStage,once:Bool=true,context:Context?=nil)->Bool {
        guard let context=context ?? current,context.owner === self else{return false}
        return context.remaining>0 && (!once || !context.recorded.contains(stage))
    }

    /// Default admission is once per stage per epoch. `once:false` remains subject to the same hard cap.
    /// A failed journal write consumes admission too: ordinary frames must not repeatedly retry disk I/O.
    public func record(_ stage:PlaybackBoundaryStage,generation:Int,fields:[LifecycleField:Double]=[:],once:Bool=true,context:Context?=nil) {
        guard let context=context ?? current,shouldRecord(stage,once:once,context:context) else{return}
        context.remaining -= 1;context.recorded.insert(stage)
        var values=fields
        // These correlation fields belong to the trace; caller snapshots cannot replace them.
        // `detail` remains caller-owned for a fixed stage-specific reason, separate from epoch cause.
        values[.scope]=Double(scope);values[.phase]=Double(stage.rawValue)
        values[.trace]=Double(traceID);values[.epoch]=Double(context.epoch)
        values[.cause]=Double(context.reason);values[.generation]=Double(generation)
        diagnostics.record(.playbackBoundary,values)
    }
}

/// Matches the same live frame session across controller and presenter without recording its UUID.
/// Entries live only in process memory. After eviction, seeing an old session assigns a new numeric ID.
/// Session IDs use their own counter, independent from trace/logger IDs, and never initialize a logger.
@MainActor public enum PlaybackBoundaryIdentity {
    private static let sessions=PlaybackBoundarySessionIdentities()
    public static func session(_ id:UUID)->UInt64 {sessions.session(id)}
}

/// Pure in-memory identity map. Creating or using one has no logger or filesystem dependency.
@MainActor final class PlaybackBoundarySessionIdentities {
    static let capacity=64
    private var identifier:UInt64=0
    private var identifiers:[UUID:UInt64]=[:],order:[UUID]=[]
    var count:Int {identifiers.count}
    func session(_ id:UUID)->UInt64 {
        if let existing=identifiers[id] {return existing}
        if order.count>=Self.capacity {identifiers.removeValue(forKey:order.removeFirst())}
        identifier += 1
        identifiers[id]=identifier;order.append(id)
        return identifier
    }
}
