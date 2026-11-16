#if VISTA_VLC_CANDIDATE
import Foundation
import CoreVideo
import VideoToolbox

/// Fixed user-facing reasons only. Never include source names, credentials or VLC log strings.
enum VLCPlaybackError: Int, Error, LocalizedError {
    case source=1, engine, video, audio, geometry, time, seek, renderer, drain, timeout, rate
    var errorDescription:String? {
        let reason:String
        switch self {
        case .source:reason="來源讀取失敗或檔案已變更，請重新開啟影片。"
        case .engine:reason="VLC 播放器無法啟動這個檔案。"
        case .video:reason="這個視訊軌道無法以本候選的硬體解碼路徑播放。"
        case .audio:reason="本候選僅包含 AAC 音訊解碼，這個音軌無法播放。"
        case .geometry:reason="這個影片的裁切、旋轉或像素比例尚未接入 VLC 呈現路徑。"
        case .time:reason="影片時間資訊無效，已停止播放。"
        case .seek:reason="跳轉未能確認新的畫面與時間位置，已停止播放。請重新開啟影片。"
        case .renderer:reason="影片呈現尚未準備好，請重新開啟 VR 播放。"
        case .drain:reason="播放資源尚未完成清理，請關閉後重試。"
        case .timeout:reason="等候可呈現的影片畫面逾時，已停止播放。"
        case .rate:reason="這個影片無法套用選定倍率，已停止播放。"
        }
        return "MKV 無法播放："+reason
    }
}
private let vlcReadAt:@convention(c) (UnsafeMutableRawPointer?,UInt64,UnsafeMutablePointer<UInt8>?,Int)->Int = { opaque,offset,output,count in
    guard let opaque,let output else{return -1}
    return Unmanaged<AsyncInputContext>.fromOpaque(opaque).takeUnretainedValue().read(offset:offset,count:count,output:output)
}
private let vlcValidate:@convention(c) (UnsafeMutableRawPointer?)->Int32 = { opaque in
    guard let opaque else{return -1};return Unmanaged<AsyncInputContext>.fromOpaque(opaque).takeUnretainedValue().validate()
}
private let vlcEOF:@convention(c) (UnsafeMutableRawPointer?)->Int32 = { opaque in
    guard let opaque else{return -1};return Unmanaged<AsyncInputContext>.fromOpaque(opaque).takeUnretainedValue().verifyEOF()
}
struct VLCAppFrame:@unchecked Sendable {
    let pixel:CVPixelBuffer
    let metadata:VLCProbeMetadata
    var flow:PlaybackFlowToken {.init(metadata.trace_frame_id)}
    var displayEvidence:VLCDisplayRecoveryPolicy.Frame {metadata.displayEvidence}
    var seconds:Double {displayEvidence.ptsUS.map{Double($0)/1e6} ?? .nan}
}
extension VLCProbeMetadata {
    var displayEvidence:VLCDisplayRecoveryPolicy.Frame {
        .init(rawPTS:raw_pts,tickZero:tick_zero,ticksPerSecond:ticks_per_second,displayUS:display_tick,producer:producer_generation)
    }
}
struct VLCAppPoll:@unchecked Sendable {
    let frame:VLCAppFrame?
    var state:VLCVistaState
    var seekObservation=VLCVistaSeekObservation()
    let diagnostics:VLCProbeDiagnostics
    let sourceFailures:Int
    var rawMetadata:VLCProbeMetadata?
    var nativeDiagnostics=VLCVistaNativeDiagnostics()
    var ordinaryNativeRead=false
    var queuePressureSnapshot:vista_queue_pressure_snapshot_data?
    var frameStageSnapshot:vista_frame_stage_snapshot_data?
    var frameStageFinishStatus:Int32?
    var resumeSnapshot:vista_resume_snapshot_data?
    var resumeFinishStatus:Int32?
    var audioBoundarySnapshot:vista_audio_boundary_snapshot_data?
    var audioBoundaryFinishStatus:Int32?
    var mediaStats=VLCVistaMediaStats()
    var pipeline=VLCProbePipelineDiagnostics()
    var rawWidth=0,rawHeight=0
    var preparationError:VLCPlaybackError?
    var cropCopies:UInt64=0,cropAllocationFailures:UInt64=0
    var cropMaximumMS=0.0
}
/// Retains one already-read post-confirmation pressure sample across core initialization.
/// It never reads native counters or treats reuse as a second sample.
struct VLCQueueEvidenceHandoff {
    struct Identity:Equatable {
        let engine:ObjectIdentifier,sourceEpoch:UInt64?,presentation:UInt64,revision:UInt64,seekSequence:UInt64
        let rate:Double,codec:UInt32
    }
    static func flags(eligible:Bool,ready:Bool,paused:Bool,confirmed:Bool,valid:Bool,nativePaused:Bool,seeking:Bool,buffering:Bool,rate:Double,effective:Double,hasEngine:Bool)->Int64 {
        let values=[eligible,ready,!paused,confirmed,valid,!nativePaused,!seeking,!buffering,
                    rate.isFinite && rate>=2.5 && rate<=5,
                    effective.isFinite && abs(effective-rate)<=PlaybackAutomaticSpeedPolicy.effectiveRateTolerance,hasEngine]
        return values.enumerated().reduce(Int64(0)){$0 | ($1.element ? Int64(1)<<$1.offset:0)}
    }
    private(set) var pending:PlaybackQueuePressureSample?
    private var identity:Identity?
    private(set) var scopeSerial:UInt64=0,confirmedSinceUS:Int64=0
    private(set) var origin:Int64=0,reason:Int64=0
    mutating func reset(){pending=nil;identity=nil;confirmedSinceUS=0;scopeSerial &+= 1;origin=0;reason=2}
    mutating func select(fresh:PlaybackQueuePressureSample?,hadSnapshot:Bool,identity next:Identity?,observedUS:Int64,nowUS:Int64)->PlaybackQueuePressureSample? {
        origin=hadSnapshot ? 1:(pending == nil ? 0:2);reason=0
        if next != identity {if pending != nil {reason=6};pending=nil;identity=next;confirmedSinceUS=next == nil ? 0:observedUS;scopeSerial &+= 1}
        // The ordinary fresh path keeps its original conversion/policy semantics.
        // Additional ownership/post-confirmation gates apply only to retention/reuse.
        if hadSnapshot {
            pending=nil
            guard let fresh,fresh.consumptionFreshness(at:nowUS)==0 else{reason=3;return nil}
            return fresh
        }
        guard next != nil,observedUS>0,nowUS>=observedUS else {pending=nil;identity=nil;confirmedSinceUS=0;reason=2;return nil}
        let value=pending
        guard let value else {return nil}
        guard value.consumptionFreshness(at:nowUS)==0 else{pending=nil;reason=3;return nil}
        guard confirmedSinceUS>0,value.completedUS>confirmedSinceUS else{pending=nil;reason=4;return nil}
        return value
    }
    mutating func finish(_ offered:PlaybackQueuePressureSample?,outcome:PlaybackQueuePressurePolicy.Outcome,reset:PlaybackAutomaticSpeedPolicy.ResetReason,decision:Bool) {
        guard let offered else{return}
        guard !decision,outcome == .none else{pending=nil;reason=0;return}
        guard identity != nil,confirmedSinceUS>0 else{pending=nil;reason=2;return}
        guard offered.completedUS>confirmedSinceUS else{pending=nil;reason=4;return}
        guard reset == .manualRate || reset == .rateTransition || reset == .none else{pending=nil;reason=5;return}
        pending=offered;reason=1
    }
}

/// Two early evidence reads, one narrowly authorized old-context replacement,
/// plus the original two legacy reads per armed chain (maximum five).
/// Independent budgets preserve legacy recovery when the early candidate rejects.
/// No timer or new control task; requests ride the existing output poll.
struct VLCResyncSampleBudget {
    enum Phase:Int,Equatable,Sendable {case legacy=1,early=2}
    struct Identity: Equatable, Sendable {
        let revision:UInt64, presentation:UInt64
        let source:UInt64?
        let engine:ObjectIdentifier
        let chain:UInt64
    }
    struct Request: Equatable, Sendable {
        let identity:Identity
        let sequence:Int
        var phase:Phase = .legacy
    }
    private struct Lane {
        var issued=0,nextEarliestUS:Int64=0,waitingForOrdinaryBaseline=false
    }
    private(set) var chain:UInt64=0
    private var early=Lane(),legacy=Lane()
    private var firstOldContextIdentity:Identity?
    private var completedEarlyFirst:Request?
    private(set) var replacementBaselineUS:Int64=0
    private var replacementIdentity:Identity?
    private var completedEarlySecond:Request?
    private var earlyLimit:Int {replacementBaselineUS>0 ? 3:2}
    private(set) var notSevereSeed:VLCClockResyncPolicy.Input?
    private var notSevereIdentity:Identity?
    private var notSevereGranted=false
    private var notSevereHoldDeadline:Int64=0,notSevereLastValidatedUS:Int64=0
    private(set) var retrySequence:UInt64=0,retryReason:Int64=0,retryNowUS:Int64=0
    private(set) var retryFirstUS:Int64=0,retrySecondUS:Int64=0
    private(set) var retryQueueFirstUS:Int64=0,retryQueueSecondUS:Int64=0,retryQueueID:UInt64=0
    private(set) var retryScope:Identity?
    private(set) var retryRate:Double=0,retryHoldDeadline:Int64=0
    private mutating func retryChange(_ reason:Int64,_ now:Int64) {retryReason=reason;retryNowUS=now;retrySequence &+= 1}
    private mutating func discardNotSevere(_ reason:Int64,_ now:Int64) {
        guard notSevereSeed != nil else{return}
        notSevereSeed=nil;notSevereIdentity=nil;notSevereGranted=false
        replacementBaselineUS=0;replacementIdentity=nil
        early.waitingForOrdinaryBaseline=true;retryChange(reason,now)
    }
    mutating func invalidateNotSevere(nowUS:Int64) {discardNotSevere(4,nowUS)}
    mutating func finishNotSevere(nowUS:Int64) {discardNotSevere(6,nowUS)}
    mutating func captureNotSevere(_ request:Request,input:VLCClockResyncPolicy.Input,
                                  holdRate:Double,holdDeadline:Int64)->Bool {
        guard !cancelled,request==completedEarlyFirst,request.phase == .early,request.sequence==1,
              early.issued==1,firstOldContextIdentity==nil,notSevereSeed==nil,
              input.sampleUS>0,VLCNotSevereRetryWitness.seed(input),holdRate==input.selectedRate,
              holdDeadline>input.nowUS,earlyWindowStartUS>0,input.nowUS>=earlyWindowStartUS,
              input.nowUS-earlyWindowStartUS<=Self.earlyWindowUS else{return false}
        notSevereSeed=input;notSevereIdentity=request.identity;notSevereHoldDeadline=holdDeadline;notSevereLastValidatedUS=input.sampleUS
        notSevereGranted=false;early.waitingForOrdinaryBaseline=true
        retryFirstUS=input.sampleUS;retrySecondUS=0;retryQueueFirstUS=0;retryQueueSecondUS=0;retryQueueID=0
        retryScope=request.identity;retryRate=holdRate;retryHoldDeadline=holdDeadline
        retryChange(1,input.nowUS);return true
    }
    mutating func validateNotSevere(_ x:VLCClockResyncPolicy.Input,identity:Identity?,holdRate:Double,holdDeadline:Int64,freshRead:Bool=false) {
        guard let seed=notSevereSeed else{return}
        guard identity==notSevereIdentity,x.eligible,x.rateConfirmed,x.selectedRate==seed.selectedRate,
              x.effectiveRate.isFinite,abs(x.effectiveRate-seed.selectedRate)<=0.01,
              x.lastFrameAt==seed.lastFrameAt,holdRate==seed.selectedRate,holdDeadline==notSevereHoldDeadline else {
            discardNotSevere(4,x.nowUS);return
        }
        guard x.nowUS>=earlyWindowStartUS,x.nowUS-earlyWindowStartUS<=Self.earlyWindowUS,x.nowUS<holdDeadline else {
            discardNotSevere(5,x.nowUS);return
        }
        // A cached sample aging does not fabricate contradictory new evidence.
        if x.sampleUS<notSevereLastValidatedUS,freshRead {discardNotSevere(4,x.nowUS);return}
        guard x.sampleUS>notSevereLastValidatedUS else{return}
        guard VLCNotSevereRetryWitness.follows(x,seed) else {discardNotSevere(4,x.nowUS);return}
        notSevereLastValidatedUS=x.sampleUS;retrySecondUS=x.sampleUS;retryNowUS=x.nowUS
    }
    mutating func acceptsNotSevereCompletion(_ request:Request,nowUS:Int64,holdRate:Double,holdDeadline:Int64)->Bool {
        guard request.phase == .early,request.sequence>=2,notSevereGranted else{return true}
        guard let seed=notSevereSeed,request.identity==notSevereIdentity,holdRate==seed.selectedRate,
              holdDeadline==notSevereHoldDeadline,nowUS<holdDeadline,nowUS>=earlyWindowStartUS,
              nowUS-earlyWindowStartUS<=Self.earlyWindowUS else {
            discardNotSevere(5,nowUS);return false
        }
        return true
    }
    mutating func grantNotSevereQueue(nowUS:Int64,identity:Identity,holdRate:Double,holdDeadline:Int64,
                                      firstUS:Int64,secondUS:Int64,queueID:UInt64)->Bool {
        guard let seed=notSevereSeed,!cancelled,!notSevereGranted,identity==notSevereIdentity,
              early.issued==1,firstOldContextIdentity==nil,holdRate==seed.selectedRate,
              holdDeadline==notSevereHoldDeadline,nowUS<holdDeadline,
              firstUS>seed.sampleUS,secondUS>firstUS,secondUS<=nowUS,nowUS-secondUS<=100_000,
              queueID>0,nowUS>=earlyWindowStartUS,
              nowUS-earlyWindowStartUS<=Self.earlyWindowUS-VLCClockResyncPolicy.earlySpacingUS else{return false}
        notSevereGranted=true;early.waitingForOrdinaryBaseline=false
        retryQueueFirstUS=firstUS;retryQueueSecondUS=secondUS;retryQueueID=queueID
        retryChange(2,nowUS);return true
    }
    // Start once when the existing poll first sees a confirmed, eligible 2x
    // chain. Audio boundary delays may already have made the publish gap >1s.
    // A failed probe falls back immediately; no timer and no legacy budget use.
    static let earlyWindowUS:Int64=500_000
    static let firstProbeDelayUS:Int64=20_000
    private(set) var earlyWindowStartUS:Int64=0
    private var earlyWindowClosed=false
    private(set) var firstProbeNotBeforeUS:Int64=0
    mutating func samplingPhase(nowUS:Int64,eligible:Bool,legacyBaselineUS:Int64?=nil,settleOldContext:Bool=false)->Phase {
        guard eligible,!cancelled,nowUS>0 else{return .legacy}
        if earlyWindowStartUS==0 {
            earlyWindowStartUS=nowUS
            // A newly confirmed watch may precede the first new-context drop
            // by one render turn. Delay only the first probe, never refill or
            // extend the fixed window. The actual evidence pair still needs 150ms.
            let due=nowUS.addingReportingOverflow(Self.firstProbeDelayUS)
            firstProbeNotBeforeUS=due.overflow ? Int64.max:due.partialValue
            early.nextEarliestUS=max(early.nextEarliestUS,firstProbeNotBeforeUS)
        }
        // Supplemental reads must not postpone an already-due legacy pair.
        if let baseline=legacyBaselineUS,baseline>0,legacy.issued<2,!legacy.waitingForOrdinaryBaseline {
            let due=baseline.addingReportingOverflow(750_000)
            if !due.overflow,nowUS>=max(due.partialValue,legacy.nextEarliestUS) {return .legacy}
        }
        guard !earlyWindowClosed,nowUS>=earlyWindowStartUS,
              nowUS-earlyWindowStartUS<=Self.earlyWindowUS else {
            earlyWindowClosed=true;return .legacy
        }
        guard early.issued<earlyLimit,!early.waitingForOrdinaryBaseline else{return .legacy}
        return .early
    }
    var issued:Int {early.issued+legacy.issued}
    var earlyIssued:Int {early.issued}
    var legacyIssued:Int {legacy.issued}
    private var cancelled=true
    private var inFlight:Request?
    mutating func beginNewArmedChain() {
        notSevereSeed=nil;notSevereIdentity=nil;notSevereGranted=false
        chain &+= 1;early=Lane();legacy=Lane();cancelled=false;inFlight=nil;earlyWindowStartUS=0;earlyWindowClosed=false;firstProbeNotBeforeUS=0;firstOldContextIdentity=nil;completedEarlyFirst=nil;replacementBaselineUS=0;replacementIdentity=nil;completedEarlySecond=nil
    }
    mutating func cancel() {discardNotSevere(4,retryNowUS);cancelled=true;inFlight=nil}
    mutating func ordinaryBaseline(sampleUS:Int64,acceptedUS:Int64?,earlyAcceptedUS:Int64?=nil) {
        if sampleUS>0,acceptedUS==sampleUS {legacy.waitingForOrdinaryBaseline=false}
        if sampleUS>0,earlyAcceptedUS==sampleUS {early.waitingForOrdinaryBaseline=false}
    }
    mutating func request(nowUS:Int64,baselineUS:Int64?,identity:Identity,eligible:Bool,phase:Phase = .legacy)->Request? {
        var lane=phase == .early ? early:legacy
        guard eligible,!cancelled,inFlight==nil,identity.chain==chain,lane.issued<(phase == .early ? earlyLimit:2),
              nowUS>0,!lane.waitingForOrdinaryBaseline,
              phase == .early || lane.issued==0 || baselineUS != nil else{return nil}
        if phase == .early,notSevereGranted {
            guard earlyWindowStartUS>0,nowUS>=earlyWindowStartUS,nowUS-earlyWindowStartUS<=Self.earlyWindowUS else{return nil}
        }
        if phase == .early,lane.issued==2 {
            guard replacementBaselineUS>0,baselineUS==replacementBaselineUS,
                  identity==replacementIdentity,earlyWindowStartUS>0,
                  nowUS>=earlyWindowStartUS,nowUS-earlyWindowStartUS<=Self.earlyWindowUS else{return nil}
        }
        let spacing:Int64=phase == .early ? VLCClockResyncPolicy.earlySpacingUS:750_000
        var due=lane.nextEarliestUS
        if let baselineUS {
            let sum=baselineUS.addingReportingOverflow(spacing)
            guard baselineUS>0,!sum.overflow else{return nil}
            due=max(due,sum.partialValue)
        }
        guard nowUS>=due else{return nil}
        lane.issued += 1
        if phase == .early {early=lane}else{legacy=lane}
        let request=Request(identity:identity,sequence:lane.issued,phase:phase);inFlight=request
        return request
    }
    mutating func complete(_ request:Request,current:Identity?,completedUS:Int64)->Bool {
        guard !cancelled,inFlight==request,request.identity==current else{cancel();return false}
        inFlight=nil
        if request.phase == .early,request.sequence==1 {completedEarlyFirst=request}
        if request.phase == .early,request.sequence==2 {completedEarlySecond=request}
        let spacing:Int64=request.phase == .early ? VLCClockResyncPolicy.earlySpacingUS:750_000
        let sum=completedUS.addingReportingOverflow(spacing)
        if request.phase == .early {early.nextEarliestUS=sum.overflow ? Int64.max:sum.partialValue}
        else {legacy.nextEarliestUS=sum.overflow ? Int64.max:sum.partialValue}
        return true
    }
    mutating func rejectedSample(phase:Phase,oldContextOnly:Bool) {
        // No refill, no window extension, no override of legacy priority.
        if phase == .early,oldContextOnly,!cancelled,early.issued==1,notSevereSeed==nil {
            firstOldContextIdentity=completedEarlyFirst?.identity;return
        }
        if phase == .early {discardNotSevere(4,retryNowUS);firstOldContextIdentity=nil;completedEarlyFirst=nil;replacementBaselineUS=0;replacementIdentity=nil;completedEarlySecond=nil}
        requireOrdinaryBaseline(phase:phase)
    }
    /// Only a second actual read becoming a fresh severe baseline can replace
    /// the first old-context rejection OR the mutually exclusive, queue-gated
    /// not-severe witness. Ordinary samples never grant the third read.
    mutating func acceptedSample(_ request:Request,sampleUS:Int64,acceptedUS:Int64?)->Bool {
        guard !cancelled,(request.identity==firstOldContextIdentity ||
              (notSevereGranted && request.identity==notSevereIdentity && retrySecondUS==sampleUS)),request.phase == .early,request.sequence==2,
              early.issued==2,request==completedEarlySecond,sampleUS>0,acceptedUS==sampleUS,
              request.identity.chain==chain,replacementBaselineUS==0 else{return false}
        replacementBaselineUS=sampleUS;replacementIdentity=request.identity
        if notSevereGranted {retryChange(3,retryNowUS)}
        return true
    }
    mutating func requireOrdinaryBaseline(phase:Phase = .legacy) {
        if phase == .early {early.waitingForOrdinaryBaseline=true}else{legacy.waitingForOrdinaryBaseline=true}
    }
}

