import Foundation

#if DEBUG || VISTA_DIAGNOSTICS
/// Observations only. No decoder callbacks are provided by AVPlayer's pull-output API.
/// Correlation identifies byte reads, never compressed samples or decoded frames.
public enum MP4SeekDiagnosticContext {
    @TaskLocal public static var trace: MP4SeekDiagnostics?
}

public final class MP4SeekDiagnostics: @unchecked Sendable {
    public enum Stage: Int, Sendable, Hashable {
        case entered=1, seekIssued, seekAwaitReturned, outputAvailable, copyStarted, copyReturned
        case frameDelivered, presentationNotified, terminal, closingState
        case readChunkLimit=11
        case earlyPlayCommand=12, seekCompletionCallback, pendingOutputProbe, pendingOutputAvailable
        case bridgeStarted=20, bridgeReturned, bridgeResponded, bridgeFailed, initialBridge, initialRequest
        case sourceStarted=30, sourceReturned, sourceFailed, initialSource
        case cacheSelection=40, wrapperReturned, wrapperCancelled, wrapperFailed, initialQueuedWork, cacheSpan
        case smbStarted=50, smbReturned, smbFailed
    }
    /// Independent from ordinary playback/gesture journals. Four 1 MiB files,
    /// existing 7-day retention. No per-row fsync, OSLog mirror or player wait.
    public static let writer = LifecycleDiagnostics(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VistaMP4SeekDiagnostics", isDirectory: true),
        fileLimit: 1_048_576, pendingLimit: 256, mirror: false, criticalDurability: false)
    public static let detailLimit = 2048
    private let lock=NSLock(), writer:LifecycleDiagnostics
    public let id:UInt64, epoch:Int
    private var closed=false, count=0, suppressed=0
    private var stages:Set<Stage>=[]
    public var wantsDetail:Bool {
        lock.lock();defer{lock.unlock()};return !closed && count<Self.detailLimit
    }
    public init(epoch:Int, target:Double, sourceKind:Int, writer:LifecycleDiagnostics = MP4SeekDiagnostics.writer) {
        self.writer=writer;self.epoch=epoch;id=writer.nextID()
        record(.entered,fields:[.seekTarget:target,.sourceKind:Double(sourceKind)],boundary:true)
    }
    /// Fixed boundary rows are reserved separately from per-seek detail admission.
    /// Timestamp is taken at the call site; JSON encoding/writing runs off the player.
    public func record(_ stage:Stage, fields:[LifecycleField:Double]=[:],
                       correlation:PlaybackReadCorrelation?=nil, boundary:Bool=false) {
        let at=ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !closed else{lock.unlock();return}
        if boundary {
            guard stages.insert(stage).inserted else{lock.unlock();return}
        } else {
            guard count<Self.detailLimit else{suppressed+=1;lock.unlock();return}
            count+=1
        }
        var v=fields
        v[.trace]=Double(id);v[.epoch]=Double(epoch);v[.phase]=Double(stage.rawValue)
        v[.nativeClock]=at;v[.diagnosticCount]=Double(count);v[.diagnosticSuppressed]=Double(suppressed)
        if let c=correlation {v[.bridgeID]=Double(c.bridge);v[.request]=Double(c.request);v[.chunkID]=Double(c.chunk);v[.readSeekEpoch]=Double(c.seek)}
        // Serialize admission and close: no detail can be enqueued after terminal.
        writer.record(.mp4Seek,v,priority:boundary)
        lock.unlock()
    }
    /// reason: 1 presentation notification, 2 superseded, 3 stopped, 4 cancelled.
    /// Terminal is an observation boundary, not proof outstanding reads drained.
    public func close(_ reason:Int) {
        lock.lock();defer{lock.unlock()}
        guard !closed else{return};closed=true
        writer.record(.mp4Seek,[.trace:Double(id),.epoch:Double(epoch),.phase:Double(Stage.terminal.rawValue),
            .detail:Double(reason),.nativeClock:ProcessInfo.processInfo.systemUptime,
            .diagnosticCount:Double(count),.diagnosticSuppressed:Double(suppressed)])
    }
    public static func rangeFields(_ range:Range<UInt64>) -> [LifecycleField:Double] {
        [.rangeLower:Double(range.lowerBound),.rangeUpper:Double(range.upperBound)]
    }
    /// Relative geometry against the full current cache union. Empty cache is not
    /// mislabeled a hole. No filename, payload or persistent media identifier.
    public static func cacheFields(range:Range<UInt64>, spans:[Range<UInt64>]) -> [LifecycleField:Double] {
        var v=rangeFields(range)
        let sorted=spans.filter{!$0.isEmpty}.sorted{$0.lowerBound<$1.lowerBound}
        guard let lo=sorted.first?.lowerBound,let hi=sorted.map(\.upperBound).max() else {
            v[.cacheEmpty]=1;v[.cacheOverlapBytes]=0;return v
        }
        var cursor=range.lowerBound,overlap:UInt64=0
        for s in sorted {
            let a=max(cursor,s.lowerBound),b=min(range.upperBound,s.upperBound)
            if b>a {overlap+=b-a;cursor=b}
        }
        let before=range.lowerBound<lo ? min(range.upperBound,lo)-range.lowerBound:0
        let after=range.upperBound>hi ? range.upperBound-max(range.lowerBound,hi):0
        v[.cacheEmpty]=0;v[.cacheMin]=Double(lo);v[.cacheMax]=Double(hi)
        v[.cacheBeforeBytes]=Double(before);v[.cacheAfterBytes]=Double(after)
        v[.cacheHoleBytes]=Double(range.upperBound-range.lowerBound-overlap-before-after)
        v[.cacheOverlapBytes]=Double(overlap);return v
    }
    public func work(_ stage:Stage,_ w:PlaybackRangeDiagnostics.Work) {
        var v:[LifecycleField:Double]=[.sourceCallID:Double(w.id),.sourceCallKind:Double(w.kind.rawValue),.queuedAt:w.queued,
            .selectedCacheBytes:Double(w.selectedBytes),.available:w.selectionObserved ? 1:0]
        if let r=w.range{v[.rangeLower]=Double(r.lower);v[.rangeUpper]=Double(r.upper)}
        if let t=w.started{v[.startedAt]=t};if let t=w.finished{v[.finishedAt]=t}
        if let n=w.usedCachedBytes{v[.usedCacheBytes]=Double(n)};if let n=w.bytes{v[.bytes]=Double(n)}
        if let r=w.result{v[.outcome]=Double(r.rawValue)}
        v[.generation]=Double(w.generation)
        if let t=w.callStarted{v[.sampledStart]=t}
        if let t=w.callFinished{v[.durationMS]=(t-(w.callStarted ?? t))*1000}
        record(stage,fields:v,correlation:w.correlation)
    }
    public func completed(_ w:PlaybackRangeDiagnostics.Work) {
        work(w.result == .returned ? .wrapperReturned : w.result == .cancelled ? .wrapperCancelled : .wrapperFailed,w)
    }
}
#endif
