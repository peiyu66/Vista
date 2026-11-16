import ARKit
import QuartzCore
import Foundation

/// Initial placement, a bounded reset sample, or active control drag. No anchors, authorization requests or pose persistence.
struct DeviceInitialPose: VRInitialPoseProvider {
    var resetSample = false
    func sample() async throws -> VRInitialPose? {try await sample(trace:nil)}
    func sample(trace:VRRecenterTrace?) async throws ->VRInitialPose? {
        trace?.record(.providerBegin,fields:[.detail:resetSample ? 1:0])
        guard WorldTrackingProvider.isSupported else {trace?.record(.providerEnd,outcome:1);return nil}
        guard WorldTrackingProvider.requiredAuthorizations.isEmpty else {trace?.record(.providerEnd,outcome:2);return nil}
        let normalToken=await MainActor.run {ControllerPoseProbeGate.shared.beginNormal()}
        let session=ARKitSession(),provider=WorldTrackingProvider()
        let started=ContinuousClock.now
        let resetDeadline=started.advanced(by:.milliseconds(300))
        let totalDeadline=started.advanced(by:.milliseconds(resetSample ? 300:3000))
        let timeout=Task {
            try await Task.sleep(for:.milliseconds(resetSample ? 300:3000))
            session.stop()
        }
        var queries=0,missing=0,untracked=0,invalid=0,outcome=0
        defer {
            let state=provider.state == .running ? 1:(provider.state == .stopped ? 3:0)
            timeout.cancel();session.stop();ControllerPoseProbeGate.shared.endNormal(normalToken)
            trace?.record(.providerEnd,outcome:outcome,fields:[.poseState:Double(state),.poseQueries:Double(queries),.poseMissing:Double(missing),.poseUntracked:Double(untracked),.poseInvalid:Double(invalid),.timeout:ContinuousClock.now>=totalDeadline ? 1:0])
        }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                trace?.record(.runBegin)
                do {try await session.run([provider]);trace?.record(.runEnd)}
                catch {trace?.record(.runEnd,outcome:Task.isCancelled ? 3:2);throw error}
                for _ in 0..<(resetSample ? 6:40) {
                    try Task.checkCancellation()
                    if resetSample,ContinuousClock.now>=resetDeadline {outcome=3;return nil}
                    if provider.state == .running {
                        queries+=1
                        let queryStarted=ProcessInfo.processInfo.systemUptime
                        let anchor=provider.queryDeviceAnchor(atTimestamp:CACurrentMediaTime())
                        let timing=VRPoseSampleTiming(queryStarted:queryStarted,queryFinished:ProcessInfo.processInfo.systemUptime)
                        if let anchor {
                            if !anchor.isTracked {untracked+=1}
                            else if let pose=VRInitialPose(matrix:anchor.originFromAnchorTransform) {
                                if resetSample,ContinuousClock.now>=resetDeadline {outcome=3;return nil}
                                var fields:[LifecycleField:Double]=[.recenterSensorAgeKnown:0]
                                if let ms=timing.queryMS {fields[.recenterQueryMS]=ms}
                                trace?.record(.sampleTiming,fields:fields)
                                return pose.withSampleTiming(timing)
                            } else {invalid+=1}
                        } else {missing+=1}
                    }
                    if provider.state == .stopped {outcome=ContinuousClock.now>=totalDeadline ? 3:4;return nil}
                    try await Task.sleep(for:.milliseconds(50))
                }
                outcome=5;return nil
            } onCancel:{session.stop()}
        } catch {
            outcome=Task.isCancelled ? 6:7
            throw error
        }
    }
    /// One session for the active gesture; cancellation always stops tracking.
    @MainActor
    func duringDrag(update: @MainActor (VRInitialPose) -> Void) async throws {
        guard WorldTrackingProvider.isSupported,
              WorldTrackingProvider.requiredAuthorizations.isEmpty else { return }
        let normalToken=ControllerPoseProbeGate.shared.beginNormal()
        let session = ARKitSession(), provider = WorldTrackingProvider()
        defer { session.stop();ControllerPoseProbeGate.shared.endNormal(normalToken) }
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