/// Scalar diagnostic packets. Their root ID links every field; they never feed
/// policy and remain subject to the recorder's explicit loss/retention limits.
enum VLCRecoveryFlow {
    static func integer(_ x:UInt64)->Int64 {Int64(bitPattern:x)}
    static func optional(_ x:Int64?)->Int64 {x ?? Int64.min}
    @discardableResult static func decision(action:Int64,command:UInt64,revision:UInt64,
                         policy:VLCClockResyncPolicy,budget:VLCResyncSampleBudget,
                         outcome:Int64,input:VLCClockResyncPolicy.Input?)->PlaybackFlowToken {
        let root=PlaybackFlowTrace.mark(.resyncDecision,a:action,b:integer(command),c:integer(revision))
        let e=policy.earlyEvidence
        PlaybackFlowTrace.point(root,.resyncState,a:outcome,b:Int64(policy.triggerPath.rawValue),c:integer(budget.chain))
        PlaybackFlowTrace.point(root,.resyncSamples,a:e.firstSampleUS,b:e.secondSampleUS,c:integer(e.sequence))
        PlaybackFlowTrace.point(root,.resyncPTS,a:e.firstDropPTS,b:e.secondDropPTS,c:Int64(e.reason.rawValue))
        PlaybackFlowTrace.point(root,.resyncLate,a:PlaybackFlowTrace.scalar(e.firstLateMS*1000),b:PlaybackFlowTrace.scalar(e.secondLateMS*1000),c:PlaybackFlowTrace.scalar(e.estimatedRemainingMS*1000))
        PlaybackFlowTrace.point(root,.resyncMapping,a:PlaybackFlowTrace.scalar(e.mappingErrorMS*1000),b:PlaybackFlowTrace.scalar(e.contextRate*1e6),c:integer(e.dropsAdvanced))
        PlaybackFlowTrace.point(root,.resyncReferences,a:integer(e.firstReference),b:integer(e.secondReference))
        PlaybackFlowTrace.point(root,.resyncReads,a:Int64(budget.earlyIssued),b:Int64(budget.legacyIssued),c:budget.earlyWindowStartUS)
        PlaybackFlowTrace.point(root,.resyncWindow,a:VLCResyncSampleBudget.earlyWindowUS,b:policy.armed ? 1:0,c:policy.spent ? 1:0)
        if let x=input {
            func pair(_ tag:Int64,_ a:Int64,_ b:Int64){PlaybackFlowTrace.point(root,.resyncProof,a:tag,b:a,c:b)}
            pair(1,x.nowUS,x.sampleUS);pair(2,x.queuePTS,x.queueTick);pair(3,x.dropPTS,x.dropTick)
            pair(4,integer(x.queueCount),integer(x.queueValid));pair(5,integer(x.queueInvalid),integer(x.queueRepeat))
            pair(6,integer(x.queueBackward),integer(x.admitted));pair(7,integer(x.pop),integer(x.lateDrop))
            pair(8,integer(x.renderNormal),integer(x.errors))
            pair(9,PlaybackFlowTrace.scalar(x.dropDeltaMS*1000),PlaybackFlowTrace.scalar(x.dropThresholdMS*1000))
            pair(10,PlaybackFlowTrace.scalar(x.dropRate*1e6),PlaybackFlowTrace.scalar(x.dropContextRate*1e6))
            pair(11,Int64(x.dropClockID),integer(x.dropReference))
            pair(12,(x.eligible ? 1:0)|(x.rateConfirmed ? 2:0)|(x.dropContextValid ? 4:0),0)
            pair(13,PlaybackFlowTrace.scalar(x.selectedRate*1e6),PlaybackFlowTrace.scalar(x.effectiveRate*1e6))
            pair(14,PlaybackFlowTrace.scalar(x.now*1e6),PlaybackFlowTrace.scalar(x.lastFrameAt*1e6))
        }
        let g=policy.costGuard
        func costPair(_ tag:Int64,_ a:Int64,_ b:Int64){PlaybackFlowTrace.point(root,.resyncProof,a:tag,b:a,c:b)}
        costPair(15,integer(g.sequence),Int64(g.reason.rawValue))
        costPair(16,integer(g.source?.nonce ?? 0),g.source?.commandUS ?? 0)
        costPair(17,g.source?.adoptedUS ?? 0,g.source?.durationUS ?? 0)
        costPair(18,PlaybackFlowTrace.scalar(g.remainingMS*1000),g.deadlineUS)
        costPair(19,Int64(g.history.count),integer(g.evictedNonce))
        costPair(20,integer(g.capture?.nonce ?? 0),(g.used ? 1:0))
        costPair(21,PlaybackFlowTrace.scalar((g.source?.rate ?? 0)*1e6),PlaybackFlowTrace.scalar((g.capture?.rate ?? 0)*1e6))
        costPair(22,g.capture?.runUS ?? 0,g.capture?.lastUS ?? 0)
        costPair(23,g.awaitingConfirmation ? 1:0,PlaybackFlowTrace.scalar(policy.recoveryRate*1e6))
        costPair(24,g.observation.nowUS,g.observation.invalidMask)
        costPair(25,g.observation.transportMask,PlaybackFlowTrace.scalar(g.observation.nativeRate*1e6))
        costPair(26,integer(g.observation.expectedNonce),integer(g.observation.observedNonce))
        costPair(27,g.observation.expectedEpoch,g.observation.observedEpoch)
        // Version 4: scope/transport causes survive outside armed policy input.
        PlaybackFlowTrace.point(root,.resyncProof,a:0,b:input == nil ? 13:27,c:4)
        return root
    }
    static func baseline(_ event:VLCResyncBaselineJournal.Event?,proof:PlaybackFlowToken = .none,
                         command:UInt64,revision:UInt64,policy:VLCClockResyncPolicy,budget:VLCResyncSampleBudget) {
        guard let e=event else{return}
        let root=PlaybackFlowTrace.mark(.resyncBaseline,parent:proof,a:Int64(e.reason),b:integer(command),c:integer(revision))
        func pair(_ tag:Int64,_ a:Int64,_ b:Int64){PlaybackFlowTrace.point(root,.resyncBaselineData,a:tag,b:a,c:b)}
        pair(1,e.before.legacy ?? 0,e.after.legacy ?? 0);pair(2,e.before.early ?? 0,e.after.early ?? 0)
        pair(3,e.sampleUS,e.nowUS);pair(4,Int64(e.oldFlags),Int64(e.newFlags))
        pair(5,integer(budget.chain),integer(e.sequence))
        pair(6,Int64(e.legacyOperation),Int64(e.earlyOperation))
        pair(7,e.cachedQualificationChanged ? 1:0,policy.oldContextRetrySampleUS ?? 0)
        pair(8,budget.firstProbeNotBeforeUS,budget.earlyWindowStartUS)
        pair(0,8,1)
    }
    static func automaticDecision(_ decision:PlaybackAutomaticSpeedPolicy.Decision,previous:Double) {
        let decisionProof=PlaybackFlowTrace.mark(.automaticDecision,a:Int64(decision.reason.rawValue),b:Int64(decision.sparseTrigger.rawValue),c:PlaybackFlowTrace.scalar(decision.nextSpeed*1e6))
        PlaybackFlowTrace.point(decisionProof,.automaticDecisionWindow,a:PlaybackFlowTrace.scalar(decision.observedSeconds*1e6),b:PlaybackFlowTrace.scalar(decision.maximumFrameGap*1e6),c:Int64(clamping:decision.advancingFrames))
        PlaybackFlowTrace.point(decisionProof,.automaticDecisionContext,a:PlaybackFlowTrace.scalar(previous*1e6),b:PlaybackFlowTrace.scalar(decision.clockAdvance*1e6),c:Int64(clamping:decision.outputPolls))
    }
    /// One plan, at most one replacement authorization and five reads per chain.
    static func probe(action:Int64,sequence:Int,oldContext:Bool,budget:VLCResyncSampleBudget,
                      nowUS:Int64,sampleUS:Int64,dropRate:Double,contextRate:Double,
                      revision:UInt64,presentation:UInt64,authorizedRate:Double)->PlaybackFlowToken {
        let root=(action==0 || action==3) ? PlaybackFlowTrace.mark(.resyncProbe,a:action,b:integer(budget.chain),c:action==0 ? (oldContext ? 1:0):Int64(sequence)):
            PlaybackFlowTrace.begin(.resyncProbe,a:action,b:integer(budget.chain),c:Int64(sequence))
        PlaybackFlowTrace.point(root,.resyncProbeTiming,a:budget.earlyWindowStartUS,b:budget.firstProbeNotBeforeUS,c:nowUS)
        PlaybackFlowTrace.point(root,.resyncProbeCached,a:sampleUS,b:PlaybackFlowTrace.scalar(dropRate*1e6),c:PlaybackFlowTrace.scalar(contextRate*1e6))
        PlaybackFlowTrace.point(root,.resyncProbeScope,a:integer(revision),b:integer(presentation),c:PlaybackFlowTrace.scalar(authorizedRate*1e6))
        return root
    }
    static func notSevereRetry(_ b:VLCResyncSampleBudget) {
        let root=PlaybackFlowTrace.mark(.resyncRetry,a:b.retryReason,b:integer(b.chain),c:integer(b.retrySequence))
        PlaybackFlowTrace.point(root,.resyncRetryNative,a:b.retryFirstUS,b:b.retrySecondUS,c:b.retryNowUS)
        PlaybackFlowTrace.point(root,.resyncRetryQueue,a:b.retryQueueFirstUS,b:b.retryQueueSecondUS,c:integer(b.retryQueueID))
        PlaybackFlowTrace.point(root,.resyncRetryScope,a:b.retryScope.map{integer($0.revision)} ?? -1,
            b:b.retryScope.map{integer($0.presentation)} ?? -1,c:b.retryScope?.source.map{integer($0)} ?? -1)
        PlaybackFlowTrace.point(root,.resyncRetryOutcome,a:b.earlyWindowStartUS+VLCResyncSampleBudget.earlyWindowUS,
            b:b.retryHoldDeadline,c:PlaybackFlowTrace.scalar(b.retryRate*1e6))
    }
    static func audio(_ r:VLCAudioBoundaryRecord) {
        let n=r.native
        let root=PlaybackFlowTrace.mark(.audioSummary,a:integer(r.command),b:integer(r.revision),c:n.map{integer($0.episode)} ?? 0)
        PlaybackFlowTrace.point(root,.audioIdentity,a:n.map{integer($0.instance)} ?? 0,b:integer(r.session),c:Int64(n?.valid ?? 0))
        PlaybackFlowTrace.point(root,.audioMetadata,a:Int64(r.outcome.rawValue),b:Int64(r.origin.rawValue),c:PlaybackFlowTrace.scalar(r.requestedRate*1e6))
        PlaybackFlowTrace.point(root,.audioSetter,a:r.commandIntentNativeUS,b:optional(r.setterReturnUS),c:optional(n?.command_us))
        if let n {
            PlaybackFlowTrace.point(root,.audioChange,a:optional(n.change_us),b:optional(n.block_us),c:PlaybackFlowTrace.scalar((n.audioRate ?? .nan)*1e6))
            PlaybackFlowTrace.point(root,.audioBoundary,a:optional(n.boundary_system_us),b:optional(n.boundary_audio_us),c:optional(n.enqueue_date_us))
            PlaybackFlowTrace.point(root,.audioEnqueue,a:optional(n.enqueue_us),b:optional(n.fifo_after_enqueue_us),c:optional(n.block_length_us))
            PlaybackFlowTrace.point(root,.audioCounters,a:integer(n.reports),b:integer(n.rejected),c:integer(n.accepted))
            PlaybackFlowTrace.point(root,.audioNativeEnd,a:Int64(n.endReason),b:optional(n.end_us),c:optional(r.snapshotNativeUS))
            PlaybackFlowTrace.point(root,.audioFirstReport,a:optional(n.first_report_us),b:optional(n.first_report_system_us),c:optional(n.first_report_audio_us))
            PlaybackFlowTrace.point(root,.audioLastReport,a:optional(n.last_report_us),b:optional(n.last_report_system_us),c:optional(n.last_report_audio_us))
            PlaybackFlowTrace.point(root,.audioReject,a:optional(n.first_reject_us),b:optional(n.last_reject_us),c:optional(n.last_reject_system_us))
            PlaybackFlowTrace.point(root,.audioAccept,a:optional(n.accept_us),b:optional(n.accept_system_us),c:optional(n.accept_audio_us))
            PlaybackFlowTrace.point(root,.audioClock,a:optional(n.accept_clock_audio_us),b:optional(n.watch_accept_us),c:optional(n.first_reject_system_us))
            PlaybackFlowTrace.point(root,.audioWatch,a:optional(n.watch_us),b:optional(n.watch_system_us),c:optional(n.watch_audio_us))
            PlaybackFlowTrace.point(root,.audioWatchPTS,a:optional(n.watch_native_audio_us),b:optional(n.watch_pts_offset_us))
        }
        PlaybackFlowTrace.point(root,.audioSummaryEnd,a:n == nil ? 0:1,b:integer(r.summariesEmitted),c:integer(r.summariesSuppressed))
    }
}

