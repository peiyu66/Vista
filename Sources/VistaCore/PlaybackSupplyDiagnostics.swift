import Foundation

/// Fixed-size, anonymous observations of the serial wrapper. These are Swift source
/// calls, which may perform cache assembly/recovery, never physical SMB RPCs.
public struct PlaybackSupplyDiagnostics: Sendable {
    public enum Kind: Int, Codable, Sendable { case size = 1, demand = 2, prefetch = 3 }
    public enum CallKind: Int, Codable, Sendable { case size = 1, read = 2, cachedSegments = 3, prefetch = 4 }
    public enum Result: Int, Codable, Sendable { case returned = 1, cancelled = 2, failed = 3 }
    public struct Work: Codable, Sendable, Equatable {
        public let kind: Kind, id: UInt64, generation: UInt64, epoch: UInt64?
        public let started: Double
        public var cancelled: Bool = false
        enum CodingKeys: String, CodingKey { case kind = "k", id = "id", generation = "g", epoch = "e", started = "t", cancelled = "c" }
    }
    public struct Call: Codable, Sendable, Equatable {
        public let kind: CallKind, work: Work, started: Double
        public let observedEpoch: UInt64?, generation: UInt64?
        enum CodingKeys: String, CodingKey { case kind = "k", work = "w", started = "t", observedEpoch = "e", generation = "g" }
    }
    public struct Completion: Codable, Sendable, Equatable {
        public let call: Call, finished: Double, bytes: Int, result: Result
        enum CodingKeys: String, CodingKey { case call = "c", finished = "t", bytes = "b", result = "r" }
    }
    public struct Snapshot: Codable, Sendable, Equatable {
        public let session: UInt64, generation: UInt64, epoch: UInt64?, queueDepth: Int
        public let oldestQueuedAt: Double?, work: Work?, call: Call?, lastReturn: Completion?
        enum CodingKeys: String, CodingKey { case session = "s", generation = "g", epoch = "e", queueDepth = "q", oldestQueuedAt = "qt", work = "w", call = "c", lastReturn = "r" }
    }
    public private(set) var work: Work?, call: Call?, lastReturn: Completion?
    public init() {}
    public mutating func beginWork(kind: Kind, id: UInt64, generation: UInt64, epoch: UInt64?, now: Double) {
        guard now.isFinite, now >= 0 else { return }
        work = Work(kind: kind, id: id, generation: generation, epoch: epoch, started: now)
    }
    public mutating func cancelWork(id: UInt64) { if work?.kind != .prefetch, work?.id == id { work?.cancelled = true } }
    public mutating func endWork() { work = nil }
    public mutating func beginCall(kind: CallKind, now: Double, observedEpoch: UInt64? = nil, generation: UInt64? = nil) {
        guard let work, now.isFinite, now >= work.started else { return }
        call = Call(kind: kind, work: work, started: now, observedEpoch: observedEpoch, generation: generation)
    }
    public mutating func endCall(result: Result, bytes: Int, now: Double) {
        guard let call else { return }
        self.call = nil
        guard now.isFinite, now >= call.started else { return }
        lastReturn = Completion(call: call, finished: now, bytes: max(0, bytes), result: result)
    }
    /// No source epoch getter is invoked here. `epoch` is the wrapper's last
    /// validated observation, not a claim that a recovering source is still usable.
    public func snapshot(session: UInt64, generation: UInt64, epoch: UInt64?, queueDepth: Int, oldestQueuedAt: Double?) -> Snapshot {
        .init(session: session, generation: generation, epoch: epoch, queueDepth: max(0, queueDepth),
              oldestQueuedAt: oldestQueuedAt.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }, work: work, call: call, lastReturn: lastReturn)
    }
}

/// Numeric, ephemeral identity. A bridge request is an AV loading request; a chunk
/// is one bounded source.read. Neither ID is a pointer, file ID or source work ID.
public struct PlaybackReadCorrelation: Codable, Sendable, Equatable {
    public let bridge: UInt64, request: UInt64, chunk: UInt64, seek: Int
    enum CodingKeys: String, CodingKey { case bridge = "b", request = "r", chunk = "c", seek = "s" }
    public init(bridge: UInt64, request: UInt64, chunk: UInt64, seek: Int) {
        self.bridge = bridge; self.request = request; self.chunk = chunk; self.seek = seek
    }
}
public enum PlaybackReadDiagnosticContext {
    @TaskLocal public static var correlation: PlaybackReadCorrelation?
}

