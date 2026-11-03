import Foundation

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
    public func stopAudio() { audioClock?.stop() }
    func detachAudio() { audioClock = nil; feedAudio = nil }
    private var requestedStart: Double?
    private var previewFirstFrame: Bool
    public init(previewFirstFrame: Bool = false) { self.previewFirstFrame = previewFirstFrame }
    func prepare(at time: Double) { requestedStart = time }

    public func pause() {
        guard !isPaused else { return }
        audioClock?.pause()
        isPaused = true
        pausedAt = clock.now
    }
    public func resume() {
        guard isPaused else { return }
        if origin != nil, let pausedAt { pausedDuration += pausedAt.duration(to: clock.now) }
        audioClock?.resume()
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
    public func present(at pts: Double, output: @MainActor @Sendable () -> Void) async throws {
        guard pts.isFinite, pts >= 0 else { throw PlaybackFailure.decodeFailed }
        if previewFirstFrame {
            try Task.checkCancellation()
            previewFirstFrame = false
            pause()
            output()
            return
        }
        var stalledSince = clock.now
        var lastAudioTime = -Double.infinity
        while true {
            try await waitUntilRunning()
            if let audioClock {
                try await feedAudio?(audioClock.time + 0.5)
                try Task.checkCancellation()
                if isPaused { continue }
                try audioClock.start()
                try audioClock.check()
                let now = audioClock.time
                guard now.isFinite, now - pts < 0.5 else { throw PlaybackFailure.audioFailed }
                if now >= pts { try Task.checkCancellation(); output(); return }
                if now > lastAudioTime + 0.001 { stalledSince = clock.now; lastAudioTime = now }
                guard stalledSince.duration(to: clock.now) < .seconds(3) else { throw PlaybackFailure.audioFailed }
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
            return
        }
    }
}
