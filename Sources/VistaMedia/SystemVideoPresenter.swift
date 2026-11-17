import Foundation
import ImageIO
import RealityKit
import Observation
import AVFoundation
import CoreImage
#if SWIFT_PACKAGE
import VistaCore
#endif

/// Candidate only: a single pending pixel buffer, one serial flush/enqueue worker, existing timeline upstream.
@MainActor @Observable final class SystemVideoPresenter {
    @ObservationIgnored private var flowWorkerStarted:Double?
    /// Uses existing UI/status polling only. Startup/configuration work is excluded.
    func observeFlowStall() {
        if let started=flowWorkerStarted,ProcessInfo.processInfo.systemUptime-started>=0.2 {PlaybackFlowTrace.trigger(3)}
    }
    let entity=ModelEntity()
    @ObservationIgnored private var flowCurrent=PlaybackFlowToken.none
    @ObservationIgnored private let boundary:PlaybackBoundaryTrace
    // Epoch causes are scope 3 only: 1 new session, 2 settings, 3 scene,
    // 4 requires-flush recovery, 5 first terminal failure, 6 effective stop.
    // Stage details: 11 worker flush, 12 tail flush,
    // 13 immediate flush;
    // 21 failed-session guard, 22 inactive, 23 stale after flush, 24 stale queue,
    // 25 stale catch; 31 resume failure, 32 prepare, 33 queue, 34 sample,
    // 35 injected failure, 36 asynchronous status failure.
    // Cached observations below are the values read by the original control flow,
    // not a simultaneous renderer snapshot. Instrumentation never adds API reads.
    @ObservationIgnored private var flowSpans:[PlaybackFlowStage:PlaybackFlowToken]=[:]
    @ObservationIgnored private var observedFailed:Bool?
    @ObservationIgnored private var observedAcceptsSamples:Bool?
    init() {boundary=PlaybackBoundaryTrace(scope:3)}
    #if DEBUG
    init(diagnostics:LifecycleDiagnostics) {boundary=PlaybackBoundaryTrace(scope:3,diagnostics:diagnostics)}
    #endif
    private func trace(_ stage:PlaybackBoundaryStage,ticket:Int?=nil,
                       fields:@autoclosure ()->[LifecycleField:Double]=[:],once:Bool=true,
                       context:PlaybackBoundaryTrace.Context?=nil) {
        // Existing boundary calls become per-frame transitions in the independent bounded lane.
        let flowStage:PlaybackFlowStage?
        switch stage {
        case .flushEntered,.flushReturned:flowStage = .flush
        case .materialEntered,.materialReturned:flowStage = .material
        case .readinessWaitEntered,.readinessWaitReturned:flowStage = .readyWait
        case .sampleEntered,.sampleReturned:flowStage = .sample
        case .enqueueEntered,.enqueueReturned:flowStage = .enqueue
        case .resultEnabled:flowStage = .entity
        case .discarded:flowStage = .discard
        case .failure:flowStage = .failure
        case .generationChanged:flowStage = .state
        default:flowStage=nil
        }
        if let flowStage {
            let f=fields();let parent=flowCurrent
            if [.flushEntered,.materialEntered,.readinessWaitEntered,.sampleEntered,.enqueueEntered].contains(stage) {
                flowSpans[flowStage]=PlaybackFlowTrace.begin(flowStage,parent:parent,a:Int64(generation),b:Int64(f[.detail] ?? 0))
            } else if [.flushReturned,.materialReturned,.readinessWaitReturned,.sampleReturned,.enqueueReturned].contains(stage) {
                if let span=flowSpans.removeValue(forKey:flowStage){PlaybackFlowTrace.end(span,flowStage,a:Int64(generation),b:Int64(f[.acceptsSamples] ?? -1))}
            } else {PlaybackFlowTrace.mark(flowStage,parent:parent,a:Int64(generation),b:Int64(f[.detail] ?? 0),c:Int64(f[.outcome] ?? 0))}
        }
        guard boundary.shouldRecord(stage,once:once,context:context) else{return}
        var values=fields()
        if values[.session]==nil,let session=recovery.session {
            values[.session]=Double(PlaybackBoundaryIdentity.session(session))
        }
        if let ticket {values[.ticket]=Double(ticket)}
        boundary.record(stage,generation:generation,fields:values,once:once,context:context)
    }
    private func generationChanged() {
        trace(.generationChanged,fields:[.active:recovery.sceneActive ? 1:0],once:false)
    }
    @ObservationIgnored var onRecoverableInterruption:((UUID)->Bool)?
    #if DEBUG
    /// In-process deterministic test seam. Release always uses the real renderer.
    struct TestIO {
        var requiresFlush:()->Bool
        var failed:()->Bool
        var ready:()->Bool
        var flush:(Bool) async ->Void
        var flushImmediately:()->Void
        var enqueue:(CMSampleBuffer)->Void
    }
    @ObservationIgnored var testIO:TestIO?
    var testWorkerActive:Bool {worker != nil}
    var testVideoRenderer:AVSampleBufferVideoRenderer {video}
    private(set) var testRendererReplacementCount=0
    /// Artificially fills the current observation window, without changing renderer state.
    /// Only the synthetic renderer seam can use this exhaustion test hook.
    func exhaustTraceBudgetForTesting() {
        guard testIO != nil else{return}
        for _ in 0..<PlaybackBoundaryTrace.eventLimitPerEpoch {
            trace(.discarded,fields:[.detail:24],once:false)
        }
    }
    #endif
    private var requiresFlush:Bool {
        #if DEBUG
        if let testIO {return observedRequiresFlush(testIO.requiresFlush())}
        #endif
        return observedRequiresFlush(video.requiresFlushToResumeDecoding)
    }
    private func observedRequiresFlush(_ value:Bool)->Bool {
        PlaybackFlowTrace.mark(.state,parent:flowCurrent,a:1,b:value ? 1:0,c:Int64(generation))
        trace(.requiresFlushObserved,fields:[.requiresFlush:value ? 1:0])
        return value
    }
    private var hasFailed:Bool {
        #if DEBUG
        if let testIO {let value=testIO.failed();observedFailed=value;return value}
        #endif
        let value=video.status == .failed;observedFailed=value;PlaybackFlowTrace.mark(.state,parent:flowCurrent,a:2,b:value ? 1:0,c:Int64(generation));return value
    }
    private var acceptsSamples:Bool {
        #if DEBUG
        if let testIO {let value=testIO.ready();observedAcceptsSamples=value;return value}
        #endif
        let value=video.isReadyForMoreMediaData;observedAcceptsSamples=value;PlaybackFlowTrace.mark(.state,parent:flowCurrent,a:3,b:value ? 1:0,c:Int64(generation));return value
    }
    private var buildsMaterial:Bool {
        #if DEBUG
        if testIO != nil {return false}
        #endif
        return true
    }
    private func flush(removingDisplayedImage:Bool) async {
        #if DEBUG
        if let testIO {await testIO.flush(removingDisplayedImage);return}
        #endif
        await video.flush(removingDisplayedImage:removingDisplayedImage)
    }
    private func flushImmediately() {
        #if DEBUG
        if let testIO {testIO.flushImmediately();return}
        #endif
        video.flush()
    }
    private func enqueue(_ sample:CMSampleBuffer) {
        sampleEvidenceGeneration=generation;sampleEvidenceFlow=flowCurrent.id
        sampleEvidencePTS=Self.scalarMicroseconds(CMTimeGetSeconds(sample.presentationTimeStamp))
        sampleEvidenceOutputPTS=Self.scalarMicroseconds(CMTimeGetSeconds(sample.outputPresentationTimeStamp))
        sampleEvidenceDuration=Self.scalarMicroseconds(CMTimeGetSeconds(sample.duration))
        sampleEvidenceFlags=0
        if let attachments=sample.sampleAttachments.first {
            if let immediate=attachments[.displayImmediately] as? Bool {
                sampleEvidenceFlags |= 1;if immediate {sampleEvidenceFlags |= 2}
            }
            if let suppressed=attachments[.doNotDisplay] as? Bool {
                sampleEvidenceFlags |= 4;if suppressed {sampleEvidenceFlags |= 8}
            }
        }
        let context=boundary.context(),ticket=generation
        trace(.enqueueEntered,ticket:ticket,context:context)
        defer{trace(.enqueueReturned,ticket:ticket,context:context)}
        #if DEBUG
        if let testIO {testIO.enqueue(sample);return}
        #endif
        video.enqueue(sample)
    }
    let context=CIContext()
    var ready=false
    var error:String?
    var probe=""
    private var inputProbe=""
    @ObservationIgnored private var probeTask:Task<Void,Never>?
    @ObservationIgnored private var statusTask:Task<Void,Never>?
    @ObservationIgnored private var failedSession:UUID?
    @ObservationIgnored private var video=AVSampleBufferVideoRenderer()
    // One bounded format cache for the presenter, not a fresh cache per short-lived worker.
    @ObservationIgnored private let samples=SystemVideoSamples()
    @ObservationIgnored private var sharedVideoMaterial:VideoMaterial?
    @ObservationIgnored private var configuredSettings:VRSettings?
    #if DEBUG
    @available(macOS 15.0,*)
    var packingImageSize:CGSize? {sharedVideoMaterial?.controller.currentImageSize}
    @available(macOS 15.0,*)
    var packingState:String {
        let size=sharedVideoMaterial?.controller.currentImageSize
        return "layout=\(configuredSettings?.layout.rawValue ?? "nil") image=\(size?.width ?? -1)x\(size?.height ?? -1) mode=\(String(describing:sharedVideoMaterial?.controller.currentViewingMode)) ready=\(ready) error=\(error ?? "none")"
    }
    #endif
    private(set) var materialCreationCount=0
    private(set) var lastSubmittedSession:UUID?
    private(set) var lastSubmittedAt:Double?
    @available(macOS 26.0,visionOS 26.0,*)
    private func material()->VideoMaterial {
        if let sharedVideoMaterial {return sharedVideoMaterial}
        let created=VideoMaterial(videoRenderer:video)
        sharedVideoMaterial=created;materialCreationCount += 1
        return created
    }
    @ObservationIgnored private var pending:(DecodedVideoFrame,VRSettings)?
    @ObservationIgnored private var worker:Task<Void,Never>?
    @ObservationIgnored private var generation=0
    @ObservationIgnored private var current:(UUID,VRSettings)?
    @ObservationIgnored private var needsFlush=true
    @ObservationIgnored private var recovery=VideoRendererRecoveryGate()
    @ObservationIgnored private var recoveryFlushPending=false
    @ObservationIgnored private var retained:(DecodedVideoFrame,VRSettings)?
    @ObservationIgnored private var isStopped=true
    // One bounded held renderer, never a queue of old generations. Its displayed
    // source surface remains retained by AVFoundation until owned new enqueue.
    private struct HeldPresentation {
        let renderer:AVSampleBufferVideoRenderer
        let material:VideoMaterial?
        let settings:VRSettings?
        let token:PlaybackFlowToken
        let byteCount:Int
    }
    @ObservationIgnored private var heldPresentation:HeldPresentation?
    @ObservationIgnored private var stagedModel:ModelComponent?
    @ObservationIgnored private var bindingCheckedGeneration = -1
    @ObservationIgnored private var surfaceObservationGeneration = -1
    @ObservationIgnored private var surfaceObservationCount = 0
    // Scalar metadata of the actual most recently enqueued CMSampleBuffer.
    @ObservationIgnored private var sampleEvidenceGeneration = -1
    @ObservationIgnored private var sampleEvidenceFlow:UInt64=0
    @ObservationIgnored private var sampleEvidencePTS=Int64.min
    @ObservationIgnored private var sampleEvidenceOutputPTS=Int64.min
    @ObservationIgnored private var sampleEvidenceDuration=Int64.min
    @ObservationIgnored private var sampleEvidenceFlags:Int64=0
    @ObservationIgnored private var blockedHoldInput:ObjectIdentifier?
    @ObservationIgnored private var blockedHoldFlow:UInt64?
    @ObservationIgnored private var drainSerial:UInt64=0
    @ObservationIgnored private var lastOwnedFlow:UInt64=0
    @ObservationIgnored private var maxEnqueuedByteCount=0
    static let holdByteLimit=256*1024*1024
    // Scalars only: no diagnostic retain of a pixel buffer or IOSurface.
    private struct HoldByteEstimate {
        let reported:Int, planeSum:Int, bytes:Int, width:Int, height:Int, planes:Int
        let format:UInt32, overflow:Int
    }
    @ObservationIgnored private var lastByteEstimate:HoldByteEstimate?
    @ObservationIgnored private var maxByteEstimate:HoldByteEstimate?
    @ObservationIgnored private var maxByteFlow:UInt64=0
    @ObservationIgnored private var byteMaxLogs=0
    @ObservationIgnored private var byteMaxSuppressed=0
    private static func holdByteEstimate(_ pixel:CVPixelBuffer)->HoldByteEstimate {
        let reported=CVPixelBufferGetDataSize(pixel)
        let planes=CVPixelBufferGetPlaneCount(pixel)
        var bytes=0,overflow=0
        for plane in 0..<max(planes,1) {
            let row=planes>0 ? CVPixelBufferGetBytesPerRowOfPlane(pixel,plane):CVPixelBufferGetBytesPerRow(pixel)
            let height=planes>0 ? CVPixelBufferGetHeightOfPlane(pixel,plane):CVPixelBufferGetHeight(pixel)
            let product=row.multipliedReportingOverflow(by:height)
            let sum=bytes.addingReportingOverflow(product.partialValue)
            if product.overflow || sum.overflow {
                overflow=(product.overflow ? 1:0)|(sum.overflow ? 2:0);bytes=Int.max;break
            }
            bytes=sum.partialValue
        }
        return HoldByteEstimate(reported:reported,planeSum:bytes,
            bytes:overflow == 0 ? max(reported,bytes):Int.max,
            width:CVPixelBufferGetWidth(pixel),height:CVPixelBufferGetHeight(pixel),planes:planes,
            format:CVPixelBufferGetPixelFormatType(pixel),overflow:overflow)
    }
    private static func holdByteCount(_ pixel:CVPixelBuffer)->Int {holdByteEstimate(pixel).bytes}
    private func traceHoldByteEstimate(_ value:HoldByteEstimate,reason:Int64,source:UInt64,parent:PlaybackFlowToken?=nil) {
        let flow=PlaybackFlowTrace.begin(.holdByteEstimate,parent:parent ?? PlaybackFlowToken(source),a:1,b:reason,c:Int64(bitPattern:source))
        PlaybackFlowTrace.mark(.holdByteValues,parent:flow,a:Int64(value.reported),b:Int64(value.planeSum),c:Int64(value.bytes))
        PlaybackFlowTrace.mark(.holdByteDimensions,parent:flow,a:Int64(value.width),b:Int64(value.height),c:Int64(value.format))
        PlaybackFlowTrace.mark(.holdByteLayout,parent:flow,a:Int64(value.planes),b:Int64(value.overflow),c:Int64(generation))
        PlaybackFlowTrace.mark(.holdByteIdentity,parent:flow,a:Int64(bitPattern:lastOwnedFlow),b:Int64(bitPattern:maxByteFlow),c:Int64(maxEnqueuedByteCount))
        PlaybackFlowTrace.end(flow,.holdByteEstimate,a:Int64(byteMaxLogs),b:Int64(byteMaxSuppressed))
    }
    private func recordHoldByteEstimate(_ pixel:CVPixelBuffer) {
        let value=Self.holdByteEstimate(pixel)
        lastByteEstimate=value
        if value.bytes>maxEnqueuedByteCount {
            maxByteEstimate=value;maxByteFlow=lastOwnedFlow
            maxEnqueuedByteCount=value.bytes
            if byteMaxLogs<8 {byteMaxLogs+=1;traceHoldByteEstimate(value,reason:1,source:lastOwnedFlow)}
            else {byteMaxSuppressed+=1}
        }
    }
    private func snapshotHoldByteEstimates() {
        if let value=lastByteEstimate {traceHoldByteEstimate(value,reason:2,source:lastOwnedFlow,parent:PlaybackFlowTrace.parent)}
        if let value=maxByteEstimate {traceHoldByteEstimate(value,reason:3,source:maxByteFlow,parent:PlaybackFlowTrace.parent)}
    }
    private func resetHoldByteEstimates() {
        lastByteEstimate=nil;maxByteEstimate=nil;maxByteFlow=0;byteMaxLogs=0;byteMaxSuppressed=0
    }
    private func releaseHeldPresentation(reason:Int64,hide:Bool,newFlow:UInt64=0) {
        guard let held=heldPresentation else{return}
        PlaybackFlowTrace.mark(.presentationHoldRelease,parent:held.token,a:reason,b:Int64(bitPattern:newFlow),c:Int64(held.byteCount))
        heldPresentation=nil;stagedModel=nil;blockedHoldInput=nil;blockedHoldFlow=nil
        if hide {entity.model=nil;entity.isEnabled=false;ready=false}
    }
    private func installModel(_ model:ModelComponent) {
        if heldPresentation != nil {stagedModel=model} else {entity.model=model}
    }