/// Serialized LibVLC control queue. Blocking join never runs on MainActor.
actor VLCAppEngine {
    private var pointer:OpaquePointer?
    nonisolated let context:AsyncInputContext
    private var closing=false
    private let visiblePixels=VLCVisiblePixels()
    private var mediaStats=VLCVistaMediaStats(),lastStatsAt:Int64=0
    private var lastQueuePressureAt:Int64=0
    private var nativeDiagnostics=VLCVistaNativeDiagnostics()
    init(window:LocalWindowByteSource) {context=AsyncInputContext(window:window)}
    func start()throws {
        guard pointer==nil,!closing else{throw VLCPlaybackError.engine}
        guard let p=VLCVistaCreate(Unmanaged.passUnretained(context).toOpaque(),context.source.knownSize,vlcReadAt,vlcValidate,vlcEOF) else{throw VLCPlaybackError.engine}
        pointer=p
        guard VLCProbeEnginePlay(p)==0 else{throw VLCPlaybackError.engine}
    }
    func poll(flowParent:PlaybackFlowToken = .none,audioEndReason:UInt32?=nil,observeAudio:Bool=false,observeSeek:Bool=false,resumeEndReason:UInt32?=nil,observeResume:Bool=false,observeFrame:Bool=false,observeQueuePressure:Bool=false)->VLCAppPoll? {
        let flow=PlaybackFlowTrace.begin(.pollActor,parent:flowParent);defer{PlaybackFlowTrace.end(flow,.pollActor)}
        guard !closing,let p=pointer else{return nil}
        var frame:VLCAppFrame?
        var rawMetadata:VLCProbeMetadata?
        var rawWidth=0,rawHeight=0,preparationError:VLCPlaybackError?
        if let snapshot=PlaybackFlowTrace.measure(.frameCopy,parent:flow,{VLCProbeEngineTakeSnapshot(p)}) {
            rawMetadata=VLCProbeSnapshotMetadata(snapshot)
            if let pixel=VLCProbeSnapshotCopyPixel(snapshot) {
                let metadata=VLCProbeSnapshotMetadata(snapshot)
                rawWidth=CVPixelBufferGetWidth(pixel);rawHeight=CVPixelBufferGetHeight(pixel)
                do{frame=VLCAppFrame(pixel:try PlaybackFlowTrace.measure(.pixelPrepare,parent:.init(metadata.trace_frame_id)){try visiblePixels.prepare(pixel,format:metadata.picture)},metadata:metadata)}
                catch VLCVisiblePixels.Failure.backpressure{frame=nil}
                catch{preparationError = .geometry;frame=VLCAppFrame(pixel:pixel,metadata:metadata)}
            }
            VLCProbeSnapshotRelease(snapshot)
        }
        var audioBoundarySnapshot:vista_audio_boundary_snapshot_data?,audioBoundaryFinishStatus:Int32?
        if let reason=audioEndReason {
            var status:Int32=0;audioBoundarySnapshot=VLCVistaAudioFinish(p,reason,&status);audioBoundaryFinishStatus=status
        }
        var frameStageSnapshot:vista_frame_stage_snapshot_data?,frameStageFinishStatus:Int32?
        var resumeSnapshot:vista_resume_snapshot_data?,resumeFinishStatus:Int32?
        if let reason=resumeEndReason {
            var status:Int32=0;resumeSnapshot=VLCVistaResumeFinish(p,reason,&status);resumeFinishStatus=status
            status=0;frameStageSnapshot=VLCVistaFrameFinish(p,reason,&status);frameStageFinishStatus=status
        }
        let state=VLCVistaGetState(p)
        var queuePressureSnapshot:vista_queue_pressure_snapshot_data?
        // This read is tiny and bounded to 5Hz only during a confirmed high-rate
        // playback request. It never scans the continuous Flow record store.
        if observeQueuePressure,state.timer_valid,!state.timer_paused,!state.timer_seeking,
           !state.paused,!state.buffering,state.watch_rate>=2.5,state.timer_now_us>0,
           state.timer_now_us>=lastQueuePressureAt,state.timer_now_us-lastQueuePressureAt>=200_000 {
            lastQueuePressureAt=state.timer_now_us
            queuePressureSnapshot=PlaybackFlowTrace.measure(.queuePressureRead,parent:flow){VLCVistaQueuePressure(p)}
        }
        let ordinaryNativeRead=state.timer_now_us>0 && state.timer_now_us-lastStatsAt>=1_000_000
        if ordinaryNativeRead {
            PlaybackFlowTrace.anchor()
            mediaStats=VLCVistaGetMediaStats(p);nativeDiagnostics=VLCVistaGetNativeDiagnostics(p);lastStatsAt=state.timer_now_us
            if observeAudio,audioBoundarySnapshot==nil {audioBoundarySnapshot=VLCVistaAudioSnapshot(p)}
            if observeResume,resumeSnapshot==nil {resumeSnapshot=VLCVistaResumeSnapshot(p)}
            if observeFrame,frameStageSnapshot==nil {frameStageSnapshot=VLCVistaFrameSnapshot(p)}
        }
        return VLCAppPoll(frame:frame,state:state,seekObservation:observeSeek ? VLCVistaGetSeekObservation(p):VLCVistaSeekObservation(),diagnostics:VLCProbeEngineDiagnostics(p),sourceFailures:context.snapshot().sourceFailures,rawMetadata:rawMetadata,nativeDiagnostics:nativeDiagnostics,ordinaryNativeRead:ordinaryNativeRead,queuePressureSnapshot:queuePressureSnapshot,frameStageSnapshot:frameStageSnapshot,frameStageFinishStatus:frameStageFinishStatus,resumeSnapshot:resumeSnapshot,resumeFinishStatus:resumeFinishStatus,audioBoundarySnapshot:audioBoundarySnapshot,audioBoundaryFinishStatus:audioBoundaryFinishStatus,mediaStats:mediaStats,pipeline:VLCProbeEnginePipelineDiagnostics(p),rawWidth:rawWidth,rawHeight:rawHeight,preparationError:preparationError,cropCopies:visiblePixels.copies,cropAllocationFailures:visiblePixels.allocationFailures,cropMaximumMS:visiblePixels.maximumMS)
    }
    struct ResyncSample:Sendable {
        let state:VLCVistaState
        let diagnostics:VLCVistaNativeDiagnostics
        let completedUS:Int64
    }
    /// The ordinary cache/deadline is deliberately untouched. A request is
    /// serialized with controls, and only the driver may accept its identity.
    func sampleClockResync(expectedRate:Double=2)->ResyncSample? {
        guard !closing,let pointer,VLCClockResyncPolicy.validRecoveryRate(expectedRate) else{return nil}
        let state=VLCVistaGetState(pointer)
        guard state.timer_valid,!state.timer_paused,!state.timer_seeking,!state.paused,!state.buffering,
              state.timer_time_us>=0,state.length_us>state.timer_time_us,
              abs(Double(state.rate)-expectedRate)<=0.01,abs(state.watch_rate-expectedRate)<=0.01 else{return nil}
        let diagnostics=VLCVistaGetNativeDiagnostics(pointer)
        return ResyncSample(state:state,diagnostics:diagnostics,completedUS:VLCVistaClock())
    }
    func pause(_ paused:Bool)->Int64 {
        let flow=PlaybackFlowTrace.begin(.controlActor,a:1,b:paused ? 1:0);defer{PlaybackFlowTrace.end(flow,.controlActor)}
        guard !closing,let pointer else{return 0}
        VLCVistaPause(pointer,paused);return VLCVistaClock()
    }
    func rate(_ rate:Double,session:UInt64,command:UInt64,revision:UInt64,seekNonce:UInt64,paused:Bool)->VLCVistaResumeRateReceipt {
        let flow=PlaybackFlowTrace.begin(.controlActor,a:2,b:Int64(command),c:Int64(revision));defer{PlaybackFlowTrace.end(flow,.controlActor)}
        guard !closing,let pointer else{var receipt=VLCVistaResumeRateReceipt();receipt.audio.rate.status = -1;receipt.audio.mark.status=2;receipt.mark.status=2;return receipt}
        return VLCVistaResumeRate(pointer,Float(rate),session,command,revision,seekNonce,paused)
    }
    func finishFrame(_ reason:UInt32)->(vista_frame_stage_snapshot_data,Int32)? {
        guard !closing,let pointer else{return nil}
        var status:Int32=0;let snapshot=VLCVistaFrameFinish(pointer,reason,&status);return(snapshot,status)
    }
    func finishResume(_ reason:UInt32)->(vista_resume_snapshot_data,Int32)? {
        guard !closing,let pointer else{return nil}
        var status:Int32=0;let snapshot=VLCVistaResumeFinish(pointer,reason,&status)
        return(snapshot,status)
    }
    func finishAudio(_ reason:UInt32)->(vista_audio_boundary_snapshot_data,Int32)? {
        guard !closing,let pointer else{return nil}
        var status:Int32=0;let snapshot=VLCVistaAudioFinish(pointer,reason,&status);return(snapshot,status)
    }
    struct ManualSeekReceipt {let commandClock:Int64,observationID:UInt64}
    func seek(_ seconds:Double)->ManualSeekReceipt? {
        let flow=PlaybackFlowTrace.begin(.controlActor,a:3,b:PlaybackFlowTrace.scalar(seconds*1e6));defer{PlaybackFlowTrace.end(flow,.controlActor)}
        guard !closing,let pointer,seconds.isFinite,seconds>=0,seconds<Double(Int64.max)/1e6 else{return nil}
        let previousFlowParent=VFSetParent(flow.id)
        let receipt=VLCVistaSeekObserved(pointer,Int64((seconds*1e6).rounded()))
        _ = VFSetParent(previousFlowParent)
        guard receipt.status==0 else{return nil}
        return ManualSeekReceipt(commandClock:VLCVistaClock(),observationID:receipt.command_id)
    }
    struct ResyncReceipt { let target:Double, commandClock:Int64, watchFloor:UInt64 }
    /// Read the clock and submit the precise seek in ONE serialized actor call.
    /// No trigger-time target survives renderer/source awaits.
    func seekCurrentTime(expectedNormal:UInt64,minimumLateDrop:UInt64,early:VLCClockResyncPolicy.EarlyDispatchEvidence?=nil,
                         flowCommand:UInt64,flowRevision:UInt64,flowNonce:UInt64,expectedRate:Double=2)->ResyncReceipt? {
        let flow=PlaybackFlowTrace.begin(.resyncDispatch,a:VLCRecoveryFlow.integer(flowCommand),b:VLCRecoveryFlow.integer(flowRevision),c:VLCRecoveryFlow.integer(flowNonce))
        var gate:Int64=1,status:Int64=Int64.min,target:Int64=Int64.min,commandClock:Int64=0
        defer {
            PlaybackFlowTrace.point(flow,.resyncDispatchEnd,a:gate,b:target,c:commandClock)
            PlaybackFlowTrace.end(flow,.resyncDispatch,a:gate,b:status,c:VLCVistaClock())
        }
        func pair(_ tag:Int64,_ a:Int64,_ b:Int64){PlaybackFlowTrace.point(flow,.resyncDispatchData,a:tag,b:a,c:b)}
        pair(1,VLCRecoveryFlow.integer(expectedNormal),VLCRecoveryFlow.integer(minimumLateDrop))
        guard !closing,let pointer else{return nil}
        gate=2
        guard VLCClockResyncPolicy.validRecoveryRate(expectedRate),early == nil || abs(early!.rate-expectedRate)<=0.001 else{return nil}
        let state=VLCVistaGetState(pointer)
        pair(2,(state.timer_valid ? 1:0)|(state.timer_paused ? 2:0)|(state.timer_seeking ? 4:0)|(state.paused ? 8:0)|(state.buffering ? 16:0),state.timer_time_us)
        pair(3,PlaybackFlowTrace.scalar(Double(state.rate)*1e6),PlaybackFlowTrace.scalar(state.watch_rate*1e6))
        pair(4,state.length_us,VLCRecoveryFlow.integer(state.watch_updates))
        guard state.timer_valid,!state.timer_paused,!state.timer_seeking,!state.paused,!state.buffering,
              state.timer_time_us>=0,state.length_us>state.timer_time_us,
              abs(Double(state.rate)-expectedRate)<0.01,abs(state.watch_rate-expectedRate)<0.01 else{return nil}
        // This is fresh dispatch evidence, distinct from the triggering packet.
        gate=3
        let d=VLCVistaGetNativeDiagnostics(pointer),now=VLCVistaClock()
        pair(5,d.available ? Int64(d.version):0,d.sample_clock_us)
        pair(6,d.ticks_per_second,VLCRecoveryFlow.integer(d.render_normal))
        pair(7,VLCRecoveryFlow.integer(d.late_drop),d.drop_tick)
        pair(8,d.drop_system_delta,d.drop_threshold)
        pair(9,PlaybackFlowTrace.scalar(d.drop_rate*1e6),PlaybackFlowTrace.scalar(d.drop_context_rate*1e6))
        pair(10,Int64(d.drop_clock_id),VLCRecoveryFlow.integer(d.drop_reference_generation))
        pair(11,d.drop_pts,now);pair(12,d.queue_pts,d.queue_tick)
        pair(13,d.drop_context_valid ? 1:0,early == nil ? 0:1)
        if let early {pair(14,early.sampleUS,early.dropPTS)}
        guard d.available,(d.version==1 || d.version==2),d.ticks_per_second==1_000_000,
              d.render_normal==expectedNormal,d.late_drop>=minimumLateDrop,
              d.drop_tick>0,d.drop_tick<=now,now-d.drop_tick<=250_000,
              d.drop_system_delta < -max(50_000,d.drop_threshold),abs(d.drop_rate-expectedRate)<0.01 else{return nil}
        gate=4
        // Higher-rate recovery must never use legacy evidence from another clock rate.
        if expectedRate>2 {
            guard d.version==2,d.drop_context_valid,abs(d.drop_context_rate-expectedRate)<=0.01 else{return nil}
        }
        if let early {
            guard early.permits(nowUS:now,pts:d.drop_pts,tick:d.drop_tick,
                deltaMS:Double(d.drop_system_delta)/1000,thresholdMS:Double(d.drop_threshold)/1000,
                clockID:d.drop_clock_id,contextValid:d.drop_context_valid,
                contextRate:d.drop_context_rate,reference:d.drop_reference_generation) else{return nil}
        }
        gate=5;target=state.timer_time_us
        pair(15,target,VLCVistaClock())
        let previousFlowParent=VFSetParent(flow.id)
        status=Int64(VLCVistaSeek(pointer,target));commandClock=VLCVistaClock()
        _ = VFSetParent(previousFlowParent)
        guard status==0 else{return nil}
        gate=0
        return ResyncReceipt(target:Double(target)/1e6,commandClock:commandClock,watchFloor:state.watch_updates)
    }
    func close()async throws {
        guard !closing else{return};closing=true;context.invalidate()
        // The C bridge joins VLC callbacks. Independently retained Swift pixels are
        // cleared and the real renderers drained by the caller before this point.
        if let pointer {
            guard VLCProbeEngineDestroy(pointer) else{throw VLCPlaybackError.drain}
            self.pointer=nil
        }
        if let task=context.taskAfterJoin(){await task.value}
        let witness=try await context.source.retireAndDrain(stamp:context.stamp)
        guard BridgeDrainAck.sourceConfirms(witness,stamp:context.stamp) else{throw VLCPlaybackError.drain}
        try await context.source.closeAfterDrain()
        context.clearTaskAfterDrain();visiblePixels.reset()
    }
}

/// Ordinary 1 Hz diagnostics, or a newer accepted bounded resync sample.
/// Control/stop records reuse the dated sample; no extra log fields are added.
struct VLCNativeDiagnosticsMapping {
    static let maximum:UInt64=9_007_199_254_740_991
    static let fields:[PlaybackLogField]=[.vlcNativeDiagVersion,.vlcNativeDiagSampleClock,.vlcNativeDiagAgeMS,.vlcNativeQueueCount,.vlcNativeQueueValid,.vlcNativeQueueInvalid,.vlcNativeQueueRepeat,.vlcNativeQueueBackward,.vlcNativeDeliveryAdmitted,.vlcNativeDeliveryInvalid,.vlcNativeDeliveryNoVout,.vlcNativeDeliveryWaitAbort,.vlcNativeDeliveryFlushAbort,.vlcNativeDeliveryPreroll,.vlcNativeDeliveryPrevframe,.vlcNativeFifoPop,.vlcNativeFifoEmpty,.vlcNativeLateDrop,.vlcNativeRenderNormal,.vlcNativeRenderForced,.vlcNativeRenderRedisplay,.vlcNativeQueuePTS,.vlcNativePoppedPTS,.vlcNativeDropPTS,.vlcNativeQueueClock,.vlcNativeDropClock,.vlcNativeDropSystemDeltaMS,.vlcNativeDropProcessMS,.vlcNativeDropThresholdMS,.vlcNativeDropRate,.vlcNativeDropClockID]
    static func signed(_ value:Int64)->Double {Double(max(-Int64(maximum),min(Int64(maximum),value)))}
    static func values(_ value:VLCVistaNativeDiagnostics,nowUS:Int64)->[PlaybackLogField:Double] {
        guard value.available,(value.version==1 || value.version==2),value.ticks_per_second>0 else{return [:]}
        let scale=Double(value.ticks_per_second)
        var result:[PlaybackLogField:Double]=[.vlcNativeDiagVersion:Double(value.version),
            .vlcNativeDiagSampleClock:signed(value.sample_clock_us)/1e6,
            .vlcNativeDiagAgeMS:max(0,(signed(nowUS)-signed(value.sample_clock_us))/1000)]
        result[.vlcNativeQueueCount]=Double(min(value.queue_count,maximum))
        result[.vlcNativeQueueValid]=Double(min(value.queue_valid,maximum))
        result[.vlcNativeQueueInvalid]=Double(min(value.queue_invalid,maximum))
        result[.vlcNativeQueueRepeat]=Double(min(value.queue_repeat,maximum))
        result[.vlcNativeQueueBackward]=Double(min(value.queue_backward,maximum))
        result[.vlcNativeDeliveryAdmitted]=Double(min(value.delivery_admitted,maximum))
        result[.vlcNativeDeliveryInvalid]=Double(min(value.delivery_invalid,maximum))
        result[.vlcNativeDeliveryNoVout]=Double(min(value.delivery_no_vout,maximum))
        result[.vlcNativeDeliveryWaitAbort]=Double(min(value.delivery_wait_abort,maximum))
        result[.vlcNativeDeliveryFlushAbort]=Double(min(value.delivery_flush_abort,maximum))
        result[.vlcNativeDeliveryPreroll]=Double(min(value.delivery_preroll,maximum))
        result[.vlcNativeDeliveryPrevframe]=Double(min(value.delivery_prevframe,maximum))
        result[.vlcNativeFifoPop]=Double(min(value.fifo_pop,maximum))
        result[.vlcNativeFifoEmpty]=Double(min(value.fifo_empty,maximum))
        result[.vlcNativeLateDrop]=Double(min(value.late_drop,maximum))
        result[.vlcNativeRenderNormal]=Double(min(value.render_normal,maximum))
        result[.vlcNativeRenderForced]=Double(min(value.render_forced,maximum))
        result[.vlcNativeRenderRedisplay]=Double(min(value.render_redisplay,maximum))
        if value.queue_valid>0 && value.queue_pts != value.tick_invalid {result[.vlcNativeQueuePTS]=(signed(value.queue_pts)-signed(value.tick_zero))/scale}
        if value.fifo_pop>0 && value.popped_pts != value.tick_invalid {result[.vlcNativePoppedPTS]=(signed(value.popped_pts)-signed(value.tick_zero))/scale}
        if value.late_drop>0 && value.drop_pts != value.tick_invalid {result[.vlcNativeDropPTS]=(signed(value.drop_pts)-signed(value.tick_zero))/scale}
        if value.queue_count>0 {result[.vlcNativeQueueClock]=signed(value.queue_tick)/(scale)}
        if value.late_drop>0 {result[.vlcNativeDropClock]=signed(value.drop_tick)/(scale)}
        if value.late_drop>0 {result[.vlcNativeDropSystemDeltaMS]=signed(value.drop_system_delta)/(scale/1000)}
        if value.late_drop>0 {result[.vlcNativeDropProcessMS]=signed(value.drop_process)/(scale/1000)}
        if value.late_drop>0 {result[.vlcNativeDropThresholdMS]=signed(value.drop_threshold)/(scale/1000)}
        if value.late_drop>0 {
            if value.drop_rate.isFinite {result[.vlcNativeDropRate]=value.drop_rate}
            result[.vlcNativeDropClockID]=Double(value.drop_clock_id)
        }
        return result
    }
}

