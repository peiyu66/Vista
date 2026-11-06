import Foundation

/// A short transient may discard obsolete video, but persistent lag must still stop.
struct AudioVideoCatchUp {
    private var began: ContinuousClock.Instant?
    private(set) var consecutiveDrops = 0
    mutating func reset() { began = nil; consecutiveDrops = 0 }
    mutating func shouldDrop(audio: Double, video: Double, now: ContinuousClock.Instant) throws -> Bool {
        guard audio.isFinite else { throw PlaybackFailure.audioFailed.diagnosed(.audioClockInvalid) }
        guard video.isFinite, video >= 0 else { throw PlaybackFailure.decodeFailed.diagnosed(.videoPTS) }
        let delta = audio - video
        // Recover to within 100ms, not merely just inside the 500ms entry threshold.
        if delta < (began == nil ? 0.5 : 0.1) { reset(); return false }
        if began == nil { began = now }
        guard consecutiveDrops < 120, began!.duration(to: now) < .seconds(3) else {
            let ms = Int(min(max(delta * 1_000, -86_400_000), 86_400_000))
            throw PlaybackFailure.audioFailed.diagnosed(.audioLead, deltaMS: ms)
        }
        consecutiveDrops += 1
        return true
    }
}

/// One timeline per playback. Main-actor delivery makes pause and visible frame updates atomic.
@MainActor public final class PlaybackTimeline {
    public private(set) var isPaused = false
    private let clock = ContinuousClock()
    private var origin: ContinuousClock.Instant?
    private var firstPTS = 0.0
    private var pausedAt: ContinuousClock.Instant?
    private var pausedDuration = Duration.zero
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var audioClock: PlaybackAudioClock?
    private var feedAudio: (@Sendable (Double) async throws -> Void)?
    func attachAudio(_ clock: PlaybackAudioClock, feed: @escaping @Sendable (Double) async throws -> Void) {
        audioClock = clock; feedAudio = feed
    }
    var audioTime: Double? { audioClock?.time }
    public func stopAudio() { cancelVideoWork();audioClock?.stop() }
    func detachAudio() {cancelVideoWork();audioClock = nil; feedAudio = nil; catchUp.reset() }
    private var requestedStart: Double?
    private var catchUp = AudioVideoCatchUp()
    var metrics:PlaybackMetrics?
    public private(set) var droppedVideoFrames = 0
    public private(set) var isBuffering=false
    var onBufferingChange: (@MainActor @Sendable (Bool)->Void)?
    private let videoReadBuffering:Bool
    private var videoWork:UUID?
    private var videoWatchdog:Task<Void,Never>?
    private var bufferingBegan:ContinuousClock.Instant?
    // Buffering is separate from the user's paused state. No new I/O is started by this timer.
    func beginVideoWork()->UUID {
        videoWatchdog?.cancel();let token=UUID();guard videoReadBuffering else{return token};videoWork=token
        videoWatchdog=Task { [weak self] in
            do {try await Task.sleep(for:.milliseconds(100))}catch{return}
            guard let self,self.videoWork==token,!self.isPaused,self.audioClock?.hasStarted==true else{return}
            self.beginBuffering()
        }
        return token
    }
    func endVideoWork(_ token:UUID) {
        guard videoWork==token else{return};videoWork=nil;videoWatchdog?.cancel();videoWatchdog=nil
        // Audio resumes only when a current video frame is ready, not merely when a read completes.
    }
    private func beginBuffering() {
        guard !isBuffering,audioClock?.hasStarted==true else{return}
        audioClock?.pause();isBuffering=true;bufferingBegan=clock.now;onBufferingChange?(true)
    }
    private func checkBufferingDeadline()throws {
        if let began=bufferingBegan,began.duration(to:clock.now) >= .seconds(15) {throw PlaybackFailure.readFailed.diagnosed(.videoBufferingTimeout)}
    }
    private func finishBuffering(resume:Bool) {
        guard isBuffering else{return}
        if let began=bufferingBegan {let d=began.duration(to:clock.now).components;metrics?.record(.buffering,seconds:Double(d.seconds)+Double(d.attoseconds)/1e18)}
        bufferingBegan=nil;isBuffering=false;catchUp.reset();onBufferingChange?(false)
        if resume && !isPaused {audioClock?.resume()}
    }
    private func cancelVideoWork() {
        videoWatchdog?.cancel();videoWatchdog=nil;videoWork=nil;finishBuffering(resume:false)
    }
    private var previewFirstFrame: Bool
    public init(previewFirstFrame: Bool = false,videoReadBuffering:Bool=true) { self.previewFirstFrame = previewFirstFrame;self.videoReadBuffering=videoReadBuffering }
    func prepare(at time: Double) { requestedStart = time; catchUp.reset(); droppedVideoFrames = 0 }