    /// Verify the software binding, not whether the compositor emitted light.
    /// No await: only the current worker generation can install this candidate.
    @available(macOS 26.0,visionOS 26.0,*)
    private func ensureCurrentMaterialBinding()->Bool {
        guard buildsMaterial else{return true}
        if bindingCheckedGeneration==generation {return true}
        let candidate=heldPresentation == nil ? entity.model:stagedModel
        let actual=candidate?.materials.first as? VideoMaterial
        if actual?.videoRenderer === video {
            bindingCheckedGeneration=generation
            return true
        }
        // A missing staged model may reuse the held mesh only for the exact
        // same projection/packing. A different format must never borrow it.
        var repaired=candidate
        if repaired == nil,let held=heldPresentation,let old=held.settings,
           let configuredSettings,sameVideoFormat(old,configuredSettings) {
            repaired=entity.model
        }
        guard var repaired else {
            observePresentationBoundary(reason:12)
            return false
        }
        if sharedVideoMaterial?.videoRenderer !== video {sharedVideoMaterial=nil}
        let replacement=material()
        #if os(visionOS)
        replacement.controller.preferredViewingMode = configuredSettings?.layout == .mono ? .mono:.stereo
        #endif
        repaired.materials=[replacement]
        installModel(repaired)
        bindingCheckedGeneration=generation
        observePresentationBoundary(reason:11)
        return true
    }

