#if VISTA_LOCAL_MKV_CANDIDATE
import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import QuartzCore

enum MKVPlaybackError: Error, LocalizedError {
    case failure(String)
    case engine(UInt32)
    var errorDescription: String? {
        let reason:String
        switch self {
        case .engine(let code):reason=MKVDiagnostics.engineReason(code)
        case .failure(let value):reason=MKVDiagnostics.knownMessages.contains(value) ? value:"候選內部檢查失敗。"
        }
        return "MKV 無法播放：\(reason)"
    }
}
func mkvRequire(_ condition: Bool, _ reason: String) throws { if !condition { throw MKVPlaybackError.failure(reason) } }
struct MKVEngineInfo: Sendable {
    let width: Int32, height: Int32
    let duration: Double, origin: Double, targetDuration: Int
    let startupSegments: UInt32
    let published: Int, terminal: Bool
}
struct MKVEngineSegment: Sendable { let index: Int; let duration: Double; let globalStart: Double; let globalEnd: Double; let durationNS: Int64 }
@MainActor protocol MKVEngineWindow: AnyObject, Sendable {
    var stamp: BridgeStamp { get }
    func start() throws
    func info() throws -> MKVEngineInfo
    func diagnosticSnapshot() throws -> SAPDiagnostics
    func performanceSnapshot() -> LocalSourcePerformance
    func segment(_ index: Int) throws -> MKVEngineSegment
    func acknowledgeImported(_ index: Int) async throws
    func validate() async throws
    func cancel()
    func drain() async throws -> BridgeDrainAck
    func destroy() throws
}
@MainActor protocol MKVEngineSource: AnyObject {
    func create(staging: URL, receipt: URL, generation: UInt64, target: Double) async throws -> any MKVEngineWindow
    func close() async throws
}

