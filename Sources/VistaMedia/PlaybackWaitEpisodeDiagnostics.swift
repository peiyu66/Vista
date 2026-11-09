import Foundation
#if SWIFT_PACKAGE
import VistaCore
#endif

/// Diagnostic only. No player, timer, I/O, paths, media bytes or free-form text.
struct PlaybackWaitEpisodeDiagnostics {
 static let maximumCounter:UInt64 = (1 << 53)-1
 static let burstCapacity=4.0, refillSeconds=2.0
 enum End:Int,Codable,Sendable {case advanced=1,pause,seek,inactive,stop,failure,sourceRecovery,superseded,ended,userResume,sourceEpoch}
 enum Origin:Int,Codable,Sendable {case loop=1,notification,beforeResume}
 struct Snapshot:Codable,Sendable {
  var at:Double
  var clock:Double?,rate:Double?,speed:Double?,frontier:Double?,lastFrameAt:Double?,lastFramePTS:Double?,lastDeliveryAt:Double?
  var deliveryBytes:UInt64=0,context=0,transport=0,empty=false
  var supply:PlaybackSupplyDiagnostics.Snapshot?
  var ranges:PlaybackRangeDiagnostics.Snapshot?
  var bridge:PlaybackBridgeDiagnostics.Snapshot?
  var coveragePass:Bool?
  enum CodingKeys:String,CodingKey {case at="t",clock="p",rate="r",speed="s",frontier="f",lastFrameAt="ft",lastFramePTS="fp",lastDeliveryAt="dt",deliveryBytes="db",context="c",transport="ts",empty="be",supply="io",ranges="ranges",bridge="bridge",coveragePass="ok"}
  init(now:Double){at=now.isFinite && now>=0 ? now:0}
  func sanitized()->Self {
   var v=self
   v.clock=Self.finite(clock);v.rate=Self.finite(rate);v.speed=Self.finite(speed);v.frontier=Self.finite(frontier)
   v.lastFrameAt=Self.finite(lastFrameAt);v.lastFramePTS=Self.finite(lastFramePTS);v.lastDeliveryAt=Self.finite(lastDeliveryAt)
   return v
  }
  private static func finite(_ value:Double?)->Double? {value.flatMap{$0.isFinite ? $0:nil}}
 }
 struct Record:Codable,Sendable {
  let session:UInt64,episode:UInt64,requestEpoch:Int,origin:Origin,start:Snapshot
  var resume:Snapshot?,exit:Snapshot?,frame:Snapshot?
  var notificationAt:Double?,resumeCause:Int?,lastResumeAt:Double?
  var firstCopyAt:Double?,firstCopyPTS:Double?,firstCopyRelation:Int?,framePTS:Double?
  var resumeCalls:UInt64=0,duplicateCopies:UInt64=0
  var reason:End?,finished:Double?,suppressed:UInt64=0
  var firstEmptyFalseAt:Double?,firstCoveragePassAt:Double?,lastConditionAt:Double?
  var emptyObservations:UInt64=0,coverageObservations:UInt64=0
  // 0=not comparable, 1=strictly advancing, 2=duplicate, 3=regressed.
  // frame is the first strictly advancing PTS AND clock after resume/exit.
  enum CodingKeys:String,CodingKey {case session="s",episode="id",requestEpoch="re",origin="o",start="a",resume="r",exit="x",frame="f",firstCopyAt="ct",firstCopyPTS="cp",firstCopyRelation="cr",resumeCalls="rc",duplicateCopies="dc",reason="end",finished="t",suppressed="skip",notificationAt="nt",resumeCause="why",framePTS="fp",lastResumeAt="rt",firstEmptyFalseAt="ef",firstCoveragePassAt="cf",lastConditionAt="ot",emptyObservations="eo",coverageObservations="co"}
 }
 private(set) var active:Record?
 // Lightweight epoch identity survives detail suppression. Never read transport
 // state to maintain this boundary; the caller supplies its last observation.
 private(set) var activeSourceEpoch:UInt64?
 private(set) var seen:UInt64=0,suppressed:UInt64=0,completed:UInt64=0
 private(set) var lastFrameAt:Double?,lastFramePTS:Double?
 private var tokens=burstCapacity,lastRefill:Double?
 private var detailAdmitted=false
 var capturesActiveDetail:Bool {active != nil && detailAdmitted}
 private var previousClock:Double?,lastNotification:Double?
 mutating func notified(now:Double) {
  guard now.isFinite,now>=0 else{return}
  if active != nil {
   if active?.notificationAt == nil {active?.notificationAt=now}
  } else {lastNotification=now}
 }
 /// Same containing-range criterion as the existing recovery gate, without
 /// consuming retries, changing blockedBy, invoking play or crossing gaps.
 static func coveragePass(position:Double,duration:Double,speed:Double,ranges:[Range<Double>])->Bool? {
  guard position.isFinite,duration.isFinite,position>=0,position<duration,speed.isFinite,speed>0 else{return nil}
  let required=min(0.25*speed,duration-position)
  return ranges.contains{$0.lowerBound.isFinite && $0.upperBound.isFinite && $0.lowerBound<=position && $0.upperBound-position+0.001>=required}
 }
 mutating func observeConditions(now:Double,empty:Bool?,coveragePass:Bool?) {
  guard capturesActiveDetail,now.isFinite,now>=active!.start.at else{return}
  guard empty != nil || coveragePass != nil else{return}
  active?.lastConditionAt=now
  if let empty {
   Self.increment(&active!.emptyObservations)
   if !empty,active?.firstEmptyFalseAt == nil {active?.firstEmptyFalseAt=now}
  }
  if let coveragePass {
   Self.increment(&active!.coverageObservations)
   if coveragePass,active?.firstCoveragePassAt == nil {active?.firstCoveragePassAt=now}
  }
 }
 var needsFrameSnapshot:Bool {active != nil && (active?.resume != nil || active?.exit != nil)}
 static func increment(_ value:inout UInt64){if value<maximumCounter {value += 1}}

