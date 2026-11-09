import Foundation

/// Observed controller flags only; never changes the actual UI disabled policy.
public struct PlaybackControllerUIState: Equatable, Sendable {
 public let stopping:Bool, scrubbing:Bool, preparing:Bool, advancing:Bool
 public let requiresFormatConfirmation:Bool, canResetSpeed:Bool, canIncreaseSpeed:Bool
 public let canGoBack:Bool, canAdvance:Bool, hasDuration:Bool
 public init(stopping:Bool,scrubbing:Bool,preparing:Bool,advancing:Bool,
             requiresFormatConfirmation:Bool,canResetSpeed:Bool,canIncreaseSpeed:Bool,
             canGoBack:Bool,canAdvance:Bool,hasDuration:Bool) {
  self.stopping=stopping;self.scrubbing=scrubbing;self.preparing=preparing;self.advancing=advancing
  self.requiresFormatConfirmation=requiresFormatConfirmation;self.canResetSpeed=canResetSpeed
  self.canIncreaseSpeed=canIncreaseSpeed;self.canGoBack=canGoBack;self.canAdvance=canAdvance;self.hasDuration=hasDuration
 }
 /// Bits: stop, scrub, prepare, advance, format, cannot reset/increase, no previous/next/duration.
 public var mask:Int {
  let flags=[stopping,scrubbing,preparing,advancing,requiresFormatConfirmation,
             !canResetSpeed,!canIncreaseSpeed,!canGoBack,!canAdvance,!hasDuration]
  return flags.enumerated().reduce(0) {$1.element ? $0 | (1 << $1.offset):$0}
 }
}

/// All timestamps are UI observation uptime, not GPU presentation times or inferred earlier starts.
/// Fixed-size value owned by the UI's MainActor. No timers, I/O or arbitrary metadata.
public struct PlaybackControllerUIDiagnostics: Sendable {
 public enum Action:Int,Sendable {
  case stateChanged=0,sliderValueBegan=1,sliderEditingBegan=2,sliderEnded=3
  case stopBegan=4,stopCompleted=5,viewDisappeared=6,viewAppeared=7
 }
 private var state:PlaybackControllerUIState?
 private var stateSince:Double?, scrubbingSince:Double?, stoppingSince:Double?
 private var clock:Double=0, lastActionUptime:Double=0, observationStarted:Double?
 private var lastAction:Action = .stateChanged, eventAction:Action = .stateChanged
 private var lastEdgeState:PlaybackControllerUIState?, lastEdgeAction:Action?
 private var stateSequence:UInt64=0, eventSequence:UInt64=0, suppressed:UInt64=0
 private var emitted=0, ordinaryEmitted=0
 private var terminalActions:Set<Action>=[]
 private let eventLimit:Int
 /// At most 128 events. Reserve min(3, limit) for the first stop-began, stop-completed
 /// and disappeared observations; the remaining budget serves ordinary events.
 public init(eventLimit:Int=128) {self.eventLimit=min(128,max(0,eventLimit))}
 private static func increment(_ value:inout UInt64) {if value < UInt64.max {value += 1}}
 private func safeTime(_ now:Double)->Double {now.isFinite ? max(clock,max(0,now)):clock}
 private func age(_ since:Double?,at now:Double)->Double {
  guard let since else{return 0}
  // Clamp before multiplication so even extreme injected clocks remain JSON-safe.
  return min(max(0,now-since),Double.greatestFiniteMagnitude/1000)*1000
 }
 public mutating func update(state newState:PlaybackControllerUIState,action:Action = .stateChanged,
                             now:Double = ProcessInfo.processInfo.systemUptime)->[PlaybackLogField:Double]? {
  let time=safeTime(now), changed=state != newState
  clock=time
  // Unknown injected clock values do not invent a start or get backfilled by later samples.
  let observedTime:Double? = now.isFinite && now >= 0 ? time:nil
  if observationStarted == nil, let observedTime {observationStarted=observedTime}
  if changed {
   if newState.scrubbing {if state?.scrubbing != true {scrubbingSince=observedTime}} else {scrubbingSince=nil}
   if newState.stopping {if state?.stopping != true {stoppingSince=observedTime}} else {stoppingSince=nil}
   state=newState;stateSince=observedTime;Self.increment(&stateSequence)
  }
  // Polling never overwrites edge deduplication; repeated callbacks between samples stay quiet.
  let edge=action != .stateChanged && (lastEdgeState != newState || lastEdgeAction != action)
  guard changed || edge else{return nil}
  if action != .stateChanged {
   lastEdgeState=newState;lastEdgeAction=action
   lastAction=action;lastActionUptime=observedTime ?? 0
  }
  eventAction=action;Self.increment(&eventSequence)
  let terminal=action == .stopBegan || action == .stopCompleted || action == .viewDisappeared
  let reserved=terminal && !terminalActions.contains(action) && terminalActions.count < min(3,eventLimit)
  if reserved {terminalActions.insert(action)}
  guard emitted < eventLimit && (reserved || ordinaryEmitted < max(0,eventLimit-3)) else {
   Self.increment(&suppressed);return nil
  }
  if !reserved {ordinaryEmitted += 1}
  emitted += 1
  return snapshot(now:time)
 }
 public func snapshot(now:Double = ProcessInfo.processInfo.systemUptime)->[PlaybackLogField:Double] {
  let mask=state?.mask ?? 0, time=safeTime(now)
  return [.uiStateMask:Double(mask),.uiRowDisabledMask:Double(mask & 3),
   .uiPreviousDisabledMask:Double(mask & (3|8|128)),.uiNextDisabledMask:Double(mask & (3|8|256)),
   .uiPauseDisabledMask:Double(mask & (3|4|8|16)),
   .uiIncreaseDisabledMask:Double(mask & (3|8|16|64)),
   .uiResetSpeedDisabledMask:Double(mask & (3|8|16|32)),
   .uiSeekDisabledMask:Double(mask & (1|4|8|16|512)),
   .uiObservationStartedUptime:observationStarted ?? 0,.uiStateSinceUptime:stateSince ?? 0,.uiScrubbingSinceUptime:scrubbingSince ?? 0,.uiStoppingSinceUptime:stoppingSince ?? 0,
   .uiStateSequence:Double(stateSequence),.uiEventSequence:Double(eventSequence),.uiEventSuppressed:Double(suppressed),
   .uiEventAction:Double(eventAction.rawValue),.uiLastAction:Double(lastAction.rawValue),.uiLastActionUptime:lastActionUptime,
   .uiStateAgeMS:age(state == nil ? nil:stateSince,at:time),
   .uiScrubbingAgeMS:age(scrubbingSince,at:time),.uiStoppingAgeMS:age(stoppingSince,at:time)]
 }
}
