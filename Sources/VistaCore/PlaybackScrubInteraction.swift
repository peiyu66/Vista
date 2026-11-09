import Foundation

/// One slider edit, owned by one playback generation. Playback itself keeps running
/// until a changed edit is committed; this value never pauses or resumes a player.
public struct PlaybackScrubInteraction: Sendable {
    public private(set) var owner: UUID?
    public private(set) var position: Double = 0
    public private(set) var changed = false
    public var isActive: Bool { owner != nil }
    public init() {}

    /// SwiftUI may deliver a binding setter before editingBegan. A later begin for
    /// the same owner must preserve that setter's target and change evidence.
    public mutating func begin(owner: UUID, position: Double) {
        guard position.isFinite else { return }
        guard self.owner != owner else { return }
        self.owner = owner; self.position = position; changed = false
    }

    public mutating func update(_ value: Double, owner: UUID, initialPosition: Double) {
        guard value.isFinite, initialPosition.isFinite else { return }
        begin(owner: owner, position: initialPosition)
        if value != position { changed = true }
        position = value
    }

    /// Exact equality only. A real edit that returns to its starting value still
    /// commits. A stale end cannot consume a newer owner's interaction.
    public mutating func finish(owner: UUID) -> Double? {
        guard self.owner == owner else { return nil }
        let target = changed ? position : nil
        cancel()
        return target
    }

    /// The ordinary slider uses this exact synchronous submission seam. It does
    /// not inspect preparation or pause state: changed edits retain the existing
    /// Controller seek/supersession semantics, including a second pending seek.
    @discardableResult
    public mutating func finish(owner: UUID, submit: (Double) -> Void) -> Bool {
        guard let target = finish(owner: owner) else { return false }
        submit(target)
        return true
    }

    public mutating func cancel() { self = Self() }

    public mutating func retainOnly(owner: UUID?) {
        if self.owner != owner { cancel() }
    }
}
