import Foundation
import Observation
#if SWIFT_PACKAGE
import VistaCore
#endif

/// Serializes replacement playback jobs and rejects callbacks from obsolete requests.
@MainActor @Observable public final class PlaybackController {
    public enum PreparationFailure:Error,Equatable {case sourceCleanup}
    public private(set) var isPlaying = false
    public private(set) var isPaused = false
    public private(set) var isPreparing = false
    public private(set) var position = 0.0
    public private(set) var trackInfo: VideoTrackInfo?
    public private(set) var frame: VideoFrame?
    public private(set) var pixelFrame:DecodedVideoFrame?
    public private(set) var message: String?
    public private(set) var diagnosticsText = ""
    public private(set) var preparationText = ""
    public private(set) var isSeeking = false
    public private(set) var isBuffering = false
    public private(set) var speedStatus=PlaybackSpeedStatus()
    public private(set) var speedMessage:String?
    public var playbackGeneration:UUID {generation}
    public var canIncreaseSpeed:Bool {isPlaying && !isPreparing && speedStatus.canIncrease}
    public var canResetSpeed:Bool {isPlaying && !isPreparing && speedStatus.canReset}
    public func increaseSpeed() {changeSpeed(to:speedStatus.selected+PlaybackSpeedStatus.increment)}
    public func resetSpeed() {changeSpeed(to:1)}
    private func changeSpeed(to rate:Double) {
        guard isPlaying,!isPreparing else{return}
        #if VISTA_NATIVE_PLAYER_EXPERIMENT
        guard let nativeSession else{return}
        guard nativeSession.setSpeed(rate) else {
            if rate<=Double(PlaybackSpeedStatus.upperLimit) {speedMessage="此影片不支援 \(PlaybackSpeedStatus.label(rate))× 播放。"};return
        }
        speedStatus=nativeSession.speedStatus;speedMessage=nil
        #endif
    }
    @ObservationIgnored private var submittedSession:UUID?
    public func markRendererSubmitted(session:UUID,enqueuedAt:Double?=nil) {
        guard !isPreparing,isPlaying,pixelFrame?.session==session,submittedSession != session else{return}
        submittedSession=session
        if let enqueuedAt,enqueuedAt>=preparationStart {
            preparationMarks.append(String(format:"renderer enqueue %.0f ms",(enqueuedAt-preparationStart)*1000))
        }
        markPreparation("呈現通知")
        #if VISTA_NATIVE_PLAYER_EXPERIMENT
        nativeSession?.recordPresentation(session:session)
        #if VISTA_ANON_IO_EXPERIMENT
        diagnosticsText=nativeSession?.diagnosticsText ?? diagnosticsText
        #endif
        #endif
    }
    @ObservationIgnored private var preparationStart = 0.0
    @ObservationIgnored private var preparationMarks:[String] = []
    private func markPreparation(_ label:String) {
        let ms=(ProcessInfo.processInfo.systemUptime-preparationStart)*1000
        preparationMarks.append(String(format:"%@ %.0f ms",label,ms))
        preparationText="準備時間（自請求起累計）："+preparationMarks.joined(separator:"／")
    }
    @ObservationIgnored public private(set) var metrics:PlaybackMetrics?
    @ObservationIgnored private var metricsTask:Task<Void,Never>?
    @ObservationIgnored private var previousCancellationText=""
    @ObservationIgnored private var sourceKind=PlaybackSourceKind.unknown
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var timeline: PlaybackTimeline?
    @ObservationIgnored private var file: MediaFile?
    @ObservationIgnored private var source: (any MediaByteSource)?
    @ObservationIgnored private var nativeSession:NativePlaybackSession?
    @ObservationIgnored private var preparedRecoverySource:(any PlaybackRecoveryControlling)?
    @ObservationIgnored private var preparedSourceCleanup:Task<Void,any Error>?
    @ObservationIgnored private var playbackSceneActive=true
    /// Bind before metadata inspection as well as playback, so an already-backgrounded
    /// immersive scene cannot reconnect while AVPlayer has not been created yet.
    public func bindPreparedSource(_ source:(any MediaByteSource)?) {
        let next=source as? any PlaybackRecoveryControlling
        if let previous=preparedRecoverySource {
            let unchanged=next.map{(previous as AnyObject) === ($0 as AnyObject)} ?? false
            if !unchanged {
                previous.cancelPlayback()
                let pending=preparedSourceCleanup
                // Cleanup is independent of the cancelled metadata/player task. Preserve an
                // earlier failure, and never open a replacement on an assumed timeout/drain.
                preparedSourceCleanup=Task {
                    let priorResult=await pending?.result
                    try await previous.awaitPlaybackCleanup()
                    try priorResult?.get()
                }
            }
        }
        preparedRecoverySource=next
        next?.setPlaybackSceneActive(playbackSceneActive)
    }
    /// New file factories and metadata reads must join cleanup, not merely the next play().
    /// A failed barrier stays failed for this controller's remaining preparation attempts.
    public func awaitPreparedSourceCleanup()async throws {
        do {try await preparedSourceCleanup?.value}
        catch {throw PreparationFailure.sourceCleanup}
        try Task.checkCancellation()
    }
    public func setPlaybackSceneActive(_ active:Bool) {
        playbackSceneActive=active
        preparedRecoverySource?.setPlaybackSceneActive(active)
        nativeSession?.setPlaybackSceneActive(active)
    }
    @ObservationIgnored private let engine: HardwarePlayback
    @ObservationIgnored private let nearbySeeking:Bool
    @ObservationIgnored private let boundaryTrace:PlaybackBoundaryTrace
    @ObservationIgnored private var boundaryGeneration=0
    @ObservationIgnored private var boundarySession:UUID?
    // Scope 2 causes: 1 launch, 2 accepted seek, 3 new frame session, 4 background pause,
    // 5 explicit stop, 6 pause/resume call, 7 completion/failure cleanup.
    // Outcomes: 0 returned/applied, 1 guard rejected/cancelled, 2 failure, 3 stale callback,
    // 4 preparation stopped, 5 paused, 6 explicitly resumed, 7 playback ended.
    private enum BoundaryCause:Int {case launch=1,seek,frameSession,backgroundPause,stop,togglePause,termination}
    public init() {
        engine=HardwarePlayback();nearbySeeking=PlaybackSeekingPolicy.nearby
        boundaryTrace=PlaybackBoundaryTrace(scope:2)
    }
    init(engine:HardwarePlayback,nearbySeeking:Bool=PlaybackSeekingPolicy.nearby,diagnostics:LifecycleDiagnostics = .shared) {
        self.engine=engine;self.nearbySeeking=nearbySeeking
        boundaryTrace=PlaybackBoundaryTrace(scope:2,diagnostics:diagnostics)
    }
    @discardableResult private func beginBoundary(_ cause:BoundaryCause)->PlaybackBoundaryTrace.Context {
        boundaryTrace.begin(reason:cause.rawValue,generation:boundaryGeneration)
    }
    private func recordBoundary(_ stage:PlaybackBoundaryStage,fields:[LifecycleField:Double]=[:],once:Bool=true,
                                context:PlaybackBoundaryTrace.Context?=nil) {
        guard boundaryTrace.shouldRecord(stage,once:once,context:context) else{return}
        var values:[LifecycleField:Double]=[.playing:isPlaying ? 1:0,.paused:isPaused ? 1:0,
            .preparing:isPreparing ? 1:0,.frameAvailable:pixelFrame == nil ? 0:1]
        values.merge(fields){_,new in new}
        boundaryTrace.record(stage,generation:boundaryGeneration,fields:values,once:once,context:context)
    }
    private func changedBoundaryGeneration(_ cause:BoundaryCause) {
        boundaryGeneration += 1
        boundarySession=nil
        recordBoundary(.generationChanged,fields:[.cause:Double(cause.rawValue)],once:false)
    }
    private func observePixelBoundary(_ next:DecodedVideoFrame,owner:Int,current:Bool) {
        guard current else {
            guard boundaryTrace.shouldRecord(.discarded) else{return}
            recordBoundary(.discarded,fields:[.outcome:3,.request:Double(owner),
                .session:Double(PlaybackBoundaryIdentity.session(next.session))])
            return
        }
        if boundarySession != next.session {
            boundarySession=next.session
            beginBoundary(.frameSession)
        }
        guard boundaryTrace.shouldRecord(.frameObserved) else{return}
        recordBoundary(.frameObserved,fields:[.session:Double(PlaybackBoundaryIdentity.session(next.session))])
    }
    private func appliedPixelBoundary(_ next:DecodedVideoFrame) {
        guard boundaryTrace.shouldRecord(.resultEnabled) else{return}
        recordBoundary(.resultEnabled,fields:[.outcome:0,.session:Double(PlaybackBoundaryIdentity.session(next.session))])
    }