    private static func scalarMicroseconds(_ value:Double)->Int64 {
        value.isFinite && abs(value)<1e12 ? Int64((value*1_000_000).rounded()):Int64.min
    }

    /// Bounded scalar diagnostics. Image dimensions/status are API evidence,
    /// never proof of a nonblack input or physical display. No pixel readback.
    @available(macOS 26.0,visionOS 26.0,*)
    func observePresentationBoundary(reason:Int64) {
        guard buildsMaterial else{return}
        let actual=entity.model?.materials.first as? VideoMaterial
        let staged=stagedModel?.materials.first as? VideoMaterial
        let size=actual?.controller.currentImageSize
        var flags:Int64=0
        if entity.model != nil {flags |= 1}
        if actual?.videoRenderer === video {flags |= 2}
        if sharedVideoMaterial?.videoRenderer === video {flags |= 4}
        if stagedModel != nil {flags |= 8}
        if staged?.videoRenderer === video {flags |= 16}
        if heldPresentation != nil {flags |= 32}
        if entity.isEnabled {flags |= 64}
        if entity.isEnabledInHierarchy {flags |= 128}
        if entity.isActive {flags |= 256}
        if entity.isAnchored {flags |= 512}
        if entity.scene != nil {flags |= 1024}
        if entity.parent != nil {flags |= 2048}
        if ready {flags |= 4096}
        if recovery.sceneActive {flags |= 8192}
        let flow=PlaybackFlowTrace.begin(.presentationBinding,parent:flowCurrent.id == 0 ? PlaybackFlowToken(lastOwnedFlow):flowCurrent,a:reason,b:Int64(generation),c:Int64(bitPattern:lastOwnedFlow))
        PlaybackFlowTrace.mark(.presentationSurface,parent:flow,a:flags,b:Int64(video.status.rawValue),c:video.requiresFlushToResumeDecoding ? 1:0)
        func milli(_ x:Double)->Int64 {x.isFinite && abs(x)<1e12 ? Int64((x*1000).rounded()):Int64.min}
        PlaybackFlowTrace.mark(.presentationGeometry,parent:flow,a:size.map{milli(Double($0.width))} ?? -1,b:size.map{milli(Double($0.height))} ?? -1,c:Int64(entity.model?.materials.count ?? 0))
        let orientation=entity.orientation(relativeTo:nil).vector
        PlaybackFlowTrace.mark(.presentationPose,parent:flow,a:1,b:milli(Double(orientation.x)),c:milli(Double(orientation.y)))
        PlaybackFlowTrace.mark(.presentationPose,parent:flow,a:2,b:milli(Double(orientation.z)),c:milli(Double(orientation.w)))
        // These reads are bracketed by this packet; rate and time are not an
        // atomic sample and do not identify an actual compositor presentation.
        PlaybackFlowTrace.mark(.presentationClock,parent:flow,a:Self.scalarMicroseconds(CMTimebaseGetRate(video.timebase)),b:Self.scalarMicroseconds(CMTimeGetSeconds(CMTimebaseGetTime(video.timebase))),c:0)
        PlaybackFlowTrace.mark(.presentationSample,parent:flow,a:1,b:sampleEvidenceOutputPTS,c:sampleEvidenceDuration)
        PlaybackFlowTrace.mark(.presentationSample,parent:flow,a:2,b:Int64(bitPattern:sampleEvidenceFlow),c:Int64(sampleEvidenceGeneration))
        PlaybackFlowTrace.mark(.presentationSample,parent:flow,a:3,b:sampleEvidenceFlags,c:sampleEvidencePTS)
        PlaybackFlowTrace.end(flow,.presentationBinding)
    }

