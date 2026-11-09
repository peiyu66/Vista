import Foundation

/// Build100, observations only. No pixel access, timer, player or source work.
/// Fixed rings retain the latest evidence even after intermediate emission limits.
/// JSON rows use the column definitions in docs/快速空幀與假說診斷候選.md.
struct PlaybackHypothesisDiagnostics:Sendable {
 static let sampleLimit=12,transitionLimit=4,recordLimit=8
 static let sampleInterval=0.1,payloadLimit=6800
 struct Transition:Codable,Sendable {
  let at:Double?,before:[Double?],after:[Double?]
  let input:[Double?]
  let idle:Bool?,supported:Bool?,empty:Bool,coverage:Double?
 }
 struct Record:Codable,Sendable {
  var session:UInt64=0
  let schema:Int,scope:UInt64,metricEpoch:Int,sourceEpoch:UInt64?,automaticCommand:UInt64?,automaticAt:Double?
  let reason:Int,at:Double?,counters:[UInt64]
  var polls:[[Double?]],gates:[Transition]
  let lastProofClear:Transition?
  var omittedPollRows:UInt64,omittedGateRows:UInt64
  var emitted:Int,suppressed:UInt64
  var finalizedAt:Double?
  let snapshot:PlaybackStallProbeDiagnostics.Snapshot
 }
 private var scope:UInt64=0,sourceEpoch:UInt64?,sourceCaptured=false
 private var automaticCommand:UInt64?,automaticAt:Double?
 private var polls:[[Double?]]=[],gates:[Transition]=[]
 private var lastSemanticKey:[Double?]?,lastProofClear:Transition?
 // loops, polls, hasNew, copyNil, finiteReturnedPTS, copiedFrame, advancingPTS,
 // invalidQuery, noDeadline, sampledOut, overwrittenPollRows, overwrittenGates.
 private var counters=[UInt64](repeating:0,count:12)
 private var sampledThisPoll=false
 private var lastSampleAt:Double?,lastPTS:Double?,lastPTSAt:Double?,clockAtPTS:Double?
 private var lastClock:Double?,lastQuery:Double?,lastOutcome:Int?
 private var pendingReason=0,emitted=0,suppressed:UInt64=0,nextEmissionAt:Double?
 private var finished=false,hasFault=false
 private var pendingTail:Record?
 private static func finite(_ value:Double?)->Double? {value.flatMap{$0.isFinite ? $0:nil}}
 private static func increment(_ x:inout UInt64){if x<PlaybackStallProbeDiagnostics.maximumCounter{x += 1}}
 var isArmed:Bool {automaticCommand != nil}
 var hasFaultEvidence:Bool {!finished && hasFault}
 mutating func arm(command:UInt64,now:Double,lastPTS:Double?,clock:Double?) {
  automaticCommand=command;automaticAt=Self.finite(now)
  self.lastPTS=Self.finite(lastPTS);lastPTSAt=Self.finite(now);clockAtPTS=Self.finite(clock)
 }
 /// Called with the already-read values after the sole output poll/copy.
 /// Important invalid/outcome changes are retained even between periodic rows.
 mutating func poll(now:Double,clock:Double?,query:Double?,targetHost:Double?,hostLead:Double?,
  validity:Int,returnedPTS:Double?,copiedPTS:Double?,timebaseValidity:Int,effective:Double?,
  itemStatus:Int?,rate:Double?,transport:Int?,metricEpoch:Int) {
  guard !finished else{return}
  sampledThisPoll=false
  Self.increment(&counters[0]);let polled=validity&64 != 0
  if polled {Self.increment(&counters[1])}
  if validity&128 != 0 {Self.increment(&counters[2])}
  if validity&256 != 0 {Self.increment(&counters[3])}
  if Self.finite(returnedPTS) != nil {Self.increment(&counters[4])}
  if Self.finite(copiedPTS) != nil {Self.increment(&counters[5])}
  if polled && validity&7 != 7 {Self.increment(&counters[7])}
  if validity&1 == 0 {Self.increment(&counters[8])}
  let c=Self.finite(clock),q=Self.finite(query)
  if let pts=Self.finite(copiedPTS),lastPTS.map({pts>$0}) ?? true {
   Self.increment(&counters[6]);lastPTS=pts;lastPTSAt=Self.finite(now);clockAtPTS=c
  }
  if isArmed,let began=lastPTSAt,now-began>=0.5,let c,let prior=clockAtPTS,c-prior>0.05 {pendingReason=max(pendingReason,1);hasFault=true}
  // Query rollback / implausibly large disagreement is evidence to inspect,
  // never a recovery qualifier. Finite stale queries are not silently omitted.
  let queryJump=polled && (q.map{value in lastQuery.map{value<$0-0.001 || abs(value-$0)>0.5} ?? false} ?? false)
  let clockBack=c.map{value in lastClock.map{value<$0-0.001} ?? false} ?? false
  let outcome=validity & (1|2|4|64|128|256)
  let exceptional=(polled && validity&7 != 7) || validity&256 != 0 || queryJump || clockBack
  let changed=outcome != lastOutcome
  defer {
   lastClock=c
   // A no-deadline loop supplies no query evidence. Do not erase the last
   // actual poll reference or hide a later rare jump between periodic rows.
   if polled {if let q {lastQuery=q};lastOutcome=outcome}
  }
  // Repeated invalid polls cannot flood the ring; the counter still sees each.
  let due=lastSampleAt.map{now >= $0 && now-$0>=Self.sampleInterval} ?? true
  guard due || (exceptional && changed) || queryJump || clockBack else{Self.increment(&counters[9]);return}
  lastSampleAt=Self.finite(now)
  let row:[Double?]=[Self.finite(now),c,q,Self.finite(targetHost),Self.finite(hostLead),Double(validity),
   Self.finite(returnedPTS),Self.finite(copiedPTS),Double(timebaseValidity),Self.finite(effective),
   itemStatus.map(Double.init),Self.finite(rate),transport.map(Double.init),Double(metricEpoch),
   Double(counters[1]),Double(counters[2]),Double(counters[3]),Double(counters[6]),nil,nil,nil,nil,nil,nil]
  polls.append(row);sampledThisPoll=true
  if polls.count>Self.sampleLimit {polls.removeFirst();Self.increment(&counters[10])}
 }
 /// Capture exact gate inputs plus state on a semantic transition. Fresh absent
 /// display deadlines are omitted, not confused with invalid/stale true polls.
 mutating func gate(now:Double,before:[Double?],after:[Double?],idle:Bool?,supported:Bool?,empty:Bool,coverage:Double?,activity:[Double?]=[],input:[Double?]=[]) {
  if sampledThisPoll,!polls.isEmpty {
   polls[polls.count-1][18]=Self.finite(now)
   for i in 0..<5 {polls[polls.count-1][19+i]=i<activity.count ? Self.finite(activity[i]):nil}
   sampledThisPoll=false
  }
  guard !finished,before.count==18,after.count==18 else{return}
  let proofChanged=before[0] != after[0]
  let semantic=after[16] != Double(NativePlaybackIntentRecovery.Detail.deadlineAbsent.rawValue)
  let key=[after[0],after[6],after[12],after[15],after[16],after[17]]
  guard proofChanged || (semantic && key != lastSemanticKey) else{return}
  lastSemanticKey=key
  if before[0]==1 && after[0]==0 {pendingReason=2;hasFault=true}
  let safeBefore=before.map(Self.finite),safeAfter=after.map(Self.finite)
  let transition=Transition(at:Self.finite(now),before:safeBefore,after:safeAfter,input:Array(input.prefix(7)).map(Self.finite),idle:idle,
   supported:supported,empty:empty,coverage:Self.finite(coverage))
  gates.append(transition)
  if before[0]==1 && after[0]==0 {lastProofClear=transition}
  if gates.count>Self.transitionLimit {gates.removeFirst();Self.increment(&counters[11])}
 }
 /// The caller fences real seek/lifecycle/source changes. Source epoch is the
 /// prefetch ownership epoch, never NativeRequestMetrics.epoch (a separate field).
 func sourceChanged(_ epoch:UInt64?)->Bool {sourceCaptured && sourceEpoch != epoch}
 mutating func captureSource(_ epoch:UInt64?){sourceCaptured=true;sourceEpoch=epoch}
 mutating func resetScope(){
  if scope<PlaybackStallProbeDiagnostics.maximumCounter{scope += 1}
  automaticCommand=nil;automaticAt=nil;polls=[];gates=[];lastProofClear=nil;lastSemanticKey=nil;counters=Array(repeating:0,count:12)
  hasFault=false;sampledThisPoll=false;lastSampleAt=nil;lastPTS=nil;lastPTSAt=nil;clockAtPTS=nil;lastClock=nil;lastQuery=nil;lastOutcome=nil;pendingReason=0
 }
 func shouldEmit(now:Double)->Bool { !finished && pendingReason>0 && emitted<Self.recordLimit && (nextEmissionAt.map{now >= $0} ?? true) }
 /// At most eight intermediate records, paced 5, 15, 45... seconds apart.
 /// There is a separate final record even after those slots are exhausted.
 /// This preserves useful late evidence rather than burning all slots at startup.
 mutating func record(now:Double,metricEpoch:Int,snapshot:PlaybackStallProbeDiagnostics.Snapshot,reason:Int?=nil,final:Bool=false)->Record? {
  guard !finished else{return nil}
  let why=reason ?? pendingReason
  guard final || why>0 else{return nil}
  if !final {
   guard emitted<Self.recordLimit,nextEmissionAt.map({now >= $0}) ?? true else{Self.increment(&suppressed);return nil}
   emitted += 1;nextEmissionAt=now+5*pow(3,Double(emitted-1));pendingReason=0
  }else{finished=true}
  if final,!hasFault,var tail=pendingTail {
   tail.finalizedAt=Self.finite(now);tail.emitted=emitted;tail.suppressed=suppressed
   return tail
  }
  var result=makeRecord(now:now,metricEpoch:metricEpoch,snapshot:snapshot,reason:final ? 100:why)
  if final {result.finalizedAt=Self.finite(now)}
  return result
 }
 /// Preserve one late fault tail across pause/seek when the paced writer slot
 /// is unavailable. It remains explicitly in its original scope and time.
 mutating func saveScopeTail(now:Double,metricEpoch:Int,snapshot:PlaybackStallProbeDiagnostics.Snapshot,reason:Int) {
  guard !finished,hasFault else{return}
  pendingTail=makeRecord(now:now,metricEpoch:metricEpoch,snapshot:snapshot,reason:reason)
 }
 private func makeRecord(now:Double,metricEpoch:Int,snapshot:PlaybackStallProbeDiagnostics.Snapshot,reason:Int)->Record {
  var result=Record(schema:1,scope:scope,metricEpoch:metricEpoch,sourceEpoch:sourceEpoch,
   automaticCommand:automaticCommand,automaticAt:automaticAt,reason:reason,at:Self.finite(now),counters:counters,
   polls:polls,gates:gates,lastProofClear:lastProofClear,omittedPollRows:0,omittedGateRows:0,emitted:emitted,suppressed:suppressed,finalizedAt:nil,snapshot:snapshot.sanitized())
  // Reserve >1 KiB for the ordinary record envelope and writer loss counters.
  // Trimming is explicit and oldest-first, never an oversized silent drop.
  while (try? JSONEncoder().encode(result).count).map({$0>Self.payloadLimit}) ?? true {
   if result.polls.count>1 {result.polls.removeFirst();Self.increment(&result.omittedPollRows)}
   else if !result.gates.isEmpty {result.gates.removeFirst();Self.increment(&result.omittedGateRows)}
   else {break}
  }
  return result
 }
}
extension PlaybackLogRecord {
 init(hypothesis record:PlaybackHypothesisDiagnostics.Record,session:UInt64,build:String=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0") {
  self.init(event:.playbackHypothesis,values:[:],build:build);var r=record;r.session=session;hypothesis=r
 }
}
