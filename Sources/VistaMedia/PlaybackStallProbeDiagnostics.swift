import Foundation

/// Numeric evidence for the single no-demand play probe. This observer never
/// changes playback, reads media, owns a timer, or writes a per-poll record.
/// Only actual probes consume detail budget; ordinary waits use the wait journal.
struct PlaybackStallProbeDiagnostics: Sendable {
 static let episodeLimit: UInt64 = 16
 static let maximumCounter: UInt64 = (1 << 53)-1
 enum EndReason: Int, Codable, Sendable { case progress=1,pause,seek,sourceEpoch,stop,failure,ended,superseded }
 // Matches known lifecycle codes for synthetic/local/unknown. Route 4 means
 // the actual prefetch wrapper, not a claim that its underlying source is SMB.
 enum SourceKind: Int, Codable, Sendable { case synthetic=0,local=2,unknown=3,prefetch=4 }
 enum Phase: Int, Codable, Sendable { case attempt=1,terminal }
 struct Snapshot: Codable, Sendable {
  var at: Double?
  var sourceKind: SourceKind = .unknown
  var clock: Double?, lastFramePTS: Double?, copiedFramePTS: Double?
  var selectedSpeed: Double?, defaultRate: Double?, playerRate: Double?, effectiveRate: Double?
  var coverageSeconds: Double?, queryTime: Double?, queryClockDifference: Double?, copyQueryDifference: Double?
  var targetHostLeadSeconds: Double?, outputObservationAt: Double?
  var recoveryActiveSeconds: Double?, probeQuietSeconds: Double?
  var lastProgressAge: Double?, lastDeliveryAge: Double?, lastFrameAge: Double?
  var context: Int?, transport: Int?, waitingReason: Int?, queryValidity: Int?
  var bridgeActive: Int?, sourceBusyMask: Int?, attempts: Int?, probeBlock: Int?
  var timebaseValidity: Int?
  var bufferEmpty: Bool?
  var progressEligible = false
  var bridgeRequests: UInt64?, bridgeDataRequests: UInt64?, bridgeChunks: UInt64?, bridgeCancellations: UInt64?
  var bridgeReturns: UInt64?, bridgeResponses: UInt64?, deliveredBytes: UInt64?
  var sourceGeneration: UInt64?, sourceEpoch: UInt64?, sourceRequestID: UInt64?, sourcePrefetchID: UInt64?
  init(now: Double) { at=now.isFinite && now>=0 ? now:nil }
  enum CodingKeys: String, CodingKey {
   case sourceKind="sourceRoute"
   case at="t",clock="clock",lastFramePTS="lastPTS",copiedFramePTS="copyPTS"
   case selectedSpeed="selected",defaultRate="default",playerRate="rate",effectiveRate="effective"
   case coverageSeconds="coverage",queryTime="query",queryClockDifference="queryClock",copyQueryDifference="copyQuery"
   case targetHostLeadSeconds="hostLead",outputObservationAt="outputAt"
   case recoveryActiveSeconds="budget",probeQuietSeconds="quiet",lastProgressAge="progressAge",lastDeliveryAge="dataAge",lastFrameAge="frameAge"
   case timebaseValidity="timebaseValidity"
   case context="context",transport="transport",waitingReason="waiting",queryValidity="queryValidity"
   case bridgeActive="active",sourceBusyMask="busy",attempts="attempts",probeBlock="block",bufferEmpty="empty",progressEligible="eligible"
   case bridgeRequests="requests",bridgeDataRequests="dataRequests",bridgeChunks="chunks",bridgeCancellations="cancels",bridgeReturns="returns",bridgeResponses="responses",deliveredBytes="bytes"
   case sourceGeneration="generation",sourceEpoch="epoch",sourceRequestID="requestID",sourcePrefetchID="prefetchID"
  }
  func sanitized() -> Self {
   var v=self
   func finite(_ x: Double?) -> Double? { x.flatMap { $0.isFinite ? $0:nil } }
   v.at=at.flatMap{$0.isFinite && $0>=0 ? $0:nil}
   v.clock=finite(clock);v.lastFramePTS=finite(lastFramePTS);v.copiedFramePTS=finite(copiedFramePTS)
   v.selectedSpeed=finite(selectedSpeed);v.defaultRate=finite(defaultRate);v.playerRate=finite(playerRate);v.effectiveRate=finite(effectiveRate)
   v.coverageSeconds=finite(coverageSeconds);v.queryTime=finite(queryTime);v.queryClockDifference=finite(queryClockDifference);v.copyQueryDifference=finite(copyQueryDifference)
   v.targetHostLeadSeconds=finite(targetHostLeadSeconds);v.outputObservationAt=finite(outputObservationAt)
   v.recoveryActiveSeconds=finite(recoveryActiveSeconds);v.probeQuietSeconds=finite(probeQuietSeconds)
   v.lastProgressAge=finite(lastProgressAge);v.lastDeliveryAge=finite(lastDeliveryAge);v.lastFrameAge=finite(lastFrameAge)
   return v
  }
 }
 struct CommandSnapshot: Codable, Sendable {
  let before: Snapshot, after: Snapshot, setterBranch: Int
 }
 struct Record: Codable, Sendable {
  var session: UInt64 = 0
  let episode: UInt64, epoch: Int, phase: Phase
  let started: Double?, attempted: Double?, finished: Double?, reason: EndReason?
  /// Attempt records contain the actual command's before/after snapshots.
  /// Terminal records retain its before snapshot plus the terminal observation.
  let before: Snapshot, after: Snapshot
  let firstDemandAt: Double?, firstBytesAt: Double?, firstReturnAt: Double?, firstResponseAt: Double?
  let firstClockAt: Double?, firstAdvancingPTSAt: Double?, recoveredAt: Double?
  let milestones: Int
  let rejectedObservations: UInt64, rejectionReasons: UInt64, lastRejection: Int?, invalidRejections: UInt64
  let invalidSnapshots: UInt64
  enum CodingKeys: String, CodingKey {
   case session="s",episode="id",epoch="epoch",phase="phase",started="start",attempted="attempt",finished="end",reason="reason",before="before",after="after"
   case firstDemandAt="demandAt",firstBytesAt="bytesAt",firstReturnAt="returnAt",firstResponseAt="responseAt",firstClockAt="clockAt",firstAdvancingPTSAt="ptsAt",recoveredAt="recoveredAt",milestones="milestones"
   case rejectedObservations="rejects",rejectionReasons="rejectMask",lastRejection="lastReject",invalidRejections="invalidRejects",invalidSnapshots="invalidSnapshots"
  }
 }
 struct Summary: Codable, Sendable {
  var session: UInt64 = 0
  let seenEpisodes: UInt64, attemptsSeen: UInt64, attemptsEmitted: UInt64, attemptsSuppressed: UInt64
  let terminalsEmitted: UInt64, recovered: UInt64, incomplete: UInt64
  let rejectedObservations: UInt64, rejectionReasons: UInt64, lastRejection: Int?, invalidRejections: UInt64, invalidSnapshots: UInt64
  let episodeLimit: UInt64
 }
 struct Completion: Sendable { let terminal: Record?, summary: Summary }
 private struct Episode: Sendable {
  let sequence: UInt64, epoch: Int, started: Double?
  var attempted=false, admitted=false
  var before: Snapshot?, commandReturnedAt: Double?, lastObservedAt: Double?
  var firstDemandAt: Double?, firstBytesAt: Double?, firstReturnAt: Double?, firstResponseAt: Double?
  var firstClockAt: Double?, firstAdvancingPTSAt: Double?, recoveredAt: Double?
  var highPTS: Double?, previousClock: Double?, advancingPairs=0
  var rejectedObservations: UInt64=0, rejectionReasons: UInt64=0, lastRejection: Int?, invalidRejections: UInt64=0, invalidSnapshots: UInt64=0
 }
 private var active: Episode?
 private var closed=false
 private var seenEpisodes: UInt64=0,attemptsSeen: UInt64=0,attemptsEmitted: UInt64=0,attemptsSuppressed: UInt64=0,terminalsEmitted: UInt64=0,recovered: UInt64=0,incomplete: UInt64=0
 private var rejectedObservations: UInt64=0,rejectionReasons: UInt64=0,lastRejection: Int?,invalidRejections: UInt64=0,invalidSnapshots: UInt64=0
 var isObserving: Bool { active != nil }
 private static func increment(_ value: inout UInt64) { if value<maximumCounter {value += 1} }
 @discardableResult mutating func begin(epoch: Int,snapshot: Snapshot) -> Record? {
  guard !closed else{return nil}
  let prior=finish(.superseded,snapshot:snapshot)
  Self.increment(&seenEpisodes)
  active=Episode(sequence:seenEpisodes,epoch:epoch,started:snapshot.sanitized().at)
  return prior
 }
 /// Fixed gate enum codes, not text. Zero means unblocked. Unknown codes are
 /// counted explicitly and cannot shift by an arbitrary integer.
 mutating func rejected(reason: Int) {
  guard !closed,active != nil,reason != 0 else{return}
  Self.increment(&rejectedObservations);Self.increment(&active!.rejectedObservations)
  guard (1...63).contains(reason) else {
   Self.increment(&invalidRejections);Self.increment(&active!.invalidRejections);return
  }
  let bit=UInt64(1)<<UInt64(reason)
  rejectionReasons |= bit;active!.rejectionReasons |= bit
  lastRejection=reason;active!.lastRejection=reason
 }
 @discardableResult mutating func attempt(before: Snapshot,after: Snapshot) -> Record? {
  guard !closed,var episode=active,!episode.attempted else{return nil}
  episode.attempted=true;Self.increment(&attemptsSeen)
  guard attemptsEmitted<Self.episodeLimit else {
   Self.increment(&attemptsSuppressed);active=episode;return nil
  }
  let before=before.sanitized(),after=after.sanitized()
  episode.admitted=true;episode.before=before;episode.commandReturnedAt=after.at
  episode.lastObservedAt=after.at;episode.highPTS=before.lastFramePTS;episode.previousClock=before.clock
  // An invalid command interval is retained as missing evidence, never zero.
  if before.at == nil || after.at == nil || (after.at ?? 0)<(before.at ?? 0) {
   Self.increment(&invalidSnapshots);Self.increment(&episode.invalidSnapshots)
   episode.commandReturnedAt=nil
  }
  active=episode;Self.increment(&attemptsEmitted)
  return record(episode,phase:.attempt,after:after,reason:nil)
 }
 /// O(1), scalar-only observation on the existing loop. New data, clock motion,
 /// a copied PTS, and two genuinely progressing frames are distinct milestones.
 mutating func observe(_ value: Snapshot) {
  guard !closed,var episode=active,episode.admitted,let before=episode.before else{return}
  let s=value.sanitized()
  guard let now=s.at,let commandReturnedAt=episode.commandReturnedAt,now>commandReturnedAt,
        episode.lastObservedAt.map({now>$0}) ?? true else {
   Self.increment(&invalidSnapshots);Self.increment(&episode.invalidSnapshots)
   active=episode;return
  }
  episode.lastObservedAt=now
  func advanced(_ current:UInt64?,_ base:UInt64?)->Bool {guard let current,let base else{return false};return current>base}
  if episode.firstDemandAt == nil,advanced(s.bridgeDataRequests,before.bridgeDataRequests) {episode.firstDemandAt=now}
  if episode.firstBytesAt == nil,advanced(s.deliveredBytes,before.deliveredBytes) {episode.firstBytesAt=now}
  if episode.firstReturnAt == nil,advanced(s.bridgeReturns,before.bridgeReturns) {episode.firstReturnAt=now}
  if episode.firstResponseAt == nil,advanced(s.bridgeResponses,before.bridgeResponses) {episode.firstResponseAt=now}
  if s.progressEligible,let clock=s.clock,let baseline=before.clock,clock>baseline,episode.firstClockAt == nil {episode.firstClockAt=now}
  guard s.progressEligible else {episode.previousClock=nil;episode.advancingPairs=0;active=episode;return}
  if let pts=s.copiedFramePTS {
   let advancedPTS=episode.highPTS.map{pts>$0} ?? false
   let advancedClock=s.clock.flatMap {clock in before.clock.map{clock>$0}} ?? false
   if episode.highPTS == nil {
    // No pre-probe PTS was observed (for example startup). The first post-command
    // finite copy becomes a baseline only. A second increasing clock/PTS pair
    // can then prove motion, without inventing prior PTS or a first-frame success.
    episode.highPTS=pts
    episode.advancingPairs=advancedClock ? 1:0
   } else if advancedPTS,advancedClock {
    if episode.firstAdvancingPTSAt == nil {episode.firstAdvancingPTSAt=now}
    let consecutive=episode.previousClock.map{s.clock!>$0} ?? false
    episode.advancingPairs=consecutive ? min(2,episode.advancingPairs+1):1
    if episode.advancingPairs>=2,episode.recoveredAt == nil {episode.recoveredAt=now}
   } else {episode.advancingPairs=0}
   if let high=episode.highPTS {episode.highPTS=max(high,pts)}
   episode.previousClock=s.clock
  }
  active=episode
 }
 /// Scene inactivity must not recreate a probe allowance or close its episode.
 mutating func interruptObservation() {active?.previousClock=nil;active?.advancingPairs=0}
 @discardableResult mutating func finish(_ reason: EndReason,snapshot: Snapshot) -> Record? {
  guard let episode=active else{return nil};active=nil
  guard episode.admitted else{return nil}
  Self.increment(&terminalsEmitted)
  if episode.recoveredAt != nil,reason == .progress {Self.increment(&recovered)}else{Self.increment(&incomplete)}
  return record(episode,phase:.terminal,after:snapshot.sanitized(),reason:reason)
 }
 mutating func finishSession(snapshot: Snapshot) -> Completion? {
  guard !closed else{return nil}
  let terminal=finish(.stop,snapshot:snapshot);closed=true
  return Completion(terminal:terminal,summary:Summary(seenEpisodes:seenEpisodes,attemptsSeen:attemptsSeen,attemptsEmitted:attemptsEmitted,attemptsSuppressed:attemptsSuppressed,terminalsEmitted:terminalsEmitted,recovered:recovered,incomplete:incomplete,rejectedObservations:rejectedObservations,rejectionReasons:rejectionReasons,lastRejection:lastRejection,invalidRejections:invalidRejections,invalidSnapshots:invalidSnapshots,episodeLimit:Self.episodeLimit))
 }
 private func record(_ e: Episode,phase: Phase,after: Snapshot,reason: EndReason?) -> Record {
  let mask=1 | (e.firstDemandAt == nil ? 0:2) | (e.firstBytesAt == nil ? 0:4) | (e.firstClockAt == nil ? 0:8) | (e.firstAdvancingPTSAt == nil ? 0:16) | (e.recoveredAt == nil ? 0:32) | (e.firstReturnAt == nil ? 0:64) | (e.firstResponseAt == nil ? 0:128)
  return Record(episode:e.sequence,epoch:e.epoch,phase:phase,started:e.started,attempted:e.before?.at,finished:phase == .terminal ? after.at:nil,reason:reason,before:e.before!,after:after,firstDemandAt:e.firstDemandAt,firstBytesAt:e.firstBytesAt,firstReturnAt:e.firstReturnAt,firstResponseAt:e.firstResponseAt,firstClockAt:e.firstClockAt,firstAdvancingPTSAt:e.firstAdvancingPTSAt,recoveredAt:e.recoveredAt,milestones:mask,rejectedObservations:e.rejectedObservations,rejectionReasons:e.rejectionReasons,lastRejection:e.lastRejection,invalidRejections:e.invalidRejections,invalidSnapshots:e.invalidSnapshots)
 }
}