/// Fixed scalars only, no source identity or raw VLC messages. Counts saturate at
/// the exact JSON/Double integer range. This observation does not control playback.
struct VLCControlDiagnostics {
    static let maximum:UInt64=9_007_199_254_740_991
    private(set) var polls:UInt64=0,noFrame:UInt64=0,published:UInt64=0,clockRejected:UInt64=0,seekRejected:UInt64=0
    private var previousPoll:Double?
    private var rejectionBegan:Double?
    private(set) var rejectionStreak:UInt64=0,rejectionRecoveries:UInt64=0
    private(set) var maximumRejectionMS=0.0,publishedPTS = -1.0
    private var detail:[PlaybackLogField:Double]=[:]
    private(set) var maxPollGapMS=0.0,framePTS = -1.0,clockDeltaMS=0.0,producer=0.0
    private(set) var nativeTime = -1.0,watchUpdates=0.0,nativeState=0.0,nativePaused=0.0,requestedRate=1.0,framesTaken=0.0,sourceFailures=0.0,audioErrors=0.0,audioTiming=0.0,hardware=0.0
    static func bounded(_ value:UInt64)->Double{Double(min(value,maximum))}
    static func increment(_ value:inout UInt64){if value<maximum{value += 1}}
    mutating func observeNative(_ diagnostics:VLCVistaNativeDiagnostics,nowUS:Int64) {
        for field in VLCNativeDiagnosticsMapping.fields {detail[field]=nil}
        detail.merge(VLCNativeDiagnosticsMapping.values(diagnostics,nowUS:nowUS)){_,new in new}
    }
    mutating func observe(_ poll:VLCAppPoll,now:Double){
        Self.increment(&polls)
        observeNative(poll.nativeDiagnostics,nowUS:poll.state.timer_now_us)
        detail[.vlcDisplaySnapshot]=poll.rawMetadata == nil ? 0:1
        detail[.vlcDisplayCropReady]=poll.frame == nil ? 0:1
        detail[.vlcRawDisplayPTS]=poll.rawMetadata?.displayEvidence.ptsUS.map{Double($0)/1e6} ?? -1
        if poll.mediaStats.available {
            detail[.vlcDecodedVideo]=Self.bounded(poll.mediaStats.decoded_video)
            detail[.vlcDisplayedPictures]=Self.bounded(poll.mediaStats.displayed_pictures)
            detail[.vlcLatePictures]=Self.bounded(poll.mediaStats.late_pictures)
            detail[.vlcLostPictures]=Self.bounded(poll.mediaStats.lost_pictures)
        } else {
            for key:PlaybackLogField in [.vlcDecodedVideo,.vlcDisplayedPictures,.vlcLatePictures,.vlcLostPictures]{detail[key]=nil}
        }
        detail[.vlcVideoCodec]=Double(poll.state.video_codec)
        detail[.vlcWatchRate]=poll.state.watch_rate;detail[.vlcTimerClock]=Double(poll.state.timer_time_us)/1e6
        detail[.vlcTimerValid]=poll.state.timer_valid ? 1:0;detail[.vlcTimerPaused]=poll.state.timer_paused ? 1:0
        detail[.vlcTimerSeeking]=poll.state.timer_seeking ? 1:0;detail[.vlcNativeBuffering]=poll.state.buffering ? 1:0
        detail[.vlcWatchSeeks]=Self.bounded(poll.state.watch_seeks)
        if let began=rejectionBegan{maximumRejectionMS=max(maximumRejectionMS,max(0,now-began)*1000)}
        detail[.vlcCropCopies]=Self.bounded(poll.cropCopies);detail[.vlcCropMaxMS]=poll.cropMaximumMS;detail[.vlcCropAllocationFailures]=Self.bounded(poll.cropAllocationFailures)
        let pipeline=poll.pipeline
        detail[.vlcVTSubmit]=Self.bounded(pipeline.events.0.count);detail[.vlcVTCallback]=Self.bounded(pipeline.events.1.count)
        detail[.vlcVTNewPicture]=Self.bounded(pipeline.events.8.count);detail[.vlcVTDPBInsert]=Self.bounded(pipeline.events.10.count)
        detail[.vlcVTQueueVideo]=Self.bounded(pipeline.events.11.count);detail[.vlcVoutPrepare]=Self.bounded(pipeline.events.14.count)
        detail[.vlcVoutDisplay]=Self.bounded(pipeline.events.15.count);detail[.vlcVTCallbackDropped]=Self.bounded(pipeline.events.19.count)
        detail[.vlcVTCallbackRejected]=Self.bounded(pipeline.events.1.rejected);detail[.vlcVoutPrepareRejected]=Self.bounded(pipeline.events.14.rejected)
        detail[.vlcVTSubmitStatus]=Double(pipeline.events.0.last_status);detail[.vlcVTCallbackStatus]=Double(pipeline.events.1.last_status)
        detail[.vlcPipelineFirstReject]=Double(pipeline.first_rejected_event_plus1);detail[.vlcPipelineFirstStatus]=Double(pipeline.first_reject_status);detail[.vlcPipelineFirstDetail]=Double(pipeline.first_reject_detail)
        if let frame=poll.frame {
            let p=frame.metadata.picture
            detail[.vlcPixelFormat]=Double(CVPixelBufferGetPixelFormatType(frame.pixel));detail[.vlcCodedWidth]=Double(p.coded_width);detail[.vlcCodedHeight]=Double(p.coded_height)
            detail[.vlcVisibleWidth]=Double(p.visible_width);detail[.vlcVisibleHeight]=Double(p.visible_height);detail[.vlcOffsetX]=Double(p.x_offset);detail[.vlcOffsetY]=Double(p.y_offset)
            detail[.vlcPixelWidth]=Double(poll.rawWidth);detail[.vlcPixelHeight]=Double(poll.rawHeight);detail[.vlcSARNum]=Double(p.sar_num);detail[.vlcSARDen]=Double(p.sar_den);detail[.vlcOrientation]=Double(p.orientation)
        }
        if let previousPoll{maxPollGapMS=max(maxPollGapMS,max(0,now-previousPoll)*1000)};previousPoll=now
        nativeTime=Double(poll.state.time_us)/1e6;watchUpdates=Self.bounded(poll.state.watch_updates)
        nativeState=Double(poll.diagnostics.state);nativePaused=poll.state.paused ? 1:0;requestedRate=Double(poll.state.rate)
        framesTaken=Self.bounded(poll.diagnostics.frames_taken);sourceFailures=Double(poll.sourceFailures)
        audioErrors=Double(poll.diagnostics.audio_error_logs);audioTiming=Double(poll.diagnostics.audio_timing_logs);hardware=Self.bounded(poll.diagnostics.vt_hardware)
        if let frame=poll.frame {framePTS=frame.seconds;clockDeltaMS=(framePTS-nativeTime)*1000;producer=Self.bounded(frame.metadata.producer_generation)}
        else{Self.increment(&noFrame)}
    }
    mutating func didPublish(pts:Double,now:Double){
        Self.increment(&published);publishedPTS=pts
        if let began=rejectionBegan{Self.increment(&rejectionRecoveries);maximumRejectionMS=max(maximumRejectionMS,max(0,now-began)*1000)}
        rejectionBegan=nil;rejectionStreak=0
    }
    mutating func rejectedClock(now:Double){Self.increment(&clockRejected);Self.increment(&rejectionStreak);if rejectionBegan==nil{rejectionBegan=now}}
    mutating func interruptRejection(){rejectionBegan=nil;rejectionStreak=0}
    mutating func rejectedSeek(){Self.increment(&seekRejected)}
    func values()->[PlaybackLogField:Double]{var values:[PlaybackLogField:Double]=[
        .vlcSchema:3,.vlcPublishedPTS:publishedPTS,.vlcClockRejectStreak:Self.bounded(rejectionStreak),.vlcClockRejectRecoveries:Self.bounded(rejectionRecoveries),.vlcClockRejectMaximumMS:maximumRejectionMS,.decoder:hardware>0 ? 1:-1,.vlcNativeTime:nativeTime,.vlcFramePTS:framePTS,.vlcClockDeltaMS:clockDeltaMS,
        .vlcWatchUpdates:watchUpdates,.vlcNativeState:nativeState,.vlcNativePaused:nativePaused,.vlcRequestedRate:requestedRate,
        .vlcPolls:Self.bounded(polls),.vlcNoFramePolls:Self.bounded(noFrame),.vlcFramesTaken:framesTaken,.vlcFramesPublished:Self.bounded(published),
        .vlcClockRejected:Self.bounded(clockRejected),.vlcSeekRejected:Self.bounded(seekRejected),.vlcSourceFailures:sourceFailures,
        .vlcMaxPollGapMS:maxPollGapMS,.vlcAudioErrorLogs:audioErrors,.vlcAudioTimingLogs:audioTiming,.vlcProducerToken:producer];values.merge(detail){_,new in new};return values}
}