/// Scalar-only rolling evidence. Request-time intersection detail is explicitly
/// capped; the complete boundary-time arena map is a separate observation.
public struct PlaybackRangeDiagnostics: Sendable {
    public static let historyLimit = 64, intersectionLimit = 8, queueLimit = 8, mapLimit = 1024
    public struct Span: Codable, Sendable, Equatable {
        public let lower: UInt64, upper: UInt64
        enum CodingKeys: String, CodingKey { case lower = "l", upper = "u" }
        public init(_ range: Range<UInt64>) { lower = range.lowerBound; upper = range.upperBound }
        // Compact typed pairs keep all four 1,024-entry maps plus both recent
        // histories inside one archive record without dropping precision.
        public func encode(to encoder: any Encoder) throws {
            var values=encoder.unkeyedContainer();try values.encode(lower);try values.encode(upper)
        }
        public init(from decoder: any Decoder) throws {
            var values=try decoder.unkeyedContainer();lower=try values.decode(UInt64.self);upper=try values.decode(UInt64.self)
        }
    }
    public struct Work: Codable, Sendable, Equatable {
        public let kind: PlaybackSupplyDiagnostics.Kind, id: UInt64, generation: UInt64, queued: Double
        public let range: Span?, correlation: PlaybackReadCorrelation?
        public var started: Double?, finished: Double?, selectionEpoch: UInt64?, completionEpoch: UInt64?
        public var result: PlaybackSupplyDiagnostics.Result?, bytes: Int?
        public var publicationRejectedReason: Int?
        public var available: [Span] = [], selected: [Span] = []
        public var selectionObserved = false
        public var availableCount = 0, availableBytes = 0, omittedIntersections = 0
        public var selectedBytes = 0, usedCachedBytes: Int?, fragmentedFallback = false, validationRequired = false
        public var joinedPrefetch: UInt64?, joinedRange: Span?
        public var callKind: PlaybackSupplyDiagnostics.CallKind?, callStarted: Double?, callFinished: Double?
        public var callResult: PlaybackSupplyDiagnostics.Result?, callBytes: Int?
        enum CodingKeys: String, CodingKey {
            case kind="k",id="id",generation="g",queued="q",range="r",correlation="link",started="t",finished="end",selectionEpoch="e",completionEpoch="ce",result="z",bytes="b"
            case publicationRejectedReason="pr",selectionObserved="so",available="a",selected="s",availableCount="ac",availableBytes="ab",omittedIntersections="ao",selectedBytes="sb",usedCachedBytes="ub",fragmentedFallback="ff",validationRequired="v",joinedPrefetch="jp",joinedRange="jr",callKind="ck",callStarted="ct",callFinished="cf",callResult="cz",callBytes="cb"
        }
        public init(kind: PlaybackSupplyDiagnostics.Kind, id: UInt64, generation: UInt64, queued: Double,
                    range: Range<UInt64>?, correlation: PlaybackReadCorrelation?) {
            self.kind=kind;self.id=id;self.generation=generation;self.queued=queued
            self.range=range.map(Span.init);self.correlation=correlation
        }
        public mutating func select(available ranges: [Range<UInt64>], selected chosen: [Range<UInt64>],
                                    epoch: UInt64?, fragmented: Bool, validation: Bool) {
            selectionObserved=true
            availableCount=ranges.count;availableBytes=ranges.reduce(0){$0+$1.count}
            available=Array(ranges.prefix(PlaybackRangeDiagnostics.intersectionLimit)).map(Span.init)
            omittedIntersections=max(0,ranges.count-available.count)
            // Production supplies <=8 islands, or one whole-range full cache hit.
            selected=chosen.map(Span.init);selectedBytes=chosen.reduce(0){$0+$1.count}
            selectionEpoch=epoch;fragmentedFallback=fragmented;validationRequired=validation
        }
    }
    public struct CacheEntry: Codable, Sendable, Equatable {
        public let range: Span
        /// 1 = retained history (original producer unknown), 2 = unused prefetch.
        public let kind: Int, producer: UInt64?, generation: UInt64?, epoch: UInt64?
        enum CodingKeys: String, CodingKey {case range="r",kind="k",producer="p",generation="g",epoch="e"}
        public init(range: Range<UInt64>, producer: UInt64? = nil, generation: UInt64? = nil, epoch: UInt64? = nil) {
            self.range=Span(range);kind=producer == nil ? 1:2;self.producer=producer;self.generation=generation;self.epoch=epoch
        }
        // [range, kind, producer?, generation?, epoch?]. nil producer is unknown
        // history lineage, not request zero and not a reconstructed origin.
        public func encode(to encoder: any Encoder) throws {
            var values=encoder.unkeyedContainer();try values.encode(range);try values.encode(kind)
            try values.encode(producer);try values.encode(generation);try values.encode(epoch)
        }
        public init(from decoder: any Decoder) throws {
            var values=try decoder.unkeyedContainer();range=try values.decode(Span.self);kind=try values.decode(Int.self)
            producer=try values.decodeIfPresent(UInt64.self);generation=try values.decodeIfPresent(UInt64.self);epoch=try values.decodeIfPresent(UInt64.self)
        }
    }
    public struct Forward: Codable, Sendable, Equatable {
        // Read-only state, not a prediction that admission will succeed.
        public let cursor: UInt64?, target: UInt64?, epoch: UInt64?, generation: UInt64?, evidence: Span?
        public let invalidation: Int
        public let windowID: UInt64?, transitionID: UInt64?, transition: Int?
        public let reads: Int, suspended: Bool, enabled: Bool, paused: Bool, quarantined: Bool, reason: Int
        /// Bounded byte-demand coverage, not player media-time buffering.
        public let contiguousAheadBytes: Int?, lowWatermarkBytes: Int?, highWatermarkBytes: Int?, refilling: Bool?
        // reason: 1 stopped/disabled; 2 quarantine/unknown epoch; 3 queued/work;
        // 4 no window; 5 legacy suspended (unused since96); 6 stale window; 7 budget; 8 candidate (grace still applies).
        enum CodingKeys: String, CodingKey {case cursor="c",target="t",epoch="e",generation="g",evidence="v",reads="n",suspended="s",enabled="on",paused="p",quarantined="q",reason="r",invalidation="ir",windowID="id",transitionID="ti",transition="tr",contiguousAheadBytes="ca",lowWatermarkBytes="lo",highWatermarkBytes="hi",refilling="fill"}
        public init(cursor: UInt64?, target: UInt64?, epoch: UInt64?, generation: UInt64?, evidence: Range<UInt64>?, reads: Int,
                    suspended: Bool, enabled: Bool, paused: Bool, quarantined: Bool, reason: Int, invalidation: Int = 0, windowID: UInt64? = nil, transitionID: UInt64? = nil, transition: Int? = nil, contiguousAheadBytes: Int? = nil, lowWatermarkBytes: Int? = nil, highWatermarkBytes: Int? = nil, refilling: Bool? = nil) {
            self.contiguousAheadBytes=contiguousAheadBytes;self.lowWatermarkBytes=lowWatermarkBytes
            self.highWatermarkBytes=highWatermarkBytes;self.refilling=refilling
            self.windowID=windowID;self.transitionID=transitionID;self.transition=transition
            self.cursor=cursor;self.target=target;self.epoch=epoch;self.generation=generation;self.evidence=evidence.map(Span.init)
            self.reads=reads;self.suspended=suspended;self.enabled=enabled;self.paused=paused;self.quarantined=quarantined;self.reason=reason;self.invalidation=invalidation
        }
    }
    public struct Snapshot: Codable, Sendable {
        public let session: UInt64, generation: UInt64, epoch: UInt64?, at: Double
        public let recent: [Work], current: Work?, queued: [Work], queuedOmitted: Int
        public let overwritten: UInt64, observedFrom: Double?, observedThrough: Double?
        public let cache: [CacheEntry], cacheOmitted: Int, forward: Forward
        enum CodingKeys: String, CodingKey {case session="s",generation="g",epoch="e",at="t",recent="h",current="w",queued="q",queuedOmitted="qo",overwritten="lost",observedFrom="from",observedThrough="through",cache="map",cacheOmitted="mo",forward="fw"}
    }
    public private(set) var recent: [Work] = []
    public var current: Work?
    public private(set) var overwritten: UInt64 = 0
    public init() {}
    public mutating func finish(result: PlaybackSupplyDiagnostics.Result, bytes: Int, epoch: UInt64?, now: Double) {
        guard var record=current else{return};current=nil
        record.result=result;record.bytes=bytes;record.completionEpoch=epoch;record.finished=now
        append(record)
    }
    public mutating func append(_ record: Work) {
        if recent.count==Self.historyLimit {recent.removeFirst();if overwritten<UInt64.max {overwritten+=1}}
        recent.append(record)
    }
    public func snapshot(session: UInt64, generation: UInt64, epoch: UInt64?, now: Double, queued: [Work], cache: [CacheEntry], forward: Forward)->Snapshot {
        .init(session:session,generation:generation,epoch:epoch,at:now,recent:recent,current:current,
              queued:Array(queued.prefix(Self.queueLimit)),queuedOmitted:max(0,queued.count-Self.queueLimit),overwritten:overwritten,
              observedFrom:recent.map(\.queued).min(),observedThrough:recent.compactMap(\.finished).max(),
              cache:Array(cache.prefix(Self.mapLimit)),cacheOmitted:max(0,cache.count-Self.mapLimit),forward:forward)
    }
}

