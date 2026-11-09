import Foundation
#if SWIFT_PACKAGE
import VistaCore
#endif

/// Playback intent and media movement, independent of AVPlayer's reported rate.
/// No timer, read, notification injection, or player mutation lives in this gate.
struct NativePlaybackIntentRecovery {
 enum CommandKind:Int,Codable,Sendable {case initial=1,manual,automatic,resume,seek}
 enum Block:Int {case none=0,lifecycle,invalid,unobserved,sourceChanged,noProgress,work,coverage,observing,commandGrace}
 static let quietInterval=1.0,maximumPollGap=0.25
 private(set) var commandID:UInt64=0
 private(set) var commandAt:Double?
 private(set) var commandKind:CommandKind = .initial
 private(set) var block:Block = .noProgress
 private(set) var quietSeconds=0.0,justBeganObservation=false
 // Observation labels never participate in qualification. Capture before/after
 // at the caller so a proof-clearing rollback cannot disappear into a mask.
 enum Detail:Int,Sendable {case none=0,lifecycle,invalidInput,deadlineAbsent,deadlineStale,invalidOutput,wallRollback,clockRollback,demandUnavailable,sourceEpoch,ptsRollback,noProof,work,coverage,invalidCommand,quietRestart,commandGrace,observing,qualified,interrupted}
 private(set) var detail:Detail = .none
 private var quietRestartMask=0
 var diagnosticState:[Double?] {
  [provenPlayback ? 1:0,previousPoll?.at,previousPoll?.clock,previousFrame?.clock,previousFrame?.pts,
   sourceCaptured ? 1:0,sourceEpoch.map(Double.init),lastPTS,quiet?.start,quiet?.last,quiet?.clock,
   quietSeconds,Double(commandID),commandAt,Double(commandKind.rawValue),Double(block.rawValue),Double(detail.rawValue),Double(quietRestartMask)]
 }
 private var provenPlayback=false
 private var previousFrame:(clock:Double,pts:Double)?
 private var previousPoll:(at:Double,clock:Double)?
 private var sourceEpoch:UInt64?,sourceCaptured=false
 private var lastPTS:Double?
 private var quiet:(start:Double,last:Double,clock:Double,demand:NativeStallRecoveryGate.DemandObservation)?
 mutating func acceptCommand(now:Double,kind:CommandKind) {
  if commandID<PlaybackStallProbeDiagnostics.maximumCounter {commandID += 1}
  commandAt=now.isFinite && now>=0 ? now:nil;commandKind=kind;resetQuiet()
 }
 mutating func interrupt(){detail = .interrupted;resetQuiet();previousPoll=nil;previousFrame=nil;provenPlayback=false;lastPTS=nil}
 private mutating func resetQuiet(){quiet=nil;quietSeconds=0;justBeganObservation=false}
 private mutating func reject(_ reason:Block,clearProof:Bool=false,detail:Detail)->Bool {
  if clearProof {interrupt()}else{resetQuiet()};block=reason;self.detail=detail;return false
 }
 mutating func observe(now:Double,eligible:Bool,position:Double,duration:Double,speed:Double,
  empty:Bool,ranges:[Range<Double>],outputValid:Bool,outputAt:Double?,copiedPTS:Double?,outputPolled:Bool=true,
  demand:NativeStallRecoveryGate.DemandObservation?)->Bool {
  justBeganObservation=false;detail = .none;quietRestartMask=0
  guard eligible else{return reject(.lifecycle,clearProof:true,detail:.lifecycle)}
  guard now.isFinite,now>=0,position.isFinite,position>=0,duration.isFinite,
   duration-position>0.05,speed.isFinite,speed>0 else{return reject(.invalid,clearProof:true,detail:.invalidInput)}
  // The 8ms loop often has no new display deadline on a 90Hz screen.
  // Such a loop cannot approve a command or create output evidence, but does
  // not erase a fresh real poll. A missing streak beyond .25s fails closed.
  if !outputPolled {
   guard let previousPoll,now>=previousPoll.at,now-previousPoll.at<=Self.maximumPollGap else{return reject(.unobserved,detail:.deadlineStale)}
   block = .unobserved;detail = .deadlineAbsent;return false
  }
  guard outputValid,let at=outputAt,at.isFinite,now>=at,now-at<=Self.maximumPollGap else{return reject(.unobserved,detail:.invalidOutput)}
  if let previous=previousPoll,now<previous.at || position<previous.clock-0.001 {
   return reject(.invalid,clearProof:true,detail:now<previous.at ? .wallRollback:.clockRollback)
  }
  let gap=previousPoll.map{now-$0.at>Self.maximumPollGap} ?? false
  previousPoll=(now,position)
  guard let demand,demand.supported else{return reject(.unobserved,clearProof:true,detail:.demandUnavailable)}
  let epoch=demand.source?.epoch
  if sourceCaptured,epoch != sourceEpoch {
   sourceEpoch=epoch;return reject(.sourceChanged,clearProof:true,detail:.sourceEpoch)
  }
  sourceCaptured=true;sourceEpoch=epoch
  var newPTS=false
  if let pts=copiedPTS,pts.isFinite {
   if let lastPTS,pts<lastPTS {return reject(.invalid,clearProof:true,detail:.ptsRollback)}
   newPTS=lastPTS.map{pts>$0} ?? true
   if newPTS {
    if let previousFrame,pts>previousFrame.pts,position>previousFrame.clock {provenPlayback=true}
    previousFrame=(position,pts);lastPTS=pts
   }
  }
  guard provenPlayback else{return reject(.noProgress,detail:.noProof)}
  guard demand.idle else{return reject(.work,detail:.work)}
  let needed=min(0.25*speed,duration-position)
  guard !empty,ranges.contains(where:{$0.lowerBound.isFinite && $0.upperBound.isFinite &&
   $0.lowerBound<=position && $0.upperBound-position+0.001>=needed}) else{return reject(.coverage,detail:.coverage)}
  guard let commandAt,now>=commandAt else{return reject(.invalid,detail:.invalidCommand)}
  // Duplicate PTS/copies are not media progress; normalize the delivery counter.
  let work=NativeStallRecoveryGate.DemandObservation(bridge:demand.bridge,source:demand.source,
   supported:demand.supported,frameCount:0)
  guard !gap,!newPTS,let q=quiet,now>=q.last,now-q.last<=Self.maximumPollGap,
   work==q.demand,abs(position-q.clock)<=0.001 else {
   quietRestartMask=(gap ? 1:0) | (newPTS ? 2:0) | (quiet == nil ? 4:0)
   if let prior=quiet {
    if now<prior.last {quietRestartMask |= 8}
    if now-prior.last>Self.maximumPollGap {quietRestartMask |= 16}
    if work != prior.demand {quietRestartMask |= 32}
    if abs(position-prior.clock)>0.001 {quietRestartMask |= 64}
   }
   quiet=(now,now,position,work);quietSeconds=0;block = .observing;detail = .quietRestart;return false
  }
  justBeganObservation=quietSeconds<0.5 && now-q.start>=0.5
  quiet=(q.start,now,q.clock,work);quietSeconds=now-q.start
  guard now-commandAt>=Self.quietInterval else{block = .commandGrace;detail = .commandGrace;return false}
  guard quietSeconds>=Self.quietInterval else{block = .observing;detail = .observing;return false}
  block = .none;detail = .qualified;return true
 }
}