/// Candidate-only adapter into the existing Vista state, frame, speed and source contracts.
@MainActor final class VLCPlaybackDriver {
    private var engine:VLCAppEngine?
    private var active=true,sceneActive=true,ready=false,waiting=false
    private(set) var paused=false
    private var automatic=VLCAutomaticSpeedAdapter()
    private var queueEvidence=VLCQueueEvidenceHandoff()
    private var resumeSeekIdentity=VLCResumeSeekIdentity()
    private var frameStage=VLCFrameStageObserver()
    private var resumeBoundary=VLCResumeObserver()
    private var resumeInterruption:VLCResumeRecord.Outcome?
    private var audioBoundary=VLCAudioBoundaryObserver(),audioCommand:UInt64=0
    private var audioOrigin=VLCAudioBoundaryRecord.Origin.manual
    private var audioInterruption:VLCAudioBoundaryRecord.Outcome?
    private var clockResync=VLCClockResyncPolicy()
    private struct ResyncCostScope {
        let engine:ObjectIdentifier,epoch:UInt64?,nonce:UInt64,rate:Double
    }
    private var resyncCostScope:ResyncCostScope?
    private var healthyRecovery=VLCKnownHealthyRecovery()
    private var healthSampling=VLCHealthSampleBudget()
    private var healthSample:(request:VLCHealthSampleBudget.Request,diagnostics:VLCVistaNativeDiagnostics,applied:Bool)?
    private var healthyLoggedSequence:UInt64=0
    private var earlyEvidenceRecords=0
    private var resyncBaselineJournal=VLCResyncBaselineJournal()
    private var resyncLastInput:VLCClockResyncPolicy.Input?
    private var resyncSampling=VLCResyncSampleBudget()
    private var retryPressure=PlaybackQueuePressurePolicy()
    private var retryPressureSeedUS:Int64=0
    private var retryPressurePrevious:PlaybackQueuePressureSample?
    private var emittedRetrySequence:UInt64=0
    private var resyncSample:(identity:VLCResyncSampleBudget.Identity,diagnostics:VLCVistaNativeDiagnostics)?
    private var resyncOutcome=0.0,resyncTarget = -1.0,resyncTriggerClock = -1.0,resyncCommandClock=0.0,resyncObservedMS=0.0
    var selectedSpeed:Double{automatic.selectedSpeed}
    private var appliedPause:Bool?
    var sourceState:(()->(epoch:UInt64?,recovering:Bool))?
    private var sourceRecovering=false
    private var currentSourceEpoch:UInt64?
    private var automaticRecovery=PlaybackAutomaticRecoveryDiagnostics()
    private var automaticEvents=0,automaticSuppressed=0
    private var flowOwned=false
    private let speedSession=UInt64(ProcessInfo.processInfo.systemUptime*1_000_000)
    private var frameSession=UUID(),presentationTicket:UInt64=0
    private var duration=0.0,lastFrameAt=0.0
    private var onState:((NativePlaybackSession.State)->Void)?
    private var onSpeed:((PlaybackSpeedStatus)->Void)?
    // Completion/stop can change source activity without a new UI state.
    var seekSourceSnapshot:(()->PlaybackSeekSourceSnapshot?)?
    private var seekObservations=PlaybackVLCSeekDiagnostics()
    private var seekSummary=PlaybackVLCSeekSummary()
    private var seekObservationPollAt=0.0
    private var seekObservationLastReject:[PlaybackVLCSeekDiagnostics.Scalar:Double]=[:]
    var onPrefetchActivityChanged:(()->Void)?
    var clearPresentation:(()->Void)?
    var drainPresentation:((Bool)async throws->Void)?
    private(set) var failureMessage:String?
    private(set) var diagnosticsText="VLC 候選／等待硬體解碼確認"
    private var controlDiagnostics=VLCControlDiagnostics()
    private var displayPolicy=VLCDisplayRecoveryPolicy()
    private var displayEvents=0,displaySuppressed=0,displayEpisodeEvents=0
    private var lastDisplayResult:VLCDisplayRecoveryPolicy.Result?
    private var controlEvents=0,controlSuppressed=0
    private var terminalReason=0.0
    var logValues:[PlaybackLogField:Double]{
        var values=controlDiagnostics.values()
        values[.selectedSpeed]=selectedSpeed;values[.effectiveRate]=automatic.effectiveRate
        let policy=automatic.diagnostics
        values[.autoSpeedBaselineReady]=policy.baselineReady ? 1:0;values[.autoSpeedAwaitingRateStart]=policy.awaitingRateStart ? 1:0
        values[.autoSpeedLastResetReason]=Double(policy.lastResetReason.rawValue);values[.autoSpeedResetCount]=VLCControlDiagnostics.bounded(policy.resetCount)
        values[.vlcRateConfirmed]=automatic.rateConfirmed ? 1:0;values[.vlcCommandRevision]=VLCControlDiagnostics.bounded(automatic.revision)
        values[.vlcStaleCompletions]=VLCControlDiagnostics.bounded(automatic.staleCompletions)
        values[.vlcAutomaticEvents]=Double(automaticEvents);values[.vlcAutomaticSuppressed]=Double(automaticSuppressed)
        values[.vlcPauseIntent]=paused ? 1:0
        values[.vlcResyncAttempts]=VLCControlDiagnostics.bounded(clockResync.triggerCount)
        values[.vlcResyncOutcome]=resyncOutcome;values[.vlcResyncTarget]=resyncTarget
        values[.vlcResyncTriggerClock]=resyncTriggerClock;values[.vlcResyncCommandClock]=resyncCommandClock
        values[.vlcResyncObservedMS]=resyncObservedMS
        values[.vlcResyncPath]=Double(clockResync.triggerPath.rawValue)
        let early=clockResync.earlyEvidence
        values[.vlcResyncEarlyReason]=Double(early.reason.rawValue)
        values[.vlcResyncEarlyFirstSampleUS]=Double(early.firstSampleUS)
        values[.vlcResyncEarlySecondSampleUS]=Double(early.secondSampleUS)
        values[.vlcResyncEarlyFirstPTS]=Double(early.firstDropPTS)/1e6
        values[.vlcResyncEarlySecondPTS]=Double(early.secondDropPTS)/1e6
        values[.vlcResyncEarlyFirstLateMS]=early.firstLateMS
        values[.vlcResyncEarlySecondLateMS]=early.secondLateMS
        values[.vlcResyncEarlyRemainingMS]=early.estimatedRemainingMS
        values[.vlcResyncEarlyMappingErrorMS]=early.mappingErrorMS
        values[.vlcResyncEarlyContextRate]=early.contextRate
        values[.vlcResyncEarlyFirstReference]=VLCControlDiagnostics.bounded(early.firstReference)
        values[.vlcResyncEarlySecondReference]=VLCControlDiagnostics.bounded(early.secondReference)
        values[.vlcResyncEarlyDropsAdvanced]=VLCControlDiagnostics.bounded(early.dropsAdvanced)
        values[.vlcResyncEarlyReads]=Double(resyncSampling.earlyIssued)
        values[.vlcResyncLegacyReads]=Double(resyncSampling.legacyIssued)
        values[.vlcSeekNonce]=VLCControlDiagnostics.bounded(currentSeek?.nonce ?? pendingSeek?.nonce ?? presentationTicket)
        values[.vlcSeekTarget]=currentSeek?.target ?? pendingSeek?.target ?? -1
        values[.vlcSeekSuppressed]=seekGate?.suppressed == true ? 1:0
        values[.vlcControlSuppressed]=Double(controlSuppressed)
        values[.vlcDisplayRecovered]=Double(displayPolicy.recoveryCount)
        values[.vlcDisplayNonadvancing]=Double(displayPolicy.nonadvancingCount)
        values[.vlcDisplayTimelineRejected]=Double(displayPolicy.timelineRejected)
        values[.vlcDisplaySuppressed]=Double(displaySuppressed)
        values[.vlcTerminalReason]=terminalReason
        return values
    }
    private func emitControl(_ action:Double){
        PlaybackFlowTrace.mark(.control,a:Int64(action),b:Int64(audioCommand),c:Int64(automatic.revision))
        if action==10 {
            let root=VLCRecoveryFlow.decision(action:10,command:audioCommand,revision:automatic.revision,
                policy:clockResync,budget:resyncSampling,outcome:Int64(resyncOutcome),input:resyncLastInput)
            PlaybackFlowTrace.point(root,.resyncMilestones,a:1,b:PlaybackFlowTrace.scalar(resyncTriggerClock*1e6),c:PlaybackFlowTrace.scalar(resyncTarget*1e6))
            PlaybackFlowTrace.point(root,.resyncMilestones,a:2,b:PlaybackFlowTrace.scalar(resyncCommandClock*1e6),c:PlaybackFlowTrace.scalar(resyncObservedMS*1000))
        }
        displayEpisodeEvents=0;lastDisplayResult=nil
        guard controlEvents<128 else{controlSuppressed=min(1_000_000,controlSuppressed+1);return}
        controlEvents += 1
        var values=logValues;values[.vlcControlAction]=action
        values[.vlcAudioSession]=Double(speedSession);values[.vlcAudioCommand]=Double(audioCommand)
        PlaybackLogStore.shared.enqueue(PlaybackLogRecord(event:.vlcControl,values:values))
    }
    private func audioVideo(_ poll:VLCAppPoll?=nil)->VLCAudioBoundaryRecord.Video {
        var values=logValues
        if let poll {
            for field in VLCNativeDiagnosticsMapping.fields {values[field]=nil}
            values.merge(VLCNativeDiagnosticsMapping.values(poll.nativeDiagnostics,nowUS:poll.state.timer_now_us)){_,new in new}
            values[.vlcVTSubmit]=VLCControlDiagnostics.bounded(poll.pipeline.events.0.count)
            values[.vlcVTCallback]=VLCControlDiagnostics.bounded(poll.pipeline.events.1.count)
            values[.vlcWatchUpdates]=VLCControlDiagnostics.bounded(poll.state.watch_updates)
        }
        return .init(values,at:poll==nil ? seekObservationPollAt:ProcessInfo.processInfo.systemUptime,
                     nativeNowUS:poll?.state.timer_now_us ?? VLCVistaClock())
    }
    private func audioReason(_ outcome:VLCAudioBoundaryRecord.Outcome)->UInt32 {
        switch outcome {case .pause:return 2;case .seek:return 3;case .source:return 4;case .superseded:return 1;default:return 5}
    }
    private func audioMarker(command:UInt64,phase:Double,outcome:Double,clock:Int64,rate:Double,revision:UInt64,epoch:UInt64?,bytes:Int=0) {
        let status=PlaybackLogStore.shared.status
        var values:[LifecycleField:Double]=[.scope:134,.session:Double(speedSession),.command:Double(command),
            .phase:phase,.outcome:outcome,.nativeClock:Double(clock),.rate:rate,.revision:Double(revision),
            .recordBytes:Double(bytes),.logDropped:Double(status.dropped),.logFailures:Double(status.failures)]
        if let epoch {values[.epoch]=Double(epoch)}
        LifecycleDiagnostics.shared.record(.playbackAudioBoundary,values)
    }
    private func emitAudio(_ record:VLCAudioBoundaryRecord?) {
        guard let record else{return}
        VLCRecoveryFlow.audio(record)
        let value=PlaybackLogRecord(audioBoundary:record)
        let bytes=(try? JSONEncoder().encode(value).count) ?? 0
        PlaybackLogStore.shared.enqueue(value)
        audioMarker(command:record.command,phase:2,outcome:Double(record.outcome.rawValue),clock:VLCVistaClock(),
            rate:record.requestedRate,revision:record.revision,epoch:record.sourceEpoch,bytes:bytes)
    }
    private func observeAudio(_ poll:VLCAppPoll,interruption:VLCAudioBoundaryRecord.Outcome?) {
        guard let snapshot=poll.audioBoundarySnapshot else{return}
        if let interruption {
            emitAudio(audioBoundary.finish(interruption,snapshot:snapshot,finishStatus:poll.audioBoundaryFinishStatus,after:audioVideo(poll)))
        } else {emitAudio(audioBoundary.observe(snapshot,after:audioVideo(poll)))}
    }
    private func emitFrame(_ records:[VLCFrameStageRecord]) {
        for record in records {PlaybackLogStore.shared.enqueue(PlaybackLogRecord(frameStages:record))}
    }
    private func observeFrame(_ poll:VLCAppPoll,interruption:VLCResumeRecord.Outcome?) {
        if let interruption {
            emitFrame(frameStage.finish(VLCFrameStageRecord.Outcome(rawValue:interruption.rawValue) ?? .unavailable,
                snapshot:poll.frameStageSnapshot,nativeFinishStatus:poll.frameStageFinishStatus,nowUS:poll.state.timer_now_us))
        } else if let snapshot=poll.frameStageSnapshot {
            emitFrame(frameStage.observe(snapshot,nowUS:poll.state.timer_now_us))
        }
    }
    private func emitResume(_ records:[VLCResumeRecord]) {
        for record in records {PlaybackLogStore.shared.enqueue(PlaybackLogRecord(resumeObservation:record))}
    }
    private func observeResume(_ poll:VLCAppPoll,interruption:VLCResumeRecord.Outcome?) {
        if let interruption {
            emitResume(resumeBoundary.finish(interruption,snapshot:poll.resumeSnapshot,nativeFinishStatus:poll.resumeFinishStatus,nowUS:poll.state.timer_now_us))
        } else if let snapshot=poll.resumeSnapshot {
            emitResume(resumeBoundary.observe(snapshot,nowUS:poll.state.timer_now_us))
        }
    }
    /// Passive diagnostic checkpoints. No await, source call, cache-map copy or playback decision.
    private func observeSeek(_ stage:PlaybackVLCSeekDiagnostics.Stage,nonce:UInt64?=nil,
                             poll:VLCAppPoll?=nil,seek:Seek?=nil,completionPath:Int=0) {
        guard seekObservations.isActive(nonce:nonce) else{return}
        let now=ProcessInfo.processInfo.systemUptime
        typealias S=PlaybackVLCSeekDiagnostics.Scalar
        let pairs:[(S,PlaybackLogField)]=[
            (.rawPTS,.vlcRawDisplayPTS),(.clock,.vlcNativeTime),(.watchUpdates,.vlcWatchUpdates),
            (.nativeSampleClock,.vlcNativeDiagSampleClock),(.nativeAgeMS,.vlcNativeDiagAgeMS),
            (.nativeQueueClock,.vlcNativeQueueClock),(.nativeQueuePTS,.vlcNativeQueuePTS),
            (.nativeQueueCount,.vlcNativeQueueCount),(.nativePreroll,.vlcNativeDeliveryPreroll),
            (.nativeAdmitted,.vlcNativeDeliveryAdmitted),(.nativeFlushAbort,.vlcNativeDeliveryFlushAbort),
            (.nativeFifoPop,.vlcNativeFifoPop),(.nativePoppedPTS,.vlcNativePoppedPTS),
            (.nativeNormal,.vlcNativeRenderNormal),(.nativeLateDrop,.vlcNativeLateDrop),
            (.nativeVersion,.vlcNativeDiagVersion),(.vtSubmit,.vlcVTSubmit),(.vtCallback,.vlcVTCallback),
            (.framesTaken,.vlcFramesTaken),(.seekRejected,.vlcSeekRejected),(.publishedPTS,.vlcPublishedPTS),
            (.polls,.vlcPolls),(.maxPollGapMS,.vlcMaxPollGapMS),(.timerValid,.vlcTimerValid),
            (.timerSeeking,.vlcTimerSeeking),(.buffering,.vlcNativeBuffering)]
        let sampled=controlDiagnostics.values()
        var values:[S:Double]=[:]
        if stage == .accepted {values[.completionPath]=Double(completionPath)}
        for (key,field) in pairs {values[key]=sampled[field]}
        values[.pollAt]=seekObservationPollAt
        values.merge(seekObservationLastReject){_,new in new}
        if let poll,let seek,let policy=seekGate?.policy {
            values[.framePresent]=poll.frame==nil ? 0:1
            values[.watchFloor]=VLCControlDiagnostics.bounded(seek.updates)
            values[.commandClock]=Double(seek.commandClock)/1e6
            values[.gateMask]=Double(PlaybackVLCSeekDiagnostics.gateMask(frame:poll.frame != nil,
                ptsUS:poll.frame?.displayEvidence.ptsUS,targetUS:Int64((seek.target*1e6).rounded()),
                clockUS:poll.state.time_us,watchUpdates:poll.state.watch_updates,
                watchFloor:seek.updates,halfWindowUS:policy.halfWindowUS))
            values[.nativeAvailable]=poll.nativeDiagnostics.available ? 1:0
        }
        if let record=seekObservations.record(stage,nonce:nonce,now:now,values:values,source:seekSourceSnapshot?()) {
            seekSummary.observe(record)
            PlaybackLogStore.shared.enqueue(PlaybackLogRecord(vlcSeek:record))
        }
    }
    var prefetchAllowed:Bool{active && sceneActive && !paused && pendingSeek==nil && currentSeek==nil}
    var prefetchInvalidation:PrefetchInvalidationReason{!active ? .playbackInactive:!sceneActive ? .sceneInactive:pendingSeek != nil || currentSeek != nil ? .seek:paused ? .pause:.disabled}
    var speedStatus:PlaybackSpeedStatus{.init(selected:selectedSpeed,effectiveRate:automatic.effectiveRate,ready:ready,supportsFastForward:true,paused:paused,waiting:waiting)}
    func setSceneActive(_ active:Bool){
        PlaybackFlowTrace.mark(.controlIntent,a:4,b:active ? 1:0)
        sceneActive=active
        if !active{interruptAutomatic(.background);paused=true;onState?(.paused);onSpeed?(speedStatus)}
    }
    func pause(){PlaybackFlowTrace.mark(.controlIntent,a:1,b:1);interruptAutomatic(.pause);paused=true;onState?(.paused);onSpeed?(speedStatus)}
    func resume(){PlaybackFlowTrace.mark(.controlIntent,a:1,b:0);guard active,sceneActive else{return};interruptAutomatic(.pause,resumeEnd:false);paused=false;onState?(.playing);onSpeed?(speedStatus)}
    func setSpeed(_ rate:Double)->Bool{
        PlaybackFlowTrace.mark(.controlIntent,a:2,b:PlaybackFlowTrace.scalar(rate*1e6),c:Int64(automatic.revision))
        guard active,ready,speedStatus.accepts(rate) else{return false}
        interruptClockResync(preserveHealthy:true)
        emitRecovery(automaticRecovery.interrupt(.manualRate,now:ProcessInfo.processInfo.systemUptime))
        audioOrigin = .manual
        automatic.manualRate(rate,now:ProcessInfo.processInfo.systemUptime);onSpeed?(speedStatus);return true
    }
    private func emitRecovery(_ record:PlaybackAutomaticRecoveryDiagnostics.Record?) {
        guard let record else{return}
        PlaybackFlowTrace.mark(.observerEnd,a:Int64(record.sequence),b:Int64(record.reason.rawValue),c:Int64(record.milestoneMask))
        PlaybackLogStore.shared.enqueue(PlaybackLogRecord(automaticRecovery:record,session:speedSession))
    }
    private func interruptAutomatic(_ reason:PlaybackAutomaticRecoveryDiagnostics.EndReason,resumeEnd:Bool=true) {
        if reason == .seek || reason == .stopped {resumeSeekIdentity.clear()}
        if resumeEnd {
            switch reason {case .pause,.background:resumeInterruption = .pause;case .seek:resumeInterruption = .seek;case .stopped:resumeInterruption = .stopped;default:resumeInterruption = .source}
        }
        switch reason {case .pause,.background:audioInterruption = .pause;case .seek:audioInterruption = .seek;case .stopped:audioInterruption = .stopped;default:audioInterruption = .source}
        interruptClockResync()
        automatic.interrupt();controlDiagnostics.interruptRejection()
        emitRecovery(automaticRecovery.interrupt(reason,now:ProcessInfo.processInfo.systemUptime))
    }
    private func refreshSourceState() {
        let state=sourceState?() ?? (epoch:nil,recovering:false)
        if sourceRecovering != state.recovering || currentSourceEpoch != state.epoch {PlaybackFlowTrace.mark(.state,a:4,b:state.recovering ? 1:0,c:Int64(state.epoch ?? 0))}
        if currentSourceEpoch != state.epoch || (!sourceRecovering && state.recovering) {
            resetRecoverySource()
        }
        sourceRecovering=state.recovering;currentSourceEpoch=state.epoch
        resumeSeekIdentity.source(epoch:state.epoch,recovering:state.recovering)
        if let seek=currentSeek,(seek.isResync || seek.observationID>0),seek.dispatched,
           seek.sourceEpoch != state.epoch || (seek.observationID>0 && state.recovering) {
            // Accepted native work cannot be undone. Never publish its evidence
            // under a different source epoch; a new explicit seek may supersede it.
            currentSeek?.sourceInvalidated=true
        }
        if automatic.observeSource(epoch:state.epoch,recovering:state.recovering) {
            audioInterruption = .source
            resumeInterruption = .source
            interruptClockResync()
            displayPolicy.invalidateTimeline()
            controlDiagnostics.interruptRejection()
            emitRecovery(automaticRecovery.interrupt(state.recovering ? .sourceFailure:.sourceEpoch,now:ProcessInfo.processInfo.systemUptime))
        }
    }
    private func updateAutomatic(now:Double,poll:VLCAppPoll,publishedPTS:Double?) {
        let t=poll.state
        PlaybackFlowTrace.mark(.watch,a:Int64(t.watch_updates),b:PlaybackFlowTrace.scalar(t.watch_rate*1e6),c:t.timer_valid ? t.timer_time_us:t.time_us)
        automatic.observeTiming(.init(sequence:t.watch_updates,seekSequence:t.watch_seeks,
            rate:t.watch_rate,clock:Double(t.timer_valid ? t.timer_time_us:t.time_us)/1e6,
            valid:t.timer_valid,paused:t.timer_paused || t.paused,seeking:t.timer_seeking,buffering:t.buffering))
        let eligible=active && sceneActive && !sourceRecovering && pendingSeek==nil && currentSeek==nil &&
            !poll.diagnostics.ended && duration>0 && Double(t.time_us)/1e6<duration
        let clock=Double(t.timer_valid ? t.timer_time_us:t.time_us)/1e6
        if eligible && !paused && ready && now-lastFrameAt>=0.2 {PlaybackFlowTrace.trigger(1)}
        if eligible && !paused {
            emitRecovery(automaticRecovery.observe(now:now,effectiveRate:automatic.effectiveRate,
                playing:!t.timer_paused && !t.timer_seeking && !t.buffering,waiting:t.buffering,
                clock:clock,outputPolled:true,copiedFramePTS:publishedPTS))
        }
        let previous=selectedSpeed
        let pressure=poll.queuePressureSnapshot
        let pressureNow=(pressure != nil || queueEvidence.pending != nil) ? VLCVistaClock():t.timer_now_us
        var pressureFreshness=0
        let queueSample:PlaybackQueuePressureSample?=pressure.flatMap {p in
            guard p.abi_version==1,p.status==0 else{pressureFreshness=4;return nil}
            let sample=PlaybackQueuePressureSample(generation:p.decoder_generation,epoch:p.queue_epoch,id:p.queue_id,depth:p.dequeue_depth,
                completed:p.completed,pacerUS:p.pacer_us,lost:p.lost,snapshotUS:p.snapshot_us,
                enqueueUS:p.enqueue_us,dequeueUS:p.dequeue_us,completedUS:p.completed_us,pts:p.pts,videoCodec:t.video_codec)
            pressureFreshness=sample.consumptionFreshness(at:pressureNow)
            return pressureFreshness==0 ? sample:nil
        }
        let wasHolding=healthyRecovery.holding
        let deferReduction=healthyRecovery.suppression(nowUS:t.timer_now_us)
        if wasHolding && !deferReduction {clockResync.retargetFloor(now:now);emitHealthyRecovery()}
        let queueContextFlags=VLCQueueEvidenceHandoff.flags(eligible:eligible,ready:ready,paused:paused,
            confirmed:automatic.rateConfirmed,valid:t.timer_valid,nativePaused:t.timer_paused || t.paused,
            seeking:t.timer_seeking,buffering:t.buffering,rate:previous,effective:automatic.effectiveRate,hasEngine:engine != nil)
        let queueIdentity:VLCQueueEvidenceHandoff.Identity? = queueContextFlags==2047 ? engine.map {
            .init(engine:ObjectIdentifier($0),sourceEpoch:currentSourceEpoch,presentation:presentationTicket,
                  revision:automatic.revision,seekSequence:t.watch_seeks,rate:previous,codec:t.video_codec)
        }:nil
        let reportedQueue=queueSample ?? queueEvidence.pending
        let reportQueueEvidence=pressure != nil || queueEvidence.pending != nil
        let offeredQueue=queueEvidence.select(fresh:queueSample,hadSnapshot:pressure != nil,identity:queueIdentity,
            observedUS:t.timer_now_us,nowUS:pressureNow)
        let decision=automatic.update(now:now,ready:ready,eligible:eligible,paused:paused,outputPolled:true,
            publishedPTS:publishedPTS,queueSample:offeredQueue,deferReductions:deferReduction)
        queueEvidence.finish(offeredQueue,outcome:automatic.policy.queuePressure.outcome,
            reset:automatic.diagnostics.lastResetReason,decision:decision != nil)
        if reportQueueEvidence {
            let proof=PlaybackFlowTrace.mark(.queueEvidenceContext,a:queueEvidence.origin,b:queueEvidence.reason,c:queueContextFlags)
            PlaybackFlowTrace.point(proof,.queueEvidenceScope,a:VLCRecoveryFlow.integer(queueEvidence.scopeSerial),
                b:VLCRecoveryFlow.integer(queueIdentity?.revision ?? automatic.revision),c:VLCRecoveryFlow.integer(presentationTicket))
            PlaybackFlowTrace.point(proof,.queueEvidenceResult,a:VLCRecoveryFlow.integer(offeredQueue?.id ?? reportedQueue?.id ?? 0),
                b:Int64(automatic.policy.queuePressure.outcome.rawValue),c:queueEvidence.confirmedSinceUS)
            PlaybackFlowTrace.point(proof,.queueEvidenceClock,a:offeredQueue?.snapshotUS ?? reportedQueue?.snapshotUS ?? 0,
                b:offeredQueue?.completedUS ?? reportedQueue?.completedUS ?? 0,c:pressureNow)
        }
        if let p=pressure {
            let proof=PlaybackFlowTrace.mark(.queuePressureSample,a:Int64(clamping:p.decoder_generation),
                b:Int64(clamping:p.queue_epoch),c:Int64(clamping:p.queue_id))
            PlaybackFlowTrace.point(proof,.queuePressureTiming,a:p.enqueue_us,b:p.dequeue_us,c:p.completed_us)
            PlaybackFlowTrace.point(proof,.queuePressureProgress,a:p.pts,b:Int64(clamping:p.dequeue_depth),c:Int64(clamping:p.completed))
            PlaybackFlowTrace.point(proof,.queuePressureResult,a:Int64(clamping:p.pacer_us),b:Int64(clamping:p.lost),
                c:pressureFreshness==0 ? Int64(automatic.policy.queuePressure.outcome.rawValue):-Int64(pressureFreshness))
            PlaybackFlowTrace.point(proof,.queuePressureRead,a:Int64(pressureFreshness),b:pressureNow,
                c:pressureNow>=p.completed_us && p.completed_us>0 ? pressureNow-p.completed_us:Int64.max)
            PlaybackFlowTrace.point(proof,.queuePressureDecision,a:p.snapshot_us,b:PlaybackFlowTrace.scalar(previous*1e6),
                c:(Int64(p.abi_version)<<32)|Int64(p.status))
            PlaybackFlowTrace.point(proof,.queuePressureThreshold,a:t.video_codec==0x30395056 ? 250_000:400_000,
                b:Int64(t.video_codec),c:t.video_codec==0x30395056 ? 1:0)
        }
        offerNotSevereQueue(queueSample,nowUS:pressureNow)
        if let decision {
            VLCRecoveryFlow.automaticDecision(decision,previous:previous)
            PlaybackFlowTrace.trigger(2)
            audioOrigin = .automatic
            let wasArmed=clockResync.armed
            let knownReturn=healthyRecovery.beginReturn(nowUS:t.timer_now_us,rate:decision.nextSpeed)
            clockResync.automaticDrop(now:now,authorizedRate:knownReturn ? decision.nextSpeed:2)
            emitHealthyRecovery()
            if !wasArmed,clockResync.armed {resyncSampling.beginNewArmedChain();resyncSample=nil;earlyEvidenceRecords=0;resyncLastInput=nil;resyncBaselineJournal.newChain()}
            emitRecovery(automaticRecovery.begin(sequence:decision.sequence,now:now,previousSpeed:previous,
                targetSpeed:decision.nextSpeed,decisionClock:clock,lastFramePTS:controlDiagnostics.publishedPTS,
                healthyReferenceFPS:decision.healthyReferenceFPS,trackPublications:true))
            if automaticEvents<16 {
                automaticEvents += 1
                PlaybackLogStore.shared.enqueue(PlaybackLogRecord(automaticSpeed:decision,session:speedSession,previous:previous))
                emitControl(9)
            } else {automaticSuppressed=min(1_000_000,automaticSuppressed+1)}
            onSpeed?(speedStatus)
        }
        updateClockResync(now:now,poll:poll,publishedPTS:publishedPTS,eligible:eligible)
    }
    private func emitBaseline(_ event:VLCResyncBaselineJournal.Event?,proof:PlaybackFlowToken = .none) {
        VLCRecoveryFlow.baseline(event,proof:proof,command:audioCommand,revision:automatic.revision,
                                 policy:clockResync,budget:resyncSampling)
    }
    private func recordResync(_ outcome:Double) {resyncOutcome=outcome;emitControl(10)}
    private var resyncCostLoggedSequence:UInt64=0
    private func emitResyncCost() {
        guard resyncCostLoggedSequence != clockResync.costGuard.sequence else{return}
        resyncCostLoggedSequence=clockResync.costGuard.sequence
        VLCRecoveryFlow.decision(action:14,command:audioCommand,revision:automatic.revision,
            policy:clockResync,budget:resyncSampling,outcome:Int64(resyncOutcome),input:nil)
    }
    private func emitHealthyRecovery() {
        guard healthyLoggedSequence != healthyRecovery.sequence else{return}
        healthyLoggedSequence=healthyRecovery.sequence
        let p=healthyRecovery.proof ?? healthyRecovery.consumed
        let root=PlaybackFlowTrace.mark(.healthyRecovery,a:Int64(clamping:healthyRecovery.sequence),b:Int64(healthyRecovery.reason.rawValue),c:PlaybackFlowTrace.scalar(healthyRecovery.holdingRate*1e6))
        PlaybackFlowTrace.point(root,.healthyRecoveryProof,a:p?.firstSampleUS ?? 0,b:p?.lastSampleUS ?? 0,c:PlaybackFlowTrace.scalar((p?.rate ?? 0)*1e6))
        PlaybackFlowTrace.point(root,.healthyRecoveryCounters,a:Int64(clamping:p?.firstNormal ?? 0),b:Int64(clamping:p?.lastNormal ?? 0),c:Int64(clamping:p?.late ?? 0))
        PlaybackFlowTrace.point(root,.healthyRecoveryScope,a:p?.atUS ?? 0,b:healthyRecovery.deadlineUS,c:Int64(clamping:p?.errors ?? 0))
        PlaybackFlowTrace.point(root,.healthyRecoveryRun,a:p?.runStartUS ?? 0,b:Int64(p?.frames ?? 0),c:Int64(currentSourceEpoch ?? 0))
        PlaybackFlowTrace.point(root,.healthyRecoveryTarget,a:PlaybackFlowTrace.scalar(clockResync.recoveryRate*1e6),b:PlaybackFlowTrace.scalar(selectedSpeed*1e6),c:Int64(automatic.revision))
    }
    /// Permanent accepted-command identity and intent gates. Native transient
    /// pause/seeking/buffering closes adoption only, not this capture's lifetime.
    @discardableResult private func validateCostCapture(_ poll:VLCAppPoll,nowUS:Int64)->Bool {
        guard let capture=clockResync.costGuard.capture else{resyncCostScope=nil;return false}
        var invalid:Int64=0
        let scope=resyncCostScope
        if scope==nil || engine.map({ObjectIdentifier($0)}) != scope?.engine {invalid |= 1}
        if scope?.epoch != currentSourceEpoch {invalid |= 2}
        if scope?.nonce != capture.nonce || presentationTicket != capture.nonce {invalid |= 4}
        if scope?.rate != capture.rate || !selectedSpeed.isFinite || abs(selectedSpeed-capture.rate)>0.001 {invalid |= 8}
        if !active {invalid |= 16};if !sceneActive {invalid |= 32};if paused {invalid |= 64}
        if sourceRecovering {invalid |= 128};if pendingSeek != nil {invalid |= 256}
        if let seek=currentSeek,(!seek.isResync || seek.nonce != capture.nonce || seek.sourceInvalidated) {invalid |= 512}
        if poll.diagnostics.ended {invalid |= 1024}
        if poll.sourceFailures>0 || poll.diagnostics.player_error || poll.diagnostics.vt_rejected>0 ||
           poll.state.unsupported_audio || poll.state.unsupported_video {invalid |= 2048}
        let t=poll.state
        var transport:Int64=0
        if t.timer_paused {transport |= 1};if t.timer_seeking {transport |= 2}
        if t.buffering {transport |= 4};if t.paused {transport |= 8};if !t.timer_valid {transport |= 16}
        if !t.watch_rate.isFinite || abs(t.watch_rate-capture.rate)>0.01 {transport |= 32}
        if !automatic.rateConfirmed || abs(automatic.effectiveRate-capture.rate)>0.01 {transport |= 64}
        clockResync.costGuard.recordObservation(.init(nowUS:nowUS,invalidMask:invalid,transportMask:transport,
            nativeRate:t.watch_rate,expectedNonce:capture.nonce,observedNonce:presentationTicket,
            expectedEpoch:scope?.epoch.map{Int64(bitPattern:$0)} ?? Int64.min,
            observedEpoch:currentSourceEpoch.map{Int64(bitPattern:$0)} ?? Int64.min))
        if invalid != 0 {clockResync.costGuard.interrupt();resyncCostScope=nil;return false}
        clockResync.costGuard.expireCapture(nowUS:nowUS)
        if clockResync.costGuard.capture==nil {resyncCostScope=nil;return false}
        return true
    }
    /// Actual publication timestamps remain provisional across native paused
    /// points. A mismatched native rate cannot supply a same-rate run.
    private func recordCostPublication(nowUS:Int64,pts:Double,poll:VLCAppPoll) {
        guard validateCostCapture(poll,nowUS:nowUS) else{return}
        if clockResync.costGuard.observation.transportMask & 32 != 0 {
            clockResync.costGuard.awaitConfirmation(resetRun:true);return
        }
        clockResync.costGuard.published(nowUS:nowUS,pts:pts,eligible:true,
            rateConfirmed:clockResync.costGuard.observation.transportMask==0)
        if clockResync.costGuard.capture==nil {resyncCostScope=nil}
    }
    private func resetRecoverySource() {
        queueEvidence.reset()
        resyncCostScope=nil
        clockResync.costGuard.clearScope();emitResyncCost()
        healthyRecovery.interrupt();emitHealthyRecovery()
    }
    private func resetRecoveryIntent(preserveHealthy:Bool=false) {
        resyncCostScope=nil
        healthyRecovery.interrupt(preserveProof:preserveHealthy);emitHealthyRecovery()
        clockResync.interrupt();emitResyncCost()
    }
    private func interruptClockResync(preserveHealthy:Bool=false) {
        let before=clockResync.baselines
        resetRecoveryIntent(preserveHealthy:preserveHealthy)
        resyncSampling.cancel();resyncSample=nil
        emitBaseline(resyncBaselineJournal.record(before:before,after:clockResync.baselines,input:nil,reason:4))
        if let seek=pendingSeek,seek.isResync {
            _ = seekGate?.cancelUnaccepted(nonce:seek.nonce);pendingSeek=nil
            presentationTicket &+= 1;recordResync(5)
        }
        if let seek=currentSeek,seek.isResync,!seek.dispatched {
            _ = seekGate?.cancelUnaccepted(nonce:seek.nonce);currentSeek=nil
            presentationTicket &+= 1;recordResync(5)
        }
    }
    private func validateNotSevereRetry(_ input:VLCClockResyncPolicy.Input,freshRead:Bool=false) {
        resyncSampling.validateNotSevere(input,identity:engine.flatMap{resyncSampleIdentity($0)},
            holdRate:healthyRecovery.holdingRate,holdDeadline:healthyRecovery.deadlineUS,freshRead:freshRead)
        emitNotSevereRetry()
    }
    private func offerNotSevereQueue(_ sample:PlaybackQueuePressureSample?,nowUS:Int64) {
        guard let seed=resyncSampling.notSevereSeed,let sample,let core=engine,
              let identity=resyncSampleIdentity(core),healthyRecovery.holding,automatic.rateConfirmed,
              selectedSpeed==seed.selectedRate,healthyRecovery.holdingRate==seed.selectedRate else{return}
        if retryPressureSeedUS != seed.sampleUS {
            retryPressureSeedUS=seed.sampleUS;retryPressure.reset();retryPressurePrevious=nil
        }
        guard sample.completedUS>seed.sampleUS,sample.consumptionFreshness(at:nowUS)==0 else{return}
        let prior=retryPressurePrevious
        let reduce=retryPressure.update(sample,selectedRate:selectedSpeed)
        if retryPressure.outcome == .identity || retryPressure.outcome == .discontinuity || retryPressure.outcome == .invalid {
            resyncSampling.invalidateNotSevere(nowUS:nowUS);emitNotSevereRetry();return
        }
        // Match actual policy's retained baseline for short/duplicate intervals.
        if retryPressure.outcome != .insufficientInterval && retryPressure.outcome != .duplicate {
            retryPressurePrevious=sample
        }
        guard reduce,let prior else{return}
        _=resyncSampling.grantNotSevereQueue(nowUS:nowUS,identity:identity,holdRate:healthyRecovery.holdingRate,
            holdDeadline:healthyRecovery.deadlineUS,firstUS:prior.completedUS,secondUS:sample.completedUS,queueID:sample.id)
        emitNotSevereRetry()
    }
    private func emitNotSevereRetry() {
        guard emittedRetrySequence != resyncSampling.retrySequence else{return}
        emittedRetrySequence=resyncSampling.retrySequence
        VLCRecoveryFlow.notSevereRetry(resyncSampling)
    }
    private func updateClockResync(now:Double,poll:VLCAppPoll,publishedPTS:Double?,eligible:Bool,supplementalFresh:Bool=false) {
        let allowed=eligible && ready && !paused && sceneActive && !sourceRecovering &&
            pendingSeek==nil && currentSeek==nil && !poll.state.timer_paused && !poll.state.timer_seeking && !poll.state.buffering
        let beforeFrame=clockResync.baselines
        if !allowed || !automatic.rateConfirmed {
            clockResync.observedFrame(now:now,pts:publishedPTS ?? -1,eligible:false)
        } else if let pts=publishedPTS {clockResync.observedFrame(now:now,pts:pts,eligible:true)}
        emitBaseline(resyncBaselineJournal.record(before:beforeFrame,after:clockResync.baselines,input:nil,
                                                 reason:(!allowed || !automatic.rateConfirmed) ? 3:2))
        _=validateCostCapture(poll,nowUS:poll.state.timer_now_us);emitResyncCost()
        let d=poll.nativeDiagnostics
        guard d.available,(d.version==1 || d.version==2),d.ticks_per_second>0 else{return}
        let scale=Double(d.ticks_per_second)
        let errors=[d.delivery_invalid,d.delivery_no_vout,d.delivery_wait_abort,d.delivery_flush_abort,d.delivery_preroll,d.delivery_prevframe].reduce(UInt64(0)) { total,value in
            let sum=total.addingReportingOverflow(value);return sum.overflow ? UInt64.max:sum.partialValue
        }
        let input=VLCClockResyncPolicy.Input(now:now,lastFrameAt:lastFrameAt,eligible:allowed,
            rateConfirmed:automatic.rateConfirmed,effectiveRate:automatic.effectiveRate,selectedRate:selectedSpeed,
            nowUS:VLCVistaClock(),sampleUS:d.sample_clock_us,queuePTS:d.queue_pts,queueTick:d.queue_tick,dropTick:d.drop_tick,
            queueCount:d.queue_count,queueValid:d.queue_valid,queueInvalid:d.queue_invalid,queueRepeat:d.queue_repeat,queueBackward:d.queue_backward,
            admitted:d.delivery_admitted,pop:d.fifo_pop,lateDrop:d.late_drop,renderNormal:d.render_normal,errors:errors,
            dropDeltaMS:Double(d.drop_system_delta)/scale*1000,dropThresholdMS:Double(d.drop_threshold)/scale*1000,dropRate:d.drop_rate,
            dropPTS:d.drop_pts,dropClockID:d.drop_clock_id,dropContextValid:d.drop_context_valid && d.ticks_per_second==1_000_000,
            dropContextRate:d.drop_context_rate,dropReference:d.drop_reference_generation)
        if let pts=publishedPTS {recordCostPublication(nowUS:input.nowUS,pts:pts,poll:poll)}
        let heldBeforeObservation=healthyRecovery.holding
        observeHealthyRecovery(input,publishedPTS:publishedPTS)
        if heldBeforeObservation && !healthyRecovery.holding {clockResync.retargetFloor(now:now)}
        emitHealthyRecovery()
        let previousEarlyEvidence=clockResync.earlyEvidence.sequence
        let wasArmed=clockResync.armed
        let beforeObserve=clockResync.baselines
        validateNotSevereRetry(input,freshRead:poll.ordinaryNativeRead || supplementalFresh)
        let triggered=clockResync.observe(input)
        if triggered {resyncSampling.finishNotSevere(nowUS:input.nowUS);emitNotSevereRetry()}
        emitResyncCost()
        let baselineEvent=wasArmed ? resyncBaselineJournal.record(before:beforeObserve,after:clockResync.baselines,input:input,reason:1):nil
        let freshEvidence=wasArmed && clockResync.earlyEvidence.sequence != previousEarlyEvidence
        if freshEvidence || baselineEvent != nil {
            resyncLastInput=input
            // Complete scalar proof is retained with the continuous Flow session,
            // independent of the ordinary JSONL rotation and six-line budget.
            let proof=VLCRecoveryFlow.decision(action:freshEvidence ? 12:13,command:audioCommand,revision:automatic.revision,
                policy:clockResync,budget:resyncSampling,outcome:Int64(resyncOutcome),input:input)
            emitBaseline(baselineEvent,proof:proof)
            if freshEvidence,earlyEvidenceRecords<6 {earlyEvidenceRecords += 1;emitControl(12)}
        }
        if poll.ordinaryNativeRead {resyncSampling.ordinaryBaseline(sampleUS:d.sample_clock_us,acceptedUS:clockResync.evidenceSampleUS,earlyAcceptedUS:clockResync.earlyEvidenceSampleUS)}
        guard triggered else{return}
        let target=Double(poll.state.timer_time_us)/1e6
        resyncTriggerClock=target;resyncTarget = -1;resyncCommandClock=0;resyncObservedMS=0
        guard target.isFinite,target>=0,target<duration,let request=seekGate?.request(Int64((target*1e6).rounded())) else{recordResync(4);return}
        resumeSeekIdentity.clear()
        // Automatic recovery preserves the last presented image while draining
        // and isolating old work. Manual seek and stop still clear presentation.
        presentationTicket=request.request.nonce
        pendingSeek=Seek(target:target,nonce:presentationTicket,continuation:nil,isResync:true,intentRevision:automatic.revision,
            expectedNormal:d.render_normal,minimumLateDrop:d.late_drop,sourceEpoch:currentSourceEpoch,
            earlyEvidence:clockResync.earlyDispatchEvidence,authorizedRate:clockResync.recoveryRate)
        recordResync(1);onState?(.seeking)
    }
    private func resyncSampleIdentity(_ core:VLCAppEngine)->VLCResyncSampleBudget.Identity? {
        guard active,engine===core else{return nil}
        return .init(revision:automatic.revision,presentation:presentationTicket,
                     source:currentSourceEpoch,engine:ObjectIdentifier(core),chain:resyncSampling.chain)
    }
    private func healthSampleIdentity(_ core:VLCAppEngine)->VLCHealthSampleBudget.Identity? {
        guard active,engine===core else{return nil}
        return .init(engine:ObjectIdentifier(core),source:currentSourceEpoch,revision:automatic.revision,
                     presentation:presentationTicket,rate:selectedSpeed)
    }
    /// Only actual publications consume a supplementary native observation.
    /// Its counters never enter ordinary, resync or cost caches.
    private func observeHealthyRecovery(_ input:VLCClockResyncPolicy.Input,publishedPTS:Double?) {
        var health=input
        if let cached=healthSample {
            let run=healthyRecovery.samplingState
            let sameScope=engine.flatMap {healthSampleIdentity($0)}==cached.request.identity &&
                run.runStartUS==cached.request.runStartUS
            if !sameScope || input.sampleUS>=cached.diagnostics.sample_clock_us {
                healthSample=nil
            } else if publishedPTS != nil {
                let d=cached.diagnostics
                health.sampleUS=d.sample_clock_us;health.renderNormal=d.render_normal;health.lateDrop=d.late_drop
                health.errors=[d.delivery_invalid,d.delivery_no_vout,d.delivery_wait_abort,d.delivery_flush_abort,d.delivery_preroll,d.delivery_prevframe].reduce(UInt64(0)) {
                    let sum=$0.addingReportingOverflow($1);return sum.overflow ? UInt64.max:sum.partialValue
                }
            }
        }
        let freshnessBefore=healthyRecovery.freshnessSequence
        healthyRecovery.observe(health,publishedPTS:publishedPTS)
        if freshnessBefore != healthyRecovery.freshnessSequence {
            let run=healthyRecovery.samplingState
            let flow=PlaybackFlowTrace.mark(.healthCertificateFreshness,a:health.nowUS,b:health.sampleUS,c:health.nowUS-health.sampleUS)
            PlaybackFlowTrace.point(flow,.healthProbeRun,a:run.runStartUS,b:Int64(run.frames),c:run.firstNativeUS)
            PlaybackFlowTrace.point(flow,.healthProbeScope,a:Int64(clamping:automatic.revision),b:Int64(clamping:presentationTicket),c:Int64(clamping:currentSourceEpoch ?? 0))
        }
        if var cached=healthSample,!cached.applied,
           healthyRecovery.samplingState.runStartUS==cached.request.runStartUS,
           healthyRecovery.samplingState.lastNativeUS==cached.diagnostics.sample_clock_us {
            PlaybackFlowTrace.mark(.healthProbeApply,a:Int64(cached.request.sequence),b:cached.diagnostics.sample_clock_us,c:input.nowUS)
            cached.applied=true;healthSample=cached
        }
        if let cached=healthSample,healthyRecovery.samplingState.runStartUS != cached.request.runStartUS {healthSample=nil}
    }
    private func sampleHealthyRecovery(core:VLCAppEngine,poll:VLCAppPoll,resyncRead:Bool)async {
        // Never duplicate ordinary/resync reads, nor compete with stalled recovery.
        guard !poll.ordinaryNativeRead,!resyncRead,!Task.isCancelled else{return}
        refreshSourceState()
        let t=poll.state,nowUS=VLCVistaClock(),run=healthyRecovery.samplingState
        let eligible=active && ready && !paused && sceneActive && !sourceRecovering &&
            pendingSeek==nil && currentSeek==nil && !poll.diagnostics.ended &&
            !t.timer_paused && !t.timer_seeking && !t.buffering && duration>0 && Double(t.time_us)/1e6<duration &&
            automatic.rateConfirmed && selectedSpeed>=2.5 && VLCClockResyncPolicy.validRecoveryRate(selectedSpeed) &&
            abs(automatic.effectiveRate-selectedSpeed)<=0.01 &&
            !(clockResync.armed && !clockResync.spent && nowUS-run.lastUS>=500_000)
        guard let identity=healthSampleIdentity(core) else{return}
        if let cached=healthSample,cached.request.identity != identity || cached.request.runStartUS != run.runStartUS {healthSample=nil}
        guard let request=healthSampling.request(identity:identity,state:run,nowUS:nowUS,eligible:eligible,
                                                cachedUS:healthSample?.diagnostics.sample_clock_us ?? 0) else{return}
        let flow=PlaybackFlowTrace.begin(.healthProbe,a:Int64(request.sequence),b:Int64(request.purpose),c:request.runStartUS)
        PlaybackFlowTrace.point(flow,.healthProbeRun,a:run.lastUS,b:Int64(run.frames),c:run.firstNativeUS)
        PlaybackFlowTrace.point(flow,.healthProbeScope,a:Int64(clamping:identity.revision),b:Int64(clamping:identity.presentation),c:Int64(clamping:identity.source ?? 0))
        PlaybackFlowTrace.point(flow,.healthProbeApply,a:request.dueUS,b:nowUS,c:PlaybackFlowTrace.scalar(identity.rate*1e6))
        let sample=await core.sampleClockResync(expectedRate:identity.rate)
        refreshSourceState()
        let resumedUS=VLCVistaClock()
        let completedUS=sample?.completedUS ?? resumedUS
        PlaybackFlowTrace.point(flow,.healthProbeResume,a:resumedUS,b:completedUS,c:Int64(request.purpose))
        let sameScope=healthSampling.complete(request,current:healthSampleIdentity(core),state:healthyRecovery.samplingState)
        var result:Int64=0
        defer {PlaybackFlowTrace.end(flow,.healthProbe,a:result,b:completedUS,c:sample?.diagnostics.sample_clock_us ?? 0)}
        guard sameScope,!Task.isCancelled,active,ready,!paused,sceneActive,!sourceRecovering,
              pendingSeek==nil,currentSeek==nil,automatic.rateConfirmed,
              abs(automatic.effectiveRate-identity.rate)<=0.01,
              resumedUS>=completedUS,completedUS>=run.lastUS,resumedUS-run.lastUS<=250_000 else{result=2;return}
        guard let sample else{result=3;return}
        let d=sample.diagnostics
        guard d.available,(d.version==1 || d.version==2),d.ticks_per_second>0,
              d.sample_clock_us>=request.runStartUS,d.sample_clock_us<=completedUS,
              completedUS-d.sample_clock_us<=1_250_000,
              d.sample_clock_us>run.lastNativeUS else{result=4;return}
        PlaybackFlowTrace.point(flow,.healthProbeNative,a:d.sample_clock_us,b:Int64(clamping:d.render_normal),c:Int64(clamping:d.late_drop))
        let errors=[d.delivery_invalid,d.delivery_no_vout,d.delivery_wait_abort,d.delivery_flush_abort,d.delivery_preroll,d.delivery_prevframe].reduce(UInt64(0)) {
            let sum=$0.addingReportingOverflow($1);return sum.overflow ? UInt64.max:sum.partialValue
        }
        PlaybackFlowTrace.point(flow,.healthProbeNative,a:-1,b:Int64(clamping:errors),c:d.sample_clock_us)
        healthSample=(request,d,false);result=1
    }
    /// Retain only a checked, chain-local sample until ordinary 1 Hz catches up.
    /// Otherwise an older ordinary cache would erase the new policy baseline.
    private func mergeResyncSample(_ poll:inout VLCAppPoll,core:VLCAppEngine) {
        guard let sample=resyncSample else{return}
        guard sample.identity==resyncSampleIdentity(core),clockResync.armed,!clockResync.spent else{resyncSample=nil;return}
        if poll.nativeDiagnostics.sample_clock_us>=sample.diagnostics.sample_clock_us {resyncSample=nil;return}
        poll.nativeDiagnostics=sample.diagnostics
    }
    private func sampleClockResync(core:VLCAppEngine,poll:VLCAppPoll)async {
        // An ordinary read in this poll is already a new snapshot. Do not repeat it.
        guard !poll.ordinaryNativeRead,!Task.isCancelled else{return}
        refreshSourceState()
        let now=ProcessInfo.processInfo.systemUptime,t=poll.state
        let allowed=active && sceneActive && !sourceRecovering && pendingSeek==nil && currentSeek==nil &&
            !poll.diagnostics.ended && duration>0 && Double(t.time_us)/1e6<duration &&
            ready && !paused && !t.timer_paused && !t.timer_seeking && !t.buffering
        let eligible=allowed && clockResync.armed && !clockResync.spent && automatic.rateConfirmed &&
            now.isFinite && lastFrameAt.isFinite && lastFrameAt>=0 && now-lastFrameAt>=VLCClockResyncPolicy.earlyNoFrameSeconds &&
            selectedSpeed.isFinite && automatic.effectiveRate.isFinite &&
            abs(selectedSpeed-clockResync.recoveryRate)<=0.001 && abs(automatic.effectiveRate-clockResync.recoveryRate)<=0.01
        let nowUS=VLCVistaClock()
        let cached=poll.nativeDiagnostics
        let settleOldContext=cached.available && cached.version==2 && cached.ticks_per_second==1_000_000 &&
            cached.drop_context_valid && cached.drop_context_rate.isFinite && cached.drop_context_rate>clockResync.recoveryRate+0.01 &&
            cached.drop_rate.isFinite && abs(cached.drop_rate-clockResync.recoveryRate)<=0.01 && cached.drop_reference_generation>0
        let priorWindow=resyncSampling.earlyWindowStartUS
        let phase=resyncSampling.samplingPhase(nowUS:nowUS,eligible:eligible,legacyBaselineUS:clockResync.evidenceSampleUS,settleOldContext:settleOldContext)
        if priorWindow==0,resyncSampling.earlyWindowStartUS>0 {
            _=VLCRecoveryFlow.probe(action:0,sequence:0,oldContext:settleOldContext,budget:resyncSampling,
                nowUS:nowUS,sampleUS:cached.sample_clock_us,dropRate:cached.drop_rate,contextRate:cached.drop_context_rate,
                revision:automatic.revision,presentation:presentationTicket,authorizedRate:clockResync.recoveryRate)
        }
        let baseline=phase == .early ? clockResync.earlyEvidenceSampleUS:clockResync.evidenceSampleUS
        guard let identity=resyncSampleIdentity(core),
              let request=resyncSampling.request(nowUS:nowUS,baselineUS:baseline,
                                                 identity:identity,eligible:eligible && (phase == .early || now-lastFrameAt>=1),phase:phase) else{return}
        let probe=VLCRecoveryFlow.probe(action:request.phase == .early ? 2:1,sequence:request.sequence,
            oldContext:settleOldContext,budget:resyncSampling,nowUS:nowUS,sampleUS:cached.sample_clock_us,
            dropRate:cached.drop_rate,contextRate:cached.drop_context_rate,revision:automatic.revision,
            presentation:presentationTicket,authorizedRate:clockResync.recoveryRate)
        let sample=await core.sampleClockResync(expectedRate:clockResync.recoveryRate)
        refreshSourceState()
        let completedUS=sample?.completedUS ?? VLCVistaClock()
        let accepted=resyncSampling.complete(request,current:resyncSampleIdentity(core),completedUS:completedUS)
        PlaybackFlowTrace.end(probe,.resyncProbe,a:(accepted ? 1:0)|(sample != nil ? 2:0)|((sample?.diagnostics.available ?? false) ? 4:0),
            b:completedUS,c:sample?.diagnostics.sample_clock_us ?? 0)
        guard accepted,
              !Task.isCancelled,active,ready,!paused,sceneActive,!sourceRecovering,
              pendingSeek==nil,currentSeek==nil,clockResync.armed,!clockResync.spent,
              automatic.rateConfirmed else{return}
        guard let sample else{resyncSampling.rejectedSample(phase:request.phase,oldContextOnly:false);emitNotSevereRetry();return}
        guard resyncSampling.acceptsNotSevereCompletion(request,nowUS:VLCVistaClock(),
            holdRate:healthyRecovery.holdingRate,holdDeadline:healthyRecovery.deadlineUS) else{emitNotSevereRetry();return}
        // The actor checked live native state. This sample never enters the
        // ordinary cache and cannot survive a new intent, source or engine.
        var fresh=poll;fresh.state=sample.state;fresh.nativeDiagnostics=sample.diagnostics
        fresh.ordinaryNativeRead=false
        let d=sample.diagnostics
        if d.sample_clock_us>0 {resyncSample=(identity,d)}
        controlDiagnostics.observeNative(d,nowUS:completedUS)
        updateClockResync(now:ProcessInfo.processInfo.systemUptime,poll:fresh,publishedPTS:nil,eligible:true,supplementalFresh:true)
        let acceptedSampleUS=phase == .early ? clockResync.earlyEvidenceSampleUS:clockResync.evidenceSampleUS
        if clockResync.armed,d.available,
           resyncSampling.acceptedSample(request,sampleUS:d.sample_clock_us,acceptedUS:acceptedSampleUS) {
            _=VLCRecoveryFlow.probe(action:3,sequence:3,oldContext:false,budget:resyncSampling,
                nowUS:completedUS,sampleUS:d.sample_clock_us,dropRate:d.drop_rate,contextRate:d.drop_context_rate,
                revision:automatic.revision,presentation:presentationTicket,authorizedRate:clockResync.recoveryRate)
        }
        if clockResync.armed,acceptedSampleUS != d.sample_clock_us || !d.available {
            let captured=d.available && d.version==2 && d.ticks_per_second==1_000_000 &&
                clockResync.earlyEvidence.reason == .notSevere && resyncLastInput.map { input in
                    input.sampleUS==d.sample_clock_us && resyncSampling.captureNotSevere(request,input:input,
                        holdRate:healthyRecovery.holdingRate,holdDeadline:healthyRecovery.deadlineUS)
                } == true
            if !captured {resyncSampling.rejectedSample(phase:request.phase,oldContextOnly:d.available && clockResync.oldContextRetrySampleUS==d.sample_clock_us)}
        }
        emitNotSevereRetry()
    }
    private struct Seek {
        var target:Double
        let nonce:UInt64
        let continuation:CheckedContinuation<Void,Error>?
        var isResync=false,intentRevision:UInt64=0
        var expectedNormal:UInt64=0,minimumLateDrop:UInt64=0
        var sourceEpoch:UInt64?=nil,sourceInvalidated=false
        var earlyEvidence:VLCClockResyncPolicy.EarlyDispatchEvidence?
        var authorizedRate:Double=2
        var dispatched=false,updates:UInt64=0,started=0.0,commandClock:Int64=0
        var observationID:UInt64=0
    }
    private var pendingSeek:Seek?,currentSeek:Seek?
    private var seekGate:SerializedSeekGate?
    func seek(to target:Double)async throws{
        PlaybackFlowTrace.mark(.controlIntent,a:3,b:PlaybackFlowTrace.scalar(target*1e6),c:Int64(presentationTicket))
        guard active,ready,target.isFinite,target>=0,target<duration else{throw VLCPlaybackError.seek}
        guard let request=seekGate?.request(Int64((target*1e6).rounded())) else{throw VLCPlaybackError.seek}
        observeSeek(.superseded)
        seekObservationLastReject.removeAll(keepingCapacity:true)
        seekObservations.begin(session:speedSession,nonce:request.request.nonce,target:target,now:ProcessInfo.processInfo.systemUptime)
        interruptAutomatic(.seek);presentationTicket=request.request.nonce
        try await withCheckedThrowingContinuation { continuation in
            pendingSeek?.continuation?.resume(throwing:CancellationError())
            pendingSeek=Seek(target:target,nonce:presentationTicket,continuation:continuation)
            // The synchronous state observer must see the committed seek intent.
            onState?(.seeking)
            observeSeek(.intent,nonce:presentationTicket)
        }
    }
    func stop(){
        PlaybackFlowTrace.mark(.controlIntent,a:5)
        observeSeek(.stopped)
        if active{interruptAutomatic(.stopped);emitControl(6)}
        if let summary=seekSummary.finish(session:speedSession,now:ProcessInfo.processInfo.systemUptime) {
            PlaybackLogStore.shared.enqueue(PlaybackLogRecord(vlcSeekSummary:summary))
        }
        active=false;presentationTicket += 1;seekGate?.stop();clearPresentation?();engine?.context.invalidate()
        pendingSeek?.continuation?.resume(throwing:CancellationError());pendingSeek=nil
        currentSeek?.continuation?.resume(throwing:CancellationError());currentSeek=nil
        onPrefetchActivityChanged?()
    }
    // Production presentation decision; pre-await revision and source epoch are
    // still checked by the caller. This is not a native producer/seek flush fence.
    private func displayDecision(_ frame:VLCAppFrame,poll:VLCAppPoll,ticket:UInt64)->VLCDisplayRecoveryPolicy.Result {
        let state=poll.state
        return displayPolicy.evaluate(frame.displayEvidence,.init(
            eligible:active && sceneActive && !sourceRecovering && ticket==presentationTicket &&
                pendingSeek==nil && currentSeek==nil && seekGate?.suppressed != true,
            userPaused:paused,nativePlaying:poll.diagnostics.state==2 && !state.paused,
            timerValid:state.timer_valid,timerPaused:state.timer_paused,seeking:state.timer_seeking,
            buffering:state.buffering,clockUS:state.time_us,nowUS:state.timer_now_us,rate:selectedSpeed))
    }
    private func observeDisplay(_ result:VLCDisplayRecoveryPolicy.Result,poll:VLCAppPoll) {
        guard result != lastDisplayResult else{return}
        let previous=lastDisplayResult;lastDisplayResult=result
        guard result != .clockAccepted || previous != nil else{return}
        guard displayEvents<64,displayEpisodeEvents<8 else{displaySuppressed=min(1_000_000,displaySuppressed+1);return}
        displayEvents += 1;displayEpisodeEvents += 1
        // Small independent event, not a copy of the full 1Hz sample payload.
        PlaybackLogStore.shared.enqueue(PlaybackLogRecord(event:.vlcDisplay,values:[
            .vlcSchema:4,.vlcDisplayDecision:Double(result.rawValue),
            .vlcFramePTS:poll.rawMetadata?.displayEvidence.ptsUS.map{Double($0)/1e6} ?? -1,
            .vlcDisplayAgeMS:displayPolicy.lastAgeMS,.vlcDisplayUpperPTS:displayPolicy.lastUpperPTS,
            .vlcTimerPaused:poll.state.timer_paused ? 1:0,.vlcTimerValid:poll.state.timer_valid ? 1:0,
            .vlcWatchDateKind:poll.state.watch_date_us==Int64.max ? 1:poll.state.watch_date_us<=0 ? 2:0,
            .vlcCommandRevision:VLCControlDiagnostics.bounded(automatic.revision),
            .vlcSeekNonce:VLCControlDiagnostics.bounded(presentationTicket),
            .vlcDisplayRecovered:Double(displayPolicy.recoveryCount),
            .vlcDisplayNonadvancing:Double(displayPolicy.nonadvancingCount),
            .vlcDisplayTimelineRejected:Double(displayPolicy.timelineRejected),
            .vlcDisplaySuppressed:Double(displaySuppressed)]))
    }
    private func validate(_ frame:VLCAppFrame)throws {
        guard frame.metadata.ticks_per_second>0,frame.seconds.isFinite,frame.seconds>=0 else{throw VLCPlaybackError.time}
        // Visible geometry has been verified and, only when padded, copied by the
        // serialized engine. The native metadata remains unchanged for diagnostics.
        guard frame.metadata.picture.visible_width==CVPixelBufferGetWidth(frame.pixel),
              frame.metadata.picture.visible_height==CVPixelBufferGetHeight(frame.pixel) else{throw VLCPlaybackError.geometry}
    }
    private func codec(_ value:UInt32)->String {
        let bytes=(0..<4).map {UInt8(truncatingIfNeeded:value >> ($0*8))}
        switch String(bytes:bytes,encoding:.ascii)?.lowercased(){case "h264":return "H.264";case "hevc":return "HEVC";case "vp90":return "VP9";default:return "VLC"}
    }
    func play(owner:any SourceOperationOwner,startAt:Double,startPaused:Bool,
              onInfo:@escaping (VideoTrackInfo)->Void,onState:@escaping (NativePlaybackSession.State)->Void,
              onFrame:@escaping (DecodedVideoFrame)->Void,onSpeed:@escaping (PlaybackSpeedStatus)->Void)async throws {
        self.onState=onState;self.onSpeed=onSpeed;paused=startPaused || !sceneActive
        flowOwned=PlaybackFlowTrace.start(session:speedSession)
        onState(.preparing);let started=ProcessInfo.processInfo.systemUptime;lastFrameAt=started
        var terminal:Error?
        do {
            let window=try await owner.beginWindow(generation:1)
            resetRecoverySource()
            let core=VLCAppEngine(window:window);engine=core
            resumeSeekIdentity.clear()
            emitControl(1)
            try await core.start()
            // Existing controller starts normal files at zero. Replay opens a fresh owner.
            guard startAt==0 else{throw VLCPlaybackError.seek}
            var info:VideoTrackInfo?,lastState:NativePlaybackSession.State?,lastSpeed:PlaybackSpeedStatus?
            var token:UInt64?
            while active {
                try Task.checkCancellation()
                let ticket=presentationTicket,revision=automatic.revision
                let audioEnd=audioInterruption;audioInterruption=nil
                let resumeEnd=resumeInterruption;resumeInterruption=nil
                let flowPoll=PlaybackFlowTrace.begin(.poll,a:Int64(ticket),b:Int64(revision))
                let flowPollResult=await core.poll(flowParent:flowPoll,audioEndReason:audioEnd.map(audioReason),observeAudio:audioBoundary.hasActive,
                    observeSeek:currentSeek.map{!$0.isResync && $0.observationID>0} ?? false,
                    resumeEndReason:resumeEnd.map(VLCResumeObserver.reason),observeResume:resumeBoundary.hasActive,observeFrame:frameStage.hasActive,
                    observeQueuePressure:ready && sceneActive && !paused && !sourceRecovering && pendingSeek==nil &&
                        currentSeek==nil && automatic.rateConfirmed && selectedSpeed>=2.5)
                PlaybackFlowTrace.end(flowPoll,.poll,a:flowPollResult == nil ? 1:0)
                guard var poll=flowPollResult else{throw VLCPlaybackError.engine}
                // Always consume diagnostics under their captured command identity,
                // even when a newer UI/source intent makes this playback poll stale.
                // The terminal path obtains native finish snapshots before closing observers.
                // A poll started before stop may contain no diagnostic snapshot.
                guard active else{break}
                refreshSourceState()
                observeAudio(poll,interruption:audioEnd ?? audioInterruption)
                // Only the interruption captured before this await was sent to native.
                // New UI/source interruptions remain pending for the next poll;
                // using them here would discard the active identity before Finish.
                observeResume(poll,interruption:resumeEnd)
                observeFrame(poll,interruption:resumeEnd)
                // A poll begun before a newer intent/source epoch carries stale
                // observation, even if its asynchronous engine call succeeded.
                guard revision==automatic.revision else{PlaybackFlowTrace.mark(.discard,parent:.init(poll.rawMetadata?.trace_frame_id ?? 0),a:1,b:Int64(revision),c:Int64(automatic.revision));automatic.discardTiming(through:poll.state.watch_updates);continue}
                mergeResyncSample(&poll,core:core)
                let now=ProcessInfo.processInfo.systemUptime
                PlaybackFlowTrace.point(flowPoll,.state,a:poll.state.time_us,b:PlaybackFlowTrace.scalar(poll.state.watch_rate*1e6),c:Int64(poll.state.watch_updates))
                if let raw=poll.rawMetadata {PlaybackFlowTrace.mark(.appGate,parent:.init(raw.trace_frame_id),a:Int64(ticket),b:Int64(revision),c:poll.frame == nil ? 1:0)}
                controlDiagnostics.observe(poll,now:now)
                seekObservationPollAt=now
                if let preparationError=poll.preparationError{throw preparationError}
                if poll.sourceFailures>0{throw VLCPlaybackError.source}
                if poll.state.unsupported_audio{throw VLCPlaybackError.audio}
                if poll.state.unsupported_video || poll.diagnostics.vt_rejected>0{throw VLCPlaybackError.video}
                if poll.diagnostics.player_error{throw VLCPlaybackError.video}
                if poll.state.length_us>0 {
                    duration=Double(poll.state.length_us)/1e6
                    if seekGate==nil{seekGate=SerializedSeekGate(policy:SeekPolicy(durationUS:poll.state.length_us,observationPolls:800))}
                }
                if poll.state.video_codec != 0, poll.state.width>0,poll.state.height>0 {
                    let next=VideoTrackInfo(codec:codec(poll.state.video_codec),width:Int32(clamping:poll.state.width),height:Int32(clamping:poll.state.height),duration:duration,hasAudio:poll.state.has_audio,estimatedDataRate:Double(poll.state.bitrate))
                    if next != info {info=next;onInfo(next)}
                }
                if automatic.needsRateCommand {
                    let command=automatic.beginCommand()
                    audioCommand &+= 1
                    let diagnostic=VLCAudioBoundaryObserver.Command(session:speedSession,id:audioCommand,revision:command.revision,
                        sourceEpoch:currentSourceEpoch,origin:audioOrigin,rate:command.rate,intentUS:VLCVistaClock(),video:audioVideo())
                    if audioBoundary.emitted<VLCAudioBoundaryObserver.maximumSummaries {
                        audioMarker(command:diagnostic.id,phase:1,outcome:0,clock:diagnostic.intentUS,rate:diagnostic.rate,
                            revision:diagnostic.revision,epoch:diagnostic.sourceEpoch)
                    }
                    let resumeCommand=VLCResumeObserver.Command(session:speedSession,id:diagnostic.id,revision:command.revision,
                        seekNonce:resumeSeekIdentity.nonce(engine:ObjectIdentifier(core),epoch:currentSourceEpoch),sourceEpoch:currentSourceEpoch,
                        rate:command.rate,paused:paused && (appliedPause==true || poll.state.paused))
                    let rateReceipt=await core.rate(command.rate,session:speedSession,command:diagnostic.id,revision:command.revision,
                        seekNonce:resumeCommand.seekNonce,paused:resumeCommand.paused)
                    let audioReceipt=rateReceipt.audio
                    emitFrame(frameStage.begin(resumeCommand,origin:diagnostic.origin.rawValue,mark:rateReceipt.frame.mark,setterStatus:audioReceipt.rate.status,
                        previous:rateReceipt.frame.previous,previousFinishStatus:rateReceipt.frame.finish_status,nowUS:audioReceipt.rate.command_clock_us))
                    emitResume(resumeBoundary.begin(resumeCommand,mark:rateReceipt.mark,setterStatus:audioReceipt.rate.status,
                        previous:rateReceipt.previous,previousFinishStatus:rateReceipt.finish_status,nowUS:audioReceipt.rate.command_clock_us))
                    for record in audioBoundary.begin(diagnostic,receipt:audioReceipt,after:audioVideo()){emitAudio(record)}
                    let receipt=audioReceipt.rate
                    displayPolicy.command(at:receipt.command_clock_us,preserveTimeline:false)
                    refreshSourceState()
                    guard active else{break}
                    let current=command.revision==automatic.revision
                    let accepted=automatic.complete(command,accepted:receipt.status==0,watchFloor:receipt.watch_floor)
                    if current && !accepted{throw VLCPlaybackError.rate}
                    if accepted{emitControl(4)}
                    continue // No pre-setter frame/clock is new-rate evidence.
                }
                // A paused seek uses native VLC pause semantics. No silent stop/reopen.
                if appliedPause != paused {
                    let requestedPause=paused,commandRevision=automatic.revision
                    let commandClock=await core.pause(requestedPause)
                    if !requestedPause {resumeBoundary.resumed(returnUS:commandClock)}
                    displayPolicy.command(at:commandClock,preserveTimeline:true)
                    refreshSourceState()
                    guard active else{break}
                    if commandRevision==automatic.revision,requestedPause==paused {
                        appliedPause=requestedPause;emitControl(requestedPause ? 2:3)
                    }else{appliedPause=nil}
                    continue
                }
                if let recovery=currentSeek,recovery.isResync,let next=pendingSeek,!next.isResync,
                   seekGate?.supersedeRecovery(nonce:recovery.nonce)==true {
                    currentSeek=nil;recordResync(5)
                }
                if currentSeek==nil,let next=pendingSeek {
                    guard seekGate?.begin()?.nonce==next.nonce else{throw VLCPlaybackError.seek}
                    pendingSeek=nil;currentSeek=next
                    guard let drainPresentation else{throw VLCPlaybackError.renderer}
                    do {
                        let flow=PlaybackFlowTrace.begin(.controlPresentationDrain,a:VLCRecoveryFlow.integer(next.nonce),b:VLCRecoveryFlow.integer(next.intentRevision),c:next.isResync ? 1:0)
                        defer{PlaybackFlowTrace.end(flow,.controlPresentationDrain)}
                        try await PlaybackFlowTrace.$parent.withValue(flow) { try await drainPresentation(true) }
                    }
                    if next.isResync {refreshSourceState()}
                    guard active else{break}
                    if pendingSeek != nil {
                        _ = seekGate?.supersedeUndispatched(nonce:next.nonce)
                        currentSeek?.continuation?.resume(throwing:CancellationError());currentSeek=nil;continue
                    }
                    if next.isResync && (currentSeek?.nonce != next.nonce || next.intentRevision != automatic.revision || paused || !sceneActive || sourceRecovering) {
                        _ = seekGate?.cancelUnaccepted(nonce:next.nonce);if currentSeek?.nonce==next.nonce{currentSeek=nil};recordResync(5);continue
                    }
                    do {
                        let flow=PlaybackFlowTrace.begin(.controlSourceValidation,a:VLCRecoveryFlow.integer(next.nonce),b:VLCRecoveryFlow.integer(next.intentRevision),c:next.isResync ? 1:0)
                        defer{PlaybackFlowTrace.end(flow,.controlSourceValidation)}
                        try await PlaybackFlowTrace.$parent.withValue(flow) { try await owner.validate(stamp:core.context.stamp) }
                    }
                    if next.isResync {refreshSourceState()}
                    guard active,!Task.isCancelled else{throw CancellationError()}
                    if pendingSeek != nil {
                        _ = seekGate?.supersedeUndispatched(nonce:next.nonce)
                        currentSeek?.continuation?.resume(throwing:CancellationError());currentSeek=nil;continue
                    }
                    if next.isResync {
                        guard currentSeek?.nonce==next.nonce,next.intentRevision==automatic.revision,!paused,sceneActive,!sourceRecovering else {
                            _ = seekGate?.cancelUnaccepted(nonce:next.nonce);if currentSeek?.nonce==next.nonce{currentSeek=nil};recordResync(5);continue
                        }
                        // Mark in flight before awaiting: an accepted native command cannot be revoked by a later intent.
                        currentSeek?.dispatched=true
                        guard let receipt=await core.seekCurrentTime(expectedNormal:next.expectedNormal,minimumLateDrop:next.minimumLateDrop,early:next.earlyEvidence,flowCommand:audioCommand,flowRevision:next.intentRevision,flowNonce:next.nonce,expectedRate:next.authorizedRate) else {
                            _ = seekGate?.cancelUnaccepted(nonce:next.nonce);if currentSeek?.nonce==next.nonce{currentSeek=nil}
                            healthyRecovery.dispatchRejected();emitHealthyRecovery()
                            recordResync(4);onPrefetchActivityChanged?();continue
                        }
                        guard active else{break}
                        guard seekGate?.retargetRecovery(nonce:next.nonce,targetUS:Int64((receipt.target*1e6).rounded()))==true else{throw VLCPlaybackError.seek}
                        currentSeek?.target=receipt.target;currentSeek?.updates=receipt.watchFloor
                        currentSeek?.started=ProcessInfo.processInfo.systemUptime;currentSeek?.commandClock=receipt.commandClock
                        resyncTarget=receipt.target;resyncCommandClock=Double(receipt.commandClock)/1e6
                        if engine===core,currentSeek?.nonce==next.nonce,next.intentRevision==automatic.revision,
                           next.sourceEpoch==currentSourceEpoch,!paused,sceneActive,!sourceRecovering {
                            resyncCostScope=ResyncCostScope(engine:ObjectIdentifier(core),epoch:next.sourceEpoch,nonce:next.nonce,rate:next.authorizedRate)
                            clockResync.costGuard.dispatched(nonce:next.nonce,commandUS:receipt.commandClock,rate:next.authorizedRate);emitResyncCost()
                        }
                        displayPolicy.command(at:receipt.commandClock,preserveTimeline:false);recordResync(2)
                    } else {
                        refreshSourceState()
                        let dispatchEpoch=currentSourceEpoch,dispatchRecovering=sourceRecovering
                        guard let receipt=await core.seek(next.target) else{throw VLCPlaybackError.seek}
                        guard active,engine===core,currentSeek?.nonce==next.nonce else{break}
                        let commandClock=receipt.commandClock
                        displayPolicy.command(at:commandClock,preserveTimeline:false)
                        currentSeek?.observationID=receipt.observationID;currentSeek?.sourceEpoch=dispatchEpoch
                        currentSeek?.sourceInvalidated=dispatchRecovering
                        currentSeek?.dispatched=true;currentSeek?.updates=poll.state.watch_updates;currentSeek?.started=now;currentSeek?.commandClock=commandClock;emitControl(5)
                        refreshSourceState()
                        observeSeek(.dispatch,nonce:next.nonce,poll:poll,seek:currentSeek)
                    }
                    continue
                }
                if let seek=currentSeek {
                    if !seek.isResync,seekObservations.due(nonce:seek.nonce,now:now) {
                        observeSeek(.progress,nonce:seek.nonce,poll:poll,seek:seek)
                    }
                    let expired=seek.isResync ? (!paused && sceneActive && now-lastFrameAt>30):now-seek.started>8
                    if expired{_ = seekGate?.finish(nonce:seek.nonce,observed:false);if seek.isResync{recordResync(6)};throw seek.isResync ? VLCPlaybackError.timeout:VLCPlaybackError.seek}
                    if let frame=poll.frame,let ptsUS=frame.displayEvidence.ptsUS,let policy=seekGate?.policy,
                       (seek.isResync ?
                            (!sourceRecovering && !seek.sourceInvalidated && frame.metadata.display_tick>=seek.commandClock && poll.state.watch_updates>seek.updates &&
                             ptsUS>=Int64((seek.target*1e6).rounded())-policy.halfWindowUS &&
                             policy.permitsFrame(ptsUS:ptsUS,clockUS:poll.state.time_us)):
                            policy.observedTarget(Int64((seek.target*1e6).rounded()),ptsUS:ptsUS,
                                             clockUS:poll.state.time_us,watchUpdates:poll.state.watch_updates,updatesBeforeDispatch:seek.updates) ||
                            (active && engine===core && paused && appliedPause==true && poll.state.paused && !poll.state.timer_seeking &&
                             sceneActive && !sourceRecovering && !seek.sourceInvalidated && seek.sourceEpoch==currentSourceEpoch &&
                             ticket==presentationTicket && seekGate?.active?.nonce==seek.nonce &&
                             policy.observedPausedTarget(Int64((seek.target*1e6).rounded()),ptsUS:ptsUS,
                                displayUS:frame.metadata.display_tick,commandID:seek.observationID,
                                witness:PausedSeekWitness(commandID:poll.seekObservation.command_id,targetUS:poll.seekObservation.target_us,
                                    beginUS:poll.seekObservation.begin_clock_us,endUS:poll.seekObservation.end_clock_us,
                                    startSequence:poll.seekObservation.start_sequence,endSequence:poll.seekObservation.end_sequence,
                                    startMatched:poll.seekObservation.start_matched,ended:poll.seekObservation.ended,
                                    ambiguous:poll.seekObservation.ambiguous)))) {
                        try validate(frame)
                        if let token,token != frame.metadata.producer_generation{throw VLCPlaybackError.seek}
                        token=frame.metadata.producer_generation
                        if !seek.isResync {
                            let ordinary=policy.observedTarget(Int64((seek.target*1e6).rounded()),ptsUS:ptsUS,
                                clockUS:poll.state.time_us,watchUpdates:poll.state.watch_updates,updatesBeforeDispatch:seek.updates)
                            observeSeek(.accepted,nonce:seek.nonce,poll:poll,seek:seek,completionPath:ordinary ? 1:2)
                        }
                        _ = seekGate?.finish(nonce:seek.nonce,observed:true)
                        if seek.dispatched,!seek.sourceInvalidated,!sourceRecovering,seek.sourceEpoch==currentSourceEpoch {
                            resumeSeekIdentity.completed(nonce:seek.nonce,engine:ObjectIdentifier(core),epoch:currentSourceEpoch)
                        }
                        currentSeek=nil;onPrefetchActivityChanged?();seek.continuation?.resume()
                        if seek.isResync {resyncObservedMS=max(0,(now-seek.started)*1000);recordResync(3)}
                        if pendingSeek==nil,seek.nonce==presentationTicket,(!seek.isResync || (!paused && sceneActive)) {
                            displayPolicy.acceptSeek(frame.displayEvidence)
                            if seek.isResync {clockResync.costGuard.firstPublication(nonce:seek.nonce,pts:frame.seconds)}
                            frameSession=UUID();controlDiagnostics.didPublish(pts:frame.seconds,now:now);automaticRecovery.published(now:now,pts:frame.seconds);PlaybackFlowTrace.measure(.publish,parent:frame.flow){onFrame(.init(pixel:frame.pixel,time:frame.seconds,session:frameSession,flow:frame.flow))};lastFrameAt=now
                        }
                    } else if poll.frame != nil {
                        PlaybackFlowTrace.mark(.discard,parent:poll.frame?.flow,a:2,b:Int64(seek.nonce))
                        controlDiagnostics.rejectedSeek()
                        if !seek.isResync,seekObservations.isActive(nonce:seek.nonce),let policy=seekGate?.policy {
                            seekObservationLastReject=[.lastRejectNonce:VLCControlDiagnostics.bounded(seek.nonce),
                                .lastRejectAt:now,.lastRejectClock:Double(poll.state.time_us)/1e6,
                                .lastRejectWatch:VLCControlDiagnostics.bounded(poll.state.watch_updates),
                                .lastRejectMask:Double(PlaybackVLCSeekDiagnostics.gateMask(frame:true,
                                    ptsUS:poll.frame?.displayEvidence.ptsUS,targetUS:Int64((seek.target*1e6).rounded()),
                                    clockUS:poll.state.time_us,watchUpdates:poll.state.watch_updates,
                                    watchFloor:seek.updates,halfWindowUS:policy.halfWindowUS))]
                            seekObservationLastReject[.lastRejectPTS]=poll.frame?.displayEvidence.ptsUS.map{Double($0)/1e6}
                        }
                    }
                    do {
                        let sleepFlow=PlaybackFlowTrace.begin(.pollSleep,a:10_000,b:Int64(bitPattern:presentationTicket),c:Int64(bitPattern:automatic.revision))
                        var sleepReturned=false
                        defer {PlaybackFlowTrace.end(sleepFlow,.pollSleep,a:sleepReturned ? 0:1,b:Int64(bitPattern:presentationTicket),c:Int64(bitPattern:automatic.revision))}
                        try await Task.sleep(for:.milliseconds(10))
                        sleepReturned=true
                    }
                    continue
                }
                var publishedPTS:Double?
                if let frame=poll.frame,ticket==presentationTicket,pendingSeek==nil {
                    try validate(frame)
                    if let token,token != frame.metadata.producer_generation{throw VLCPlaybackError.video}
                    token=frame.metadata.producer_generation
                    let decision=displayDecision(frame,poll:poll,ticket:ticket)
                    observeDisplay(decision,poll:poll)
                    if decision.accepted {
                        publishedPTS=frame.seconds;controlDiagnostics.didPublish(pts:frame.seconds,now:now);automaticRecovery.published(now:now,pts:frame.seconds);PlaybackFlowTrace.measure(.publish,parent:frame.flow){onFrame(.init(pixel:frame.pixel,time:frame.seconds,session:frameSession,flow:frame.flow))};lastFrameAt=now;ready=true
                    }else{PlaybackFlowTrace.mark(.discard,parent:frame.flow,a:3);controlDiagnostics.rejectedClock(now:now)}
                }
                updateAutomatic(now:now,poll:poll,publishedPTS:publishedPTS)
                if pendingSeek != nil {continue}
                waiting = !paused && now-lastFrameAt>0.5
                let state:NativePlaybackSession.State=paused ? .paused:waiting ? .waiting:ready ? .playing:.preparing
                if state != lastState{lastState=state;onState(state)}
                let speed=speedStatus;if speed != lastSpeed{lastSpeed=speed;onSpeed(speed)}
                let d=poll.diagnostics
                diagnosticsText="VLC 候選／硬解確認 \(d.vt_hardware)/\(d.vt_checks)／影格 \(d.frames_taken)／音訊開啟訊息觀測 \(d.audio_native_opened ? 1:0)"

                if d.ended {
                    guard ready else{throw VLCPlaybackError.video};onState(.ended);break
                }
                if !ready || !paused,now-lastFrameAt>30{throw VLCPlaybackError.timeout}
                let resyncReadsBefore=resyncSampling.earlyIssued+resyncSampling.legacyIssued
                let resyncChainBefore=resyncSampling.chain
                await sampleClockResync(core:core,poll:poll)
                await sampleHealthyRecovery(core:core,poll:poll,
                    resyncRead:resyncSampling.chain != resyncChainBefore ||
                        resyncSampling.earlyIssued+resyncSampling.legacyIssued != resyncReadsBefore)
                if pendingSeek != nil {continue}
                do {
                    let sleepFlow=PlaybackFlowTrace.begin(.pollSleep,a:8_000,b:Int64(bitPattern:presentationTicket),c:Int64(bitPattern:automatic.revision))
                    var sleepReturned=false
                    defer {PlaybackFlowTrace.end(sleepFlow,.pollSleep,a:sleepReturned ? 0:1,b:Int64(bitPattern:presentationTicket),c:Int64(bitPattern:automatic.revision))}
                    try await Task.sleep(for:.milliseconds(8))
                    sleepReturned=true
                }
            }
        } catch {terminal=error;terminalReason=Double((error as? VLCPlaybackError)?.rawValue ?? (error is CancellationError ? 12:13))}
        let cancelled=Task.isCancelled || !active || terminal is CancellationError
        if !cancelled {
            let reason:PlaybackAutomaticRecoveryDiagnostics.EndReason=terminal==nil ? .ended:
                (terminal as? VLCPlaybackError) == .source ? .sourceFailure:.invalidObservation
            emitRecovery(automaticRecovery.interrupt(reason,now:ProcessInfo.processInfo.systemUptime))
        }
        let resumeTerminal:VLCResumeRecord.Outcome=cancelled ? .stopped:terminal==nil ? .ended:.failed
        if let core=engine,let (snapshot,status)=await core.finishResume(VLCResumeObserver.reason(resumeTerminal)) {
            emitResume(resumeBoundary.finish(resumeTerminal,snapshot:snapshot,nativeFinishStatus:status,nowUS:VLCVistaClock()))
        } else {emitResume(resumeBoundary.finish(resumeTerminal,nowUS:VLCVistaClock()))}
        let frameTerminal=VLCFrameStageRecord.Outcome(rawValue:resumeTerminal.rawValue) ?? .unavailable
        if let core=engine,let (snapshot,status)=await core.finishFrame(VLCResumeObserver.reason(resumeTerminal)) {
            emitFrame(frameStage.finish(frameTerminal,snapshot:snapshot,nativeFinishStatus:status,nowUS:VLCVistaClock()))
        } else {emitFrame(frameStage.finish(frameTerminal,nowUS:VLCVistaClock()))}
        let audioTerminal:VLCAudioBoundaryRecord.Outcome=cancelled ? .stopped:terminal==nil ? .ended:.failed
        if let core=engine,let (snapshot,status)=await core.finishAudio(audioReason(audioTerminal)) {
            emitAudio(audioBoundary.finish(audioTerminal,snapshot:snapshot,finishStatus:status,after:audioVideo()))
        } else {emitAudio(audioBoundary.finish(audioTerminal,after:audioVideo()))}
        if audioCommand>0 {
            LifecycleDiagnostics.shared.record(.playbackAudioBoundary,[.scope:134,.session:Double(speedSession),
                .command:Double(audioCommand),.phase:3,.outcome:Double(audioTerminal.rawValue),
                .entryCount:Double(audioBoundary.emitted),.detail:Double(audioBoundary.suppressed)])
        }
        let flowCleanup=PlaybackFlowTrace.begin(.cleanup)
        stop()
        // Source/player and independent renderer pixel lifetimes are separate barriers.
        do {if let drainPresentation{try await drainPresentation(false)}}
        catch {terminal=VLCPlaybackError.drain;terminalReason=Double(VLCPlaybackError.drain.rawValue)}
        // A renderer error does not leave source reads or native audio running.
        do {if let engine{try await engine.close()}else{try await owner.closeAfterDrain()}}
        catch {terminal=VLCPlaybackError.drain;terminalReason=Double(VLCPlaybackError.drain.rawValue)}
        emitControl(terminal==nil ? 7:8)
        if let completion=automaticRecovery.finish(now:ProcessInfo.processInfo.systemUptime) {
            emitRecovery(completion.terminal)
            PlaybackLogStore.shared.enqueue(PlaybackLogRecord(automaticRecoverySummary:completion.summary,session:speedSession))
        }
        engine=nil;ready=false;onSpeed(speedStatus)
        PlaybackFlowTrace.end(flowCleanup,.cleanup)
        if flowOwned {
            let flowResult=await PlaybackFlowTrace.finish(session:speedSession)
            LifecycleDiagnostics.shared.record(.playbackAudioBoundary,[.scope:141,.session:Double(speedSession),.outcome:Double(flowResult["status"] ?? 9),.entryCount:Double(flowResult["records"] ?? 0),.detail:Double((flowResult["contentionLost"] ?? 0)+(flowResult["mapLost"] ?? 0))])
            flowOwned=false
        }
        if let terminal {
            if !cancelled {failureMessage=(terminal as? VLCPlaybackError)?.localizedDescription ?? VLCPlaybackError.source.localizedDescription}
            throw terminal
        }
        if cancelled{throw CancellationError()}
    }
}
#endif
