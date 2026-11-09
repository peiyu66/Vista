import Foundation

/// Capability and requested rate are distinct from AVPlayer's current transport rate.
public struct PlaybackSpeedStatus:Equatable,Sendable {
 public static let upperLimit = 5
 public static let increment = 0.5
 public var selected:Double,effectiveRate:Double,ready:Bool,supportsFastForward:Bool,paused:Bool,waiting:Bool
 public init(selected:Double=1,effectiveRate:Double=0,ready:Bool=false,supportsFastForward:Bool=false,paused:Bool=false,waiting:Bool=false) {
  self.selected=selected;self.effectiveRate=effectiveRate;self.ready=ready;self.supportsFastForward=supportsFastForward;self.paused=paused;self.waiting=waiting
 }
 // Ready AVPlayerItems support 1...2 even when canPlayFastForward is false (Apple QA1772).
 public var maximum:Double {ready ? (supportsFastForward ? Double(Self.upperLimit):2):1}
 public func accepts(_ rate:Double)->Bool {
  ready && rate.isFinite && (1...maximum).contains(rate) && (rate / Self.increment).rounded() == rate / Self.increment
 }
 public var canIncrease:Bool {accepts(selected+Self.increment)}
 public var canReset:Bool {ready && selected>1}
 public static func label(_ rate:Double)->String {String(format:"%g",locale:Locale(identifier:"en_US_POSIX"),rate)}
 public var showsBufferingIndicator:Bool {ready && waiting && !paused}
 public var text:String {
  let value="\(Self.label(selected))×"
  if !ready {return value}
  if paused {return "\(value) · 暫停"}
  // Transport rate can lag the waiting flag during a transition. Keep the
  // selected rate stable; the shared indicator supplies the waiting feedback.
  return value
 }
}

/// One automatic step per buffering episode. Pauses, seeks and manual choices
/// may restart the delay, but only confirmed playback progress rearms the step.
public struct PlaybackBufferingSpeedPolicy:Sendable {
 public static let interval:Double = 0.5
 public static let minimum:Double = 2
 private var waitingSince:Double?
 private var expectedSpeed:Double?
 private var reducedThisEpisode=false
 public init(){}
 public mutating func reset(){interruptWaiting();reducedThisEpisode=false}
 public mutating func interruptWaiting(){waitingSince=nil;expectedSpeed=nil}
 public mutating func playbackDidAdvance(){reset()}
 public mutating func reducedSpeed(now:Double,status:PlaybackSpeedStatus,eligible:Bool)->Double? {
  guard eligible,now.isFinite,status.showsBufferingIndicator,status.accepts(status.selected),
        status.selected>Self.minimum else{interruptWaiting();return nil}
  guard !reducedThisEpisode else{return nil}
  guard let began=waitingSince,expectedSpeed==status.selected,now>=began else {
   waitingSince=now;expectedSpeed=status.selected;return nil
  }
  guard now-began>=Self.interval else{return nil}
  reducedThisEpisode=true;interruptWaiting()
  return max(Self.minimum,status.selected-PlaybackSpeedStatus.increment)
 }
}

