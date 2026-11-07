import ARKit
import QuartzCore

/// Initial placement, a bounded reset sample, or active control drag. No anchors, authorization requests or pose persistence.
struct DeviceInitialPose: VRInitialPoseProvider {
    var resetSample = false
    func sample() async throws -> VRInitialPose? {
        guard WorldTrackingProvider.isSupported,
              WorldTrackingProvider.requiredAuthorizations.isEmpty else { return nil }
        let session = ARKitSession(), provider = WorldTrackingProvider()
        let resetDeadline = ContinuousClock.now.advanced(by: .milliseconds(300))
        let timeout = Task {
            try await Task.sleep(for: .milliseconds(resetSample ? 300:3000))
            session.stop()
        }
        defer { timeout.cancel(); session.stop() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await session.run([provider])
            for _ in 0..<(resetSample ? 6:40) {
                try Task.checkCancellation()
                if resetSample,ContinuousClock.now >= resetDeadline { return nil }
                if provider.state == .running,
                   let anchor = provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), anchor.isTracked,
                   let pose = VRInitialPose(matrix: anchor.originFromAnchorTransform) {
                    return resetSample && ContinuousClock.now >= resetDeadline ? nil:pose
                }
                if provider.state == .stopped { return nil }
                try await Task.sleep(for: .milliseconds(50))
            }
            return nil
        } onCancel: { session.stop() }
    }
    /// One session for the active gesture; cancellation always stops tracking.
    @MainActor
    func duringDrag(update: @MainActor (VRInitialPose) -> Void) async throws {
        guard WorldTrackingProvider.isSupported,
              WorldTrackingProvider.requiredAuthorizations.isEmpty else { return }
        let session = ARKitSession(), provider = WorldTrackingProvider()
        defer { session.stop() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await session.run([provider])
            while !Task.isCancelled {
                if provider.state == .running,
                   let anchor = provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), anchor.isTracked,
                   let pose = VRInitialPose(matrix: anchor.originFromAnchorTransform) { update(pose) }
                if provider.state == .stopped { return }
                try await Task.sleep(for: .milliseconds(33))
            }
        } onCancel: { session.stop() }
    }

}