    public func pause() {
        guard !isPaused else { return }
        catchUp.reset()
        finishBuffering(resume:false)
        audioClock?.pause()
        isPaused = true
        pausedAt = clock.now
    }
    public func resume() {
        guard isPaused else { return }
        if origin != nil, let pausedAt { pausedDuration += pausedAt.duration(to: clock.now) }
        if videoWork != nil {beginBuffering()}
        if !isBuffering {audioClock?.resume()}
        pausedAt = nil; isPaused = false
        let pending = Array(waiters.values)
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
    public func waitUntilRunning() async throws {
        try Task.checkCancellation()
        while isPaused {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { waiters[id] = continuation }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            }
            try Task.checkCancellation()
        }
    }
    /// Skip obsolete pixels before expensive CI conversion. Rechecked after conversion in present().
    func skipLateVideoFrame(at pts: Double) async throws -> Bool {
        try await waitUntilRunning()
        guard !previewFirstFrame, let audioClock else { return false }
        try audioClock.check()
        if isBuffering {
            try checkBufferingDeadline()
            let drop=audioClock.time-pts>0.1
            if drop {droppedVideoFrames += 1;metrics?.mark(.dropped)}
            return drop
        }
        let drop = try catchUp.shouldDrop(audio: audioClock.time, video: pts, now: clock.now)
        if drop {
            // Skipping image conversion must not also skip feeding the master audio clock.
            try await feedAudio?(audioClock.time + 0.5)
            try Task.checkCancellation()
            try audioClock.check()
            droppedVideoFrames += 1; metrics?.mark(.dropped)
        }
        return drop
    }
    @discardableResult
    public func present(at pts: Double, output: @MainActor @Sendable () -> Void) async throws -> Bool {
        guard pts.isFinite, pts >= 0 else { throw PlaybackFailure.decodeFailed }
        if previewFirstFrame {
            try Task.checkCancellation()
            previewFirstFrame = false
            pause()
            output()
            return true
        }
        var stalledSince = clock.now
        var lastAudioTime = -Double.infinity
        while true {
            try await waitUntilRunning()
            if let audioClock {
                if isBuffering {
                    try checkBufferingDeadline()
                    if audioClock.time-pts>0.1 {droppedVideoFrames += 1;metrics?.mark(.dropped);return false}
                }
                try await feedAudio?(audioClock.time + 0.5)
                try Task.checkCancellation()
                if isPaused { continue }
                try audioClock.start()
                try audioClock.check()
                finishBuffering(resume:true)
                let now = audioClock.time
                if try catchUp.shouldDrop(audio: now, video: pts, now: clock.now) {
                    droppedVideoFrames += 1; metrics?.mark(.dropped)
                    return false
                }
                if now >= pts { try Task.checkCancellation(); output(); return true }
                if now > lastAudioTime + 0.001 { stalledSince = clock.now; lastAudioTime = now }
                guard stalledSince.duration(to: clock.now) < .seconds(3) else { throw PlaybackFailure.audioFailed.diagnosed(.audioClockStalled) }
                try await clock.sleep(for: .milliseconds(5))
                continue
            }
            if origin == nil { origin = clock.now; firstPTS = requestedStart ?? pts }
            let deadline = origin!.advanced(by: .seconds(pts - firstPTS) + pausedDuration)
            if clock.now < deadline {
                try await clock.sleep(until: deadline)
                continue // Pause/resume may have changed the deadline while sleeping.
            }
            try Task.checkCancellation()
            output()
            return true
        }
    }
}
