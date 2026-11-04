import Foundation
import Observation
#if SWIFT_PACKAGE
import VistaCore
#endif

/// Serializes replacement playback jobs and rejects callbacks from obsolete requests.
@MainActor @Observable public final class PlaybackController {
    public private(set) var isPlaying = false
    public private(set) var isPaused = false
    public private(set) var isPreparing = false
    public private(set) var position = 0.0
    public private(set) var trackInfo: VideoTrackInfo?
    public private(set) var frame: VideoFrame?
    public private(set) var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var timeline: PlaybackTimeline?
    @ObservationIgnored private var file: MediaFile?
    @ObservationIgnored private var source: (any MediaByteSource)?
    @ObservationIgnored private let engine: HardwarePlayback
    public init() { engine = HardwarePlayback() }
    init(engine: HardwarePlayback) { self.engine = engine }

    public func play(file: MediaFile, source: any MediaByteSource) {
        self.file = file; self.source = source
        trackInfo = nil
        launch(at: 0, paused: false)
    }
    public func seek(to requested: Double) {
        guard requested.isFinite, let trackInfo else { return }
        let target = max(0, min(requested, trackInfo.duration))
        if target == trackInfo.duration {
            stop()
            position = target; message = "播放結束"
            return
        }
        launch(at: target, paused: isPaused)
    }
    public func skip(by interval: Double) { seek(to: position + interval) }
    public func togglePause() {
        guard isPlaying, !isPreparing, let timeline else { return }
        if isPaused { timeline.resume() } else { timeline.pause() }
        isPaused = timeline.isPaused
        message = isPaused ? "已暫停" : "繼續播放中"
    }
    public func stop() {
        generation = UUID()
        timeline?.stopAudio()
        task?.cancel()
        // Keep the cancelled task until a replacement can join its cleanup.
        timeline = nil
        isPlaying = false; isPaused = false; isPreparing = false
        frame = nil; position = 0; message = "已停止"
    }
    private func launch(at target: Double, paused: Bool) {
        guard let file, let source else { return }
        let oldTask = task
        timeline?.stopAudio(); oldTask?.cancel()
        let id = UUID(); generation = id
        let control = PlaybackTimeline(previewFirstFrame: paused)
        timeline = control
        isPlaying = true; isPaused = paused; isPreparing = true
        frame = nil; position = target; message = target == 0 ? "正在準備影片…" : "正在跳轉…"
        task = Task {
            await oldTask?.value
            guard !Task.isCancelled, generation == id else { return }
            do {
                _ = try await engine.play(file: file, source: source, startAt: target, timeline: control,
                    onInfo: { [weak self] info in
                        guard let self, self.generation == id else { return }
                        self.trackInfo = info
                    }, onFrame: { [weak self] next in
                        guard let self, self.generation == id else { return }
                        self.frame = next; self.position = next.time; self.isPreparing = false
                        self.isPaused = control.isPaused
                        self.message = self.isPaused ? "已暫停" : (PlaybackDecodingPolicy.simulatorSoftwareTest ? "模擬器軟體解碼測試中" : "硬體解碼播放中")
                    })
                guard generation == id else { return }
                position = trackInfo?.duration ?? position; message = "播放結束"
            } catch {
                guard generation == id else { return }
                message = (error as? PlaybackFailure)?.message ?? "無法讀取影片。請確認連線及檔案後重試。"
            }
            if generation == id {
                isPlaying = false; isPaused = false; isPreparing = false
                timeline = nil; task = nil
            }
        }
    }
}