    func setSceneActive(_ active:Bool) {
        guard recovery.setSceneActive(active) else{return}
        if !active {blockedHoldInput=nil;blockedHoldFlow=nil}
        releaseHeldPresentation(reason:3,hide:true)
        boundary.begin(reason:3,generation:generation)
        trace(.sceneEntered,fields:[.active:active ? 1:0])
        generation += 1;pending=nil;needsFlush=true;recoveryFlushPending=false
        generationChanged()
        ready=false;entity.isEnabled=false
        statusTask?.cancel();statusTask=nil
        probeTask?.cancel();probeTask=nil
        // Never flush here: the serial worker owns flush/enqueue ordering.
        // The view submits its current frame on activation, avoiding stale retained UI.
        trace(.sceneReturned,fields:[.active:active ? 1:0])
    }

    /// Returns true only when the explicit requires-flush interruption was handled.
    private func recoverIfRequired()->Bool {
        guard requiresFlush,let retained else{return false}
        boundary.begin(reason:4,generation:generation)
        trace(.requiresFlushObserved,fields:[.requiresFlush:1])
        // This is synchronous on MainActor: pause the matching upstream player before
        // recovery starts. A stale frame or a preparation/seek stop must not reappear.
        if let onRecoverableInterruption {
            trace(.upstreamPauseEntered)
            let accepted=onRecoverableInterruption(retained.0.session)
            trace(.upstreamPauseReturned,fields:[.outcome:accepted ? 0:1])
            if !accepted {
                trace(.recoveryDecision,fields:[.outcome:3])
                stop();return true
            }
        }
        let decision=recovery.requestRecovery()
        // Recovery outcomes: 0 deferred, 1 retry, 2 exhausted/missing, 3 upstream rejected.
        trace(.recoveryDecision,fields:[.outcome:decision == .deferred ? 0:decision == .retry ? 1:2,.worker:worker == nil ? 0:1])
        switch decision {
        case .failed:return false
        case .deferred:
            generation += 1;pending=nil;needsFlush=true
        case .retry:
            generation += 1;needsFlush=true;recoveryFlushPending=true
            pending=retained
        }
        generationChanged()
        ready=false;entity.isEnabled=false
        statusTask?.cancel();statusTask=nil
        probeTask?.cancel();probeTask=nil
        if recovery.sceneActive,worker == nil {
            if #available(macOS 26.0,visionOS 26.0,*) {submit(retained.0,settings:retained.1)}
        }
        return true
    }

