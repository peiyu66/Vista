import Foundation

/// Build97 observational evidence only. One active automatic-rate episode, no
/// timer, pixels, player controls, file identity, or per-frame journal records.
/// A cadence witness describes copied advancing PTS, not physical presentation.
struct PlaybackAutomaticRecoveryDiagnostics:Sendable {
 static let recordLimit:UInt64=16
 static let cadenceWindow=0.3,minimumCadenceFPS=20.0,checkInterval=0.05,maximumObservationGap=0.1
 static let minimumPollFPS=30.0,rateTolerance=0.01
 static let frameCapacity=32,pollCapacity=16,clockCapacity=64
 enum EndReason:Int,Sendable {
  case recovered=1,firstFrameOnly,manualRate,seek,pause,background,sourceFailure,stopped,superseded,ended,invalidObservation
  // The source can change epoch between callbacks without exposing a recovery flag.
  case sourceEpoch=12
 }
 struct Record:Sendable {
  let sequence:UInt64,previousSpeed:Double,targetSpeed:Double
  let decisionAt:Double?,rateConfirmedAt:Double?,firstFrameAt:Double?,sustainedAt:Double?,endedAt:Double?
  let reason:EndReason,cadenceApplicable:Bool,healthyReferenceFPS:Double
  let baselineMask:Int,resets:UInt64,invalidObservations:UInt64
  var milestoneMask:Int {(decisionAt == nil ? 0:1) | (rateConfirmedAt == nil ? 0:2) | (firstFrameAt == nil ? 0:4) | (sustainedAt == nil ? 0:8) | (endedAt == nil ? 0:16)}
 }
 struct Summary:Sendable {
  let seen:UInt64,emitted:UInt64,suppressed:UInt64,recovered:UInt64,firstFrameOnly:UInt64,incomplete:UInt64
 }
 struct Completion:Sendable {let terminal:Record?;let summary:Summary}
 private struct Episode:Sendable {
  var sequence:UInt64,previousSpeed:Double,targetSpeed:Double,decisionAt:Double?
  var healthyReferenceFPS:Double,cadenceApplicable:Bool,baselineMask:Int
  var lastObservedAt:Double?,lastClock:Double?,lastClockAdvanceAt:Double?,highPTS:Double?
  var confirmingAt:Double?,confirmingClock:Double?,currentConfirmedAt:Double?
  var rateConfirmedAt:Double?,firstFrameAt:Double?,sustainedAt:Double?
  var cadenceAt:Double?,cadenceClock:Double?,lastPollAt:Double?
  var frameTimes:[Double]=[],pollTimes:[Double]=[],clockSamples:[(time:Double,clock:Double)]=[]
  var lastCheckAt:Double?,goodChecks=0
  var resets:UInt64=0,invalidObservations:UInt64=0
  mutating func resetEvidence() {
   confirmingAt=nil;confirmingClock=nil;currentConfirmedAt=nil
   cadenceAt=nil;cadenceClock=nil;lastPollAt=nil
   frameTimes.removeAll(keepingCapacity:true);pollTimes.removeAll(keepingCapacity:true)
   clockSamples.removeAll(keepingCapacity:true);lastCheckAt=nil;goodChecks=0
   PlaybackAutomaticRecoveryDiagnostics.increment(&resets)
  }
 }
 private var active:Episode?
 private var closed=false
 private var seen:UInt64=0,emitted:UInt64=0,suppressed:UInt64=0,recovered:UInt64=0,firstFrameOnly:UInt64=0,incomplete:UInt64=0
 var isObserving:Bool {active != nil}
 var activeSequence:UInt64? {active?.sequence}
 // Testable bounded state; never includes pixels or media content.
 var retainedFrameTimes:Int {active?.frameTimes.count ?? 0}
 var retainedPollTimes:Int {active?.pollTimes.count ?? 0}
 var retainedClockSamples:Int {active?.clockSamples.count ?? 0}
 init(){}
 @discardableResult mutating func begin(sequence:UInt64,now:Double,previousSpeed:Double,targetSpeed:Double,
  decisionClock:Double?,lastFramePTS:Double?,healthyReferenceFPS:Double)->Record? {
  guard !closed else{return nil}
  let prior=interrupt(.superseded,now:now)
  Self.increment(&seen)
  // Suppressed episodes allocate no observation state. A single summary makes
  // this bounded diagnostic budget visible even if playback continues for hours.
  guard emitted<Self.recordLimit else {Self.increment(&suppressed);return prior}
  let validClock=decisionClock.flatMap{ $0.isFinite ? $0:nil }
  let validPTS=lastFramePTS.flatMap{ $0.isFinite && $0>=0 ? $0:nil }
  let reference=healthyReferenceFPS.isFinite ? max(0,healthyReferenceFPS):0
  active=Episode(sequence:sequence,previousSpeed:previousSpeed,targetSpeed:targetSpeed,
   decisionAt:now.isFinite ? now:nil,healthyReferenceFPS:reference,cadenceApplicable:reference>=Self.minimumCadenceFPS,
   baselineMask:(validClock == nil ? 0:1) | (validPTS == nil ? 0:2),
   lastObservedAt:now.isFinite ? now:nil,lastClock:validClock,highPTS:validPTS)
  return prior
 }
 /// Call once for each existing playback loop, including target rate 2x after
 /// the sparse policy has stopped. Call lifecycle interrupts before later frames.
 @discardableResult mutating func observe(now:Double,effectiveRate:Double,playing:Bool,waiting:Bool,
  clock:Double,outputPolled:Bool,copiedFramePTS:Double?)->Record? {
  guard var episode=active else{return nil}
  guard now.isFinite,let decisionAt=episode.decisionAt,now>decisionAt,
        episode.lastObservedAt.map({now>$0}) ?? true else {
   // Duplicate callbacks cannot count as fresh confirmations or evidence.
   Self.increment(&episode.invalidObservations);episode.resetEvidence();active=episode;return nil
  }
  let priorNow=episode.lastObservedAt,priorClock=episode.lastClock
  let priorClockAdvanceAt=episode.lastClockAdvanceAt,priorPollAt=episode.lastPollAt
  episode.lastObservedAt=now
  var advancedPTS=false
  if let pts=copiedFramePTS {
   if pts.isFinite,pts>=0 {
    advancedPTS=episode.highPTS.map{pts>$0} ?? false
    episode.highPTS=max(episode.highPTS ?? pts,pts)
   } else {
    Self.increment(&episode.invalidObservations);episode.resetEvidence();episode.lastClock=clock.isFinite ? clock:nil;active=episode;return nil
   }
  }
  guard clock.isFinite else {
   Self.increment(&episode.invalidObservations);episode.resetEvidence();episode.lastClock=nil;active=episode;return nil
  }
  episode.lastClock=clock
  if priorClock.map({clock>$0}) ?? false {episode.lastClockAdvanceAt=now}
  let rateMatches=effectiveRate.isFinite && effectiveRate>0 && episode.targetSpeed.isFinite &&
   abs(effectiveRate-episode.targetSpeed)<=Self.rateTolerance
  guard playing,!waiting,rateMatches else {
   episode.resetEvidence();active=episode;return nil
  }
  if let priorClock,let priorNow,
     clock<priorClock || clock-priorClock>max(0.5,(now-priorNow)*episode.targetSpeed*2) {
   Self.increment(&episode.invalidObservations);episode.resetEvidence();active=episode;return nil
  }
  if let priorNow,now-priorNow>Self.maximumObservationGap+1e-9 {
   episode.resetEvidence()
  }
  if let confirmed=episode.currentConfirmedAt,
     now-(priorPollAt ?? confirmed)>Self.maximumObservationGap+1e-9 ||
     now-(priorClockAdvanceAt ?? confirmed)>Self.maximumObservationGap+1e-9 {
   episode.resetEvidence()
  }
  if episode.currentConfirmedAt == nil {
   // The decision callback, equal clocks and pre-confirmation copied frames do
   // not establish a new-rate milestone. Both observations must be fresh and
   // individually advance their preceding clock samples.
   guard let priorClock,clock>priorClock else {
    episode.confirmingAt=nil;episode.confirmingClock=nil;active=episode;return nil
   }
   if let confirmingAt=episode.confirmingAt,let confirmingClock=episode.confirmingClock,
      now>confirmingAt,clock>confirmingClock {
    episode.currentConfirmedAt=now
    if episode.rateConfirmedAt == nil {episode.rateConfirmedAt=now}
    episode.cadenceAt=now;episode.cadenceClock=clock;episode.clockSamples=[(now,clock)]
   } else {episode.confirmingAt=now;episode.confirmingClock=clock}
   // A frame in the confirmation callback is raised into the PTS high-water
   // but is not a post-confirmation first frame or cadence sample.
   active=episode;return nil
  }
  if outputPolled {
   episode.lastPollAt=now
   episode.pollTimes.removeAll{$0<=now-Self.cadenceWindow+1e-9}
   if episode.pollTimes.count==Self.pollCapacity {episode.pollTimes.removeFirst()}
   episode.pollTimes.append(now)
  }
  if outputPolled,advancedPTS,let confirmed=episode.currentConfirmedAt,now>confirmed {
   if episode.firstFrameAt == nil {episode.firstFrameAt=now}
   if !episode.cadenceApplicable {
    active=episode;return interrupt(.firstFrameOnly,now:now)
   }
   episode.frameTimes.removeAll{$0<=now-Self.cadenceWindow+1e-9}
   if episode.frameTimes.count==Self.frameCapacity {episode.frameTimes.removeFirst()}
   episode.frameTimes.append(now)
  }
  episode.frameTimes.removeAll{$0<=now-Self.cadenceWindow+1e-9}
  episode.pollTimes.removeAll{$0<=now-Self.cadenceWindow+1e-9}
  if now-(episode.clockSamples.last?.time ?? now)>=1.0/120 {
   if episode.clockSamples.count==Self.clockCapacity {episode.clockSamples.removeFirst()}
   episode.clockSamples.append((now,clock))
  }
  while episode.clockSamples.count>1 && episode.clockSamples[1].time<=now-Self.cadenceWindow {
   episode.clockSamples.removeFirst()
  }
  let rollingClock=episode.clockSamples.first(where:{$0.time>=now-Self.cadenceWindow})?.clock ?? clock
  if episode.lastCheckAt.map({now-$0+1e-9<Self.checkInterval}) ?? false {active=episode;return nil}
  episode.lastCheckAt=now
  if let began=episode.cadenceAt,let startClock=episode.cadenceClock,
     now-began+1e-9>=Self.cadenceWindow,clock>startClock,
     clock-rollingClock+1e-9>=episode.targetSpeed*Self.cadenceWindow*0.5,
     let lastClockAdvance=episode.lastClockAdvanceAt,now-lastClockAdvance<=Self.maximumObservationGap+1e-9,
     let lastPoll=episode.lastPollAt,now-lastPoll<=Self.maximumObservationGap+1e-9,
     Double(episode.pollTimes.count)+1e-9>=Self.minimumPollFPS*Self.cadenceWindow,
     Double(episode.frameTimes.count)/Self.cadenceWindow+1e-9>=Self.minimumCadenceFPS {
   episode.goodChecks+=1
  } else {episode.goodChecks=0}
  if episode.goodChecks>=2 {
   episode.sustainedAt=now;active=episode;return interrupt(.recovered,now:now)
  }
  active=episode;return nil
 }
 @discardableResult mutating func interrupt(_ reason:EndReason,now:Double)->Record? {
  guard let episode=active else{return nil}
  active=nil
  if reason == .recovered {Self.increment(&recovered)}
  else if reason == .firstFrameOnly {Self.increment(&firstFrameOnly)}
  else {Self.increment(&incomplete)}
  Self.increment(&emitted)
  return Record(sequence:episode.sequence,previousSpeed:episode.previousSpeed,targetSpeed:episode.targetSpeed,
   decisionAt:episode.decisionAt,rateConfirmedAt:episode.rateConfirmedAt,firstFrameAt:episode.firstFrameAt,
   sustainedAt:episode.sustainedAt,endedAt:now.isFinite && (episode.decisionAt.map({now >= $0}) ?? true) ? now:nil,
   reason:reason,cadenceApplicable:episode.cadenceApplicable,healthyReferenceFPS:episode.healthyReferenceFPS,
   baselineMask:episode.baselineMask,resets:episode.resets,invalidObservations:episode.invalidObservations)
 }
 mutating func finish(now:Double)->Completion? {
  guard !closed else{return nil}
  let terminal=interrupt(.stopped,now:now);closed=true
  return Completion(terminal:terminal,summary:Summary(seen:seen,emitted:emitted,suppressed:suppressed,
   recovered:recovered,firstFrameOnly:firstFrameOnly,incomplete:incomplete))
 }
 private static func increment(_ value:inout UInt64) {if value<UInt64.max {value+=1}}
}