/// Actual ResourceBridge API observations, independent of wrapper completion.
/// A returned payload can be rejected; only responded marks respond(with:) called.
public struct PlaybackBridgeDiagnostics: Sendable {
    public struct Request: Codable, Sendable {
        public let id: UInt64, accepted: Double
        public var range: PlaybackRangeDiagnostics.Span?
        enum CodingKeys: String, CodingKey {case id="id",accepted="t",range="r"}
    }
    public struct Chunk: Codable, Sendable {
        public let correlation: PlaybackReadCorrelation, range: PlaybackRangeDiagnostics.Span, started: Double
        public var returnedAt: Double?, returnedBytes: Int?, respondedAt: Double?, deliveredBytes: Int?
        public var finished: Double?, result: Int? // 1 responded, 2 cancelled, 3 failed
        enum CodingKeys: String, CodingKey {case correlation="link",range="r",started="t",returnedAt="rt",returnedBytes="rb",respondedAt="dt",deliveredBytes="db",finished="end",result="z"}
    }
    public struct Snapshot: Codable, Sendable {
        public let session: UInt64, requests: [Request], active: [Chunk], recent: [Chunk], overwritten: UInt64, overflow: UInt64
        public let observedFrom: Double?, observedThrough: Double?
        enum CodingKeys: String, CodingKey {case session="s",requests="q",active="a",recent="h",overwritten="lost",overflow="overflow",observedFrom="from",observedThrough="through"}
    }
    public private(set) var requests: [Request] = [], active: [Chunk] = [], recent: [Chunk] = []
    public private(set) var overwritten: UInt64 = 0, overflow: UInt64 = 0
    public init() {}
    public mutating func accepted(_ id: UInt64, now: Double) {
        guard requests.count<8 else{overflow &+= 1;return}
        requests.append(.init(id:id,accepted:now))
    }
    public mutating func planned(_ id: UInt64, range: Range<UInt64>) {
        if let i=requests.firstIndex(where:{$0.id==id}) {requests[i].range = .init(range)}
    }
    public mutating func ended(_ id: UInt64, cancelled: Bool, now: Double) {
        for record in active.filter({$0.correlation.request==id}) {finish(record.correlation,result:cancelled ? 2:3,now:now)}
        requests.removeAll{$0.id==id}
    }
    public mutating func began(_ correlation: PlaybackReadCorrelation, range: Range<UInt64>, now: Double) {
        guard active.count<8 else{overflow &+= 1;return}
        active.append(.init(correlation:correlation,range:.init(range),started:now))
    }
    public mutating func returned(_ correlation: PlaybackReadCorrelation, bytes: Int, now: Double) {
        if let i=active.firstIndex(where:{$0.correlation==correlation}) {active[i].returnedAt=now;active[i].returnedBytes=bytes}
    }
    public mutating func responded(_ correlation: PlaybackReadCorrelation, bytes: Int, now: Double) {
        if let i=active.firstIndex(where:{$0.correlation==correlation}) {active[i].respondedAt=now;active[i].deliveredBytes=bytes}
        finish(correlation,result:1,now:now)
    }
    public mutating func finish(_ correlation: PlaybackReadCorrelation, result: Int, now: Double) {
        guard let i=active.firstIndex(where:{$0.correlation==correlation}) else{return}
        var record=active.remove(at:i);record.result=result;record.finished=now
        if recent.count==64 {recent.removeFirst();if overwritten<UInt64.max {overwritten+=1}}
        recent.append(record)
    }
    public func snapshot(session: UInt64)->Snapshot {
        .init(session:session,requests:requests,active:active,recent:recent,overwritten:overwritten,overflow:overflow,
              observedFrom:recent.map(\.started).min(),observedThrough:recent.compactMap(\.finished).max())
    }
}

