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
    let entity=ModelEntity()
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
    @ObservationIgnored private var observedFailed:Bool?
    @ObservationIgnored private var observedAcceptsSamples:Bool?
    init() {boundary=PlaybackBoundaryTrace(scope:3)}
    #if DEBUG
    init(diagnostics:LifecycleDiagnostics) {boundary=PlaybackBoundaryTrace(scope:3,diagnostics:diagnostics)}
    #endif
    private func trace(_ stage:PlaybackBoundaryStage,ticket:Int?=nil,
                       fields:@autoclosure ()->[LifecycleField:Double]=[:],once:Bool=true,
                       context:PlaybackBoundaryTrace.Context?=nil) {
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
        trace(.requiresFlushObserved,fields:[.requiresFlush:value ? 1:0])
        return value
    }
    private var hasFailed:Bool {
        #if DEBUG
        if let testIO {let value=testIO.failed();observedFailed=value;return value}
        #endif
        let value=video.status == .failed;observedFailed=value;return value
    }
    private var acceptsSamples:Bool {
        #if DEBUG
        if let testIO {let value=testIO.ready();observedAcceptsSamples=value;return value}
        #endif
        let value=video.isReadyForMoreMediaData;observedAcceptsSamples=value;return value
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

    func setSceneActive(_ active:Bool) {
        guard recovery.setSceneActive(active) else{return}
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
        failedSession=session;pending=nil;needsFlush=true;recoveryFlushPending=false
        error=failureMessage(stage:stage);ready=false;entity.isEnabled=false
        let detail=["resume":31,"prepare":32,"queue":33,"sample":34,"injected":35,"async":36][stage] ?? 0
        var fields:[LifecycleField:Double]=[.detail:Double(detail),.outcome:2]
        if let session {fields[.session]=Double(PlaybackBoundaryIdentity.session(session))}
        if let observedFailed {fields[.rendererFailed]=observedFailed ? 1:0}
        trace(.failure,fields:fields,once:false)
    }
    func stop() {
        guard !isStopped else{return}
        boundary.begin(reason:6,generation:generation)
        let stoppedSession=recovery.session.map {Double(PlaybackBoundaryIdentity.session($0))} ?? 0
        trace(.stopEntered,fields:[.worker:worker == nil ? 0:1,.session:stoppedSession],once:false)
        isStopped=true
        generation += 1;pending=nil;retained=nil;needsFlush=true;recoveryFlushPending=false
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
    @available(macOS 26.0,visionOS 26.0,*)
    func submit(_ frame:DecodedVideoFrame,settings:VRSettings) {
        if failedSession != frame.session {
            if recovery.session != frame.session {boundary.begin(reason:1,generation:generation)}
            else if let retained,retained.1 != settings {boundary.begin(reason:2,generation:generation)}
        }
        let submitContext=boundary.context()
        trace(.submitEntered,fields:[.session:Double(PlaybackBoundaryIdentity.session(frame.session))],context:submitContext)
        defer{trace(.submitReturned,context:submitContext)}
        guard failedSession != frame.session else {
            trace(.discarded,fields:[.detail:21]);return
        }
        isStopped=false
        recovery.selectSession(frame.session)
        retained=(frame,settings)
        guard recovery.sceneActive else {
            trace(.discarded,fields:[.detail:22]);return
        }
        // Do not hide a different fatal error behind the foreground flush.
        if current?.0 == frame.session,hasFailed,
           !requiresFlush,!recoveryFlushPending {
            fail(session:frame.session,stage:"resume");return
        }
        if current?.0 != frame.session || current?.1 != settings {
            generation += 1;needsFlush=true;current=(frame.session,settings)
            generationChanged()
            probeTask?.cancel();probeTask=nil;probe="";inputProbe=""
        statusTask?.cancel();statusTask=nil
        }
        pending=(frame,settings)
        trace(.submitQueued,fields:[.pending:1,.worker:worker == nil ? 0:1])
        guard worker == nil else{return}
        let workerContext=boundary.context()
        let workerSession=Double(PlaybackBoundaryIdentity.session(frame.session))
        worker=Task { @MainActor in
            trace(.workerEntered,fields:[.session:workerSession],context:workerContext)
            let samples=SystemVideoSamples()
            while let next=pending {
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
                            entity.model=nil;sharedVideoMaterial=nil
                            video=AVSampleBufferVideoRenderer();configuredSettings=nil
                            #if DEBUG
                            testRendererReplacementCount += 1
                            #endif
                        }
                        if buildsMaterial,(configuredSettings != next.1 || entity.model == nil) {
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
                        entity.model=ModelComponent(mesh:try MeshResource.generate(from:[descriptor]),materials:[material])
                        entity.orientation=VRInitialPose.manualRotation(yaw:next.1.yawDegrees,pitch:next.1.pitchDegrees,roll:next.1.rollDegrees)
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--system-renderer-flat") {
                        entity.model=ModelComponent(mesh:.generatePlane(width:2,height:1),materials:[material])
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
                    ready=true;entity.isEnabled=true;error=nil
                    trace(.resultEnabled,ticket:ticket,fields:[.active:1,.outcome:0])
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
    private func failureMessage(stage:String)->String {
        let status=(video.error as NSError?).map {" code=\($0.code)"} ?? ""
        return "系統影片呈現失敗，已停止 [videoRenderer/\(stage)\(status)]"
    }
    private func startStatusMonitor(ticket:Int) {
        guard statusTask==nil else{return}
        statusTask=Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(for:.milliseconds(100))} catch{return}
                guard let self,ticket==self.generation,self.recovery.sceneActive else{return}
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
                    probe=inputProbe+" renderer 可讀回影格 \(CVPixelBufferGetWidth(pixel))×\(CVPixelBufferGetHeight(pixel))；非雙眼輸出驗收"
                    return
                }
            }
            probe=inputProbe+" renderer 讀回不可用（不代表黑畫面） status=\(video.status.rawValue) ready=\(acceptsSamples) flush=\(requiresFlush) rate=\(CMTimebaseGetRate(video.timebase)) error=\((video.error as NSError?)?.code ?? 0)"
            print("SYSTEM_RENDERER_PROBE status=\(video.status.rawValue) ready=\(acceptsSamples) requiresFlush=\(requiresFlush) time=\(CMTimebaseGetTime(video.timebase).seconds) rate=\(CMTimebaseGetRate(video.timebase)) error=\((video.error as NSError?)?.code ?? 0)")
        }
        #endif
    }

}