/// Two strictly advancing delivered PTS, each paired with advancing clock.
/// Seeded at a recovery command; bytes and transport transitions do not enter.
struct NativeRecoveryProgressProof {
 private var previous:(clock:Double,pts:Double)?
 private var pairs=0
 private var sourceEpoch:UInt64?,sourceCaptured=false
 @discardableResult mutating func observeSourceEpoch(_ epoch:UInt64?)->Bool {
  let changed=sourceCaptured && epoch != sourceEpoch
  sourceCaptured=true;sourceEpoch=epoch
  if changed {reset()};return changed
 }
 mutating func reset(){previous=nil;pairs=0}
 // A new current-item data stall cuts the evidence sequence even if its
 // recovery ledger is already pending. It never refunds that ledger.
 mutating func interruptedByDataStall(eligible:Bool){if eligible {reset()}}
 mutating func begin(clock:Double?,pts:Double?,sourceEpoch:UInt64?=nil) {
  observeSourceEpoch(sourceEpoch);reset();if let clock,let pts,clock.isFinite,pts.isFinite {previous=(clock,pts)}
 }
 mutating func record(position:Double,framePTS:Double,eligible:Bool,sourceEpoch:UInt64?=nil)->Bool {
  observeSourceEpoch(sourceEpoch)
  guard eligible,position.isFinite,framePTS.isFinite else{reset();return false}
  defer{previous=(position,framePTS)}
  guard let previous else{return false}
  if position>previous.clock,framePTS>previous.pts {pairs=min(2,pairs+1)}else{pairs=0}
  return pairs>=2
 }
}