 /// Only actual observed waiting opens an episode, never stall-pending alone.
 mutating func observe(waiting:Bool,eligible:Bool,session:UInt64,epoch:Int,origin:Origin,now:Double?=nil,observedSourceEpoch:UInt64?=nil,snapshot:()->Snapshot)->Record? {
  guard eligible else{return nil}
  if waiting {
   if active != nil,active?.exit == nil{return nil}
   // Native callers supply uptime, so admission precedes map/history capture.
   // The optional fallback preserves the small pure-observer test API.
   let collected=now == nil ? snapshot().sanitized():nil
   let time=Snapshot(now:now ?? collected!.at).at
   let old=finish(.superseded,now:time)
   guard seen<Self.maximumCounter else{return old}
   Self.increment(&seen)
   detailAdmitted=admit(now:time)
   let s=detailAdmitted ? (collected ?? snapshot().sanitized()):Snapshot(now:time)
   active=Record(session:session,episode:seen,requestEpoch:epoch,origin:origin,start:s)
   activeSourceEpoch=observedSourceEpoch ?? s.supply?.epoch
   active?.notificationAt=lastNotification;lastNotification=nil
   observeConditions(now:s.at,empty:s.empty,coveragePass:s.coveragePass)
   return old
  }
  guard active != nil,active?.exit == nil else{return nil}
  let s=detailAdmitted ? snapshot().sanitized():Snapshot(now:now ?? active!.start.at);active?.exit=s
  observeConditions(now:s.at,empty:s.empty,coveragePass:s.coveragePass)
  if active?.frame != nil {return finish(.advanced,now:s.at)}
  return nil
 }
 mutating func resumed(now:Double?=nil,cause:Int=1,snapshot:()->Snapshot) {
  guard active != nil else{return}
  Self.increment(&active!.resumeCalls)
  if active?.resume == nil {
   var value=detailAdmitted ? snapshot().sanitized():Snapshot(now:now ?? active!.start.at)
   if let now,now.isFinite,now>=value.at {value.at=now}
   active?.resume=value;active?.resumeCause=cause
   observeConditions(now:value.at,empty:value.empty,coveragePass:value.coveragePass)
  }
  let timestamp=now.flatMap{$0.isFinite ? $0:nil} ?? active?.resume?.at
  active?.lastResumeAt=timestamp
 }
 /// Caller already obtained a finite copied output PTS. Duplicate delivery is
 /// preserved separately and cannot finish an episode or prove recovery.
 mutating func copiedFrame(now:Double,pts:Double,clock:Double,eligible:Bool,snapshot:()->Snapshot)->Record? {
  guard now.isFinite,now>=0,pts.isFinite else{return nil}
  defer {lastFrameAt=now;lastFramePTS=pts;previousClock=clock.isFinite ? clock:nil}
  if active == nil,eligible,let prior=lastFramePTS,pts>prior,clock.isFinite,let previousClock,clock>previousClock {lastNotification=nil}
  guard eligible,active != nil else{return nil}
  let relation:Int
  if let previous=lastFramePTS {relation=pts>previous ? 1:pts==previous ? 2:3}else{relation=0}
  if active?.firstCopyAt == nil {active?.firstCopyAt=now;active?.firstCopyPTS=pts;active?.firstCopyRelation=relation}
  if relation==2 {Self.increment(&active!.duplicateCopies)}
  guard needsFrameSnapshot,relation==1,clock.isFinite,let previousClock,clock>previousClock,active?.frame == nil else{return nil}
  let value=detailAdmitted ? snapshot().sanitized():Snapshot(now:now);active?.frame=value;active?.framePTS=pts
  observeConditions(now:value.at,empty:value.empty,coveragePass:value.coveragePass)
  if active?.exit != nil {return finish(.advanced,now:now)}
  return nil
 }
 mutating func abort(_ reason:End,now:Double)->Record? {
  let result=finish(reason,now:now)
  lastFrameAt=nil;lastFramePTS=nil;previousClock=nil;lastNotification=nil
  return result
 }
 private mutating func finish(_ reason:End,now:Double)->Record? {
  guard var record=active else{return nil};active=nil;activeSourceEpoch=nil;Self.increment(&completed)
  let admitted=detailAdmitted;detailAdmitted=false
  record.reason=reason;record.finished=now.isFinite ? max(record.start.at,now):record.start.at
  guard admitted else{Self.increment(&suppressed);return nil}
  record.suppressed=suppressed
  return record
 }
 private mutating func admit(now:Double)->Bool {
  if let lastRefill,now>=lastRefill {
   tokens=min(Self.burstCapacity,tokens+(now-lastRefill)/Self.refillSeconds)
  }
  lastRefill=max(lastRefill ?? now,now)
  guard tokens>=1 else{return false}
  tokens -= 1;return true
 }
}