// MARK: - Small VLC seek observations (passive; never used for admission)
/// Small source projection: no cache map, payload, filename, URL or source getter.
public struct PlaybackSeekSourceSnapshot: Codable, Sendable {
    public struct Work: Codable, Sendable {
        public let id: UInt64, kind: Int, generation: UInt64
        public let range: PlaybackRangeDiagnostics.Span?
        public let queued: Double, started: Double?, finished: Double?
        public let callStarted: Double?, callFinished: Double?, callKind: Int?, result: Int?
        public let cachedBytes: Int?, selectedBytes: Int
        enum CodingKeys: String, CodingKey {
            case id,kind="k",generation="g",range="r",queued="q",started="t",finished="end"
            case callStarted="ct",callFinished="cf",callKind="ck",result="z",cachedBytes="ub",selectedBytes="sb"
        }
        public init(_ value: PlaybackRangeDiagnostics.Work) {
            id=value.id;kind=value.kind.rawValue;generation=value.generation;range=value.range
            queued=value.queued;started=value.started;finished=value.finished
            callStarted=value.callStarted;callFinished=value.callFinished;callKind=value.callKind?.rawValue
            result=value.result?.rawValue;cachedBytes=value.usedCachedBytes;selectedBytes=value.selectedBytes
        }
    }
    public let session: UInt64, generation: UInt64, epoch: UInt64?, at: Double
    public let current: Work?, queued: [Work], recent: [Work]
    public let queueOmitted: Int, recentOmitted: Int, historyOverwritten: UInt64
    public let forward: PlaybackRangeDiagnostics.Forward
    public let sourceCalls: UInt64, sourceWaitMS: Double, missBytes: UInt64, historyHitBytes: UInt64
    public let prefetchBytes: UInt64, prefetchWaitMS: Double
    public init(session: UInt64,generation: UInt64,epoch: UInt64?,at: Double,
                current: PlaybackRangeDiagnostics.Work?,queued: [PlaybackRangeDiagnostics.Work],queuedCount: Int,
                recent: [PlaybackRangeDiagnostics.Work],historyOverwritten: UInt64,
                forward: PlaybackRangeDiagnostics.Forward,sourceCalls: UInt64,sourceWaitMS: Double,
                missBytes: UInt64,historyHitBytes: UInt64,prefetchBytes: UInt64,prefetchWaitMS: Double) {
        self.session=session;self.generation=generation;self.epoch=epoch;self.at=at
        self.current=current.map(Work.init);self.queued=queued.prefix(2).map(Work.init)
        self.recent=recent.suffix(4).map(Work.init);queueOmitted=max(0,queuedCount-2)
        recentOmitted=max(0,recent.count-4);self.historyOverwritten=historyOverwritten
        self.forward=forward;self.sourceCalls=sourceCalls;self.sourceWaitMS=sourceWaitMS
        self.missBytes=missBytes;self.historyHitBytes=historyHitBytes
        self.prefetchBytes=prefetchBytes;self.prefetchWaitMS=prefetchWaitMS
    }
}