    public func persistDiagnostics(event:PlaybackLogEvent = .sample,projection:Int=0,layout:Int=0,route:Int = -1,rendererValues:[PlaybackLogField:Double]=[:]) {
        var v=nativeSession?.anonymousLogValues() ?? [:]
        v[.position]=position;v[.playing]=isPlaying ? 1:0;v[.paused]=isPaused ? 1:0;v[.preparing]=isPreparing ? 1:0;v[.buffering]=isBuffering ? 1:0
        if let info=trackInfo {v[.width]=Double(info.width);v[.height]=Double(info.height)}
        v[.projection]=Double(projection);v[.layout]=Double(layout);v[.route]=Double(route)
        if let snapshot=metrics?.snapshot() {v[.textureCount]=Double(snapshot.stages[.texture]?.count ?? 0);v[.textureMS]=(snapshot.stages[.texture]?.seconds ?? 0)*1000;v[.uploaded]=Double(snapshot.events[.uploaded,default:0]);v[.coalesced]=Double(snapshot.events[.coalesced,default:0])}
        v.merge(rendererValues){_,new in new}
        v[.decoder] = -1 // AVPlayer decoder implementation is not publicly observable.
        let status=PlaybackLogStore.shared.status;v[.logFailures]=Double(status.failures);v[.logDropped]=Double(status.dropped)
        PlaybackLogStore.shared.enqueue(PlaybackLogRecord(event:event,values:v))
    }
    public func play(file: MediaFile, source: any MediaByteSource, sourceKind:PlaybackSourceKind = .unknown) {
        bindPreparedSource(source)
        self.sourceKind=sourceKind
        self.file = file; self.source = source
        trackInfo = nil;speedStatus=PlaybackSpeedStatus();speedMessage=nil
        launch(at: 0, paused: false)
    }
    public func seek(to requested: Double) {seek(to:requested,minimum:0)}
    private func seek(to requested:Double,minimum:Double) {
        guard requested.isFinite, let trackInfo else {
            recordBoundary(.discarded,fields:[.outcome:1]);return
        }
        let target = max(0, min(requested, trackInfo.duration))
        // A paused exact no-op already has its displayed frame. Do not wait for a duplicate pixel.
        if isPaused && !isPreparing && pixelFrame != nil && target == position {
            recordBoundary(.discarded,fields:[.outcome:1]);return
        }
        let seekBoundary=beginBoundary(.seek)
        recordBoundary(.submitEntered,fields:[.cause:Double(BoundaryCause.seek.rawValue)])
        if target == trackInfo.duration {
            stop()
            position = target; message = "播放結束"
            recordBoundary(.submitReturned,fields:[.outcome:7],context:seekBoundary)
            return
        }
        #if VISTA_NATIVE_PLAYER_EXPERIMENT
        if let nativeSession,isPlaying {
            isSeeking=true;isPreparing=true
            preparationStart=ProcessInfo.processInfo.systemUptime;preparationMarks=[];preparationText="";submittedSession=nil
            let seekOwner=generation
            let seekBoundaryOwner=boundaryGeneration
            Task { [weak self] in
                do {
                    try await nativeSession.seek(to:target,maximumBackward:min(1,max(0,target-minimum)))
                    guard let self else{return}
                    self.recordBoundary(self.generation==seekOwner ? .submitReturned:.discarded,
                        fields:[.cause:Double(BoundaryCause.seek.rawValue),.request:Double(seekBoundaryOwner),
                            .outcome:self.generation==seekOwner ? 0:3],context:seekBoundary)
                }
                catch is CancellationError {
                    guard let self else{return}
                    self.recordBoundary(.submitReturned,fields:[.outcome:1],context:seekBoundary)
                } catch {
                    guard let self,self.generation==seekOwner else{return}
                    self.recordBoundary(.failure,fields:LifecycleFailure(error).fields,context:seekBoundary)
                    self.message="跳轉失敗，可停止後重試。";self.isPreparing=false;self.isSeeking=false
                }
            }
            return
        }
        #endif
        launch(at: target, paused: isPaused, preservingFrame:true,tolerance:nearbySeeking ? SeekTargetTolerance(maximumBackward:1,minimum:minimum):.exact)
        recordBoundary(.submitReturned,fields:[.outcome:0],context:seekBoundary)
    }
    public func skip(by interval: Double) { seek(to: position + interval,minimum:interval>0 ? position:0) }
    // Keep the zero-argument API bindable as a SwiftUI Button action.
    public func togglePause() { togglePause(userInitiated:true) }
    private func togglePause(userInitiated:Bool) {
        #if VISTA_NATIVE_PLAYER_EXPERIMENT
        if let nativeSession,isPlaying,!isPreparing {
            beginBoundary(.togglePause)
            recordBoundary(.upstreamPauseEntered,fields:[.cause:Double(BoundaryCause.togglePause.rawValue)])
            if isPaused {nativeSession.resume()}else{nativeSession.pause(userInitiated:userInitiated)};isPaused.toggle()
            recordBoundary(.upstreamPauseReturned,fields:[.outcome:isPaused ? 5:6]);return
        }
        #endif
        guard isPlaying, !isPreparing, let timeline else { return }
        beginBoundary(.togglePause)
        recordBoundary(.upstreamPauseEntered,fields:[.cause:Double(BoundaryCause.togglePause.rawValue)])
        if isPaused { timeline.resume() } else { timeline.pause() }
        isPaused = timeline.isPaused
        message = isPaused ? "已暫停" : "繼續播放中"
        recordBoundary(.upstreamPauseReturned,fields:[.outcome:isPaused ? 5:6])
    }
    /// Never automatically resume after leaving the immersive foreground.
    public func pauseForBackground() {
        // Rejected duplicate notifications share the current budget; they never reopen it.
        if boundaryTrace.context()==nil || (isPlaying && !isPaused) {beginBoundary(.backgroundPause)}
        let pauseBoundary=boundaryTrace.context()
        recordBoundary(.pauseEntered,context:pauseBoundary)
        guard isPlaying, !isPaused else {
            recordBoundary(.discarded,fields:[.outcome:1],context:pauseBoundary)
            recordBoundary(.pauseReturned,fields:[.outcome:1],context:pauseBoundary);return
        }
        if isPreparing {stop();recordBoundary(.pauseReturned,fields:[.outcome:4],context:pauseBoundary);return}
        togglePause(userInitiated:false)
        recordBoundary(.pauseReturned,fields:[.outcome:isPaused ? 5:0],context:pauseBoundary)
    }
    public func stop(discardTrackInfo:Bool=false) {
        beginBoundary(.stop)
        recordBoundary(.stopEntered,fields:[.cause:Double(BoundaryCause.stop.rawValue)])
        if isPlaying || isPreparing {persistDiagnostics(event:.stopped)}
        bindPreparedSource(nil)
        nativeSession?.stop()
        speedStatus=PlaybackSpeedStatus();speedMessage=nil
        finishMetrics()
        generation = UUID()
        if discardTrackInfo {trackInfo=nil}
        changedBoundaryGeneration(.stop)
        timeline?.stopAudio()
        task?.cancel()
        // Keep the cancelled task until a replacement can join its cleanup.
        timeline = nil
        isPlaying = false; isPaused = false; isPreparing = false; isBuffering=false
        frame = nil; pixelFrame=nil; position = 0; message = "已停止"
        recordBoundary(.stopReturned,fields:[.outcome:0])
    }
    private func launch(at target: Double, paused: Bool, preservingFrame:Bool = false,tolerance:SeekTargetTolerance = .exact) {
        guard let file, let source else { return }
        #if VISTA_NATIVE_PLAYER_EXPERIMENT
        launchNative(file:file,source:source,startAt:target,startPaused:paused);return
        #endif
        beginBoundary(.launch)
        recordBoundary(.submitEntered,fields:[.cause:Double(BoundaryCause.launch.rawValue)])
        let requestStarted=ProcessInfo.processInfo.systemUptime
        finishMetrics()
        let oldTask = task
        let oldMetrics=metrics
        timeline?.stopAudio(); oldTask?.cancel()
        let id = UUID(); generation = id
        changedBoundaryGeneration(.launch)
        let boundaryOwner=boundaryGeneration
        let control = PlaybackTimeline(previewFirstFrame: paused)
        timeline = control
        isBuffering=false
        control.onBufferingChange={ [weak self] buffering in
            guard let self,self.generation==id else{return};self.isBuffering=buffering
            if !self.isPreparing {self.message=buffering ? "緩衝中…":self.isPaused ? "已暫停":"繼續播放中"}
        }
        isPlaying = true; isPaused = paused; isPreparing = true
        if !preservingFrame {frame = nil; pixelFrame=nil}
        isSeeking=preservingFrame
        submittedSession=nil
        preparationStart=requestStarted;preparationMarks=[];preparationText=""
        position = target; message = target == 0 ? "正在準備影片…" : "正在跳轉…"
        task = Task {
            await oldTask?.value
            guard !Task.isCancelled, generation == id else { return }
            if preservingFrame && nearbySeeking {
                let remaining=0.15-(ProcessInfo.processInfo.systemUptime-requestStarted)
                if remaining>0 {do {try await Task.sleep(for:.seconds(remaining))} catch{return}}
                guard !Task.isCancelled,generation==id else{return}
            }
            previousCancellationText=oldMetrics.map {"前次"+$0.cancellationTrace.text} ?? ""
            markPreparation("舊播放清理")
            let measure=PlaybackMetrics(source:sourceKind)
            metrics=measure;control.metrics=measure;diagnosticsText=measure.snapshot().text
            metricsTask=Task { [weak self] in
                for _ in 0..<10 {
                    do {try await Task.sleep(for:.seconds(1))} catch {return}
                    guard let self,self.generation==id else{return}
                    let snapshot=measure.snapshot();self.diagnosticsText=snapshot.text+"\n"+measure.cancellationTrace.text+"\n"+self.previousCancellationText
                    if snapshot.complete {return}
                }
            }
            let pixelCallback:(@MainActor @Sendable (DecodedVideoFrame)->Void)?
            #if VISTA_SYSTEM_VIDEO_EXPERIMENT
            pixelCallback = { [weak self] next in
                guard let self else{return}
                self.observePixelBoundary(next,owner:boundaryOwner,current:self.generation==id)
                guard self.generation==id else{return}
                measure.mark(.delivered)
                if self.isPreparing {self.markPreparation("首幀交付")}
                self.pixelFrame=next;self.position=next.time;self.isPreparing=false
                self.isPaused=control.isPaused
                self.message=self.isPaused ? "已暫停":"系統影片呈現候選"
                self.appliedPixelBoundary(next)
            }
            #else
            pixelCallback=nil
            #endif
            var terminalFailure:LifecycleFailure?
            do {
                _ = try await engine.play(file: file, source: source, startAt: target, timeline: control, metrics:measure,
                    onInfo: { [weak self] info in
                        guard let self, self.generation == id else { return }
                        self.trackInfo = info
                        measure.setFormat(codec:info.codec,width:Int(info.width),height:Int(info.height))
                    }, onFrame: { [weak self] next in
                        guard let self, self.generation == id else { return }
                        measure.mark(.delivered)
                        if self.isPreparing {self.markPreparation("首幀交付")}
                        self.frame = next; self.position = next.time; self.isPreparing = false
                        self.isPaused = control.isPaused
                        self.message = self.isPaused ? "已暫停" : (PlaybackDecodingPolicy.simulatorSoftwareTest ? "模擬器軟體解碼測試中" : "硬體解碼播放中")
                    },onPixelFrame:pixelCallback,onPreparation:{ [weak self] stage in
                    guard let self,self.generation==id else{return}
                    self.markPreparation(stage.rawValue)
                },seekTolerance:tolerance,onSeekResolved:{ [weak self] requested,resolved in
                    guard let self,self.generation==id else{return}
                    self.markPreparation(String(format:"落點 %.2f s（目標 %.2f s）",resolved,requested))
                })
                guard generation == id else { return }
                position = trackInfo?.duration ?? position; message = "播放結束"
            } catch {
                guard generation == id else { return }
                let failure=LifecycleFailure(error);terminalFailure=failure
                beginBoundary(.termination)
                recordBoundary(.failure,fields:failure.fields)
                message = (error as? PlaybackFailure)?.message ?? "無法讀取影片。請確認連線及檔案後重試。"
            }
            if generation == id {
                if terminalFailure==nil {beginBoundary(.termination)}
                recordBoundary(.stopEntered,fields:[.cause:Double(BoundaryCause.termination.rawValue)])
                finishMetrics()
                isPlaying = false; isPaused = false; isPreparing = false; isBuffering=false
                timeline = nil; task = nil
                recordBoundary(.stopReturned,fields:[.outcome:terminalFailure.map{$0.isCancellation ? 1:2} ?? 7])
            }
        }
        recordBoundary(.submitReturned,fields:[.cause:Double(BoundaryCause.launch.rawValue),.outcome:0])
    }
    #if VISTA_NATIVE_PLAYER_EXPERIMENT
    private func launchNative(file:MediaFile,source:any MediaByteSource,startAt:Double,startPaused:Bool) {
        beginBoundary(.launch)
        recordBoundary(.submitEntered,fields:[.cause:Double(BoundaryCause.launch.rawValue)])
        let old=task;nativeSession?.stop();old?.cancel();finishMetrics()
        let id=UUID();generation=id
        changedBoundaryGeneration(.launch)
        let boundaryOwner=boundaryGeneration
        speedStatus=PlaybackSpeedStatus();speedMessage=nil
        isPlaying=true;isPreparing=true;isPaused=startPaused;isBuffering=false;frame=nil;pixelFrame=nil
        position=0;message="正在準備影片…";preparationText="";submittedSession=nil
        preparationStart=ProcessInfo.processInfo.systemUptime;preparationMarks=[]
        diagnosticsText="AVPlayer 候選／解碼方式：系統管理（未知）"
        task=Task {
            await old?.value
            guard generation==id,!Task.isCancelled else{return}
            let session=NativePlaybackSession();nativeSession=session
            session.setPlaybackSceneActive(playbackSceneActive)
            var terminalFailure:LifecycleFailure?
            do {
                try await session.play(file:file,source:source,startAt:startAt,startPaused:startPaused,onInfo:{ [weak self] info in
                    guard let self,self.generation==id else{return};self.trackInfo=info
                },onState:{ [weak self] state in
                    guard let self,self.generation==id else{return}
                    self.isBuffering = state == .waiting
                    self.isPaused = session.isPlaybackPaused
                    self.message = state == .waiting ? "緩衝中…":state == .seeking ? "正在跳轉…":state == .paused ? "已暫停":"AVPlayer 系統播放"
                },onFrame:{ [weak self] next in
                    guard let self else{return}
                    self.observePixelBoundary(next,owner:boundaryOwner,current:self.generation==id)
                    guard self.generation==id else{return}
                    if self.isPreparing {self.markPreparation("首幀交付")}
                    self.diagnosticsText=session.diagnosticsText
                    self.pixelFrame=next;self.position=next.time;self.isPreparing=false;self.isSeeking=false
                    self.appliedPixelBoundary(next)
                },onSpeed:{ [weak self] speed in
                    guard let self,self.generation==id else{return};self.speedStatus=speed
                })
                if generation==id {message="播放結束"}
            }catch {
                guard generation==id else{return}
                let failure=LifecycleFailure(error);terminalFailure=failure
                beginBoundary(.termination)
                recordBoundary(.failure,fields:failure.fields)
                if !(error is CancellationError) {
                    let kind:Double
                    switch error as? NativePlaybackSession.Failure {case .source:kind=1;case .stalled:kind=2;case .player:kind=3;case .unsupported:kind=4;case nil:kind=0}
                    persistDiagnostics(event:.failed,rendererValues:[.failureKind:kind])
                }
                if let failure=error as? NativePlaybackSession.Failure {
                    message=failure == .source ? "來源讀取失敗，請確認連線後重新播放。":failure == .stalled ? "資料等待逾時，請停止後重試。":"系統播放器無法播放這個檔案。"
                }else if !(error is CancellationError) {message="系統播放失敗，請停止後重試。"}
            }
            if generation==id {
                if terminalFailure==nil {beginBoundary(.termination)}
                recordBoundary(.stopEntered,fields:[.cause:Double(BoundaryCause.termination.rawValue)])
                isPlaying=false;isPreparing=false;isSeeking=false;isBuffering=false;speedStatus=PlaybackSpeedStatus();speedMessage=nil;nativeSession=nil;task=nil
                recordBoundary(.stopReturned,fields:[.outcome:terminalFailure.map{$0.isCancellation ? 1:2} ?? 7])
            }
        }
        recordBoundary(.submitReturned,fields:[.cause:Double(BoundaryCause.launch.rawValue),.outcome:0])
    }
    #endif
    private func finishMetrics() {
        metricsTask?.cancel();metricsTask=nil
        if let metrics {metrics.finish();diagnosticsText=metrics.snapshot().text+"\n"+metrics.cancellationTrace.text+"\n"+previousCancellationText}
    }

}

/// Display helpers never interpret unknown duration as seekable media.
public enum PlaybackProgress {
    public static let skipInterval:Double = 30
    public static func duration(_ value:Double?)->Double? {
        guard let value,value.isFinite,value>0 else{return nil};return value
    }
    public static func clamp(_ position:Double,duration:Double?)->Double {
        guard position.isFinite else{return 0};return max(0,min(position,duration ?? 1))
    }
    public static func time(_ value:Double?)->String {
        guard let value,value.isFinite,value>=0,value<Double(Int.max/2) else{return "—"}
        let seconds=Int(value),hours=seconds/3600,minutes=(seconds/60)%60
        return hours>0 ? String(format:"%d:%02d:%02d",hours,minutes,seconds%60):String(format:"%02d:%02d",minutes,seconds%60)
    }
}