/// Fixed per-session ceilings. Observations/rejections aggregate in memory only.
struct PlaybackIntentRecoveryDiagnostics:Sendable {
 enum Phase:Int,Codable,Sendable {case command=1,observing,attempt,terminal,summary}
 struct CompactSnapshot:Codable,Sendable {
  let at:Double?,selected:Double?,requested:Double?,rate:Double?,effective:Double?,clock:Double?,pts:Double?
  let timebase:Int?,transport:Int?,context:Int?
  init(_ input:PlaybackStallProbeDiagnostics.Snapshot) {
   let s=input.sanitized();at=s.at;selected=s.selectedSpeed;requested=s.defaultRate;rate=s.playerRate
   effective=s.effectiveRate;clock=s.clock;pts=s.lastFramePTS;timebase=s.timebaseValidity;transport=s.transport;context=s.context
  }
 }
 struct CommandEvidence:Codable,Sendable {
  let id:UInt64,at:Double?,kind:NativePlaybackIntentRecovery.CommandKind,issued:Bool
  let before:CompactSnapshot?,after:CompactSnapshot
 }
 struct Record:Codable,Sendable {
  var session:UInt64=0
  let phase:Phase,command:UInt64,acceptedAt:Double?,kind:NativePlaybackIntentRecovery.CommandKind
  let quiet:Double,reason:Int,issued:Bool
  let before:PlaybackStallProbeDiagnostics.Snapshot?,after:PlaybackStallProbeDiagnostics.Snapshot
  let emitted:[UInt64],suppressed:UInt64,rejections:UInt64,rejectionMask:UInt64
  let commandEvidence:CommandEvidence?
 }
 private var emitted=[UInt64](repeating:0,count:5)
 private var suppressed:UInt64=0,rejections:UInt64=0,rejectionMask:UInt64=0
 private var attempted:(id:UInt64,at:Double?,kind:NativePlaybackIntentRecovery.CommandKind)?
 private var closed=false
 private var latestCommand:CommandEvidence?,attemptCommand:CommandEvidence?
 mutating func reject(_ reason:Int) {
  guard !closed,reason>0,reason<63 else{return}
  if rejections<PlaybackStallProbeDiagnostics.maximumCounter {rejections += 1}
  rejectionMask |= UInt64(1)<<UInt64(reason)
 }
 mutating func record(_ phase:Phase,command:UInt64,acceptedAt:Double?,kind:NativePlaybackIntentRecovery.CommandKind,
  quiet:Double,before:PlaybackStallProbeDiagnostics.Snapshot?,after:PlaybackStallProbeDiagnostics.Snapshot,
  reason:Int,issued:Bool)->Record? {
  guard !closed else{return nil}
  // Auto already has its own bounded before/after record. Do not let it
  // exhaust manual command detail; retain the latest accepted command even
  // after manual quota exhaustion, for the next attempt or final summary.
  if phase == .command {
   latestCommand=CommandEvidence(id:command,at:acceptedAt,kind:kind,issued:issued,
    before:before.map(CompactSnapshot.init),after:CompactSnapshot(after))
   if kind != .manual {return nil}
  }
  if phase == .attempt {
   attempted=(command,acceptedAt,kind)
   attemptCommand=latestCommand?.id == command ? latestCommand:nil
  }
  let evidence=phase == .attempt || phase == .terminal ? attemptCommand:
   phase == .summary ? latestCommand:nil
  if phase == .terminal && attempted == nil {return nil}
  let identity=phase == .terminal ? attempted:nil
  if phase == .terminal {attempted=nil}
  if phase == .summary {closed=true}
  let index=phase.rawValue-1,limit:UInt64=phase == .summary ? 1:16
  guard emitted[index]<limit else {
   if suppressed<PlaybackStallProbeDiagnostics.maximumCounter {suppressed += 1};return nil
  }
  emitted[index] += 1
  return Record(phase:phase,command:identity?.id ?? command,acceptedAt:identity?.at ?? acceptedAt,
   kind:identity?.kind ?? kind,quiet:quiet.isFinite ? max(0,quiet):0,reason:reason,issued:issued,
   before:before?.sanitized(),after:after.sanitized(),emitted:emitted,suppressed:suppressed,
   rejections:rejections,rejectionMask:rejectionMask,commandEvidence:evidence)
 }
}
extension PlaybackLogRecord {
 init(intentRecovery record:PlaybackIntentRecoveryDiagnostics.Record,session:UInt64,
  build:String=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0") {
  self.init(event:.intentRecovery,values:[:],build:build)
  var payload=record;payload.session=session;intentRecovery=payload
 }
}