/// Build97: waiting, current frame gap and rolling low cadence share one step.
/// Waiting retains its recovery interval; sparse output can be observed again
/// once the new effective rate and subsequent media-clock progress are verified.
/// This is an output-cadence heuristic, not a count of
/// decoded, dropped or physically displayed frames. Pixels are never inspected.
/// A dense baseline avoids classifying consistently low-frame-rate material;
/// a legitimate dense-to-sparse VFR transition remains indistinguishable here.
public struct PlaybackAutomaticSpeedPolicy:Sendable {
 /// Waiting-only cooldown after either kind of automatic reduction.
 public static let cooldown:Double = 3
 public static let sparseInterval:Double = 0.3
 public static let baselineInterval:Double = 1
 public static let minimumBaselineFPS:Double = 12
 public static let minimumSparseFrameGap:Double = 0.2
 public static let lowCadenceFPS:Double = 20
 public static let lowCadenceFrameCount = 6
 public static let lowCadenceCheckInterval:Double = 0.05
 public static let minimumLowCadenceChecks = 2
 public static let maximumShortObservationGap:Double = 0.1
 public static let minimumSparseSpeed:Double = 2.5
 public static let minimumPollFPS:Double = 30
 public static let maximumObservationGap:Double = 0.25
 public static let manualBaselineMaximumAge:Double = 10
 public static let effectiveRateTolerance:Double = 0.01
 public enum Reason:Int,Sendable {case buffering=1,sparseOutput=2}
 public enum SparseTrigger:Int,Sendable {case none=0,frameGap=1,lowCadence=2}
 public enum ResetReason:Int,Sendable {
  case none=0,manualRate=1,rateTransition=2,ineligible=3,recovery=4,clock=5,pts=6
  case poll=7,observationGap=8,insufficientWindow=9,interruption=10,automaticReduction=11,waiting=12,staleManualBaseline=13
 }
 public struct DiagnosticSnapshot:Equatable,Sendable {
  public let baselineReady:Bool,awaitingRateStart:Bool,lastResetReason:ResetReason,resetCount:UInt64
 }
 public struct Decision:Equatable,Sendable {
  public let nextSpeed:Double,reason:Reason,sequence:UInt64
  public let observedSeconds:Double,advancingFrames:UInt64,outputPolls:UInt64
  public let clockAdvance:Double,maximumFrameGap:Double
  public var sparseTrigger:SparseTrigger = .none
  public var healthyReferenceFPS:Double = 0
  public var recentAdvancingFrames:UInt64 = 0
  public var lowCadenceChecks:Int = 0
 }
 private struct Window:Sendable {
  var began:Double,initialClock:Double,lastTime:Double,lastClock:Double,lastClockAdvance:Double
  var lastPTS:Double?,lastFrameAt:Double,lastPollAt:Double
  var frames:UInt64=0,polls:UInt64=0,maximumFrameGap:Double=0
 }
 /// Fixed-memory sufficient statistics for the short rolling decision. Six
 /// deliveries and nine polls are enough to prove the respective thresholds.
 /// Clock checkpoints are sampled at most 120/s, retaining only 0.3 s plus one.
 private struct ShortWindow:Sendable {
  var began:Double,lastFrameAt:Double
  var deliveries:[Double]=[],polls:[Double]=[]
  var clocks:[(time:Double,clock:Double)]=[]
  var lastCheck:Double?,lowChecks=0
 }
 private var shortWindow:ShortWindow?
 private var sparseGateWasOpen:Bool?
 private var healthyReferenceFPS:Double=0
 private var lastHealthy20At:Double?
 private var transferredHealthy20ExpiresAt:Double?
 private var window:Window?
 private var normalCadenceEstablished=false
 private var lastHealthyAt:Double?
 private var transferredBaselineExpiresAt:Double?
 private var selectedSpeed:Double?
 private var waitingSince:Double?
 private var cooldownUntil:Double?
 private var requiresRateStart=false
 private var rateChangeAt:Double?
 private var rateStartSample:(time:Double,clock:Double)?
 private var wasRecovering=false
 private var lastCopiedPTS:Double?
 private var discardThroughPTS:Double?
 private var previousTime:Double?
 private var sequence:UInt64=0
 private var lastResetReason:ResetReason = .none
 private var resetCount:UInt64=0
 public init(){}
 public var diagnostics:DiagnosticSnapshot {
  DiagnosticSnapshot(baselineReady:normalCadenceEstablished,awaitingRateStart:requiresRateStart,
   lastResetReason:lastResetReason,resetCount:resetCount)
 }
 /// Only new playback / cleanup clears the waiting recovery interval.
 public mutating func reset(){self=Self()}
 /// Pause, seek, background, source recovery and invalid observations discard
 /// the same-play healthy reference as well as the current evidence window,
 /// but cannot bypass an automatic reduction's waiting recovery interval.
 public mutating func interruptObservation(reason:ResetReason = .interruption){
  recordReset(reason,changed:window != nil || rateStartSample != nil || normalCadenceEstablished)
  window=nil;shortWindow=nil;normalCadenceEstablished=false;lastHealthyAt=nil;waitingSince=nil;selectedSpeed=nil
  requiresRateStart=true;rateStartSample=nil;rateChangeAt=nil;lastCopiedPTS=nil;discardThroughPTS=nil
  transferredBaselineExpiresAt=nil;healthyReferenceFPS=0;lastHealthy20At=nil;transferredHealthy20ExpiresAt=nil;sparseGateWasOpen=nil
 }
 /// A rate-only change on the same playback may reuse a recently observed dense
 /// cadence, including one learned at 1–2×. Never use this for pause or seek.
 /// Freshness applies to manual transfer, not expiry of a continuing sparse
 /// incident: automatic steps may continue after verified rate start and a fresh
 /// observation window until smooth or 2×.
 public mutating func manualSpeedDidChange(now:Double){
  recordReset(.manualRate,changed:true)
  let fresh=lastHealthyAt.map{now.isFinite && now >= $0 && now-$0<=Self.manualBaselineMaximumAge} ?? false
  if !fresh {normalCadenceEstablished=false;lastHealthyAt=nil;healthyReferenceFPS=0}
  let strongFresh=lastHealthy20At.map{now.isFinite && now >= $0 && now-$0<=Self.manualBaselineMaximumAge} ?? false
  if !strongFresh {lastHealthy20At=nil;healthyReferenceFPS=min(healthyReferenceFPS,Self.minimumBaselineFPS)}
  transferredHealthy20ExpiresAt=lastHealthy20At.map{$0+Self.manualBaselineMaximumAge}
  transferredBaselineExpiresAt=normalCadenceEstablished ? lastHealthyAt.map{$0+Self.manualBaselineMaximumAge}:nil
  window=nil;shortWindow=nil;waitingSince=nil;selectedSpeed=nil
  requiresRateStart=true;rateStartSample=nil;rateChangeAt=now;discardThroughPTS=nil
 }
 /// Call once per playback loop, after the actual output poll/copy. `recovering`
 /// distinguishes real recovery from a normal requested-rate transport transition;
 /// `eligible` excludes seek/background/source recovery/failure/end.
 /// Pass nil unless this loop successfully copied a finite output PTS. Repeated
 /// PTS are not advancing frames, irrespective of their pixel contents.
 public mutating func update(now:Double,status:PlaybackSpeedStatus,eligible:Bool,playing:Bool,recovering:Bool=false,
  clock:Double,outputPolled:Bool,copiedFramePTS:Double?)->Decision? {
  guard now.isFinite,now>=0 else{interruptObservation(reason:.clock);return nil}
  if let previousTime,now<previousTime {interruptObservation(reason:.clock)}
  previousTime=now
  guard eligible,status.ready,!status.paused,status.accepts(status.selected),clock.isFinite,clock>=0 else {
   interruptObservation(reason:clock.isFinite && clock>=0 ? .ineligible:.clock);return nil
  }
  if let selectedSpeed,selectedSpeed != status.selected {manualSpeedDidChange(now:now)}
  selectedSpeed=status.selected
  if outputPolled,let value=copiedFramePTS,(!value.isFinite || value<0) {
   interruptObservation(reason:.pts);return nil
  }
  let copiedPTS=outputPolled ? copiedFramePTS.flatMap{$0.isFinite && $0>=0 ? $0:nil}:nil
  if let copiedPTS {lastCopiedPTS=max(lastCopiedPTS ?? copiedPTS,copiedPTS)}
  let recoveryTransition=wasRecovering || recovering
  let recoveryEntered=recovering && !wasRecovering
  wasRecovering=recovering
  if recoveryEntered {
   // An ordinary data stall suspends evidence, not the already proven cadence
   // of this playback. Never refresh lastHealthyAt or a manual-transfer expiry.
   // Source recovery and intentional interruptions still use the full reset.
   recordReset(.recovery,changed:window != nil || rateStartSample != nil)
   window=nil;shortWindow=nil;rateStartSample=nil;discardThroughPTS=nil;requiresRateStart=true
   // Both confirmation samples must be later than the pending-entry callback.
   // Keep the reference through a transient zero-rate transport after pending
   // clears, but count no frames or clock progress until fresh confirmation.
   rateChangeAt=now
  }
  if status.waiting {
   // Do not replace an explicit recovery reset reason with a wait on every loop.
   if !recovering {recordReset(.waiting,changed:window != nil || rateStartSample != nil)}
   window=nil;shortWindow=nil;requiresRateStart=true;rateStartSample=nil;rateChangeAt=now
   guard status.selected>PlaybackBufferingSpeedPolicy.minimum else{waitingSince=nil;return nil}
   if let until=cooldownUntil {
    // Waiting never banks evidence during cooldown. A late first call still
    // starts a fresh half-second rather than catching up on missed reductions.
    waitingSince=nil
    guard now>=until else{return nil}
    cooldownUntil=nil
   }
   guard let began=waitingSince else{waitingSince=now;return nil}
   guard now-began>=PlaybackBufferingSpeedPolicy.interval else{return nil}
   return reduce(now:now,status:status,reason:.buffering,seconds:now-began)
  }
  waitingSince=nil
  // pending is a recovery latch, not proof that transport is still waiting.
  // Independent, fresh playing/rate/clock evidence may establish this window
  // even while that latch is waiting for advancing output frames to clear it.
  guard playing,status.effectiveRate.isFinite,status.effectiveRate>0 else {
   // The timebase can reach zero before transport or the stall notification
   // reports waiting. Treat that observation like the other rate transitions,
   // not a user pause (already excluded above). Do not refresh the reference.
   let playingAtZero=playing && status.effectiveRate==0
   if (requiresRateStart && rateChangeAt != nil) || recoveryTransition || playingAtZero {
    // AVPlayer.play() can briefly report zero rate or non-playing during a
    // normal rate-only transition. Do not erase a proven same-play baseline;
    // merely require two new effective-rate/clock samples once it starts.
    recordReset(.rateTransition,changed:window != nil || rateStartSample != nil)
    window=nil;shortWindow=nil;rateStartSample=nil;requiresRateStart=true
    if recoveryTransition || playingAtZero {rateChangeAt=now}
    return nil
   }
   interruptObservation(reason:.rateTransition);return nil
  }
  let sparseGate=status.selected>=Self.minimumSparseSpeed && status.effectiveRate>=Self.minimumSparseSpeed
  if !sparseGate {shortWindow=nil}
  // Literal lower bound: effective 2.49 never starts a 2.5x countdown even
  // when its difference happens to fit the separate rate-match tolerance.
  if status.selected>=Self.minimumSparseSpeed && !sparseGate {
   recordReset(.rateTransition,changed:window != nil || rateStartSample != nil)
   window=nil;shortWindow=nil;requiresRateStart=true;rateStartSample=nil;rateChangeAt=now
   sparseGateWasOpen=sparseGate
   return nil
  }
  if sparseGate && sparseGateWasOpen==false {
   window=nil;shortWindow=nil;requiresRateStart=true;rateStartSample=nil
   // This first newly matching callback may be confirmation sample one.
   // Its timestamp must still be after the last manual/below-gate observation.
  }
  sparseGateWasOpen=sparseGate
  guard abs(status.effectiveRate-status.selected)<=Self.effectiveRateTolerance else {
   // Requested/default/player.rate are not proof that the timebase changed.
   recordReset(.rateTransition,changed:window != nil || rateStartSample != nil)
   window=nil;shortWindow=nil;requiresRateStart=true;rateStartSample=nil;return nil
  }
  if requiresRateStart {
   guard rateChangeAt.map({now>$0}) ?? true else{return nil}
   guard let previous=rateStartSample else{rateStartSample=(now,clock);return nil}
   let dt=now-previous.time,advance=clock-previous.clock
   guard dt>0 else{return nil}
   if advance<0 || advance>max(0.5,dt*status.selected*2) {
    interruptObservation(reason:.clock);return nil
   }
   guard dt<=Self.maximumObservationGap,advance>0 else{rateStartSample=(now,clock);return nil}
   if let expiry=transferredBaselineExpiresAt,now>expiry {
    recordReset(.staleManualBaseline,changed:normalCadenceEstablished)
    normalCadenceEstablished=false;lastHealthyAt=nil;healthyReferenceFPS=0;lastHealthy20At=nil
   }
   if let expiry=transferredHealthy20ExpiresAt,now>expiry {
    lastHealthy20At=nil;healthyReferenceFPS=min(healthyReferenceFPS,Self.minimumBaselineFPS)
   }
   transferredBaselineExpiresAt=nil;transferredHealthy20ExpiresAt=nil
   requiresRateStart=false;rateStartSample=nil;rateChangeAt=nil
   // The confirmation callback only establishes an anchor. Its clock delta,
   // copied PTS and all pre-change evidence are excluded from the new window.
   // Do not require a copied frame to start: zero output must remain observable.
   // Nor require PTS >= clock: valid output can legitimately trail that clock.
   discardThroughPTS=lastCopiedPTS
   begin(now:now,clock:clock,polled:false,pts:nil)
   window?.lastPTS=lastCopiedPTS
   if sparseGate {beginShort(now:now,clock:clock)}
   return nil
  }
  let pts:Double?=copiedPTS.flatMap {value in
   if let floor=discardThroughPTS,value<=floor {return nil};return value
  }
  guard var sample=window else {
   begin(now:now,clock:clock,polled:outputPolled,pts:pts)
   if sparseGate {beginShort(now:now,clock:clock)}
   return nil
  }
  let dt=now-sample.lastTime,clockDelta=clock-sample.lastClock
  guard dt>0 else{return nil}
  let ptsReversed:Bool
  if let pts,let previous=sample.lastPTS {ptsReversed=pts<previous}else{ptsReversed=false}
  // A stalled observation loop, stale clock, backwards time or an unannounced
  // seek cannot be evidence that a well-observed output became sparse.
  if dt>Self.maximumObservationGap {interruptObservation(reason:.observationGap);return nil}
  if clockDelta<0 || clockDelta>max(0.5,dt*status.selected*2) {interruptObservation(reason:.clock);return nil}
  if now-sample.lastPollAt>Self.maximumObservationGap {interruptObservation(reason:.poll);return nil}
  if ptsReversed {interruptObservation(reason:.pts);return nil}
  // A short observer outage must not look like a well-observed 0.3 s gap.
  // Keep the proven same-play reference through this smaller interruption.
  let shortInterrupted=dt>Self.maximumShortObservationGap || now-sample.lastPollAt>Self.maximumShortObservationGap
   || (clockDelta<=0 && now-sample.lastClockAdvance>Self.maximumShortObservationGap)
  if shortInterrupted {shortWindow=nil}
  sample.lastTime=now;sample.lastClock=clock
  if clockDelta>0 {sample.lastClockAdvance=now}
  if now-sample.lastClockAdvance>Self.maximumObservationGap {
   interruptObservation(reason:.clock);return nil
  }
  if outputPolled {if sample.polls<UInt64.max {sample.polls += 1};sample.lastPollAt=now}
  let frameGap=now-sample.lastFrameAt
  sample.maximumFrameGap=max(sample.maximumFrameGap,frameGap)
  var advancingFrame=false
  if outputPolled,let pts {
   if let previous=sample.lastPTS,pts>previous {
    advancingFrame=true
    if sample.frames<UInt64.max {sample.frames += 1};sample.lastFrameAt=now
   }
   else if sample.lastPTS==nil {sample.lastFrameAt=now}
   sample.lastPTS=pts
  }
  window=sample
  // Process a new advancing frame before either deadline. A current frame
  // cancels the gap branch, but does not erase genuinely low rolling density.
  if sparseGate {
   if shortWindow==nil {beginShort(now:now,clock:clock,polled:outputPolled,advancing:advancingFrame)}
   else if let result=observeShort(now:now,clock:clock,status:status,polled:outputPolled,advancing:advancingFrame) {return result}
  }
  let seconds=now-sample.began
  guard seconds>=Self.baselineInterval else{return nil}
  let advance=clock-sample.initialClock
  let wellObserved=Double(sample.polls)/seconds>=Self.minimumPollFPS && advance/seconds>=status.selected*0.5
  let fps=Double(sample.frames)/seconds
  if !wellObserved {
   recordReset(.insufficientWindow,changed:true)
   normalCadenceEstablished=false;lastHealthyAt=nil;healthyReferenceFPS=0;lastHealthy20At=nil
  }
  else if fps>=Self.minimumBaselineFPS && sample.maximumFrameGap<=Self.maximumObservationGap {
   normalCadenceEstablished=true;lastHealthyAt=now;transferredBaselineExpiresAt=nil
   // A bad interval cannot downgrade or refresh the strong healthy reference.
   if fps>=Self.lowCadenceFPS {
    healthyReferenceFPS=max(healthyReferenceFPS,fps);lastHealthy20At=now;transferredHealthy20ExpiresAt=nil
   } else if lastHealthy20At==nil {healthyReferenceFPS=max(healthyReferenceFPS,fps)}
  }
  // Preserve the PTS seed across baseline windows: the next advancing copy is
  // a delivery, not a new seed. Short-window rolling never resets that seed.
  begin(now:now,clock:clock,polled:outputPolled,pts:sample.lastPTS)
  window?.lastPollAt=sample.lastPollAt;window?.lastClockAdvance=sample.lastClockAdvance;window?.lastFrameAt=sample.lastFrameAt
  return nil
 }
 private mutating func beginShort(now:Double,clock:Double,polled:Bool=false,advancing:Bool=false) {
  shortWindow=ShortWindow(began:now,lastFrameAt:now,deliveries:advancing ? [now]:[],polls:polled ? [now]:[],clocks:[(now,clock)])
 }
 private mutating func observeShort(now:Double,clock:Double,status:PlaybackSpeedStatus,polled:Bool,advancing:Bool)->Decision? {
  guard var short=shortWindow else{return nil}
  let boundary=now-Self.sparseInterval
  short.deliveries.removeAll{$0<=boundary}
  short.polls.removeAll{$0<=boundary}
  if polled {short.polls.append(now);if short.polls.count>9 {short.polls.removeFirst()}}
  if advancing {
   short.lastFrameAt=now;short.deliveries.append(now)
   if short.deliveries.count>Self.lowCadenceFrameCount {short.deliveries.removeFirst()}
  }
  // Sample checkpoints at a bounded frequency, retaining the latest point at
  // or before the rolling boundary. Using the next point is conservative for
  // the minimum forward-clock test and cannot credit stale progress.
  if now-(short.clocks.last?.time ?? now)>=1.0/120 {short.clocks.append((now,clock))}
  while short.clocks.count>1 && short.clocks[1].time<=boundary {short.clocks.removeFirst()}
  let clockAnchor=short.clocks.first(where:{$0.time>=boundary}) ?? (now,clock)
  let advance=max(0,clock-clockAnchor.clock)
  let seconds=now-short.began,gap=now-short.lastFrameAt
  let complete=seconds>=Self.sparseInterval
  let wellObserved=complete && short.polls.count>=9 && advance>=status.selected*Self.sparseInterval*0.5
  // Build100: independently mature the approved gap witness; rolling stays .3 s.
  // Conservatively exclude a 1 ns boundary band. Six points are a nominal
  // 30/s window count, not a guarantee about true observer frequency or jitter.
  let gapBoundary=now-Self.minimumSparseFrameGap
  let gapPolls=short.polls.filter{$0>gapBoundary+1e-9}.count
  let gapClockAnchor=short.clocks.first(where:{$0.time>=gapBoundary}) ?? (now,clock)
  let gapAdvance=max(0,clock-gapClockAnchor.clock)
  let gapWellObserved=seconds>=Self.minimumSparseFrameGap && gapPolls>=6
   && gapAdvance>=status.selected*Self.minimumSparseFrameGap*0.5
  if !wellObserved {short.lowChecks=0}
  // Check density no faster than every 50 ms; two overlapping checks are a
  // debounce, not independent samples or proof of a physical display fault.
  if complete && (short.lastCheck.map{now-$0>=Self.lowCadenceCheckInterval} ?? true) {
   short.lastCheck=now
   if wellObserved && lastHealthy20At != nil && healthyReferenceFPS>=Self.lowCadenceFPS
      && short.deliveries.count<Self.lowCadenceFrameCount {
    short.lowChecks=min(Self.minimumLowCadenceChecks,short.lowChecks+1)
   } else {short.lowChecks=0}
  }
  shortWindow=short
  guard normalCadenceEstablished else{return nil}
  let trigger:SparseTrigger
  if gapWellObserved && gap>=Self.minimumSparseFrameGap {trigger = .frameGap}
  else if wellObserved && short.lowChecks>=Self.minimumLowCadenceChecks {trigger = .lowCadence}
  else {return nil}
  let isGap=trigger == .frameGap
  let measuredFrames=isGap ? short.deliveries.filter{$0>gapBoundary+1e-9}.count:short.deliveries.count
  return reduce(now:now,status:status,reason:.sparseOutput,
   seconds:isGap ? Self.minimumSparseFrameGap:Self.sparseInterval,
   frames:UInt64(measuredFrames),polls:UInt64(isGap ? gapPolls:short.polls.count),
   clockAdvance:isGap ? gapAdvance:advance,frameGap:gap,trigger:trigger,lowChecks:short.lowChecks)
 }
 private mutating func begin(now:Double,clock:Double,polled:Bool,pts:Double?){
  window=Window(began:now,initialClock:clock,lastTime:now,lastClock:clock,lastClockAdvance:now,
   lastPTS:pts,lastFrameAt:now,lastPollAt:now)
 }
 private mutating func recordReset(_ reason:ResetReason,changed:Bool){
  if changed || lastResetReason != reason {
   if resetCount<(1 << 53)-1 {resetCount += 1}
   lastResetReason=reason
  }
 }
 private mutating func reduce(now:Double,status:PlaybackSpeedStatus,reason:Reason,seconds:Double,
  frames:UInt64=0,polls:UInt64=0,clockAdvance:Double=0,frameGap:Double=0,trigger:SparseTrigger = .none,lowChecks:Int=0)->Decision {
  let next=max(PlaybackBufferingSpeedPolicy.minimum,status.selected-PlaybackSpeedStatus.increment)
  recordReset(.automaticReduction,changed:true)
  if reason == .sparseOutput {transferredBaselineExpiresAt=nil;transferredHealthy20ExpiresAt=nil}
  if sequence<UInt64.max {sequence += 1}
  selectedSpeed=next;cooldownUntil=now+Self.cooldown;waitingSince=nil;window=nil;shortWindow=nil
  requiresRateStart=true;rateStartSample=nil;rateChangeAt=now;discardThroughPTS=nil
  return Decision(nextSpeed:next,reason:reason,sequence:sequence,observedSeconds:seconds,
   advancingFrames:frames,outputPolls:polls,clockAdvance:clockAdvance,maximumFrameGap:frameGap,
   sparseTrigger:trigger,healthyReferenceFPS:healthyReferenceFPS,recentAdvancingFrames:frames,lowCadenceChecks:lowChecks)
 }
}