/// At most intent + dispatch + four elapsed milestones + one terminal per seek.
/// No lifetime quota: later seeks remain observable within the existing journal rotation.
public struct PlaybackVLCSeekDiagnostics: Sendable {
    public enum Stage: Int, Codable, Sendable { case intent=1,dispatch,progress,accepted,superseded,stopped }
    public enum Scalar: String, Sendable {
        case pollAt,rawPTS,clock,watchUpdates,watchFloor,gateMask,framePresent
        case nativeSampleClock,nativeAgeMS,nativeQueueClock,nativeQueuePTS,nativeQueueCount
        case nativePreroll,nativeAdmitted,nativeFlushAbort,nativeFifoPop,nativePoppedPTS
        case nativeNormal,nativeLateDrop,nativeAvailable,nativeVersion
        case vtSubmit,vtCallback,framesTaken,seekRejected,publishedPTS,polls,maxPollGapMS
        case timerValid,timerSeeking,buffering,commandClock
        /// Accepted only: 1=ordinary clock/watch, 2=paused receipt + target preview.
        case completionPath
        case lastRejectNonce,lastRejectAt,lastRejectPTS,lastRejectClock,lastRejectMask,lastRejectWatch
    }
    public struct Record: Codable, Sendable {
        public let schema: Int, session: UInt64, nonce: UInt64, sequence: Int
        public let stage: Stage, target: Double, intentAt: Double, at: Double, dispatchAt: Double?
        public let skippedMilestones: Int, values: [String: Double], source: PlaybackSeekSourceSnapshot?
    }
    private struct Active: Sendable {
        let session: UInt64, nonce: UInt64, target: Double, started: Double
        var dispatchAt: Double?, nextMilestone=0, sequence=0, skipped=0
    }
    private var active: Active?
    private static let milestones=[0.5,1.0,2.0,3.0]
    public init() {}
    public mutating func begin(session: UInt64,nonce: UInt64,target: Double,now: Double) {
        guard target.isFinite,target>=0,now.isFinite,now>=0 else{return}
        active=Active(session:session,nonce:nonce,target:target,started:now)
    }
    public func isActive(nonce: UInt64?=nil)->Bool {
        guard let active else{return false};return nonce==nil || nonce==active.nonce
    }
    public func due(nonce: UInt64,now: Double)->Bool {
        guard let a=active,a.nonce==nonce,a.nextMilestone<Self.milestones.count else{return false}
        return now.isFinite && now-a.started>=Self.milestones[a.nextMilestone]
    }
    public mutating func record(_ stage: Stage,nonce: UInt64?=nil,now: Double,
                                values: [Scalar:Double],source: PlaybackSeekSourceSnapshot?)->Record? {
        guard var a=active,nonce==nil || nonce==a.nonce,now.isFinite,now>=a.started else{return nil}
        switch stage {
        case .intent: guard a.sequence==0 else{return nil}
        case .dispatch: guard a.dispatchAt==nil else{return nil};a.dispatchAt=now
        case .progress:
            guard due(nonce:a.nonce,now:now) else{return nil}
            var crossed=0
            while a.nextMilestone<Self.milestones.count,now-a.started>=Self.milestones[a.nextMilestone] {
                a.nextMilestone += 1;crossed += 1
            }
            a.skipped += max(0,crossed-1)
        case .accepted,.superseded,.stopped: break
        }
        guard a.sequence<7 else{return nil}
        a.sequence += 1
        let result=Record(schema:1,session:a.session,nonce:a.nonce,sequence:a.sequence,stage:stage,
            target:a.target,intentAt:a.started,at:now,dispatchAt:a.dispatchAt,
            skippedMilestones:a.skipped,values:Dictionary(uniqueKeysWithValues:values.filter{$0.value.isFinite}.map{($0.key.rawValue,$0.value)}),source:source)
        switch stage {case .accepted,.superseded,.stopped:active=nil;default:active=a}
        return result
    }
    /// Diagnostic only; mirrors the existing precise policy without affecting it.
    /// 1=no frame, 2=invalid PTS, 4=PTS off target, 8=PTS/clock mismatch,
    /// 16=clock off target/invalid, 32=no post-dispatch watch update.
    public static func gateMask(frame: Bool,ptsUS: Int64?,targetUS: Int64,clockUS: Int64,
                                watchUpdates: UInt64,watchFloor: UInt64,halfWindowUS: Int64)->Int {
        var mask=0
        if !frame{mask |= 1}
        if let ptsUS,ptsUS>=0 {
            if abs(Double(ptsUS)-Double(targetUS))>Double(halfWindowUS){mask |= 4}
            if clockUS<0 || abs(Double(ptsUS)-Double(clockUS))>Double(halfWindowUS){mask |= 8}
        }else{mask |= 2}
        if clockUS<0 || abs(Double(clockUS)-Double(targetUS))>Double(halfWindowUS){mask |= 16}
        if watchUpdates<=watchFloor{mask |= 32}
        return mask
    }
}