/// One numeric snapshot per play, independently retained by delayed source cleanup.
/// No player/session/source/data references. Reusing a Native session binds a new
/// instance, so an old cleanup cannot read the new play's counters.
@MainActor final class PlaybackWaitEpisodeCounters {
 private var seen:UInt64=0,completed:UInt64=0,suppressed:UInt64=0
 private var incomplete=false
 func update(seen:UInt64,completed:UInt64,suppressed:UInt64,incomplete:Bool) {
  self.seen=seen;self.completed=completed;self.suppressed=suppressed;self.incomplete=incomplete
 }
 var values:[PlaybackLogField:Double] {
  [.waitEpisodes:Double(seen),.waitCompleted:Double(completed),
   .waitSuppressed:Double(suppressed),.waitIncomplete:incomplete ? 1:0]
 }
}

/// An independent rolling lane. Ordinary/prefetch detail cannot consume it.
/// Four scalar-only records, each encoded below the independent 1 MiB wait limit,
/// plus the original eight ordinary records. No payload Data is retained here.
struct PlaybackWaitEpisodeLogBuffer {
 static let capacity=4
 private(set) var pending:[PlaybackLogRecord]=[]
 private(set) var dropped:UInt64=0
 mutating func append(_ record:PlaybackLogRecord) {
  if pending.count==Self.capacity {pending.removeFirst();PlaybackWaitEpisodeDiagnostics.increment(&dropped)}
  pending.append(record)
 }
 mutating func take()->PlaybackLogRecord? {pending.isEmpty ? nil:pending.removeFirst()}
}
