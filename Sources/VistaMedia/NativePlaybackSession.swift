import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import VideoToolbox
#if os(visionOS)
import UIKit

/// Latest display deadline only; never accumulate a queue of refresh callbacks.
@MainActor private final class NativeDisplayClock:NSObject {
 private var link:CADisplayLink?
 private var pending:CFTimeInterval?
 func start(){let value=CADisplayLink(target:self,selector:#selector(tick));link=value;value.add(to:.main,forMode:.common)}
 @objc private func tick(_ link:CADisplayLink){pending=link.targetTimestamp}
 func take()->CFTimeInterval?{defer{pending=nil};return pending}
 func stop(){link?.invalidate();link=nil;pending=nil}
}
#endif
#if SWIFT_PACKAGE
import VistaCore
#endif

/// One bounded aggregate per request. Overlapping read durations are not wall time.
struct NativeStageSnapshot:Equatable {
 let at:Double,reads:Int,bytes:Int,readSeconds:Double,interrupted:Int,waitingSeconds:Double
 let reason:String
}
struct NativeRequestMetrics {
 var epoch=0,reads=0,bytes=0,interrupted=0
 var started=0.0,readSeconds=0.0,waitingSeconds=0.0
 var waitingSince:Double?,seekCompleted:Double?,firstFrame:Double?,firstPTS:Double?
 var reason="無",kind="開片"
 var target:Double?,targetBuffered:Bool?
 var seekSnapshot:NativeStageSnapshot?,firstSnapshot:NativeStageSnapshot?,presentationSnapshot:NativeStageSnapshot?
 func snapshot(now:Double)->NativeStageSnapshot {
  .init(at:now,reads:reads,bytes:bytes,readSeconds:readSeconds,interrupted:interrupted,
        waitingSeconds:waitingSeconds+(waitingSince.map{max(0,now-$0)} ?? 0),reason:reason)
 }
 mutating func completeSeek(now:Double){guard seekSnapshot==nil else{return};seekCompleted=now;seekSnapshot=snapshot(now:now)}
 mutating func deliverFirst(now:Double,pts:Double){guard firstSnapshot==nil else{return};firstFrame=now;firstPTS=pts;firstSnapshot=snapshot(now:now)}
 mutating func present(now:Double){guard presentationSnapshot==nil else{return};presentationSnapshot=snapshot(now:now)}
 static func isBuffered(_ target:Double,ranges:[Range<Double>])->Bool {
  guard target.isFinite else{return false}
  return ranges.contains{$0.lowerBound.isFinite && $0.upperBound.isFinite && $0.contains(target)}
 }
 mutating func begin(_ kind:String,now:Double){let next=epoch+1;self=Self();epoch=next;started=now;self.kind=kind}
 mutating func endRead(epoch:Int,bytes:Int,seconds:Double,interrupted:Bool){
  guard epoch==self.epoch else{return};reads += 1;self.bytes += bytes;readSeconds += seconds
  if interrupted {self.interrupted += 1}
 }
 mutating func waiting(_ value:Bool,reason:String,now:Double){
  if value {if waitingSince==nil {waitingSince=now};self.reason=reason}
  else if let start=waitingSince {waitingSeconds += max(0,now-start);waitingSince=nil}
 }
 func text(now:Double)->String {
  func stage(_ name:String,_ value:NativeStageSnapshot?)->String {
   guard let v=value else{return "\(name)：—"}
   return "\(name) \(Int((v.at-started)*1000)) ms／讀\(v.reads)、\(v.bytes) B、Σ\(Int(v.readSeconds*1000)) ms／中止\(v.interrupted)／等\(Int(v.waitingSeconds*1000)) ms（\(v.reason)）"
  }
  let targetText=target.map{String(format:"%.2f",$0)} ?? "—"
  let buffered=targetBuffered.map{$0 ? "是":"未報告涵蓋"} ?? "不適用"
  return "請求 \(epoch) \(kind)／目標 \(targetText) s／已緩衝：\(buffered)\n" +
   [stage("seek",seekSnapshot),stage("首幀",firstSnapshot),stage("呈現通知",presentationSnapshot)].joined(separator:"\n")
 }

}

#if VISTA_ANON_IO_EXPERIMENT
struct AnonymousIOSnapshot:Equatable {
 let started:Int,finished:Int,cancelled:Int,failed:Int,inFlight:Int,oldAtStart:Int,oldRemaining:Int,peak:Int,bytes:Int,overflow:Int
 let maxTotalMS:Double,lastOldMS:Double
 var text:String {"I/O 起\(started) 完\(finished) 取消\(cancelled) 錯\(failed) 在途\(inFlight) 峰\(peak) B\(bytes) 溢\(overflow) 舊\(oldAtStart)/\(oldRemaining) 舊尾\(Int(lastOldMS))ms 最長總等待\(Int(maxTotalMS))ms"}
}
@MainActor final class AnonymousIOAggregate {
 private struct Slot {let epoch:Int,start:Double}
 private var slots:[UInt64:Slot]=[:],serial:UInt64=0,epoch=0
 private var epochStart=0.0,started=0,finished=0,cancelled=0,failed=0,oldAtStart=0,peak=0,bytes=0
 private var maxTotalMS=0.0,lastOldMS=0.0
 private(set) var overflow=0
 func beginEpoch(now:Double) {epoch += 1;epochStart=now;started=0;finished=0;cancelled=0;failed=0;oldAtStart=slots.count;peak=slots.count;bytes=0;maxTotalMS=0;lastOldMS=0}
 func begin(now:Double)->UInt64? {
  guard slots.count<8 else{overflow += 1;return nil}
  serial &+= 1;slots[serial]=Slot(epoch:epoch,start:now);started += 1;peak=max(peak,slots.count);return serial
 }
 func end(_ id:UInt64?,now:Double,bytes count:Int,cancelled wasCancelled:Bool,failed wasFailed:Bool) {
  guard let id,let slot=slots.removeValue(forKey:id) else{return}
  if slot.epoch != epoch {lastOldMS=max(lastOldMS,max(0,now-epochStart)*1000);return}
  finished += 1;bytes += max(0,count);if wasCancelled {cancelled += 1};if wasFailed {failed += 1}
  maxTotalMS=max(maxTotalMS,max(0,now-slot.start)*1000)
 }
 func snapshot()->AnonymousIOSnapshot {.init(started:started,finished:finished,cancelled:cancelled,failed:failed,inFlight:slots.count,oldAtStart:oldAtStart,oldRemaining:slots.values.filter{$0.epoch != epoch}.count,peak:peak,bytes:bytes,overflow:overflow,maxTotalMS:maxTotalMS,lastOldMS:lastOldMS)}
}
#endif

/// Opt in once per process to a system-provided VP9 decoder, when the public API exists.
/// A requested registration is not evidence that a decoder exists or that playback uses hardware.
@MainActor enum NativeSupplementalVideoDecoders {
 static let vp9RegistrationRequested: Bool = {
  #if os(visionOS)
  guard #available(visionOS 26.2, *) else { return false }
  #elseif os(macOS)
  guard #available(macOS 11.0, *) else { return false }
  #else
  return false
  #endif
  #if os(visionOS) || os(macOS)
  VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
  return true
  #endif
 }()
}

/// A/B selector for this isolated candidate. This is not an SMB read/cache policy.
public enum NativePlaybackWaitPolicy:Sendable {
 case systemAutomatic,resourceLoaderControlled
 var automaticallyWaits:Bool {self == .systemAutomatic}
}

/// A transport pause alone must never authorize autoplay. A current item's
/// data-stall notification owns one episode until real clock/video progress.
/// A failed play is not recovery. After the initial paced attempts, require
/// new contiguous playable media before retrying within the same active budget.
struct NativeStallRecoveryGate {
 enum Block:Int {case none=0,noEpisode,attemptLimit,lifecycle,notReady,transportNotPaused,bufferEmpty,invalidPosition,retryDelay,insufficientCoverage}
 enum ResumeKind:Int {case buffered=1,demandProbe,intentRecovery}
 enum Mode {case all,bufferedOnly,probeOnly}
 enum ProbeBlock:Int {case none=0,noEpisode,used,lifecycle,notReady,transportNotPaused,invalidObservation,workPending,observing,retryDelay,bufferedPath,attemptLimit,sourceChanged}
 struct DemandObservation:Equatable {
  let bridge:ResourceBridge.RecoveryActivity
  let source:PlaybackPrefetchSource.RecoveryActivity?
  let supported:Bool
  let frameCount:Int
  var idle:Bool {supported && bridge.idle && (source?.idle ?? true)}
 }
 static let probeQuietInterval:Double = 0.5
 static let probeMaximumObservationGap:Double = 0.25
 private(set) var probeUsed=false
 private(set) var probeBlockedBy:ProbeBlock = .noEpisode
 private(set) var probeQuietSeconds=0.0
 private(set) var lastResumeKind:ResumeKind?
 private(set) var probeSourceInvalid=false
 private var episodeSourceEpoch:UInt64?
 private var episodeSourceCaptured=false
 private var probeQuiet:(start:Double,last:Double,position:Double,observation:DemandObservation)?
 mutating func resetProbeObservation(){probeQuiet=nil;probeQuietSeconds=0}
 mutating func invalidateProbeSource(){probeSourceInvalid=true;resetProbeObservation()}

 private(set) var blockedBy:Block = .noEpisode
 static let retryInterval:Double = 0.5
 static let initialAttempts = 3
 static let improvedBufferRetryInterval:Double = 1
 private(set) var pending=false
 private(set) var intentUsed=false
 var hasRecoveryBudget:Bool {attempts>0}
 // Cancel notification permission, never refund spent recovery budget.
 mutating func suspend(){pending=false;resetProbeObservation()}
 mutating func interrupt(userInitiated:Bool){if userInitiated {clear()}else{suspend()}}
 mutating func takeIntentResume(now:Double)->Bool {
  guard now.isFinite,!probeUsed,attempts<Self.initialAttempts,
        lastAttempt.map({now >= $0 && now-$0>=Self.retryInterval}) ?? true else{return false}
  intentUsed=true;probeUsed=true;recordAttempt(now:now,kind:.intentRecovery);return true
 }
 private(set) var attempts=0
 private(set) var recoveryActiveElapsed:Double=0
 private var lastAttempt:Double?,budgetSample:Double?
 private var attemptedBufferEnd:Double?
 private var budgetWasActive=false
 mutating func clear(){self=Self()}
 mutating func stalled(eligible:Bool){
  guard eligible,!pending else{return}
  if attempts==0 {clear()};pending=true
 }
 mutating func observeElapsed(now:Double,eligible:Bool){
  guard attempts>0,now.isFinite else{return}
  if let previous=budgetSample,budgetWasActive,now>=previous {recoveryActiveElapsed += now-previous}
  budgetSample=now;budgetWasActive=eligible
 }
 func recoveryExpired(limit:Double)->Bool {attempts>0 && recoveryActiveElapsed>=limit}
 mutating func takeResume(now:Double,active:Bool,sceneActive:Bool,paused:Bool,seeking:Bool,ready:Bool,
                          transportPaused:Bool,bufferEmpty:Bool,position:Double,duration:Double,
                          selectedSpeed:Double,ranges:[Range<Double>],demand:DemandObservation?=nil,mode:Mode = .all)->Bool {
  // Source identity changes invalidate only the unbuffered probe. Ordinary
  // same-item buffered recovery and already-spent budget remain untouched.
  if let demand,let source=demand.source {
   if episodeSourceCaptured,episodeSourceEpoch != source.epoch {invalidateProbeSource()}
   else if !episodeSourceCaptured {episodeSourceCaptured=true;episodeSourceEpoch=source.epoch}
  }
  probeBlockedBy = .noEpisode
  guard pending else{blockedBy = .noEpisode;return false}
  guard active,sceneActive,!paused,!seeking else{blockedBy = .lifecycle;probeBlockedBy = .lifecycle;resetProbeObservation();return false}
  guard ready else{blockedBy = .notReady;probeBlockedBy = .notReady;resetProbeObservation();return false}
  guard transportPaused else{blockedBy = .transportNotPaused;probeBlockedBy = .transportNotPaused;resetProbeObservation();return false}
  guard now.isFinite,now>=0,position.isFinite,duration.isFinite,position>=0,position<duration,
        selectedSpeed.isFinite,selectedSpeed>0 else{blockedBy = .invalidPosition;probeBlockedBy = .invalidObservation;resetProbeObservation();return false}
  let interval=attempts<Self.initialAttempts ? Self.retryInterval:Self.improvedBufferRetryInterval
  if let lastAttempt,now<lastAttempt || now-lastAttempt<interval {blockedBy = .retryDelay;probeBlockedBy = .retryDelay;resetProbeObservation();return false}
  // Quarter second of wall-clock playback at the current requested rate, capped at EOF.
  let required=min(0.25*selectedSpeed,duration-position)
  let end=ranges.filter{$0.lowerBound.isFinite && $0.upperBound.isFinite &&
   $0.lowerBound<=position && $0.upperBound-position+0.001>=required}.map{min($0.upperBound,duration)}.max()
  guard !bufferEmpty,let end else {
   blockedBy = bufferEmpty ? .bufferEmpty:.insufficientCoverage
   guard mode != .bufferedOnly else{return false}
   return takeDemandProbe(now:now,position:position,demand:demand)
  }
  probeBlockedBy = .bufferedPath;resetProbeObservation()
  guard mode != .probeOnly else{return false}
  if attempts>=Self.initialAttempts,let attemptedBufferEnd {
   // A new notification, rate change, duplicate bytes or shrinking/refilling an
   // old range cannot renew retries. Only a new contiguous frontier can do so.
   // EOF may contain less than a quarter wall-second of new playable media.
   let growth=min(0.25*selectedSpeed,max(0,duration-attemptedBufferEnd))
   guard end>attemptedBufferEnd+0.001,end-attemptedBufferEnd+0.001>=growth else {
    blockedBy = .attemptLimit;return false
   }
  }
  recordAttempt(now:now,kind:.buffered)
  attemptedBufferEnd=max(attemptedBufferEnd ?? end,end)
  return true
 }
 private mutating func recordAttempt(now:Double,kind:ResumeKind) {
  blockedBy = .none;lastResumeKind=kind
  if attempts==0 {budgetSample=now;budgetWasActive=true}
  attempts += 1;lastAttempt=now
 }
 private mutating func takeDemandProbe(now:Double,position:Double,demand:DemandObservation?)->Bool {
  guard !probeUsed else{probeBlockedBy = .used;resetProbeObservation();return false}
  guard !probeSourceInvalid else{probeBlockedBy = .sourceChanged;resetProbeObservation();return false}
  guard attempts<Self.initialAttempts else{probeBlockedBy = .attemptLimit;resetProbeObservation();return false}
  guard let demand,demand.supported else{probeBlockedBy = .invalidObservation;resetProbeObservation();return false}
  guard demand.idle else{probeBlockedBy = .workPending;resetProbeObservation();return false}
  guard let quiet=probeQuiet,now>=quiet.last,now-quiet.last<=Self.probeMaximumObservationGap,
        quiet.observation==demand,abs(position-quiet.position)<=0.001 else {
   probeQuiet=(now,now,position,demand);probeQuietSeconds=0;probeBlockedBy = .observing;return false
  }
  probeQuietSeconds=now-quiet.start
  probeQuiet=(quiet.start,now,quiet.position,demand)
  guard probeQuietSeconds>=Self.probeQuietInterval else{probeBlockedBy = .observing;return false}
  // Spend before play, even if AVFoundation immediately returns to paused.
  // A thin range is not a new attempted buffered frontier.
  probeUsed=true;probeBlockedBy = .none
  recordAttempt(now:now,kind:.demandProbe)
  return true
 }
}

/// A .playing transition alone is not recovery: both the media clock and two
/// consecutive delivered video timestamps must advance outside pause/seek waits.
struct NativePlaybackProgressGate {
 private var previous:(position:Double,framePTS:Double)?
 mutating func reset(){previous=nil}
 mutating func record(position:Double,framePTS:Double,eligible:Bool)->Bool {
  guard eligible,position.isFinite,framePTS.isFinite else{reset();return false}
  defer{previous=(position,framePTS)}
  guard let previous else{return false}
  return position>previous.position && framePTS>previous.framePTS
 }
}

/// Fixed-size session aggregates. These measure API delivery, not GPU presentation.
/// Wall-time gaps/age include intentional pause, seek and scene inactivity; interpret
/// them with the existing context/boundary records, never as standalone failure flags.
struct NativeVideoDeliveryDiagnostics {
 // Largest integer exactly represented by the numeric log format. Saturate, never wrap.
 static let maximumCounter:UInt64 = (1 << 53)-1
 var loopTicks:UInt64=0,outputPolls:UInt64=0,outputHasNew:UInt64=0,outputCopyNil:UInt64=0
 private var previousLoopUptime:Double?,lastFrameUptime:Double?
 private var loopSessionMaxGapMS=0.0
 private static func increment(_ value:inout UInt64) {if value<maximumCounter {value += 1}}
 private static func elapsedMS(from start:Double?,to now:Double)->Double? {
  guard let start,start.isFinite,start>=0,now.isFinite,now>=start else{return nil}
  let seconds=now-start
  return seconds>Double.greatestFiniteMagnitude/1000 ? Double.greatestFiniteMagnitude:seconds*1000
 }
 mutating func recordLoop(now:Double) {
  Self.increment(&loopTicks)
  guard now.isFinite,now>=0,previousLoopUptime.map({now >= $0}) ?? true else{return}
  if let gap=Self.elapsedMS(from:previousLoopUptime,to:now) {loopSessionMaxGapMS=max(loopSessionMaxGapMS,gap)}
  previousLoopUptime=now
 }
 mutating func recordOutputPoll(){Self.increment(&outputPolls)}
 mutating func recordOutputHasNew(){Self.increment(&outputHasNew)}
 mutating func recordOutputCopyNil(){Self.increment(&outputCopyNil)}
 mutating func recordFrame(now:Double,presentationTime:Double) {
  guard presentationTime.isFinite,now.isFinite,now>=0,lastFrameUptime.map({now >= $0}) ?? true else{return}
  lastFrameUptime=now
 }
 // The loop has ended, so no further loop gap accrues. Frame age still means
 // wall time since the last copy, even after stop; terminal error snapshots are
 // frozen separately by the session, and the controller logs stopped before stop().
 mutating func finishLoop(now:Double) {
  if let gap=Self.elapsedMS(from:previousLoopUptime,to:now) {loopSessionMaxGapMS=max(loopSessionMaxGapMS,gap)}
  previousLoopUptime=nil
 }
 // Read-only snapshots cannot consume a reporting window. The explicit session name
 // distinguishes this high-water mark (including the unfinished gap) from a window max.
 func values(now:Double)->[PlaybackLogField:Double] {
  var values:[PlaybackLogField:Double] = [
   .videoLoopTicks:Double(loopTicks),
   .videoLoopSessionMaxGapMS:max(loopSessionMaxGapMS,Self.elapsedMS(from:previousLoopUptime,to:now) ?? 0),
   .videoOutputPolls:Double(outputPolls),.videoOutputHasNew:Double(outputHasNew),.videoOutputCopyNil:Double(outputCopyNil)]
  if let age=Self.elapsedMS(from:lastFrameUptime,to:now) {values[.videoFrameAgeMS]=age}
  return values
 }
}

/// Controlled AVPlayer candidate. No claim about the internal decoder identity.
@MainActor public final class NativePlaybackSession {
 public enum State:Equatable,Sendable {case preparing,playing,waiting,paused,seeking,ended}
 public enum Failure:Error,Equatable {case source,stalled,player,unsupported}
 public let decoderDescription="解碼方式：系統管理（未知）"
 #if os(visionOS)
 private var displayClock:NativeDisplayClock?
 #endif
 var experimentPlayerTime:Double?{player?.currentTime().seconds}
 #if SWIFT_PACKAGE
 var experimentPlayer:AVPlayer?{player}
 private(set) var experimentIntentLastRecord:PlaybackIntentRecoveryDiagnostics.Record?
 var experimentPendingDataStall:Bool{stallRecovery.pending}
 var experimentAutomaticWait:Bool?{player?.automaticallyWaitsToMinimizeStalling}
 private(set) var experimentStallResumes=0
 #endif
 private var player:AVPlayer?
 private var item:AVPlayerItem?
 private var asset:AVURLAsset?
 private var bridge:ResourceBridge?
 private var recoverySource:(any PlaybackRecoveryControlling)?
 private var observedSourceRecovery=false
 private var running=false,prepared=false
 private var active=false,sourceFailed=false,paused=false,seeking=false
 private let waitPolicy:NativePlaybackWaitPolicy
 private var stallObserver:(any NSObjectProtocol)?
 private var stallRecovery=NativeStallRecoveryGate()
 private var stallProbe=PlaybackStallProbeDiagnostics()
 private var intentRecovery=NativePlaybackIntentRecovery()
 private var intentDiagnostics=PlaybackIntentRecoveryDiagnostics()
 private var hypothesisDiagnostics=PlaybackHypothesisDiagnostics()
 private func emitHypothesis(reason:Int?=nil,final:Bool=false) {
  let now=ProcessInfo.processInfo.systemUptime
  guard waitSession>0,let record=hypothesisDiagnostics.record(now:now,metricEpoch:requestMetrics.epoch,
   snapshot:probeSnapshot(now:now),reason:reason,final:final) else{return}
  PlaybackLogStore.shared.enqueue(PlaybackLogRecord(hypothesis:record,session:waitSession))
 }
 private func endHypothesisScope(_ reason:Int) {
  if hypothesisDiagnostics.hasFaultEvidence {
   hypothesisDiagnostics.saveScopeTail(now:ProcessInfo.processInfo.systemUptime,metricEpoch:requestMetrics.epoch,
    snapshot:probeSnapshot(),reason:reason)
   emitHypothesis(reason:reason)
  }
  hypothesisDiagnostics.resetScope()
 }
 private func observeHypothesisOutput(now:Double,clock:Double,returnedPTS:Double?,copiedPTS:Double?) {
  if hypothesisDiagnostics.sourceChanged(prefetchSource?.diagnosticObservedEpoch) {endHypothesisScope(31)}
  hypothesisDiagnostics.captureSource(prefetchSource?.diagnosticObservedEpoch)
  let rate=item?.timebase.map{CMTimebaseGetEffectiveRate($0)}
  hypothesisDiagnostics.poll(now:now,clock:clock,query:latestOutput.query,targetHost:latestOutput.targetHost,
   hostLead:latestOutput.hostLead,validity:latestOutput.validity,returnedPTS:returnedPTS,copiedPTS:copiedPTS,
   timebaseValidity:(item?.timebase == nil ? 0:1) | (rate?.isFinite == true ? 2:0),effective:rate,
   itemStatus:item?.status.rawValue,rate:player.map{Double($0.rate)},transport:player?.timeControlStatus.rawValue,
   metricEpoch:requestMetrics.epoch)
 }

 private var recoveryPlaybackProgress=NativeRecoveryProgressProof()
 private var recoveryCommandIssuedThisLoop=false
 private func emitIntent(_ phase:PlaybackIntentRecoveryDiagnostics.Phase,before:PlaybackStallProbeDiagnostics.Snapshot?=nil,reason:Int=0,issued:Bool=false) {
  guard waitSession>0,let record=intentDiagnostics.record(phase,command:intentRecovery.commandID,
   acceptedAt:intentRecovery.commandAt,kind:intentRecovery.commandKind,quiet:intentRecovery.quietSeconds,
   before:before,after:probeSnapshot(),reason:reason,issued:issued) else{return}
  PlaybackLogStore.shared.enqueue(PlaybackLogRecord(intentRecovery:record,session:waitSession))
  #if SWIFT_PACKAGE
  experimentIntentLastRecord=record
  #endif
 }
 private func acceptIntentCommand(_ kind:NativePlaybackIntentRecovery.CommandKind) {
  if kind == .manual {endHypothesisScope(40)} // Diagnostic attribution only; no recovery reset is added.
  recoveryPlaybackProgress.reset()
  intentRecovery.acceptCommand(now:ProcessInfo.processInfo.systemUptime,kind:kind)
 }
 private func interruptIntent(_ reason:Int) {
  endHypothesisScope(20+reason)
  if stallRecovery.intentUsed {emitIntent(.terminal,reason:reason)}
  intentRecovery.interrupt();recoveryPlaybackProgress.reset()
 }
 private func observeIntentRecovery(duration:Double,copiedFramePTS:Double?) {
  guard waitPolicy == .resourceLoaderControlled,let player,let item else{return}
  let now=ProcessInfo.processInfo.systemUptime,position=player.currentTime().seconds
  let ranges=item.loadedTimeRanges.map(\.timeRangeValue).compactMap {range->Range<Double>? in
   let start=range.start.seconds,end=CMTimeRangeGetEnd(range).seconds
   return start.isFinite && end.isFinite && end>start ? start..<end:nil
  }
  let eligible=waitEligible && item.status == .readyToPlay
  let gateBefore=intentRecovery.diagnosticState
  let demand=bridge.map{NativeStallRecoveryGate.DemandObservation(bridge:$0.recoveryActivity,source:prefetchSource?.recoveryActivity,
    supported:demandOnlyLocalSource || prefetchSource != nil,frameCount:frames)}
  let observed=intentRecovery.observe(now:now,eligible:eligible,position:position,duration:duration,
   speed:selectedSpeed,empty:item.isPlaybackBufferEmpty,ranges:ranges,
   outputValid:latestOutput.validity & 70 == 70,outputAt:latestOutput.at,copiedPTS:copiedFramePTS,
   outputPolled:latestOutput.validity & 64 != 0,
   demand:demand)
  let coverage=ranges.filter{$0.lowerBound<=position && $0.upperBound>=position}.map{$0.upperBound-position}.max() ?? 0
  hypothesisDiagnostics.gate(now:now,before:gateBefore,after:intentRecovery.diagnosticState,
   idle:demand?.idle,supported:demand?.supported,empty:item.isPlaybackBufferEmpty,coverage:coverage,
   activity:[demand.map{Double($0.bridge.activeRequests)},demand.map{Double($0.bridge.returns)},
    demand.map{Double($0.bridge.responses)},demand.map{Double($0.bridge.deliveredBytes)},demand?.source.map{Double($0.busy)}],
   input:[position,copiedFramePTS,latestOutput.at,latestOutput.validity & 70 == 70 ? 1:0,
    latestOutput.validity & 64 != 0 ? 1:0,duration,selectedSpeed])
  if hypothesisDiagnostics.shouldEmit(now:now) {emitHypothesis()}
  intentDiagnostics.reject(intentRecovery.block.rawValue)
  if intentRecovery.justBeganObservation {emitIntent(.observing)}
  performIntentResume(qualified:observed,now:now)
 }
 /// Synthetic tests may exercise this real command seam, never call it a
 /// reproduction of the user's natural stall. The observer owns qualification.
 func performIntentResume(qualified:Bool,now:Double=ProcessInfo.processInfo.systemUptime) {
  guard qualified,waitPolicy == .resourceLoaderControlled,!recoveryCommandIssuedThisLoop,
   waitEligible,item?.status == .readyToPlay,let player,
   !stallRecovery.recoveryExpired(limit:stallLimit),stallRecovery.takeIntentResume(now:now) else{return}
  let before=probeSnapshot()
  recoveryCommandIssuedThisLoop=true;recoveryPlaybackProgress.begin(clock:player.currentTime().seconds,pts:waitEpisodes.lastFramePTS,sourceEpoch:prefetchSource?.diagnosticObservedEpoch)
  player.defaultRate=Float(selectedSpeed);player.play();stallResumes += 1
  emitIntent(.attempt,before:before,issued:true)
  #if SWIFT_PACKAGE
  experimentStallResumes += 1
  #endif
 }

 private struct OutputObservation {
  var at:Double?,query:Double?,queryClock:Double?,copyQuery:Double?,hostLead:Double?,targetHost:Double?
  // 1=query supplied, 2=valid CMTime, 4=finite query, 8=host deadline,
  // 16=finite host deadline lead, 32=finite copied PTS, 64=actually polled,
  // 128=hasNew true, 256=copy returned nil. Missing is not zero.
  var validity=0
 }
 private var latestOutput=OutputObservation()
 private func probeSnapshot(now:Double=ProcessInfo.processInfo.systemUptime,copiedFramePTS:Double?=nil,includeCoverage:Bool=true)->PlaybackStallProbeDiagnostics.Snapshot {
  var v=PlaybackStallProbeDiagnostics.Snapshot(now:now)
  v.sourceKind=demandOnlyLocalSource ? .local:prefetchSource != nil ? .prefetch:.unknown
  v.lastFramePTS=waitEpisodes.lastFramePTS;v.copiedFramePTS=copiedFramePTS
  v.selectedSpeed=selectedSpeed;v.attempts=stallRecovery.attempts
  v.recoveryActiveSeconds=stallRecovery.recoveryActiveElapsed;v.probeQuietSeconds=stallRecovery.probeQuietSeconds
  v.probeBlock=stallRecovery.probeBlockedBy.rawValue
  var context=0
  for (flag,bit) in [(active,1),(sceneActive,2),(paused,4),(seeking,8),(item?.status == .readyToPlay,16),(sourceFailed,32),(recoverySource?.isPlaybackRecovering ?? false,64),(prepared,128)] {if flag {context |= bit}}
  v.context=context
  if let player,let item {
   let position=player.currentTime().seconds
   v.clock=position;v.defaultRate=Double(player.defaultRate);v.playerRate=Double(player.rate)
   v.effectiveRate=item.timebase.map{CMTimebaseGetEffectiveRate($0)}
   v.timebaseValidity=(item.timebase == nil ? 0:1) | (v.effectiveRate?.isFinite == true ? 2:0)
   v.transport=player.timeControlStatus.rawValue;v.bufferEmpty=item.isPlaybackBufferEmpty
   switch player.reasonForWaitingToPlay {
    case .toMinimizeStalls:v.waitingReason=1
    case .evaluatingBufferingRate:v.waitingReason=2
    case .noItemToPlay:v.waitingReason=3
    case nil:v.waitingReason=0
    default:v.waitingReason=4
   }
   if includeCoverage {v.coverageSeconds=item.loadedTimeRanges.compactMap {value->Double? in
    let range=value.timeRangeValue,start=range.start.seconds,end=CMTimeRangeGetEnd(range).seconds
    guard position.isFinite,start.isFinite,end.isFinite,start<=position,end>=position else{return nil}
    return end-position
   }.max() ?? 0}
   v.progressEligible=waitEligible && position.isFinite
  }
  if let b=bridge?.recoveryActivity {
   v.bridgeActive=b.activeRequests;v.bridgeRequests=b.requests;v.bridgeChunks=b.chunks
   v.bridgeDataRequests=bridge.map{UInt64($0.rawDataRequests)}
   v.bridgeCancellations=b.cancellations;v.deliveredBytes=b.deliveredBytes
   v.bridgeReturns=b.returns;v.bridgeResponses=b.responses
  }
  if let p=prefetchSource?.recoveryActivity {
   // 1=request, 2=demand task, 4=prefetch, 8=pump, 16=idle grace,
   // 32=handoff, 64=queued work, 128=unavailable/quarantined/unknown epoch.
   v.sourceBusyMask=p.busy | (p.queued>0 ? 64:0) | (p.available ? 0:128);v.sourceGeneration=p.generation;v.sourceEpoch=p.epoch
   v.sourceRequestID=p.requests;v.sourcePrefetchID=p.prefetches
  }
  v.queryValidity=latestOutput.validity;v.queryTime=latestOutput.query;v.queryClockDifference=latestOutput.queryClock
  v.copyQueryDifference=latestOutput.copyQuery;v.targetHostLeadSeconds=latestOutput.hostLead;v.outputObservationAt=latestOutput.at
  v.lastProgressAge=now>=lastProgress ? now-lastProgress:nil
  v.lastDeliveryAge=lastDeliveryAt.flatMap{now >= $0 ? now-$0:nil}
  v.lastFrameAge=waitEpisodes.lastFrameAt.flatMap{now >= $0 ? now-$0:nil}
  return v
 }
 private func emitStallProbe(_ record:PlaybackStallProbeDiagnostics.Record?) {
  guard waitSession>0,let record else{return}
  PlaybackLogStore.shared.enqueue(PlaybackLogRecord(stallProbe:record,session:waitSession))
 }
 private func finishStallProbe(_ reason:PlaybackStallProbeDiagnostics.EndReason,copiedFramePTS:Double?=nil) {
  guard stallProbe.isObserving else{return}
  emitStallProbe(stallProbe.finish(reason,snapshot:probeSnapshot(copiedFramePTS:copiedFramePTS)))
 }
 private func finishStallProbeSession() {
  guard let completion=stallProbe.finishSession(snapshot:probeSnapshot()) else{return}
  emitStallProbe(completion.terminal)
  if waitSession>0 {PlaybackLogStore.shared.enqueue(PlaybackLogRecord(stallProbeSummary:completion.summary,session:waitSession))}
 }
 private var stallNotifications=0,stallResumes=0,timeoutReason=0
 private var waitEpisodes=PlaybackWaitEpisodeDiagnostics()
 private var waitCounters=PlaybackWaitEpisodeCounters()
 private var waitSession:UInt64=0
 private static var nextWaitSession:UInt64=0
 private var lastDeliveryAt:Double?
 private func emitWait(_ record:PlaybackWaitEpisodeDiagnostics.Record?) {
  // Update even when output admission suppresses the final abort record.
  waitCounters.update(seen:waitEpisodes.seen,completed:waitEpisodes.completed,
   suppressed:waitEpisodes.suppressed,incomplete:waitEpisodes.active != nil)
  if let record {PlaybackLogStore.shared.enqueue(PlaybackLogRecord(waitEpisode:record))}
 }
 private var waitEligible:Bool {waitSession>0 && active && prepared && sceneActive && !paused && !seeking && !sourceFailed && !(recoverySource?.isPlaybackRecovering ?? false)}
 /// Only called for admitted boundary snapshots. In particular, never calls the
 /// process-memory probe or source epoch validation used by other diagnostics.
 private func waitSnapshot(frameAt:Double?,framePTS:Double?)->PlaybackWaitEpisodeDiagnostics.Snapshot {
  var v=PlaybackWaitEpisodeDiagnostics.Snapshot(now:ProcessInfo.processInfo.systemUptime)
  v.lastFrameAt=frameAt;v.lastFramePTS=framePTS;v.lastDeliveryAt=lastDeliveryAt
  v.deliveryBytes=bridge?.deliveredBytes ?? 0;v.speed=selectedSpeed
  for (flag,bit) in [(active,1),(sceneActive,2),(paused,4),(seeking,8),(item?.status == .readyToPlay,16),(sourceFailed,32),(recoverySource?.isPlaybackRecovering ?? false,64)] {if flag {v.context |= bit}}
  if let player,let item {
   let position=player.currentTime().seconds
   v.clock=position;v.rate=item.timebase.map{CMTimebaseGetEffectiveRate($0)}
   v.transport=player.timeControlStatus.rawValue;v.empty=item.isPlaybackBufferEmpty
   let loadedRanges=item.loadedTimeRanges.map(\.timeRangeValue)
   v.frontier=loadedRanges.compactMap {range->Double? in
    let start=range.start.seconds,end=CMTimeRangeGetEnd(range).seconds
    return start.isFinite && end.isFinite && position.isFinite && start<=position && end>=position ? end:nil
   }.max()
   // Keep the exact recovery tolerance even when a range ends just behind
   // position near EOF. The diagnostic frontier is stricter and may be nil.
   let coverageRanges=loadedRanges.compactMap {range->Range<Double>? in
    let start=range.start.seconds,end=CMTimeRangeGetEnd(range).seconds
    guard start.isFinite,end.isFinite,end>start else{return nil};return start..<end
   }
   v.coveragePass=PlaybackWaitEpisodeDiagnostics.coveragePass(position:position,duration:item.duration.seconds,speed:selectedSpeed,ranges:coverageRanges)
  }
  v.supply=prefetchSource?.supplyDiagnosticSnapshot()
  v.ranges=prefetchSource?.rangeDiagnosticSnapshot();v.bridge=bridge?.rangeDiagnosticSnapshot()
  return v
 }
 private func observeWait(_ origin:PlaybackWaitEpisodeDiagnostics.Origin) {
  if let initial=waitEpisodes.activeSourceEpoch,initial != prefetchSource?.diagnosticObservedEpoch {
   abortWait(.sourceEpoch)
  }
  let frameAt=waitEpisodes.lastFrameAt,framePTS=waitEpisodes.lastFramePTS
  let record=waitEpisodes.observe(waiting:isWaitingForData,eligible:waitEligible,session:waitSession,
   epoch:requestMetrics.epoch,origin:origin,now:ProcessInfo.processInfo.systemUptime,observedSourceEpoch:prefetchSource?.diagnosticObservedEpoch,snapshot:{self.waitSnapshot(frameAt:frameAt,framePTS:framePTS)})
  emitWait(record)
 }
 private func recordWaitResume(cause:Int=1) {
  let frameAt=waitEpisodes.lastFrameAt,framePTS=waitEpisodes.lastFramePTS
  guard waitEpisodes.active != nil else{return}
  let snapshot=waitEpisodes.capturesActiveDetail && waitEpisodes.active?.resume == nil ? waitSnapshot(frameAt:frameAt,framePTS:framePTS):nil
  // Sample after collecting getters, immediately before the existing play call.
  waitEpisodes.resumed(now:ProcessInfo.processInfo.systemUptime,cause:cause,snapshot:{snapshot!})
 }
 private func abortWait(_ reason:PlaybackWaitEpisodeDiagnostics.End) {
  emitWait(waitEpisodes.abort(reason,now:ProcessInfo.processInfo.systemUptime))
 }

 // Capture before cleanup destroys the item/bridge and clears the stall episode.
 private var terminalLogValues:[PlaybackLogField:Double]?
 private var automaticSpeedPolicy=PlaybackAutomaticSpeedPolicy()
 private var automaticRecovery=PlaybackAutomaticRecoveryDiagnostics()
 private var automaticRecoverySourceEpoch:UInt64?
 private func emitAutomaticRecovery(_ record:PlaybackAutomaticRecoveryDiagnostics.Record?) {
  guard waitSession>0,let record else{return}
  PlaybackLogStore.shared.enqueue(PlaybackLogRecord(automaticRecovery:record,session:waitSession))
 }
 private func interruptAutomaticRecovery(_ reason:PlaybackAutomaticRecoveryDiagnostics.EndReason) {
  emitAutomaticRecovery(automaticRecovery.interrupt(reason,now:ProcessInfo.processInfo.systemUptime))
 }
 private func finishAutomaticRecovery() {
  guard let completion=automaticRecovery.finish(now:ProcessInfo.processInfo.systemUptime) else{return}
  emitAutomaticRecovery(completion.terminal)
  if waitSession>0 {PlaybackLogStore.shared.enqueue(PlaybackLogRecord(automaticRecoverySummary:completion.summary,session:waitSession))}
 }
 #if SWIFT_PACKAGE
 private(set) var experimentLastAutomaticSpeedDecision:PlaybackAutomaticSpeedPolicy.Decision?
 var experimentAutomaticRecoveryIsObserving:Bool {automaticRecovery.isObserving}
 #endif
 private var bufferingPlaybackProgress=NativePlaybackProgressGate()
 private func interruptBufferingWait(){automaticSpeedPolicy.interruptObservation();bufferingPlaybackProgress.reset()}
 private var sceneActive=true
 #if SWIFT_PACKAGE
 // Baseline comparison only; production always uses the fixed native demand ceiling.
 var experimentDemandChunkBytes:UInt64 = MediaReadPlan.nativeChunkBytes
 var experimentDemandChunkLimit:UInt64? {bridge?.demandChunkLimit}
 var experimentRecoveryActivity:ResourceBridge.RecoveryActivity? {bridge?.recoveryActivity}
 var experimentOutputQueryValidity:Int {latestOutput.validity}
 var experimentDemandProbeSourceSupported:Bool {demandOnlyLocalSource || prefetchSource != nil}
 #endif
 private var demandChunkBytes:UInt64 {
  #if SWIFT_PACKAGE
  experimentDemandChunkBytes
  #else
  MediaReadPlan.nativeChunkBytes
  #endif
 }
 private var prefetchSource:PlaybackPrefetchSource?
 private var demandOnlyLocalSource=false
 private var finalPrefetchMetrics:PlaybackPrefetchSource.Metrics?
 private var memoryPressureSource:(any DispatchSourceMemoryPressure)?
 private var memoryDiagnostics=PlaybackMemoryDiagnostics()
 private func updatePrefetchActivity() {
  let enabled = active && prepared && sceneActive && !paused && !seeking
  let reason:PrefetchInvalidationReason = !active ? .playbackInactive : !sceneActive ? .sceneInactive : seeking ? .seek : paused ? .pause : !prepared ? .notReady : .disabled
  prefetchSource?.setPrefetchEnabled(enabled,reason:reason)
 }
 private var inactiveStallSuspension:Double?
 public func setPlaybackSceneActive(_ active:Bool){
  if sceneActive != active {interruptIntent(4);if !active {abortWait(.inactive);interruptAutomaticRecovery(.background)};stallProbe.interruptObservation();stallRecovery.resetProbeObservation();interruptBufferingWait();stallRecovery.observeElapsed(now:ProcessInfo.processInfo.systemUptime,eligible:false)}
  sceneActive=active;updatePrefetchActivity()
 }
 private var isWaitingForData:Bool {
  guard active,!paused,!seeking,let player else{return false}
  // rate == 0 / .paused after starvation is not the user's pause intent.
  return player.timeControlStatus != .playing
 }
 private func receivedDataStall() {
  let notificationAt=ProcessInfo.processInfo.systemUptime
  observeWait(.notification);waitEpisodes.notified(now:notificationAt)
  stallNotifications += 1
  let alreadyPending=stallRecovery.pending
  let eligible=waitPolicy == .resourceLoaderControlled && waitEligible && item?.status == .readyToPlay
  recoveryPlaybackProgress.interruptedByDataStall(eligible:eligible)
  if eligible {stallProbe.interruptObservation()}
  stallRecovery.stalled(eligible:eligible)
  if !alreadyPending && stallRecovery.pending {
   bufferingPlaybackProgress.reset()
   emitStallProbe(stallProbe.begin(epoch:requestMetrics.epoch,snapshot:probeSnapshot(now:notificationAt)))
  }
 }
 private func resumeAfterDataStall(duration:Double,probeOnly:Bool=false) {
  if recoveryCommandIssuedThisLoop || (probeOnly && !stallRecovery.pending) {return}
  guard waitPolicy == .resourceLoaderControlled,let player,let item else{return}
  let ranges=item.loadedTimeRanges.map(\.timeRangeValue).compactMap {range->Range<Double>? in
   let start=range.start.seconds,end=CMTimeRangeGetEnd(range).seconds
   guard start.isFinite,end.isFinite,end>start else{return nil};return start..<end
  }
  if !probeOnly {observeWait(.beforeResume)}
  let observedAt=ProcessInfo.processInfo.systemUptime,position=player.currentTime().seconds,empty=item.isPlaybackBufferEmpty
  // Observe independently of the gate's early exits, including while empty=true.
  if !probeOnly,waitEpisodes.active != nil {
   waitEpisodes.observeConditions(now:observedAt,empty:empty,
    coveragePass:PlaybackWaitEpisodeDiagnostics.coveragePass(position:position,duration:duration,speed:selectedSpeed,ranges:ranges))
  }
  let approved=stallRecovery.takeResume(now:observedAt,active:active,sceneActive:sceneActive,paused:paused,seeking:seeking,
    ready:prepared && item.status == .readyToPlay && !sourceFailed && !(recoverySource?.isPlaybackRecovering ?? false),transportPaused:player.timeControlStatus == .paused,
    bufferEmpty:empty,position:position,duration:duration,
    selectedSpeed:selectedSpeed,ranges:ranges,demand:bridge.map{.init(bridge:$0.recoveryActivity,
     source:prefetchSource?.recoveryActivity,supported:demandOnlyLocalSource || prefetchSource != nil,frameCount:frames)},mode:probeOnly ? .probeOnly:.bufferedOnly)
  if stallRecovery.probeSourceInvalid {finishStallProbe(.sourceEpoch)}
  if approved {
   performStallResume(kind:stallRecovery.lastResumeKind ?? .buffered)
  } else if probeOnly,stallRecovery.pending {
   stallProbe.rejected(reason:stallRecovery.probeBlockedBy.rawValue)
  }
 }
 /// The gate is evaluated synchronously immediately before this command seam.
 /// Tests may exercise the command separately, without claiming a natural stall.
 func performStallResume(kind:NativeStallRecoveryGate.ResumeKind) {
  guard waitPolicy == .resourceLoaderControlled,waitEligible,item?.status == .readyToPlay,
        let player,player.timeControlStatus == .paused else{return}
  let before=kind == .demandProbe ? probeSnapshot():nil
  recoveryCommandIssuedThisLoop=true;recoveryPlaybackProgress.begin(clock:player.currentTime().seconds,pts:waitEpisodes.lastFramePTS,sourceEpoch:prefetchSource?.diagnosticObservedEpoch)
  bufferingPlaybackProgress.reset()
  // Preserve requested rate and pause intent. No seek, flush or lastProgress reset.
  player.defaultRate=Float(selectedSpeed);recordWaitResume(cause:kind == .demandProbe ? 3:1)
  player.play();stallResumes += 1
  if let before {emitStallProbe(stallProbe.attempt(before:before,after:probeSnapshot()))}
  #if SWIFT_PACKAGE
  experimentStallResumes += 1
  #endif
 }
 private var seekGeneration=UUID(),frameSession=UUID()
 private var lastProgress=0.0
 private let stallLimit:Double
 private let muted:Bool
 private var frames=0,waits=0
 private var videoDeliveryDiagnostics=NativeVideoDeliveryDiagnostics()
 private var maxClockDifference=0.0
 public private(set) var diagnosticsText="AVPlayer 候選／解碼方式：系統管理（未知）"
 private var diagnosticUpdate=0.0
 #if VISTA_ANON_IO_EXPERIMENT
 var experimentItem:AVPlayerItem?{item}
 private var anonymousIO=AnonymousIOAggregate()
 private var anonymousStages:[String:AnonymousIOSnapshot]=[:]
 #endif
 private(set) var requestMetrics=NativeRequestMetrics()
 public init(stallLimit:Double=15,muted:Bool=false,waitPolicy:NativePlaybackWaitPolicy = .resourceLoaderControlled) {self.stallLimit=max(0.1,stallLimit);self.muted=muted;self.waitPolicy=waitPolicy}
 public func anonymousLogValues()->[PlaybackLogField:Double] {
  if let terminalLogValues {return terminalLogValues}
  let now=ProcessInfo.processInfo.systemUptime
  let speed=speedStatus
  let m=requestMetrics;var v:[PlaybackLogField:Double]=[.frames:Double(frames),.waits:Double(waits),.clockDeltaMS:maxClockDifference*1000,.epoch:Double(m.epoch),.reads:Double(m.reads),.bytes:Double(m.bytes),.readMS:m.readSeconds*1000,.interrupted:Double(m.interrupted),.waitMS:m.waitingSeconds*1000]
  v[.waitCompleted]=Double(waitEpisodes.completed);v[.waitEpisodes]=Double(waitEpisodes.seen);v[.waitSuppressed]=Double(waitEpisodes.suppressed);v[.waitIncomplete]=waitEpisodes.active == nil ? 0:1
  // Existing low-frequency log/terminal snapshots only. No timer or per-frame memory probes.
  v.merge(memoryDiagnostics.values(sampling:.current())){_,new in new}
  v.merge(videoDeliveryDiagnostics.values(now:now)){_,new in new}
  v[.selectedSpeed]=Double(speed.selected);v[.effectiveRate]=speed.effectiveRate;v[.maximumSpeed]=Double(speed.maximum)
  let automatic=automaticSpeedPolicy.diagnostics
  v[.autoSpeedBaselineReady]=automatic.baselineReady ? 1:0;v[.autoSpeedAwaitingRateStart]=automatic.awaitingRateStart ? 1:0
  v[.autoSpeedLastResetReason]=Double(automatic.lastResetReason.rawValue);v[.autoSpeedResetCount]=Double(automatic.resetCount)
  v[.stallNotifications]=Double(stallNotifications);v[.stallPending]=stallRecovery.pending ? 1:0
  v[.stallAttempts]=Double(stallRecovery.attempts);v[.stallResumes]=Double(stallResumes)
  v[.stallBlockedBy]=Double(stallRecovery.blockedBy.rawValue);v[.stallActiveMS]=stallRecovery.recoveryActiveElapsed*1000
  v[.stallTimeout]=Double(timeoutReason)
  // Bit mask: active, scene active, user paused, seeking, ready, source failed/recovering.
  var context=0
  for (flag,bit) in [(active,1),(sceneActive,2),(paused,4),(seeking,8),(item?.status == .readyToPlay,16),(sourceFailed,32),(recoverySource?.isPlaybackRecovering ?? false,64)] {if flag {context |= bit}}
  v[.resumeContext]=Double(context)
  if let player,let item {
   let position=player.currentTime().seconds
   v[.playerClock]=position;v[.transportStatus]=Double(player.timeControlStatus.rawValue)
   v[.bufferEmpty]=item.isPlaybackBufferEmpty ? 1:0
   v[.bufferAheadMS]=(item.loadedTimeRanges.map(\.timeRangeValue).compactMap {range->Double? in
    let start=range.start.seconds,end=CMTimeRangeGetEnd(range).seconds
    guard start.isFinite,end.isFinite,position.isFinite,start<=position,end>=position else{return nil}
    return max(0,end-position)
   }.max() ?? 0)*1000
  }
  if let target=m.target {v[.target]=target};if let buffered=m.targetBuffered {v[.targetBuffered]=buffered ? 1:0}
  if let b=bridge {
   v[.rawDataRequests]=Double(b.rawDataRequests);v[.rawRequestsAtLeast512]=Double(b.rawRequestsAtLeast512)
   v[.rawRequestsToEnd]=Double(b.rawRequestsToEnd);v[.rawMaximumBytes]=Double(b.rawMaximumBytes)
   v[.smallDemandReads]=Double(b.smallDemandReads);v[.largeDemandReads]=Double(b.largeDemandReads)
   v[.largeDemandBytes]=Double(b.largeDemandBytes);v[.maximumDemandReads]=Double(b.maximumDemandReads)
   v[.currentDemandChunkBytes]=Double(b.demandChunkLimit)
   v[.deliveredBytes]=Double(b.deliveredBytes)
  }
  if let p=prefetchSource?.metrics ?? finalPrefetchMetrics {
   v[.prefetchHitBytes]=Double(p.hitBytes);v[.prefetchJoinedBytes]=Double(p.joinedBytes);v[.prefetchMissBytes]=Double(p.missBytes)
   v[.prefetchReadBytes]=Double(p.speculativeBytes);v[.prefetchDiscardedBytes]=Double(p.discardedBytes)
   v[.prefetchResidentBytes]=Double(p.residentBytes);v[.prefetchPeakBytes]=Double(p.maxResidentBytes)
   v[.prefetchReadMS]=p.speculativeSeconds*1000;v[.prefetchDemandWaitMS]=p.demandWaitSeconds*1000
   v.merge(p.diagnostics.playbackLogValues){_,new in new}
   v[.cacheHistoryHitBytes]=Double(p.historyHitBytes);v[.cacheHistoryBytes]=Double(p.historyBytes)
   v[.cacheTotalBytes]=Double(p.totalCacheBytes);v[.cacheInFlightReservedBytes]=Double(p.inFlightReservedBytes)
   v[.cacheMaxTotalBytes]=Double(p.maxTotalCacheBytes)
   v[.cacheStorageAllocatedBytes]=Double(p.storageAllocatedBytes);v[.cacheStoragePeakAllocatedBytes]=Double(p.maxStorageAllocatedBytes)
   v[.prefetchRetiredBytes]=Double(p.retiredSpeculativeBytes);v[.cacheQuarantineEntered]=Double(p.diagnostics.quarantineEnteredCount);v[.cacheQuarantineValidated]=Double(p.diagnostics.quarantineValidatedCount);v[.cacheQuarantineCleared]=Double(p.diagnostics.quarantineClearedCount)
   v[.cacheQuarantined]=p.cacheQuarantined ? 1:0;v[.cacheValidBytes]=Double(p.validCacheBytes);v[.cacheMetadataEntries]=Double(p.cacheMetadataEntries);v[.cacheMetadataPeakEntries]=Double(p.maxCacheMetadataEntries)
   v[.cacheMetadataAllocatedBytes]=Double(p.cacheMetadataAllocatedBytes);v[.cacheMetadataPeakAllocatedBytes]=Double(p.maxCacheMetadataAllocatedBytes)
   v[.prefetchWaitCount]=Double(p.speculativeWaitCount);v[.prefetchWaitMS]=p.speculativeWaitSeconds*1000
  }
  for (stage,at,reads,bytes) in [(m.seekSnapshot,PlaybackLogField.seekMS,PlaybackLogField.seekReads,PlaybackLogField.seekBytes),(m.firstSnapshot,PlaybackLogField.firstFrameMS,PlaybackLogField.firstReads,PlaybackLogField.firstBytes),(m.presentationSnapshot,PlaybackLogField.presentMS,PlaybackLogField.presentReads,PlaybackLogField.presentBytes)] {
   if let stage {v[at]=max(0,stage.at-m.started)*1000;v[reads]=Double(stage.reads);v[bytes]=Double(stage.bytes)}
  }
  #if VISTA_ANON_IO_EXPERIMENT
  let io=anonymousIO.snapshot()
  v[.ioStarted]=Double(io.started);v[.ioFinished]=Double(io.finished);v[.ioCancelled]=Double(io.cancelled);v[.ioFailed]=Double(io.failed);v[.ioInFlight]=Double(io.inFlight);v[.ioPeak]=Double(io.peak);v[.ioOld]=Double(io.oldAtStart);v[.ioOldRemaining]=Double(io.oldRemaining);v[.ioOldMS]=io.lastOldMS;v[.ioMaxMS]=io.maxTotalMS
  #endif
  return v
 }
 public private(set) var selectedSpeed=1.0
 public var speedStatus:PlaybackSpeedStatus {
  let effectiveRate=item?.timebase.map {CMTimebaseGetEffectiveRate($0)} ?? 0
  return PlaybackSpeedStatus(selected:selectedSpeed,effectiveRate:effectiveRate,ready:active && item?.status == .readyToPlay,
   supportsFastForward:item?.canPlayFastForward ?? false,paused:paused,waiting:isWaitingForData)
 }
 public var isPlaybackPaused:Bool {paused}
 @discardableResult public func setSpeed(_ requested:Double)->Bool {
  guard active,let player,speedStatus.accepts(requested) else{return false}
  let before=probeSnapshot()
  acceptIntentCommand(.manual)
  interruptAutomaticRecovery(.manualRate)
  automaticSpeedPolicy.manualSpeedDidChange(now:ProcessInfo.processInfo.systemUptime);bufferingPlaybackProgress.reset()
  selectedSpeed=requested;player.defaultRate=Float(requested)
  let issued = !paused && !seeking
  if issued {observeWait(.beforeResume);recordWaitResume(cause:2);player.play()}
  emitIntent(.command,before:before,issued:issued)
  return true
 }
 // Updating a waiting transport's requested rate is not permission to resume
 // a paused transport. The existing data-stall gate owns that decision.
 func updateBufferingSpeed(now:Double,duration:Double,outputPolled:Bool=false,copiedFramePTS:Double?=nil) {
  let position=player?.currentTime().seconds ?? .nan
  let eligible=active && prepared && sceneActive && !sourceFailed && !seeking && !(recoverySource?.isPlaybackRecovering ?? false) &&
   position.isFinite && duration.isFinite && position<duration
  let status=speedStatus
  // Attribute each episode to its captured source epoch, even if recovery
  // completed between callbacks and the transient recovery flag was not seen.
  if automaticRecovery.isObserving,automaticRecoverySourceEpoch != prefetchSource?.diagnosticObservedEpoch {
   emitAutomaticRecovery(automaticRecovery.interrupt(.sourceEpoch,now:now))
  }
  // Observational only, including the 2x floor where sparse policy evidence is
  // disabled. This helper never changes rate, resumes, seeks or owns a timer.
  if !eligible || status.paused {
   let reason:PlaybackAutomaticRecoveryDiagnostics.EndReason = status.paused ? .pause : !sceneActive ? .background : seeking ? .seek : (sourceFailed || (recoverySource?.isPlaybackRecovering ?? false)) ? .sourceFailure : position>=duration ? .ended : .invalidObservation
   emitAutomaticRecovery(automaticRecovery.interrupt(reason,now:now))
  } else {
   emitAutomaticRecovery(automaticRecovery.observe(now:now,effectiveRate:status.effectiveRate,
    playing:player?.timeControlStatus == .playing,waiting:status.waiting,clock:position,
    outputPolled:outputPolled,copiedFramePTS:copiedFramePTS))
  }
  if !eligible || status.paused || status.waiting || !status.effectiveRate.isFinite || status.effectiveRate<=0 {bufferingPlaybackProgress.reset()}
  guard let decision=automaticSpeedPolicy.update(now:now,status:status,eligible:eligible,
        playing:player?.timeControlStatus == .playing,recovering:stallRecovery.pending,
        clock:position,outputPolled:outputPolled,copiedFramePTS:copiedFramePTS) else{return}
  applyAutomaticSpeedDecision(decision)
 }
 /// No await between policy decision and application. Kept separate so synthetic
 /// output evidence can verify the real player's running-rate boundary.
 func applyAutomaticSpeedDecision(_ decision:PlaybackAutomaticSpeedPolicy.Decision) {
  guard let player else{return}
  let commandBefore=probeSnapshot()
  acceptIntentCommand(.automatic)
  let previous=selectedSpeed,next=decision.nextSpeed
  emitAutomaticRecovery(automaticRecovery.begin(sequence:decision.sequence,now:ProcessInfo.processInfo.systemUptime,
   previousSpeed:previous,targetSpeed:next,decisionClock:player.currentTime().seconds,
   lastFramePTS:waitEpisodes.lastFramePTS,healthyReferenceFPS:decision.healthyReferenceFPS))
  automaticRecoverySourceEpoch=prefetchSource?.diagnosticObservedEpoch
  let before=automaticRecovery.isObserving ? probeSnapshot():nil
  selectedSpeed=next;player.defaultRate=Float(next)
  // Preserve the original post-defaultRate conditional evaluation order.
  // 0=default only, 1=waiting transport rate, 2=playing sparse-output rate.
  let setterBranch=player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? 1:
   (decision.reason == .sparseOutput && player.timeControlStatus == .playing) ? 2:0
  if setterBranch != 0 {player.rate=Float(next)}
  let after=before == nil ? nil:probeSnapshot()
  hypothesisDiagnostics.arm(command:intentRecovery.commandID,now:ProcessInfo.processInfo.systemUptime,
   lastPTS:waitEpisodes.lastFramePTS,clock:player.currentTime().seconds)
  emitIntent(.command,before:commandBefore,issued:false)
  #if SWIFT_PACKAGE
  experimentLastAutomaticSpeedDecision=decision
  #endif
  PlaybackLogStore.shared.enqueue(PlaybackLogRecord(automaticSpeed:decision,session:waitSession,previous:previous,
   before:before,after:after,setterBranch:before == nil ? nil:setterBranch))
 }
 public func pause(userInitiated:Bool=true){interruptIntent(userInitiated ? 2:4);finishStallProbe(.pause);interruptAutomaticRecovery(.pause);abortWait(.pause);interruptBufferingWait();paused=true;stallRecovery.interrupt(userInitiated:userInitiated);updatePrefetchActivity();player?.pause()}
 public func resume(){
  let before=probeSnapshot()
  interruptIntent(3);acceptIntentCommand(.resume);finishStallProbe(.superseded);interruptAutomaticRecovery(.manualRate)
  abortWait(.userResume);interruptBufferingWait();paused=false;stallRecovery.interrupt(userInitiated:true)
  lastProgress=ProcessInfo.processInfo.systemUptime;updatePrefetchActivity()
  if !seeking {player?.play()};emitIntent(.command,before:before,issued:!seeking && player != nil)
 }
 public func seek(to target:Double,maximumBackward:Double=1,maximumForward:Double=0)async throws {
  guard target.isFinite,target>=0,let player,let item,active else{throw Failure.unsupported}
  let ranges=item.loadedTimeRanges.map(\.timeRangeValue).compactMap { range -> Range<Double>? in
   let start=range.start.seconds,end=CMTimeRangeGetEnd(range).seconds
   guard start.isFinite,end.isFinite,end>start else{return nil};return start..<end
  }
  interruptIntent(5)
  finishStallProbe(.seek)
  interruptAutomaticRecovery(.seek)
  interruptBufferingWait()
  abortWait(.seek)
  let id=UUID();seekGeneration=id;seeking=true;stallRecovery.interrupt(userInitiated:true);prefetchSource?.invalidatePrefetch(reason:.seek);updatePrefetchActivity();player.pause();item.cancelPendingSeeks()
  requestMetrics.begin("跳轉",now:ProcessInfo.processInfo.systemUptime)
  #if VISTA_ANON_IO_EXPERIMENT
  anonymousIO.beginEpoch(now:ProcessInfo.processInfo.systemUptime);anonymousStages=[:]
  #endif
  requestMetrics.target=target;requestMetrics.targetBuffered=NativeRequestMetrics.isBuffered(target,ranges:ranges)
  maxClockDifference=0;diagnosticUpdate=0
  let finished=await player.seek(to:CMTime(seconds:target,preferredTimescale:60000),toleranceBefore:CMTime(seconds:min(1,max(0,maximumBackward)),preferredTimescale:60000),toleranceAfter:CMTime(seconds:min(1,max(0,maximumForward)),preferredTimescale:60000))
  guard active,seekGeneration==id else{throw CancellationError()}
  seeking=false;interruptBufferingWait();lastProgress=ProcessInfo.processInfo.systemUptime
  guard finished else{throw CancellationError()}
  requestMetrics.completeSeek(now:ProcessInfo.processInfo.systemUptime)
  #if VISTA_ANON_IO_EXPERIMENT
  anonymousStages["seek"]=anonymousIO.snapshot()
  #endif
  frameSession=UUID()
  updatePrefetchActivity()
  let commandBefore=probeSnapshot();acceptIntentCommand(.seek)
  if !paused {player.play()};emitIntent(.command,before:commandBefore,issued:!paused)
 }
 public func recordPresentation(session:UUID) {
  guard active,session==frameSession else{return}
  requestMetrics.present(now:ProcessInfo.processInfo.systemUptime)
  #if VISTA_ANON_IO_EXPERIMENT
  if anonymousStages["呈現"]==nil {anonymousStages["呈現"]=anonymousIO.snapshot()}
  // Presentation can arrive while paused, without another video frame to refresh the text.
  if let divider=diagnosticsText.range(of:"\nAVPlayer 候選") {
   let suffix=String(diagnosticsText[divider.lowerBound...]).components(separatedBy:"\n").filter{!$0.contains(" I/O 起")}.joined(separator:"\n")
   let lines=["seek","首幀","呈現"].compactMap {key in anonymousStages[key].map{key+" "+$0.text}}
   diagnosticsText=requestMetrics.text(now:ProcessInfo.processInfo.systemUptime)+suffix+"\n"+lines.joined(separator:"\n")
  }
  #endif
 }
 public func stop(){
  emitHypothesis(final:true)
  interruptIntent(8);emitIntent(.summary)
  finishStallProbe(.stop);finishStallProbeSession()
  finishAutomaticRecovery()
  abortWait(.stop)
  videoDeliveryDiagnostics.finishLoop(now:ProcessInfo.processInfo.systemUptime)
  active=false;interruptBufferingWait();automaticSpeedPolicy.reset();stallRecovery.clear();inactiveStallSuspension=nil
  updatePrefetchActivity()
  memoryPressureSource?.setEventHandler {};memoryPressureSource?.cancel();memoryPressureSource=nil
  if let prefetchSource {finalPrefetchMetrics=prefetchSource.metrics}
  prefetchSource=nil
  if let observer=stallObserver {NotificationCenter.default.removeObserver(observer);stallObserver=nil}
  seekGeneration=UUID();item?.cancelPendingSeeks();player?.pause();asset?.cancelLoading()
  recoverySource?.cancelPlayback();recoverySource=nil;observedSourceRecovery=false
 }
 private func check()throws {
  try Task.checkCancellation()
  guard active else{throw CancellationError()}
  if sourceFailed {throw Failure.source}
  if item?.status == .failed {throw Failure.player}
  let now=ProcessInfo.processInfo.systemUptime
  // Fence before any buffered resume or delivered-frame proof in this loop.
  // A recovery entirely between callbacks must not join old/new source PTS.
  if recoveryPlaybackProgress.observeSourceEpoch(prefetchSource?.diagnosticObservedEpoch) {
   interruptIntent(6);finishStallProbe(.sourceEpoch);stallRecovery.invalidateProbeSource()
  }
  let recoveringSource=recoverySource?.isPlaybackRecovering ?? false
  let recoveryClockActive=active && prepared && sceneActive && !paused && !seeking && !recoveringSource
  stallRecovery.observeElapsed(now:now,eligible:recoveryClockActive)
  // Start this bound after the first buffered resume or one-shot demand probe.
  // Incoming bytes cannot keep an unsuccessful player recovery spinning forever.
  if recoveryClockActive && stallRecovery.recoveryExpired(limit:stallLimit) {timeoutReason=2;throw Failure.stalled}
  if let recoverySource,recoverySource.isPlaybackRecovering {
   interruptIntent(6);stallRecovery.resetProbeObservation();stallProbe.interruptObservation()
   abortWait(.sourceRecovery);interruptAutomaticRecovery(.sourceFailure)
   observedSourceRecovery=true
   // Only the source's accumulated active time counts. Inactive/background waits
   // cannot spend or renew this episode's bound, and no AVPlayer state is changed.
   guard recoverySource.recoveryActiveElapsed<PlaybackSourceRecoveryPolicy.activeBudget else {
    recoverySource.cancelPlayback()
    throw Failure.source
   }
   return
  }
  if observedSourceRecovery {observedSourceRecovery=false;lastProgress=now}
  // Inactive is not user pause. If it intentionally blocks a pending data-stall
  // resume, suspend only this interval, preserving all previously spent active time.
  if !sceneActive && (stallRecovery.pending || stallRecovery.hasRecoveryBudget) && !paused && !seeking {
   if inactiveStallSuspension==nil {inactiveStallSuspension=now}
   return
  }
  if let start=inactiveStallSuspension {
   lastProgress=lastProgress>=start ? now:lastProgress+max(0,now-start)
   inactiveStallSuspension=nil
  }
  if (!paused || !prepared) && now-lastProgress>stallLimit {timeoutReason=1;throw Failure.stalled}
 }
 public func play(file:MediaFile,source:any MediaByteSource,startAt:Double=0,startPaused:Bool=false,
  onInfo:@escaping @MainActor (VideoTrackInfo)->Void,
  onState:@escaping @MainActor (State)->Void,
  onFrame:@escaping @MainActor (DecodedVideoFrame)->Void,
  onSpeed:@escaping @MainActor (PlaybackSpeedStatus)->Void = {_ in})async throws {
  guard !running else{throw Failure.unsupported}
  let ext=(file.components.last! as NSString).pathExtension.lowercased()
  guard ["mp4","m4v","mov"].contains(ext) else{throw Failure.unsupported}
  automaticRecovery=PlaybackAutomaticRecoveryDiagnostics();automaticRecoverySourceEpoch=nil
  stallProbe=PlaybackStallProbeDiagnostics();latestOutput=OutputObservation()
  hypothesisDiagnostics=PlaybackHypothesisDiagnostics()
  intentRecovery=NativePlaybackIntentRecovery();intentDiagnostics=PlaybackIntentRecoveryDiagnostics();recoveryPlaybackProgress=NativeRecoveryProgressProof()
  waitEpisodes=PlaybackWaitEpisodeDiagnostics();waitCounters=PlaybackWaitEpisodeCounters();lastDeliveryAt=nil
  if Self.nextWaitSession<PlaybackWaitEpisodeDiagnostics.maximumCounter {
   PlaybackWaitEpisodeDiagnostics.increment(&Self.nextWaitSession);waitSession=Self.nextWaitSession
  } else {waitSession=0} // Exhausted diagnostic identity never wraps/reuses or changes playback.
  terminalLogValues=nil;stallNotifications=0;stallResumes=0;timeoutReason=0
  memoryDiagnostics=PlaybackMemoryDiagnostics()
  interruptBufferingWait();automaticSpeedPolicy.reset()
  running=true;prepared=false;active=true;stallRecovery.clear();sourceFailed=false;paused=startPaused;seeking=false;selectedSpeed=1;frameSession=UUID()
  recoverySource=source as? any PlaybackRecoveryControlling;observedSourceRecovery=false
  finalPrefetchMetrics=nil;prefetchSource=source as? PlaybackPrefetchSource
  demandOnlyLocalSource=source is LocalDirectoryProvider
  if let prefetchSource {
   prefetchSource.diagnosticSink = { record in PlaybackLogStore.shared.enqueue(PlaybackLogRecord(prefetch:record)) }
   prefetchSource.cleanupDiagnosticSink = { [counters=waitCounters] metrics,succeeded in
    var values=metrics.diagnostics.playbackLogValues
    // This play's four numeric values outlive Native session teardown/reuse.
    // Source cleanup order is unchanged, and no player/session is retained here.
    values.merge(counters.values){_,new in new}
    values[.pfTraceReason]=Double((succeeded ? PrefetchDiagnosticReason.cleanupSucceeded : .cleanupFailed).rawValue)
    values[.prefetchReadBytes]=Double(metrics.speculativeBytes)
    values[.prefetchHitBytes]=Double(metrics.hitBytes)
    values[.prefetchJoinedBytes]=Double(metrics.joinedBytes)
    values[.prefetchDiscardedBytes]=Double(metrics.discardedBytes)
    values[.prefetchResidentBytes]=Double(metrics.residentBytes)
    values[.cacheHistoryHitBytes]=Double(metrics.historyHitBytes);values[.cacheHistoryBytes]=Double(metrics.historyBytes)
    values[.cacheTotalBytes]=Double(metrics.totalCacheBytes);values[.cacheInFlightReservedBytes]=Double(metrics.inFlightReservedBytes)
    values[.cacheMaxTotalBytes]=Double(metrics.maxTotalCacheBytes)
    values[.cacheStorageAllocatedBytes]=Double(metrics.storageAllocatedBytes);values[.cacheStoragePeakAllocatedBytes]=Double(metrics.maxStorageAllocatedBytes)
   values[.prefetchRetiredBytes]=Double(metrics.retiredSpeculativeBytes);values[.cacheQuarantineEntered]=Double(metrics.diagnostics.quarantineEnteredCount);values[.cacheQuarantineValidated]=Double(metrics.diagnostics.quarantineValidatedCount);values[.cacheQuarantineCleared]=Double(metrics.diagnostics.quarantineClearedCount)
   values[.cacheQuarantined]=metrics.cacheQuarantined ? 1:0;values[.cacheValidBytes]=Double(metrics.validCacheBytes);values[.cacheMetadataEntries]=Double(metrics.cacheMetadataEntries);values[.cacheMetadataPeakEntries]=Double(metrics.maxCacheMetadataEntries)
   values[.cacheMetadataAllocatedBytes]=Double(metrics.cacheMetadataAllocatedBytes);values[.cacheMetadataPeakAllocatedBytes]=Double(metrics.maxCacheMetadataAllocatedBytes)
    values[.prefetchWaitCount]=Double(metrics.speculativeWaitCount);values[.prefetchWaitMS]=metrics.speculativeWaitSeconds*1000
    PlaybackLogStore.shared.enqueue(PlaybackLogRecord(event:.prefetchSummary,values:values))
   }
   let pressure=DispatchSource.makeMemoryPressureSource(eventMask:[.warning,.critical],queue:.main)
   pressure.setEventHandler { [weak self,weak pressure,weak prefetchSource] in
    guard let pressure else{return}
    let flags=pressure.data
    Task { @MainActor in
     if let self,self.memoryPressureSource === pressure {
      self.memoryDiagnostics.recordPressure(warning:flags.contains(.warning),critical:flags.contains(.critical))
     }
     prefetchSource?.handleMemoryPressure()
    }
   }
   memoryDiagnostics.pressureMonitored=true
   memoryPressureSource=pressure;pressure.resume()
  }
  videoDeliveryDiagnostics=NativeVideoDeliveryDiagnostics()
  lastProgress=ProcessInfo.processInfo.systemUptime;frames=0;waits=0;maxClockDifference=0;diagnosticUpdate=0;onState(.preparing)
  do {
   requestMetrics.begin("開片",now:ProcessInfo.processInfo.systemUptime)
   let size:UInt64
   do {size=try await source.fileSize(for:file);lastProgress=ProcessInfo.processInfo.systemUptime}
   catch is CancellationError {throw CancellationError()}
   catch {throw Failure.source}
   try check()
   guard size>0,size<=Int64.max else{throw Failure.source}
   let loader=ResourceBridge(source:source,file:file,size:size,contentType:ext=="mov" ? "com.apple.quicktime-movie":"public.mpeg-4",chunkBytes:demandChunkBytes)
   bridge=loader
   #if VISTA_ANON_IO_EXPERIMENT
   anonymousIO=AnonymousIOAggregate();anonymousIO.beginEpoch(now:ProcessInfo.processInfo.systemUptime);anonymousStages=[:]
   let aggregate=anonymousIO
   loader.onAnonymousBegin={aggregate.begin(now:ProcessInfo.processInfo.systemUptime)}
   loader.onAnonymousEnd={id,bytes,cancelled,failed in aggregate.end(id,now:ProcessInfo.processInfo.systemUptime,bytes:bytes,cancelled:cancelled,failed:failed)}
   #endif
   loader.onRangeBegin={ [weak self] in self?.requestMetrics.epoch ?? -1 }
   loader.onRangeEnd={ [weak self] epoch,bytes,seconds,interrupted in
    self?.requestMetrics.endRead(epoch:epoch,bytes:bytes,seconds:seconds,interrupted:interrupted)
   }
   loader.onReadFailure={ [weak self] in self?.sourceFailed=true }
   loader.onReadProgress={ [weak self] in
    let now=ProcessInfo.processInfo.systemUptime;self?.lastProgress=now;self?.lastDeliveryAt=now
   }
   _ = NativeSupplementalVideoDecoders.vp9RegistrationRequested
   let urlAsset=AVURLAsset(url:URL(string:"vista-media://native/\(UUID().uuidString).\(ext)")!)
   asset=urlAsset;urlAsset.resourceLoader.setDelegate(loader,queue:.main)
   let media=AVPlayerItem(asset:urlAsset);item=media
   let output=AVPlayerItemVideoOutput(pixelBufferAttributes:nil)
   media.add(output)
   let native=AVPlayer(playerItem:media);player=native;native.isMuted=muted;native.defaultRate=1
   // Apple recommends NO when a ResourceLoader delegate supplies the media bytes.
   native.automaticallyWaitsToMinimizeStalling=waitPolicy.automaticallyWaits
   stallObserver=NotificationCenter.default.addObserver(forName:AVPlayerItem.playbackStalledNotification,object:media,queue:.main) { [weak self] notification in
    guard let observed=notification.object as? AVPlayerItem else{return}
    let identity=ObjectIdentifier(observed)
    MainActor.assumeIsolated {
     guard let self,self.item.map(ObjectIdentifier.init)==identity else{return}
     self.receivedDataStall()
    }
   }
   #if SWIFT_PACKAGE
   experimentStallResumes=0
   #endif
   while media.status == .unknown {try check();try await Task.sleep(for:.milliseconds(10))}
   try check()
   let tracks=try await urlAsset.loadTracks(withMediaType:.video)
   guard tracks.count==1,try await !urlAsset.load(.hasProtectedContent) else{throw Failure.unsupported}
   let (formats,transform)=try await tracks[0].load(.formatDescriptions,.preferredTransform)
   let duration=try await urlAsset.load(.duration).seconds
   guard let format=formats.first,duration.isFinite,duration>0 else{throw Failure.unsupported}
   let dimensions=CMVideoFormatDescriptionGetDimensions(format),code=CMFormatDescriptionGetMediaSubType(format)
   let codec=String(bytes:[24,16,8,0].map{UInt8((code >> $0)&255)},encoding:.ascii) ?? "unknown"
   // Optional display metadata must not turn a playable item into an error.
   let estimatedDataRate=try? await tracks[0].load(.estimatedDataRate)
   onInfo(VideoTrackInfo(codec:codec,width:dimensions.width,height:dimensions.height,duration:duration,hasAudio:try await !urlAsset.loadTracks(withMediaType:.audio).isEmpty,estimatedDataRate:estimatedDataRate.map(Double.init)))
   try check()
   #if os(visionOS)
   let clock=NativeDisplayClock();displayClock=clock;clock.start()
   #endif
   if startAt>0 {try await seek(to:min(startAt,duration))}
   prepared=true
   updatePrefetchActivity()
   let initialBefore=probeSnapshot();acceptIntentCommand(.initial)
   if paused {native.pause()}else{native.play()};emitIntent(.command,before:initialBefore,issued:!paused)
   var state:State = .preparing
   var reportedSpeed:PlaybackSpeedStatus?
   while true {
    try check()
    videoDeliveryDiagnostics.recordLoop(now:ProcessInfo.processInfo.systemUptime)
    observeWait(.loop)
    recoveryCommandIssuedThisLoop=false
    resumeAfterDataStall(duration:duration)
    let speed=speedStatus
    if reportedSpeed != speed {reportedSpeed=speed;onSpeed(speed)}
    observeWait(.loop)
    let next:State=seeking ? .seeking:paused ? .paused:isWaitingForData ? .waiting:.playing
    if next != state {if next == .waiting {waits += 1};state=next;onState(next)}
    let now=ProcessInfo.processInfo.systemUptime
    let reason:String
    switch native.reasonForWaitingToPlay {
     case .toMinimizeStalls:reason="避免停滯"
     case .evaluatingBufferingRate:reason="評估緩衝"
     case .noItemToPlay:reason="無項目"
     default:reason=stallRecovery.pending ? "資料不足":"其他／無"
    }
    requestMetrics.waiting(isWaitingForData,reason:reason,now:now)
    let time=native.currentTime()
    #if os(visionOS)
    let targetHost=displayClock?.take()
    let outputTime=targetHost.map{output.itemTime(forHostTime:$0)}
    let hostLead=targetHost.map{$0-CACurrentMediaTime()}
    #else
    let outputTime:CMTime?=time
    let targetHost:Double?=nil,hostLead:Double?=nil
    #endif
    latestOutput=OutputObservation(at:now)
    latestOutput.targetHost=targetHost
    if let outputTime {
     latestOutput.validity |= 1
     if outputTime.isValid {latestOutput.validity |= 2}
     if outputTime.seconds.isFinite {
      latestOutput.validity |= 4;latestOutput.query=outputTime.seconds
      if time.seconds.isFinite {latestOutput.queryClock=outputTime.seconds-time.seconds}
     }
    }
    if targetHost != nil {latestOutput.validity |= 8}
    if let hostLead,hostLead.isFinite {latestOutput.validity |= 16;latestOutput.hostLead=hostLead}
    var returnedFramePTS:Double?
    var outputPolled=false,copiedFramePTS:Double?
    if !seeking,let outputTime {
     outputPolled=true;latestOutput.validity |= 64
     videoDeliveryDiagnostics.recordOutputPoll()
     if output.hasNewPixelBuffer(forItemTime:outputTime) {
      latestOutput.validity |= 128
      videoDeliveryDiagnostics.recordOutputHasNew()
      var display=CMTime.invalid
      let copiedPixel=output.copyPixelBuffer(forItemTime:outputTime,itemTimeForDisplay:&display)
      returnedFramePTS=display.seconds.isFinite ? display.seconds:nil
      if copiedPixel == nil {latestOutput.validity |= 256;videoDeliveryDiagnostics.recordOutputCopyNil()}
      if let pixel=copiedPixel,display.seconds.isFinite {
       copiedFramePTS=display.seconds;latestOutput.validity |= 32
       latestOutput.copyQuery=latestOutput.query.map{display.seconds-$0}
       if stallProbe.isObserving {stallProbe.observe(probeSnapshot(copiedFramePTS:display.seconds,includeCoverage:false))}
       // Actual/effective rates are diagnostic only for recovery success too.
       if recoveryPlaybackProgress.record(position:native.currentTime().seconds,framePTS:display.seconds,eligible:waitEligible,sourceEpoch:prefetchSource?.diagnosticObservedEpoch) {
        if stallRecovery.intentUsed {emitIntent(.terminal,reason:1)}
        finishStallProbe(.progress,copiedFramePTS:display.seconds);stallRecovery.clear()
       }
       lastProgress=ProcessInfo.processInfo.systemUptime
       let priorFrameAt=waitEpisodes.lastFrameAt,priorFramePTS=waitEpisodes.lastFramePTS
       let waitRecord=waitEpisodes.copiedFrame(now:lastProgress,pts:display.seconds,clock:native.currentTime().seconds,
        eligible:waitEligible,snapshot:{self.waitSnapshot(frameAt:priorFrameAt,framePTS:priorFramePTS)})
       emitWait(waitRecord)
       frames += 1
       videoDeliveryDiagnostics.recordFrame(now:lastProgress,presentationTime:display.seconds)
       requestMetrics.deliverFirst(now:lastProgress,pts:display.seconds)
       #if VISTA_ANON_IO_EXPERIMENT
       if anonymousStages["首幀"]==nil {anonymousStages["首幀"]=anonymousIO.snapshot()}
       #endif
       maxClockDifference=max(maxClockDifference,abs(display.seconds-native.currentTime().seconds))
       if lastProgress-diagnosticUpdate>=1 {
        diagnosticUpdate=lastProgress
        diagnosticsText=requestMetrics.text(now:lastProgress)+"\nAVPlayer 候選／解碼方式：系統管理（未知）\n影格 \(frames)／等待 \(waits)／影格與播放器時鐘差最大 \(Int(maxClockDifference*1000)) ms／\(CVPixelBufferGetWidth(pixel))×\(CVPixelBufferGetHeight(pixel))"
        #if VISTA_ANON_IO_EXPERIMENT
        let aggregateLines=["seek","首幀","呈現"].compactMap {key in anonymousStages[key].map{key+" "+$0.text}}
        diagnosticsText += "\n"+aggregateLines.joined(separator:"\n")
        #endif
       }
       onFrame(DecodedVideoFrame(pixel:pixel,time:display.seconds,transform:transform,session:frameSession))
      }
     }
    }
    observeHypothesisOutput(now:now,clock:time.seconds,returnedPTS:returnedFramePTS,copiedPTS:copiedFramePTS)
    if copiedFramePTS == nil,stallProbe.isObserving {stallProbe.observe(probeSnapshot(includeCoverage:false))}
    // One coordinator invocation per observed loop: waiting and sparse output
    // cannot reduce twice, and polls are never counted as delivered frames.
    updateBufferingSpeed(now:ProcessInfo.processInfo.systemUptime,duration:duration,outputPolled:outputPolled,copiedFramePTS:copiedFramePTS)
    // New unbuffered probes run only after this loop's existing speed decision.
    // Re-read live state and latest requested rate, with no await before play.
    // Ordinary buffered resumes retain their original earlier loop position.
    resumeAfterDataStall(duration:duration,probeOnly:true)
    observeIntentRecovery(duration:duration,copiedFramePTS:copiedFramePTS)
    if !seeking,!paused,time.seconds>=duration,native.rate==0 {interruptIntent(7);finishStallProbe(.ended);interruptAutomaticRecovery(.ended);abortWait(.ended);onState(.ended);break}
    try await Task.sleep(for:.milliseconds(8))
   }
   await cleanup()
  }catch {
   interruptIntent(error is CancellationError ? 8 : (error as? Failure) == .stalled ? 10:9)
   finishStallProbe(error is CancellationError ? .stop:.failure)
   interruptAutomaticRecovery(error is CancellationError ? .stopped:.sourceFailure)
   abortWait(error is CancellationError ? .stop:.failure)
   if !(error is CancellationError),terminalLogValues==nil {terminalLogValues=anonymousLogValues()}
   await cleanup();throw error
  }
 }
 private func cleanup()async {
  stop()
  #if os(visionOS)
  displayClock?.stop();displayClock=nil
  #endif
  player?.replaceCurrentItem(with:nil)
  let old=bridge;bridge=nil;old?.onReadFailure=nil;old?.onReadProgress=nil;old?.onRangeBegin=nil;old?.onRangeEnd=nil
  await old?.stop()
  item=nil;player=nil;asset=nil;seeking=false;running=false
 }
}