@MainActor final class MKVPlaybackDriver {
    private let outputGain: Float
    private(set) var diagnostics=MKVDiagnostics()
    var onObservation: (([String:Double])->Void)?
    private var observationBudget=MKVObservationBudget()
    private func emitObservation(_ fields:[String:Double]) {
        guard !fields.isEmpty else{return}
        guard observationBudget.admit() else{diagnostics.suppressObservation();return}
        var values=fields;values["mkvObservationSchema"]=1;values["mkvGeneration"]=Double(generation);values["mkvObservationOriginUptime"]=diagnostics.observationOrigin
        onObservation?(values)
    }
    private func markStartup(_ mark:MKVStartupMark,requested:Double?=nil,origin:Double?=nil,current:Double?=nil,outcome:Double?=nil) {
        emitObservation(diagnostics.startupMark(mark,requested:requested,origin:origin,current:current,outcome:outcome))
    }
    #if MKV_SYNTHETIC_AUDIO_OBSERVATION
    // Host-only seam. Never included in the candidate App; synthetic tap only.
    var configureSyntheticItem: ((AVPlayerItem)->Void)?
    #endif
    private func captureEngine() {
        guard let session else{return}
        if let snapshot=try? session.diagnosticSnapshot() {diagnostics.observe(snapshot)}
        diagnostics.observeSourcePerformance(session.performanceSnapshot())
    }
    // These are elapsed API scopes, including queue/scheduling waits and errors.
    // store.stage includes write, fsync, immutable close and SHA256 together.
    private func measureImport<T:Sendable>(_ cost:MKVImportCost,_ work:@MainActor () async throws -> T) async rethrows -> T {
        let start=DispatchTime.now().uptimeNanoseconds
        defer {diagnostics.importCost(cost,since:start)}
        return try await work()
    }
    func captureFailure(_ error:any Error) {captureEngine();diagnostics.fail(error)}
    init(outputGain: Float = 1) { self.outputGain = min(1,max(0,outputGain)) }
    private var source: (any MKVEngineSource)?
    private var session: (any MKVEngineWindow)?
    private var store: MKVSegmentStore?, server: MKVLoopbackServer?
    private var player: AVPlayer?, item: AVPlayerItem?, output: AVPlayerItemVideoOutput?
    private var root: URL?, staging: URL?, ledger: URL?
    private var pumpTask: Task<Void, Error>?
    private var ended = false, active = true, sceneActive = true, seeking = false, initialPositioning = false
    private(set) var paused = false
    var prefetchAllowed:Bool { active && sceneActive && !paused && !seeking }
    var prefetchInvalidation:PrefetchInvalidationReason { !active ? .playbackInactive : !sceneActive ? .sceneInactive : seeking ? .seek : paused ? .pause : .disabled }
    private(set) var selectedSpeed = 1.0
    private var generation: UInt64 = 0, frameSession = UUID(), seekToken = UUID()
    private var sourceInfo: MKVEngineInfo?
    private var segments: [MKVEngineSegment] = []
    private var segmentBytes:[Int:Int] = [:]
    private var firstPublishedIndex = 1
    private var terminal = false
    private var endObserver: NSObjectProtocol?
    private var pendingSeek: (Double, CheckedContinuation<Void, Error>)?
    private var onState: ((NativePlaybackSession.State)->Void)?
    private var state: NativePlaybackSession.State = .preparing
    private var failure: Error?
    private static var retainedIncomplete: MKVPlaybackDriver?
    var diagnosticsText: String { "MKV／VP9 P0＋AAC-LC／AVPlayer 系統解碼" }
    var speedStatus: PlaybackSpeedStatus {
        PlaybackSpeedStatus(selected:selectedSpeed,effectiveRate:item?.timebase.map { CMTimebaseGetEffectiveRate($0) } ?? 0,ready:active && item?.status == .readyToPlay,supportsFastForward:item?.canPlayFastForward ?? false,paused:paused,waiting:player?.timeControlStatus == .waitingToPlayAtSpecifiedRate)
    }
    func setSpeed(_ value: Double) -> Bool {
        guard speedStatus.accepts(value),let player else{return false}
        selectedSpeed=value;player.defaultRate=Float(value)
        playIfAllowed();return true
    }
    private func playIfAllowed() {
        guard active,!initialPositioning,!paused,sceneActive,pendingSeek == nil,let player else{return}
        player.play();markStartup(.play,current:player.currentTime().seconds)
    }
    func pause() { paused=true;player?.pause();setState(.paused) }
    func resume() { paused=false;playIfAllowed();setState(.playing) }
    func setSceneActive(_ value: Bool) { sceneActive=value;if !value {player?.pause()} else {playIfAllowed()} }
    func stop() { active=false;player?.pause();item?.cancelPendingSeeks();session?.cancel();pumpTask?.cancel();pendingSeek?.1.resume(throwing:CancellationError());pendingSeek=nil }
    private func setState(_ value: NativePlaybackSession.State) { if value != state {state=value;onState?(value)} }
    func seek(to target: Double) async throws {
        guard target.isFinite,target>=0,let info=sourceInfo,target<info.duration,active else{throw NativePlaybackSession.Failure.unsupported}
        let token=UUID();seekToken=token;seeking=true
        defer {if seekToken==token {seeking=false}}
        let local=CMTime(seconds:target-info.origin,preferredTimescale:1_000_000_000)
        if !initialPositioning,let item,let player, target>=info.origin, let servedStart=segments.first?.globalStart,let servedEnd=segments.last?.globalEnd,target>=servedStart,target<servedEnd, item.seekableTimeRanges.contains(where:{CMTimeRangeContainsTime($0.timeRangeValue,time:local)}) {
            setState(.seeking);player.pause()
            let success=await player.seek(to:local,toleranceBefore:.zero,toleranceAfter:.zero)
            guard active,seekToken==token,success else{throw CancellationError()}
            frameSession=UUID();playIfAllowed();setState(paused ? .paused:.playing);return
        }
        pendingSeek?.1.resume(throwing:CancellationError());pendingSeek=nil
        try await withCheckedThrowingContinuation { continuation in pendingSeek=(target,continuation);player?.pause();setState(.seeking) }
    }
    func play(source: any MKVEngineSource, startAt: Double, startPaused: Bool,
              onInfo: @escaping (VideoTrackInfo)->Void, onState: @escaping (NativePlaybackSession.State)->Void,
              onFrame: @escaping (DecodedVideoFrame)->Void, onSpeed: @escaping (PlaybackSpeedStatus)->Void) async throws {
        guard Self.retainedIncomplete == nil else {throw MKVPlaybackError.failure("先前來源尚未安全結束，請重新開啟候選 App。")}
        diagnostics.enter(.workspace)
        self.source=source;paused=startPaused;self.onState=onState;onState(.preparing)
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("VistaLocalMKV-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false);root=folder
        do {
            try await openGeneration(target:startAt,onInfo:onInfo)
            diagnostics.enter(.playback)
            var lastPTS: CMTime?, lastPixelClock=ProcessInfo.processInfo.systemUptime
            while active {
                try Task.checkCancellation()
                if let failure {throw failure}
                if let request=pendingSeek {
                    pendingSeek=nil
                    do {try await closeGeneration();try await openGeneration(target:request.0,onInfo:onInfo);request.1.resume();lastPTS=nil;lastPixelClock=ProcessInfo.processInfo.systemUptime}
                    catch {request.1.resume(throwing:error);throw error}
                }
                guard let player,let item,let output,let info=sourceInfo else{throw NativePlaybackSession.Failure.player}
                if item.status == .failed {diagnostics.enter(.playback);throw item.error ?? NativePlaybackSession.Failure.player}
                if item.status == .readyToPlay {markStartup(.ready,current:player.currentTime().seconds)}
                if ended {try mkvRequire(terminal,"影片在完整片尾之前結束");setState(.ended);break}
                diagnostics.poll()
                let query=output.itemTime(forHostTime:CACurrentMediaTime())
                if sceneActive && !seeking,output.hasNewPixelBuffer(forItemTime:query) {
                    var actual=CMTime.invalid
                    if let pixel=output.copyPixelBuffer(forItemTime:query,itemTimeForDisplay:&actual),actual.seconds.isFinite,
                       lastPTS.map({CMTimeCompare($0,actual) != 0}) ?? true {
                        lastPTS=actual;lastPixelClock=ProcessInfo.processInfo.systemUptime
                        diagnostics.frame()
                        markStartup(.firstVideo,current:info.origin+actual.seconds)
                        onFrame(DecodedVideoFrame(pixel:pixel,time:info.origin+actual.seconds,session:frameSession))
                    }
                }
                if !paused && sceneActive && ProcessInfo.processInfo.systemUptime-lastPixelClock>30 {diagnostics.enter(.playback);throw NativePlaybackSession.Failure.stalled}
                if paused || !sceneActive {lastPixelClock=ProcessInfo.processInfo.systemUptime}
                if !seeking {setState(paused ? .paused:player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? .waiting:.playing)}
                onSpeed(speedStatus)
                try await Task.sleep(nanoseconds:8_000_000)
            }
            try await closeGeneration();try await source.close();self.source=nil
            try FileManager.default.removeItem(at:folder);root=nil
        } catch {
            let original=error
            captureFailure(original)
            do {try await closeGeneration();try await source.close();self.source=nil;try FileManager.default.removeItem(at:folder);root=nil}
            catch {Self.retainedIncomplete=self}
            throw original
        }
    }
    @MainActor private final class InitialSeekResult {var value:Bool?}
    private func checkInitialPlayer(_ native:AVPlayer,_ media:AVPlayerItem,generation expected:UInt64) throws {
        try Task.checkCancellation()
        guard active,generation==expected,player === native,item === media else{throw CancellationError()}
        if media.status == .failed {throw media.error ?? NativePlaybackSession.Failure.player}
    }
    private func positionInitialPlayer(_ native:AVPlayer,_ media:AVPlayerItem,local:Double,generation expected:UInt64) async throws {
        do {
            let readyDeadline=ProcessInfo.processInfo.systemUptime+15
            while media.status != .readyToPlay {
                try checkInitialPlayer(native,media,generation:expected)
                try mkvRequire(ProcessInfo.processInfo.systemUptime<readyDeadline,"MKV 系統播放器準備逾時")
                try await Task.sleep(nanoseconds:5_000_000)
            }
            try checkInitialPlayer(native,media,generation:expected)
            markStartup(.ready,current:native.currentTime().seconds)
            markStartup(.seekBegin)
            try checkInitialPlayer(native,media,generation:expected)
            let result=InitialSeekResult(),seekDeadline=ProcessInfo.processInfo.systemUptime+15
            native.seek(to:CMTime(seconds:local,preferredTimescale:1_000_000_000),toleranceBefore:.zero,toleranceAfter:.zero) { succeeded in
                Task { @MainActor in result.value=succeeded }
            }
            while result.value == nil {
                try checkInitialPlayer(native,media,generation:expected)
                try mkvRequire(ProcessInfo.processInfo.systemUptime<seekDeadline,"MKV 起始跳轉逾時")
                try await Task.sleep(nanoseconds:5_000_000)
            }
            try checkInitialPlayer(native,media,generation:expected)
            markStartup(.seekEnd,current:native.currentTime().seconds,outcome:result.value == true ? 1:0)
            try mkvRequire(result.value == true,"MKV 起始跳轉失敗")
        } catch {
            media.cancelPendingSeeks();markStartup(.aborted);throw error
        }
    }
    private func waitPublished(_ count: Int) async throws -> MKVEngineInfo {
        diagnostics.enter(.enginePlan)
        let deadline=ProcessInfo.processInfo.systemUptime+15
        while active {
            try Task.checkCancellation()
            guard let session else{throw CancellationError()}
            captureEngine()
            let info=try session.info()
            captureEngine()
            if info.published>=count || info.terminal{return info}
            try mkvRequire(ProcessInfo.processInfo.systemUptime<deadline,"來源準備逾時")
            try await Task.sleep(nanoseconds:5_000_000)
        };throw CancellationError()
    }
    private func windowEntries(adding candidate:MKVEngineSegment?=nil,bytes:Int=0)->[MKVWindowBudget.Entry] {
        var values=segments.map{MKVWindowBudget.Entry(index:$0.index,duration:$0.duration,globalEnd:$0.globalEnd,bytes:segmentBytes[$0.index] ?? 0)}
        if let candidate {values.append(.init(index:candidate.index,duration:candidate.duration,globalEnd:candidate.globalEnd,bytes:bytes))}
        return values
    }
    private func globalNow(_ info:MKVEngineInfo)->Double {
        info.origin+(player?.currentTime().seconds.isFinite == true ? player!.currentTime().seconds:0)
    }
    private func inspectSegment(_ index:Int,startup:Bool) async throws -> (MKVEngineSegment,Int) {
        guard let session,let staging,let info=sourceInfo else{throw CancellationError()}
        diagnostics.enter(.segmentImport)
        let start=DispatchTime.now().uptimeNanoseconds
        defer {diagnostics.importCost(.validation,since:start)}
        let meta=try session.segment(index);try await session.validate()
        let bytes=try await MKVFileImport.size(staging,name:String(format:"segment-%03d.m4s",index),limit:MKVWindowBudget.payloadCap)
        let kept=MKVWindowBudget.retained(windowEntries(adding:meta,bytes:bytes),now:globalNow(info),targetDuration:info.targetDuration,startup:startup)
        diagnostics.capacity(windowBytes:MKVWindowBudget.byteCount(kept),incomingBytes:bytes)
        try mkvRequire(MKVWindowBudget.admits(kept,startup:startup),"MKV 播放窗口超過 128 MiB 或有界片段數")
        return (meta,bytes)
    }
    private func importSegment(_ prepared:(MKVEngineSegment,Int),startup:Bool) async throws {
        guard let session,let store,let staging else{throw CancellationError()}
        diagnostics.enter(.segmentImport)
        let (meta,expectedBytes)=prepared
        let index=meta.index
        try await measureImport(.validation) {try await session.validate()}
        let name=String(format:"segment-%03d.m4s",index)
        let bytes=try await measureImport(.dataRead) {try await MKVFileImport.read(staging,name:name,limit:MKVWindowBudget.payloadCap)}
        try mkvRequire(bytes.count==expectedBytes,"片段讀取不完整")
        let hash=try await measureImport(.storeStageWriteFsyncHash) {try await store.stage(stamp:session.stamp,name:name,data:bytes)}
        try await measureImport(.validation) {try await session.validate()}
        try await measureImport(.storeCommit) {try await store.commit(stamp:session.stamp,expectedSHA256:hash)}
        if startup {diagnostics.startupImported(durationNS:meta.durationNS)}
        segments.append(meta);segmentBytes[index]=bytes.count;try await session.acknowledgeImported(index)
        captureEngine()
    }
    private func publish() async throws {
        guard let store,let session,let info=sourceInfo else{throw CancellationError()}
        diagnostics.enter(.manifest)
        let kept=MKVWindowBudget.retained(windowEntries(),now:globalNow(info),targetDuration:info.targetDuration,startup:false)
        diagnostics.capacity(windowBytes:MKVWindowBudget.byteCount(kept),incomingBytes:0)
        try mkvRequire(MKVWindowBudget.admits(kept,startup:false),"MKV 播放窗口超過 128 MiB 或有界片段數")
        let ids=Set(kept.map{$0.index});segments.removeAll{!ids.contains($0.index)};segmentBytes=segmentBytes.filter{ids.contains($0.key)}
        firstPublishedIndex=segments.first!.index
        let body=segments.map{String(format:"#EXTINF:%.9f,\nsegment-%03d.m4s",$0.duration,$0.index)}.joined(separator:"\n")
        // Prefer this generation's first segment for initial positioning. Once
        // that segment leaves the rolling window, do not retarget to its new head.
        let startHint=firstPublishedIndex == 1 ? "#EXT-X-START:TIME-OFFSET=0,PRECISE=YES\n":""
        let text="#EXTM3U\n\(startHint)#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(info.targetDuration)\n#EXT-X-MEDIA-SEQUENCE:\(firstPublishedIndex-1)\n#EXT-X-MAP:URI=\"init.mp4\"\n\(body)\n"+(terminal ? "#EXT-X-ENDLIST\n":"")
        try await store.publishManifest(stamp:session.stamp,segments:segments.map{String(format:"segment-%03d.m4s",$0.index)},data:Data(text.utf8))
    }
    private func openGeneration(target:Double,onInfo:(VideoTrackInfo)->Void) async throws {
        guard let source,let root,session == nil else{throw NativePlaybackSession.Failure.source}
        diagnostics.enter(.workspace)
        generation+=1;frameSession=UUID();ended=false;terminal=false;segments=[];segmentBytes=[:];failure=nil
        initialPositioning=true
        diagnostics.beginGeneration(generation)
        observationBudget=MKVObservationBudget()
        markStartup(.requested,requested:target)
        let staging=root.appendingPathComponent("staging-\(generation)",isDirectory:true);self.staging=staging
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false)
        let ledger=root.appendingPathComponent("producer-\(generation).jsonl");self.ledger=ledger
        diagnostics.enter(.engineCreate)
        let window=try await source.create(staging:staging,receipt:ledger,generation:generation,target:target);session=window
        try window.start()
        diagnostics.enter(.enginePlan)
        var info=try await waitPublished(1);sourceInfo=info
        diagnostics.startupContract(targetSeconds:UInt64(clamping:info.targetDuration),requiredSegments:UInt64(info.startupSegments))
        try mkvRequire(info.width>0 && info.height>0 && info.duration.isFinite && info.duration>0 && info.targetDuration>0 && info.targetDuration<=10,"不支援的 MKV 視訊或時間資料")
        diagnostics.enter(.initImport)
        let store=try await MKVSegmentStore.create(parent:root,name:"store-\(generation)",stamp:window.stamp);self.store=store
        let data=try await measureImport(.dataRead) {try await MKVFileImport.read(staging,name:"init.mp4",limit:MKVWindowBudget.initCap)}
        let hash=try await measureImport(.storeStageWriteFsyncHash) {try await store.stage(stamp:window.stamp,name:"init.mp4",data:data)}
        try await measureImport(.validation) {try await window.validate()}
        try await measureImport(.storeCommit) {try await store.commit(stamp:window.stamp,expectedSHA256:hash)}
        captureEngine()
        var imported=0
        while true {
            while imported < info.published && segments.reduce(0,{$0+$1.duration}) < Double(info.targetDuration*3) {
                imported += 1;let prepared=try await inspectSegment(imported,startup:true);try await importSegment(prepared,startup:true)
            }
            terminal=info.terminal && imported==info.published
            if terminal || segments.reduce(0,{$0+$1.duration})>=Double(info.targetDuration*3){break}
            try mkvRequire(segments.count<MKVWindowBudget.segmentCountCap,"初始窗口無法在有限儲存內成立")
            info=try await waitPublished(imported+1)
        }
        sourceInfo=info;try await publish()
        diagnostics.enter(.server)
        let server=MKVLoopbackServer(store:store,stamp:window.stamp);self.server=server
        let observationGeneration=generation
        server.onObservation = { [weak self] observation in
            guard let self,self.generation==observationGeneration else{return}
            self.diagnostics.observedHTTP(observation)
            var fields=observation.values(relativeTo:self.diagnostics.observationOrigin);fields["mkvObservationKind"]=20
            self.emitObservation(fields)
        }
        let port=try await server.start()
        diagnostics.enter(.player)
        let media=AVPlayerItem(url:URL(string:"http://127.0.0.1:\(port)/index.m3u8")!);item=media
        let output=AVPlayerItemVideoOutput(pixelBufferAttributes:nil);self.output=output;media.add(output)
        let native=AVPlayer(playerItem:media);player=native;native.volume=outputGain;native.defaultRate=Float(selectedSpeed)
        markStartup(.playerCreated,origin:info.origin)
        #if MKV_SYNTHETIC_AUDIO_OBSERVATION
        configureSyntheticItem?(media)
        #endif
        let windowID=generation
        endObserver=NotificationCenter.default.addObserver(forName:AVPlayerItem.didPlayToEndTimeNotification,object:media,queue:.main) { [weak self] _ in MainActor.assumeIsolated {guard let self,self.generation==windowID else{return};self.ended=true} }
        onInfo(VideoTrackInfo(codec:"vp09",width:info.width,height:info.height,duration:info.duration,hasAudio:true))
        let local=max(0,target-info.origin)
        #if MKV_START_BASELINE
        // One-shot host comparison only: unchanged v7 initial-position behavior.
        if local>0 { let ok=await native.seek(to:CMTime(seconds:local,preferredTimescale:1_000_000_000),toleranceBefore:.zero,toleranceAfter:.zero);try mkvRequire(ok,"MKV 起始跳轉失敗") }
        #else
        try await positionInitialPlayer(native,media,local:local,generation:windowID)
        #endif
        try checkInitialPlayer(native,media,generation:windowID)
        initialPositioning=false;playIfAllowed()
        pumpTask=Task { @MainActor [weak self] in
            guard let self else{return}
            do {
                while self.active && self.generation==windowID && !self.terminal {
                    try Task.checkCancellation()
                    let now=info.origin+(native.currentTime().seconds.isFinite ? native.currentTime().seconds:0)
                    let ahead=(self.segments.last?.globalEnd ?? now)-now
                    if self.sceneActive && !self.paused && ahead<Double(info.targetDuration*3) && (self.segments.first?.globalEnd ?? now) <= now {
                        let next=try await self.waitPublished(imported+1)
                        if next.published>imported {
                            let n=imported+1,prepared=try await self.inspectSegment(n,startup:false)
                            if try await store.hasImportCapacity(stamp:window.stamp) {try await self.importSegment(prepared,startup:false);imported=n}
                        }
                        self.terminal=next.terminal && imported==next.published;try await self.publish()
                    }
                    try await store.reap(stamp:window.stamp)
                    try await Task.sleep(nanoseconds:100_000_000)
                }
            } catch is CancellationError {} catch {self.captureFailure(error);self.failure=error}
        }
    }
    private func closeGeneration() async throws {
        captureEngine();diagnostics.enter(.cleanup)
        pumpTask?.cancel();if let pumpTask{_ = await pumpTask.result};pumpTask=nil
        player?.pause();item?.cancelPendingSeeks();if let output{item?.remove(output)}
        if let endObserver{NotificationCenter.default.removeObserver(endObserver)};endObserver=nil
        player?.replaceCurrentItem(with:nil);player=nil;item=nil;output=nil;initialPositioning=false
        guard let session else{return}
        session.cancel()
        if let store{try await store.beginRetirement(stamp:session.stamp)}
        if let server {
            let status=await server.stop()
            try mkvRequire(status["responseTasksReturned"] as? Bool == true && status["socketTerminalCallbacksObserved"] as? Bool == true,"HTTP 讀取尚未結束")
        }
        let ack=try await session.drain();try mkvRequire(ack.fullyAcknowledged,"來源讀取尚未結束")
        if let store{try await store.acknowledgeDrain(ack);try mkvRequire(try await store.cleanup(stamp:session.stamp),"片段仍有讀取租約")}
        try session.destroy()
        // The engine destroys its recorded staged files only after join; do not recursively delete unowned content.
        if let staging,FileManager.default.fileExists(atPath:staging.path) {
            let contents=try FileManager.default.contentsOfDirectory(atPath:staging.path)
            try mkvRequire(contents.isEmpty,"來源暫存仍有未收尾檔案")
            try FileManager.default.removeItem(at:staging)
        }
        if let ledger,FileManager.default.fileExists(atPath:ledger.path){try FileManager.default.removeItem(at:ledger)}
        self.session=nil;store=nil;server=nil;staging=nil;ledger=nil
    }
}
#endif