/// One bounded, successful manual-seek witness per driver session. Independent of
/// journal admission: ordinary checkpoint loss cannot change the selected winner.
/// No input here participates in playback, precision gates or source scheduling.
public struct PlaybackVLCSeekSummary: Sendable {
    public struct RangeEvidence: Codable, Sendable {
        public let id: UInt64, kind: Int, generation: UInt64
        public let range: PlaybackRangeDiagnostics.Span?
        public let callKind: Int?, result: Int?
        enum CodingKeys: String, CodingKey {case id,kind="k",generation="g",range="r",callKind="ck",result="z"}
        init(_ work: PlaybackSeekSourceSnapshot.Work) {
            id=work.id;kind=work.kind;generation=work.generation;range=work.range
            callKind=work.callKind;result=work.result
        }
    }
    public struct Source: Codable, Sendable {
        public let session: UInt64, generation: UInt64, epoch: UInt64?, at: Double
        public let current: RangeEvidence?, last: RangeEvidence?
        public let queueCount: Int, recentOmitted: Int, historyOverwritten: UInt64
        public let contiguousAheadBytes: Int?
        public let sourceCalls: UInt64, sourceWaitMS: Double, missBytes: UInt64
        enum CodingKeys: String, CodingKey {
            case session="s",generation="g",epoch="e",at,current="c",last="l"
            case queueCount="q",recentOmitted="om",historyOverwritten="lost",contiguousAheadBytes="ca"
            case sourceCalls="n",sourceWaitMS="w",missBytes="b"
        }
        init(_ source: PlaybackSeekSourceSnapshot, includeLast: Bool=true) {
            session=source.session;generation=source.generation;epoch=source.epoch;at=source.at
            current=source.current.map(RangeEvidence.init)
            last=includeLast ? source.recent.last.map(RangeEvidence.init):nil
            queueCount=source.queued.count+source.queueOmitted
            recentOmitted=source.recentOmitted+max(0,source.recent.count-(includeLast ? 1:0))
            historyOverwritten=source.historyOverwritten;contiguousAheadBytes=source.forward.contiguousAheadBytes
            sourceCalls=source.sourceCalls;sourceWaitMS=source.sourceWaitMS;missBytes=source.missBytes
        }
    }
    public struct Point: Codable, Sendable {
        public let stage: PlaybackVLCSeekDiagnostics.Stage, at: Double
        public let values: [String:Double], source: Source?
        enum CodingKeys: String, CodingKey {case stage="k",at,values="v",source="s"}
        init(_ record: PlaybackVLCSeekDiagnostics.Record) {
            stage=record.stage;at=record.at;source=record.source.map{Source($0)}
            // Fixed whitelist, never arbitrary text or the full native/source map.
            let keys:[(PlaybackVLCSeekDiagnostics.Scalar,String)]=[
                (.pollAt,"p"),(.rawPTS,"pts"),(.clock,"clk"),(.watchUpdates,"wu"),(.watchFloor,"wf"),
                (.gateMask,"gm"),(.completionPath,"cp"),(.nativeSampleClock,"ns"),(.nativeAgeMS,"na"),
                (.nativeQueueClock,"nqc"),(.nativeQueuePTS,"nqp"),(.vtSubmit,"vts"),(.vtCallback,"vtc"),
                (.nativeAvailable,"ok"),(.nativePreroll,"np"),(.nativeAdmitted,"nd")]
            values=Dictionary(uniqueKeysWithValues:keys.compactMap { key,short in
                record.values[key.rawValue].flatMap{$0.isFinite ? (short,$0):nil}
            })
        }
    }
    public struct Delta: Codable, Sendable {
        public let calls: UInt64, waitMS: Double, missBytes: UInt64, historyHitBytes: UInt64
        public let prefetchBytes: UInt64, prefetchWaitMS: Double
        init?(_ start: PlaybackSeekSourceSnapshot?, _ end: PlaybackSeekSourceSnapshot?) {
            guard let start,let end,start.session==end.session,end.at>=start.at,
                  end.sourceCalls>=start.sourceCalls,end.sourceWaitMS>=start.sourceWaitMS,
                  end.missBytes>=start.missBytes,end.historyHitBytes>=start.historyHitBytes,
                  end.prefetchBytes>=start.prefetchBytes,end.prefetchWaitMS>=start.prefetchWaitMS,
                  (end.sourceWaitMS-start.sourceWaitMS).isFinite,
                  (end.prefetchWaitMS-start.prefetchWaitMS).isFinite else{return nil}
            calls=end.sourceCalls-start.sourceCalls;waitMS=end.sourceWaitMS-start.sourceWaitMS
            missBytes=end.missBytes-start.missBytes;historyHitBytes=end.historyHitBytes-start.historyHitBytes
            prefetchBytes=end.prefetchBytes-start.prefetchBytes;prefetchWaitMS=end.prefetchWaitMS-start.prefetchWaitMS
        }
    }
    public struct Winner: Codable, Sendable {
        public let nonce: UInt64, target: Double, intentAt: Double, dispatchAt: Double, acceptedAt: Double
        public let totalSeconds: Double, beforeDispatchSeconds: Double, afterDispatchSeconds: Double
        public let intentSource: Source?, sourceDelta: Delta?, points: [Point]
    }
    public struct Record: Codable, Sendable {
        public let schema: Int, session: UInt64, endedAt: Double
        /// 0=no manual seek; 1=manual seek(s), none accepted; 2=successful winner.
        public let status: Int
        public let started: UInt64, accepted: UInt64, superseded: UInt64, stopped: UInt64, incomplete: UInt64
        public let slowest: Winner?
    }
    private struct Active: Sendable {
        let intent: PlaybackVLCSeekDiagnostics.Record
        var dispatch: Point?, first: Point?, last: Point?
    }
    private var session: UInt64?, active: Active?, slowest: Winner?, finished=false
    private var started: UInt64=0, accepted: UInt64=0, superseded: UInt64=0, stopped: UInt64=0, incomplete: UInt64=0
    public init() {}
    private static func increment(_ value: inout UInt64) {if value<UInt64.max {value+=1}}
    public mutating func observe(_ record: PlaybackVLCSeekDiagnostics.Record) {
        guard !finished,session==nil || session==record.session else{return}
        if record.stage == .intent {
            guard active?.intent.nonce != record.nonce else{return}
            if active != nil {Self.increment(&incomplete)}
            session=record.session;Self.increment(&started);active=Active(intent:record);return
        }
        guard var a=active,a.intent.nonce==record.nonce,record.at>=a.intent.at else{return}
        switch record.stage {
        case .intent: return
        case .dispatch: if a.dispatch==nil {a.dispatch=Point(record)}
        case .progress:
            if a.first==nil {a.first=Point(record)}
            a.last=Point(record)
        case .accepted:
            // A stop/failure or an old nonce cannot become a successful witness.
            guard let dispatch=a.dispatch,record.at>=dispatch.at else {
                Self.increment(&incomplete);active=nil;return
            }
            Self.increment(&accepted)
            let duration=record.at-a.intent.intentAt
            if duration.isFinite,slowest==nil || duration>slowest!.totalSeconds {
                var points=[dispatch]
                if let first=a.first {points.append(first)}
                if let last=a.last,last.at != a.first?.at {points.append(last)}
                points.append(Point(record))
                slowest=Winner(nonce:record.nonce,target:a.intent.target,intentAt:a.intent.intentAt,
                    dispatchAt:dispatch.at,acceptedAt:record.at,totalSeconds:duration,
                    beforeDispatchSeconds:dispatch.at-a.intent.intentAt,afterDispatchSeconds:record.at-dispatch.at,
                    intentSource:a.intent.source.map{Source($0,includeLast:false)},
                    sourceDelta:Delta(a.intent.source,record.source),points:points)
            }
            active=nil;return
        case .superseded: Self.increment(&superseded);active=nil;return
        case .stopped: Self.increment(&stopped);active=nil;return
        }
        active=a
    }
    /// Called once by the existing driver stop path, also reached after end/error.
    /// A new movie creates a new driver/helper. No retry or per-seek recovery rows.
    public mutating func finish(session: UInt64,now: Double)->Record? {
        guard !finished,self.session==nil || self.session==session,now.isFinite else{return nil}
        finished=true
        if active != nil {Self.increment(&incomplete);active=nil}
        return Record(schema:1,session:session,endedAt:now,status:slowest != nil ? 2:started==0 ? 0:1,
            started:started,accepted:accepted,superseded:superseded,stopped:stopped,incomplete:incomplete,slowest:slowest)
    }
}
