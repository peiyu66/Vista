import Foundation

/// The retry budget is local to one video session and one foreground interval.
/// It never restarts playback, reconnects a source, or treats other failures as recoverable.
public struct VideoRendererRecoveryGate: Sendable {
    public enum Decision: Equatable, Sendable { case deferred, retry, failed }
    public private(set) var sceneActive = true
    public private(set) var session: UUID?
    public private(set) var attempted = false

    public init() {}

    public mutating func selectSession(_ value: UUID) {
        guard session != value else { return }
        session = value
        attempted = false
    }

    @discardableResult public mutating func setSceneActive(_ value: Bool) -> Bool {
        guard sceneActive != value else { return false }
        sceneActive = value
        // A new real interruption gets a new budget; duplicate inactive/background
        // notifications and ordinary frames do not repeatedly replenish it.
        if !value { attempted = false }
        return true
    }

    /// Call only for the renderer's explicit requires-flush signal.
    public mutating func requestRecovery() -> Decision {
        guard session != nil else { return .failed }
        guard sceneActive else { return .deferred }
        guard !attempted else { return .failed }
        attempted = true
        return .retry
    }

    public mutating func stop() {
        session = nil
        attempted = false
    }
}