    private func fail(session:UUID?,stage:String) {
        // Preserve a first terminal failure even after a busy observation window fills.
        // Repeated failures of the same failed session never replenish its diagnostic budget.
        if failedSession != session || error == nil {boundary.begin(reason:5,generation:generation)}
        releaseHeldPresentation(reason:4,hide:true)
        failedSession=session;pending=nil;needsFlush=true;recoveryFlushPending=false
        error=failureMessage(stage:stage);ready=false;entity.isEnabled=false
        let detail=["resume":31,"prepare":32,"queue":33,"sample":34,"injected":35,"async":36][stage] ?? 0
        var fields:[LifecycleField:Double]=[.detail:Double(detail),.outcome:2]
        if let session {fields[.session]=Double(PlaybackBoundaryIdentity.session(session))}
        if let observedFailed {fields[.rendererFailed]=observedFailed ? 1:0}
        trace(.failure,fields:fields,once:false)
    }
    func stop() {
        blockedHoldInput=nil;blockedHoldFlow=nil
        let wasHolding=heldPresentation != nil
        releaseHeldPresentation(reason:2,hide:true)
        // A held drain is logically stopped for submission, but still owns a
        // displayed source until its pending worker/flush has completed.
        guard !isStopped || wasHolding else{return}
        boundary.begin(reason:6,generation:generation)
        let stoppedSession=recovery.session.map {Double(PlaybackBoundaryIdentity.session($0))} ?? 0
        trace(.stopEntered,fields:[.worker:worker == nil ? 0:1,.session:stoppedSession],once:false)
        isStopped=true
        generation += 1;pending=nil;retained=nil;needsFlush=true;recoveryFlushPending=false
        samples.reset()
        recovery.stop();ready=false;entity.isEnabled=false
        generationChanged()
        probeTask?.cancel();probeTask=nil;probe="";inputProbe=""
        statusTask?.cancel();statusTask=nil
        // The existing serial worker finishes any flush before a later generation can enqueue.
        if worker == nil {
            trace(.flushEntered,fields:[.detail:13,.session:stoppedSession],once:false)
            flushImmediately()
            trace(.flushReturned,fields:[.detail:13,.session:stoppedSession],once:false)
        }
        trace(.stopReturned,fields:[.worker:worker == nil ? 0:1,.session:stoppedSession],once:false)
    }
    #if VISTA_VLC_CANDIDATE
    @ObservationIgnored private var draining=false
    func stopAndDrain(preservingPresentedImage preserve:Bool=false,blockedInput:DecodedVideoFrame?=nil) async {
        drainSerial &+= 1
        let serial=drainSerial
        draining=true
        defer {if serial==drainSerial {draining=false}}
        if preserve {snapshotHoldByteEstimates()}
        let canHold=preserve && recovery.sceneActive &&
            (heldPresentation != nil || (ready && entity.isEnabled && entity.model != nil &&
             maxEnqueuedByteCount>0 && maxEnqueuedByteCount<=Self.holdByteLimit))
        if canHold {
            let flow=PlaybackFlowTrace.begin(.presentationHold,a:1,b:Int64(generation),c:Int64(maxEnqueuedByteCount))
            defer {PlaybackFlowTrace.end(flow,.presentationHold,a:heldPresentation == nil ? 0:1)}
            if heldPresentation == nil {
                heldPresentation=HeldPresentation(renderer:video,material:sharedVideoMaterial,
                    settings:configuredSettings,token:flow,byteCount:maxEnqueuedByteCount)
            }
            if let blockedInput {
                blockedHoldInput=ObjectIdentifier(blockedInput)
                blockedHoldFlow=blockedInput.flow.id == 0 ? nil:blockedInput.flow.id
            }
            PlaybackFlowTrace.mark(.presentationHoldState,parent:flow,a:10,b:Int64(bitPattern:blockedHoldFlow ?? 0),c:Int64(maxEnqueuedByteCount))
            PlaybackFlowTrace.mark(.presentationHoldState,parent:flow,a:11,b:Int64(bitPattern:lastOwnedFlow),c:Int64(generation))
            PlaybackFlowTrace.mark(.presentationHoldState,parent:flow,a:12,b:Int64(lastSubmittedSession.map{PlaybackBoundaryIdentity.session($0)} ?? 0),c:1)
            let drainingRenderer=video
            generation += 1
            let ticket=generation
            pending=nil;retained=nil;needsFlush=false;recoveryFlushPending=false
            isStopped=true;ready=false;samples.reset();recovery.stop()
            probeTask?.cancel();probeTask=nil;statusTask?.cancel();statusTask=nil
            worker?.cancel()
            let existing=worker;await existing?.value
            guard serial==drainSerial,ticket==generation,recovery.sceneActive,heldPresentation != nil else{
                // Another auto drain may own this same held renderer. Only a
                // true release/stop is allowed to remove its displayed image.
                if heldPresentation?.renderer !== drainingRenderer {
                    await drainingRenderer.flush(removingDisplayedImage:true)
                }
                return
            }
            // This completion drops every pending sample. Only the one current
            // displayed image is deliberately retained; no new work targets it.
            let isHeld=heldPresentation?.renderer === drainingRenderer
            await drainingRenderer.flush(removingDisplayedImage:!isHeld)
            guard serial==drainSerial,ticket==generation,recovery.sceneActive,heldPresentation != nil else{
                // Another auto drain may own this same held renderer. Only a
                // true release/stop is allowed to remove its displayed image.
                if heldPresentation?.renderer !== drainingRenderer {
                    await drainingRenderer.flush(removingDisplayedImage:true)
                }
                return
            }
            context.clearCaches()
            stagedModel=nil;sharedVideoMaterial=nil;configuredSettings=nil
            video=AVSampleBufferVideoRenderer();current=nil;samples.reset();maxEnqueuedByteCount=0;resetHoldByteEstimates()
            PlaybackFlowTrace.mark(.presentationHoldState,parent:flow,a:1,b:Int64(ticket),c:isHeld ? 1:0)
            return
        }
        PlaybackFlowTrace.mark(.presentationHoldState,a:1,b:preserve ? 1:0,c:Int64(maxEnqueuedByteCount))
        stop();pending=nil;retained=nil
        if preserve,let blockedInput {
            blockedHoldInput=ObjectIdentifier(blockedInput)
            blockedHoldFlow=blockedInput.flow.id == 0 ? nil:blockedInput.flow.id
        }
        let ticket=generation
        let existing=worker;await existing?.value
        guard serial==drainSerial,ticket==generation else{return}
        await flush(removingDisplayedImage:true)
        guard serial==drainSerial,ticket==generation else{return}
        context.clearCaches()
        entity.model=nil;sharedVideoMaterial=nil;configuredSettings=nil;stagedModel=nil
        video=AVSampleBufferVideoRenderer();current=nil;samples.reset();maxEnqueuedByteCount=0;resetHoldByteEstimates()
        #if DEBUG
        testRendererReplacementCount += 1
        #endif
    }
    #endif
    @available(macOS 26.0,visionOS 26.0,*)
    func submit(_ frame:DecodedVideoFrame,settings:VRSettings) {
        let previousFlow=flowCurrent;flowCurrent=frame.flow
        let flowSubmit=PlaybackFlowTrace.begin(.presentSubmit,parent:frame.flow,a:Int64(generation));defer{PlaybackFlowTrace.end(flowSubmit,.presentSubmit);flowCurrent=previousFlow}
        #if VISTA_VLC_CANDIDATE
        guard !draining else{return}
        #endif
        if (blockedHoldInput != nil || blockedHoldFlow != nil),
           (blockedHoldFlow.map{$0==frame.flow.id} ?? (blockedHoldInput==ObjectIdentifier(frame))) {
            PlaybackFlowTrace.mark(.presentationHoldState,parent:heldPresentation?.token ?? PlaybackFlowToken.none,a:3,b:Int64(generation),c:1)
            return
        }
        if failedSession != frame.session {
            if recovery.session != frame.session {boundary.begin(reason:1,generation:generation)}
            else if let retained,!sameVideoFormat(retained.1,settings) {boundary.begin(reason:2,generation:generation)}
        }
        let submitContext=boundary.context()
        trace(.submitEntered,fields:[.session:Double(PlaybackBoundaryIdentity.session(frame.session))],context:submitContext)
        defer{trace(.submitReturned,context:submitContext)}
        guard failedSession != frame.session else {
            trace(.discarded,fields:[.detail:21]);return
        }
        if let held=heldPresentation,let heldSettings=held.settings,!sameVideoFormat(heldSettings,settings) {releaseHeldPresentation(reason:5,hide:true)}
        isStopped=false
        recovery.selectSession(frame.session)
        let previousFrame=retained?.0
        retained=(frame,settings)
        guard recovery.sceneActive else {
            trace(.discarded,fields:[.detail:22]);return
        }
        // Do not hide a different fatal error behind the foreground flush.
        if current?.0 == frame.session,hasFailed,
           !requiresFlush,!recoveryFlushPending {
            fail(session:frame.session,stage:"resume");return
        }
        let formatChanged=current?.0 != frame.session || current.map{!sameVideoFormat($0.1,settings)} != false
        let settingsChanged=current?.1 != settings
        // Apply the newest orientation synchronously. An older worker may be suspended in
        // flush/readiness, so it must never restore the orientation from its frame snapshot.
        if settingsChanged || formatChanged {applyOrientation(settings)}
        current=(frame.session,settings)
        if formatChanged {
            generation += 1;needsFlush=true
            generationChanged()
            probeTask?.cancel();probeTask=nil;probe="";inputProbe=""
        statusTask?.cancel();statusTask=nil
        }
        // Paused angle changes reuse the displayed frame. Never bypass lifecycle recovery,
        // a pending worker, a new session/format, or an actual newly decoded frame.
        if settingsChanged,!formatChanged,previousFrame === frame,ready,worker == nil,!needsFlush,!requiresFlush {return}
        if let pending {PlaybackFlowTrace.mark(.coalesce,parent:pending.0.flow,a:Int64(frame.flow.id))}
        pending=(frame,settings)
        trace(.submitQueued,fields:[.pending:1,.worker:worker == nil ? 0:1])
        guard worker == nil else{return}
        let workerContext=boundary.context()
        let workerSession=Double(PlaybackBoundaryIdentity.session(frame.session))
        worker=Task { @MainActor in
            trace(.workerEntered,fields:[.session:workerSession],context:workerContext)
            while let next=pending {
                flowWorkerStarted=ready ? ProcessInfo.processInfo.systemUptime:nil
                flowCurrent=next.0.flow
                let flowWorker=PlaybackFlowTrace.begin(.worker,parent:next.0.flow,a:Int64(generation))
                defer {observeFlowStall();flowWorkerStarted=nil;for (stage,span) in flowSpans {PlaybackFlowTrace.end(span,stage,a:-1)};flowSpans.removeAll();PlaybackFlowTrace.end(flowWorker,.worker);flowCurrent = .none}
                pending=nil
                let ticket=generation
                var stage="prepare"
                do {
                    guard recovery.sceneActive else {
                        trace(.discarded,ticket:ticket,fields:[.detail:22],once:false);continue
                    }
                    if requiresFlush,!recoveryFlushPending {
                        if recoverIfRequired() {continue}
                        throw PlaybackFailure.decodeFailed
                    }
                    if needsFlush {
                        needsFlush=false;samples.reset()
                        // RealityKit retains the initial packing for a renderer/material pair.
                        // Retire both together only when packing changes; ordinary frames reuse them.
                        let changesPacking = configuredSettings.map { $0.layout != next.1.layout } ?? false
                        let flushContext=boundary.context()
                        let flushSession=Double(PlaybackBoundaryIdentity.session(next.0.session))
                        trace(.flushEntered,ticket:ticket,fields:[.detail:11,.outcome:changesPacking ? 1:0,.session:flushSession],once:false,context:flushContext)
                        await flush(removingDisplayedImage:changesPacking)
                        trace(.flushReturned,ticket:ticket,fields:[.detail:11,.session:flushSession],once:false,context:flushContext)
                        guard ticket==generation,recovery.sceneActive else {
                            trace(.discarded,ticket:ticket,fields:[.detail:23,.session:flushSession],once:false,context:flushContext);continue
                        }
                        recoveryFlushPending=false
                        trace(.materialEntered,ticket:ticket,fields:[.outcome:changesPacking ? 1:0])
                        if changesPacking {
                            if heldPresentation == nil {entity.model=nil}
                            stagedModel=nil;sharedVideoMaterial=nil
                            video=AVSampleBufferVideoRenderer();configuredSettings=nil
                            #if DEBUG
                            testRendererReplacementCount += 1
                            #endif
                        }
                        let needsMesh = configuredSettings.map{!sameVideoFormat($0,next.1)} != false || (buildsMaterial && entity.model == nil)
                        if buildsMaterial,needsMesh {
                        let crop=next.1.crop(width:CVPixelBufferGetWidth(next.0.pixel),height:CVPixelBufferGetHeight(next.0.pixel),rightEye:false)!
                        guard let mesh=VRMesh(projection:next.1.projection,eyeWidth:Int(crop.width),eyeHeight:Int(crop.height)) else{throw PlaybackFailure.unsupportedTrack}
                        var descriptor=MeshDescriptor(name:"System video candidate")
                        descriptor.positions=MeshBuffers.Positions(mesh.positions)
                        descriptor.normals=MeshBuffers.Normals(mesh.normals)
                        descriptor.textureCoordinates=MeshBuffers.TextureCoordinates(mesh.uv)
                        descriptor.primitives = .triangles(mesh.indices)
                        let material=material()
                        #if os(visionOS)
                        material.controller.preferredViewingMode = next.1.layout == .mono ? .mono:.stereo
                        #endif
                        installModel(ModelComponent(mesh:try MeshResource.generate(from:[descriptor]),materials:[material]))
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--system-renderer-flat") {
                        installModel(ModelComponent(mesh:.generatePlane(width:2,height:1),materials:[material]))
                        entity.position=[0,0,-2];entity.orientation=simd_quatf()
                    }
                    #endif
                        }
                        configuredSettings=next.1
                        trace(.materialReturned,ticket:ticket)
                    }
                    stage="queue"
                    let readinessContext=boundary.context()
                    let readinessSession=Double(PlaybackBoundaryIdentity.session(next.0.session))
                    trace(.readinessWaitEntered,ticket:ticket,fields:[.session:readinessSession],context:readinessContext)
                    let deadline=ContinuousClock.now.advanced(by:.milliseconds(250))
                    while !acceptsSamples,ContinuousClock.now<deadline,ticket==generation,pending==nil {
                        try await Task.sleep(for:.milliseconds(5))
                    }
                    if let observedAcceptsSamples {
                        trace(.readinessWaitReturned,ticket:ticket,fields:[.acceptsSamples:observedAcceptsSamples ? 1:0,.session:readinessSession],context:readinessContext)
                    }
                    guard ticket==generation,pending==nil,recovery.sceneActive else {
                        trace(.discarded,ticket:ticket,fields:[.detail:24,.session:readinessSession],once:false,context:readinessContext);continue
                    }
                    guard acceptsSamples,!hasFailed,!requiresFlush else{throw PlaybackFailure.decodeFailed}
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--system-renderer-failure") {stage="injected";throw PlaybackFailure.decodeFailed}
                    #endif
                    let firstOwnedInGeneration=bindingCheckedGeneration != generation
                    if firstOwnedInGeneration {observePresentationBoundary(reason:1)}
                    guard ensureCurrentMaterialBinding() else{throw PlaybackFailure.decodeFailed}
                    stage="sample"
                    trace(.sampleEntered,ticket:ticket)
                    let sample=try samples.sample(next.0,settings:next.1)
                    trace(.sampleReturned,ticket:ticket)
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--system-renderer-probe"),inputProbe.isEmpty {
                        let image=CIImage(cvPixelBuffer:next.0.pixel)
                        let thumb=image.transformed(by:CGAffineTransform(scaleX:16/image.extent.width,y:16/image.extent.height))
                        var bytes=[UInt8](repeating:0,count:16*16*4)
                        context.render(thumb,toBitmap:&bytes,rowBytes:64,bounds:CGRect(x:0,y:0,width:16,height:16),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
                        let rgb=bytes.enumerated().filter{$0.offset%4 != 3}.map{Int($0.element)}
                        let sum=rgb.reduce(0,+),bright=rgb.filter{$0>20}.count
                        inputProbe="inputRGBsum=\(sum) bright=\(bright) surface=\(CVPixelBufferGetIOSurface(next.0.pixel) != nil) format=\(CVPixelBufferGetPixelFormatType(next.0.pixel)) PTS=\(next.0.time)"
                        if ProcessInfo.processInfo.arguments.contains("--shortcut-ui-tests"),let cg=context.createCGImage(image,from:image.extent),let destination=CGImageDestinationCreateWithURL(FileManager.default.temporaryDirectory.appendingPathComponent("vista-input-calibration.png") as CFURL,"public.png" as CFString,1,nil) {
                            CGImageDestinationAddImage(destination,cg,nil);_ = CGImageDestinationFinalize(destination)
                        }
                    }
                    #endif
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--system-renderer-raw") {
                        let rawFormat=try CMVideoFormatDescription(imageBuffer:next.0.pixel)
                        let raw=try CMSampleBuffer(imageBuffer:next.0.pixel,formatDescription:rawFormat,sampleTiming:CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:.zero,decodeTimeStamp:.invalid))
                        raw.sampleAttachments[0][.displayImmediately]=true
                        enqueue(raw)
                    } else {enqueue(sample)}
                    #else
                    enqueue(sample)
                    #endif
                    lastOwnedFlow=next.0.flow.id
                    recordHoldByteEstimate(next.0.pixel)
                    if heldPresentation != nil {
                        // Owned enqueue is an API boundary, not proof of photons.
                        if let stagedModel {entity.model=stagedModel}
                        releaseHeldPresentation(reason:1,hide:false,newFlow:next.0.flow.id)
                    }
                    blockedHoldInput=nil;blockedHoldFlow=nil
                    ready=true;entity.isEnabled=true;error=nil
                    trace(.resultEnabled,ticket:ticket,fields:[.active:1,.outcome:0])
                    if firstOwnedInGeneration {observePresentationBoundary(reason:2)}
                    if lastSubmittedSession != next.0.session {
                        lastSubmittedAt=ProcessInfo.processInfo.systemUptime
                        lastSubmittedSession=next.0.session
                    }
                    startProbe(ticket:ticket)
                    startStatusMonitor(ticket:ticket)
                } catch { if ticket==generation {
                    if recoverIfRequired() {continue}
                    fail(session:next.0.session,stage:stage)
                } else {trace(.discarded,ticket:ticket,fields:[.detail:25],once:false)} }
            }
            if needsFlush {
                let tailTicket=generation,tailContext=boundary.context()
                let tailSession=recovery.session.map {Double(PlaybackBoundaryIdentity.session($0))} ?? 0
                trace(.flushEntered,ticket:tailTicket,fields:[.detail:12,.session:tailSession],once:false,context:tailContext)
                await flush(removingDisplayedImage:true)
                trace(.flushReturned,ticket:tailTicket,fields:[.detail:12,.session:tailSession],once:false,context:tailContext)
            }
            worker=nil
            trace(.workerExited,fields:[.session:workerSession],context:workerContext)
            if let next=pending {submit(next.0,settings:next.1)}
        }
    }
    private func sameVideoFormat(_ lhs:VRSettings,_ rhs:VRSettings)->Bool {
        lhs.layout==rhs.layout && lhs.projection==rhs.projection
    }
    private func applyOrientation(_ settings:VRSettings) {
        entity.orientation=VRInitialPose.manualRotation(yaw:settings.yawDegrees,pitch:settings.pitchDegrees,roll:settings.rollDegrees)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--system-renderer-flat") {entity.orientation=simd_quatf()}
        #endif
    }
    private func failureMessage(stage:String)->String {
        let status=(video.error as NSError?).map {" code=\($0.code)"} ?? ""
        return VistaL10n.text("系統影片呈現失敗，已停止 [videoRenderer/%@%@]" , String(describing: stage), String(describing: status))
    }
    private func startStatusMonitor(ticket:Int) {
        guard statusTask==nil else{return}
        statusTask=Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(for:.milliseconds(100))} catch{return}
                guard let self,ticket==self.generation,self.recovery.sceneActive else{return}
                self.observeFlowStall()
                if self.surfaceObservationGeneration != ticket {
                    self.surfaceObservationGeneration=ticket;self.surfaceObservationCount=0
                }
                if self.surfaceObservationCount<20 {
                    self.surfaceObservationCount+=1
                    if [1,5,20].contains(self.surfaceObservationCount) {
                        if #available(macOS 26.0,visionOS 26.0,*) {
                            self.observePresentationBoundary(reason:Int64(100+self.surfaceObservationCount))
                        }
                    }
                }
                if self.requiresFlush,self.recoverIfRequired() {return}
                if self.hasFailed || self.requiresFlush {
                    self.fail(session:self.current?.0,stage:"async")
                    return
                }
            }
        }
    }
    @available(macOS 14.4,*)
    private func startProbe(ticket:Int) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--system-renderer-probe"),probeTask==nil else{return}
        probeTask=Task { @MainActor in
            for _ in 0..<20 {
                do {try await Task.sleep(for:.milliseconds(100))} catch{return}
                guard ticket==generation else{return}
                // Apple's copyDisplayedPixelBuffer contract returns nil at nonzero rate.
                // Freeze only the renderer for this synthetic Debug observation, then restore.
                let synthetic=ProcessInfo.processInfo.arguments.contains("--shortcut-ui-tests")
                let savedRate=CMTimebaseGetRate(video.timebase)
                if synthetic {CMTimebaseSetRate(video.timebase,rate:0)}
                let displayed=video.displayedPixelBuffer()
                if synthetic {CMTimebaseSetRate(video.timebase,rate:savedRate)}
                if let pixel=displayed {
                    if ProcessInfo.processInfo.arguments.contains("--shortcut-ui-tests"),let image=context.createCGImage(CIImage(cvPixelBuffer:pixel),from:CIImage(cvPixelBuffer:pixel).extent) {
                        let url=FileManager.default.temporaryDirectory.appendingPathComponent("vista-renderer-calibration.png")
                        if let destination=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil) {
                            CGImageDestinationAddImage(destination,image,nil);_ = CGImageDestinationFinalize(destination)
                        }
                    }
                    probe=inputProbe+VistaL10n.text(" renderer 可讀回影格 %@×%@；非雙眼輸出驗收" , String(describing: CVPixelBufferGetWidth(pixel)), String(describing: CVPixelBufferGetHeight(pixel)))
                    return
                }
            }
            probe=inputProbe+VistaL10n.text(" renderer 讀回不可用（不代表黑畫面） status=%@ ready=%@ flush=%@ rate=%@ error=%@" , String(describing: video.status.rawValue), String(describing: acceptsSamples), String(describing: requiresFlush), String(describing: CMTimebaseGetRate(video.timebase)), String(describing: (video.error as NSError?)?.code ?? 0))
            print("SYSTEM_RENDERER_PROBE status=\(video.status.rawValue) ready=\(acceptsSamples) requiresFlush=\(requiresFlush) time=\(CMTimebaseGetTime(video.timebase).seconds) rate=\(CMTimebaseGetRate(video.timebase)) error=\((video.error as NSError?)?.code ?? 0)")
        }
        #endif
    }

}

