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
        // reason: 1 stopped/disabled; 2 quarantine/unknown epoch; 3 queued/work;
        // 4 no window; 5 legacy suspended (unused since96); 6 stale window; 7 budget; 8 candidate (grace still applies).
        enum CodingKeys: String, CodingKey {case cursor="c",target="t",epoch="e",generation="g",evidence="v",reads="n",suspended="s",enabled="on",paused="p",quarantined="q",reason="r",invalidation="ir",windowID="id",transitionID="ti",transition="tr"}
        public init(cursor: UInt64?, target: UInt64?, epoch: UInt64?, generation: UInt64?, evidence: Range<UInt64>?, reads: Int,
                    suspended: Bool, enabled: Bool, paused: Bool, quarantined: Bool, reason: Int, invalidation: Int = 0, windowID: UInt64? = nil, transitionID: UInt64? = nil, transition: Int? = nil) {
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
