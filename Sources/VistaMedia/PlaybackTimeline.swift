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
    public init() {}

    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        pausedAt = clock.now
    }
    public func resume() {
        guard isPaused else { return }
        if origin != nil, let pausedAt { pausedDuration += pausedAt.duration(to: clock.now) }
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
        while true {
            try await waitUntilRunning()
            if origin == nil { origin = clock.now; firstPTS = pts }
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
