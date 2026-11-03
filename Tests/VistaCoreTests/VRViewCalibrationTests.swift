import Foundation
import simd
import Testing
@testable import VistaCore

private func pose(yaw: Float = 0, pitch: Float = 0, roll: Float = 0, position: SIMD3<Float> = [0,1.2,0]) -> VRInitialPose {
    let q = simd_quatf(angle: yaw, axis: [0,1,0]) * simd_quatf(angle: pitch, axis: [1,0,0]) * simd_quatf(angle: roll, axis: [0,0,1])
    var matrix = simd_float4x4(q); matrix.columns.3 = SIMD4(position, 1)
    return VRInitialPose(matrix: matrix)!
}
private actor PoseSource: VRInitialPoseProvider {
    var value: VRInitialPose?
    var calls = 0
    init(_ value: VRInitialPose?) { self.value = value }
    func change(_ value: VRInitialPose?) { self.value = value }
    func sample() async throws -> VRInitialPose? { calls += 1; return value }
}
private actor GatedPoseSource: VRInitialPoseProvider {
    var continuation: CheckedContinuation<VRInitialPose?, Never>?
    var started: CheckedContinuation<Void, Never>?
    func sample() async throws -> VRInitialPose? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation; started?.resume(); started = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func complete(_ pose: VRInitialPose) { continuation?.resume(returning: pose); continuation = nil }
}
@MainActor struct VRViewCalibrationTests {
    @Test func seatedLyingAndSideLyingPreserveFullOrientation() {
        let forward = SIMD3<Float>(0,0,-1), up = SIMD3<Float>(0,1,0)
        let seated = pose(yaw: .pi / 2)
        #expect(simd_distance(seated.orientation.act(forward), [-1,0,0]) < 0.00001)
        #expect(seated.position == [0,1.2,0])
        let lying = pose(pitch: .pi / 2, position: [1,0.6,2])
        #expect(simd_distance(lying.orientation.act(forward), [0,1,0]) < 0.00001)
        #expect(simd_distance(lying.orientation.act(up), [0,0,1]) < 0.00001)
        let side = pose(roll: .pi / 2)
        #expect(simd_distance(side.orientation.act(up), [-1,0,0]) < 0.00001)
        #expect(simd_distance(side.orientation.act(forward), forward) < 0.00001)
    }
    @Test func invalidPoseDoesNotBecomeAnIdentityCalibration() {
        var scaled = matrix_identity_float4x4; scaled.columns.0.x = 2
        var reflected = matrix_identity_float4x4; reflected.columns.0.x = -1
        var invalid = matrix_identity_float4x4; invalid.columns.3.x = .nan
        var perspective = matrix_identity_float4x4; perspective.columns.0.w = 1
        for matrix in [scaled, reflected, invalid, perspective, simd_float4x4()] {
            #expect(VRInitialPose(matrix: matrix) == nil)
        }
        #expect(VRInitialPose(matrix: matrix_identity_float4x4) != nil)
    }
    @Test func manualOffsetsUseCalibratedLocalAxes() {
        let lying = pose(pitch: .pi / 2)
        let yaw = VRInitialPose.manualRotation(yaw: 90, pitch: 0, roll: 0)
        #expect(simd_distance((lying.orientation * yaw).act([0,0,-1]), [-1,0,0]) < 0.00001)
        let pitch = VRInitialPose.manualRotation(yaw: 0, pitch: 90, roll: 0)
        #expect(simd_distance(pitch.act([0,0,-1]), [0,1,0]) < 0.00001)
        let roll = VRInitialPose.manualRotation(yaw: 0, pitch: 0, roll: 90)
        #expect(simd_distance(roll.act([0,1,0]), [-1,0,0]) < 0.00001)
        let invalid = VRInitialPose.manualRotation(yaw: .nan, pitch: .infinity, roll: 720)
        #expect(simd_distance(invalid.act([0,0,-1]), [0,0,-1]) < 0.00001)
    }
    @Test func capturesOnceUntilExplicitRecenterOrNewFile() async {
        let calibration = VRViewCalibration(), source = PoseSource(pose())
        #expect(await calibration.capture(using: source))
        let first = calibration.pose!.orientation.vector
        await source.change(pose(pitch: .pi / 2))
        #expect(!(await calibration.capture(using: source)))
        #expect(calibration.pose!.orientation.vector == first)
        #expect(await source.calls == 1)
        calibration.requestRecenter()
        #expect(await calibration.capture(using: source))
        #expect(await source.calls == 2)
        #expect(simd_distance(calibration.pose!.orientation.act([0,0,-1]), [0,1,0]) < 0.00001)
        calibration.resetForNewFile()
        #expect(calibration.pose == nil); #expect(calibration.status == .idle)
        #expect(await calibration.capture(using: source)); #expect(await source.calls == 3)
    }
    @Test func unavailableDoesNotRetryOrDiscardPreviousValidPose() async {
        let calibration = VRViewCalibration(), source = PoseSource(nil)
        #expect(!(await calibration.capture(using: source)))
        #expect(calibration.pose == nil); #expect(calibration.status == .unavailable)
        #expect(!(await calibration.capture(using: source))); #expect(await source.calls == 1)
        await source.change(pose()); calibration.requestRecenter()
        #expect(await calibration.capture(using: source))
        let previous = calibration.pose!.orientation.vector
        await source.change(nil); calibration.requestRecenter()
        #expect(!(await calibration.capture(using: source)))
        #expect(calibration.pose!.orientation.vector == previous); #expect(calibration.status == .unavailable)
    }
    @Test func latePoseCannotUpdateANewFileOrCancelledView() async {
        for reset in [true, false] {
            let calibration = VRViewCalibration(), source = GatedPoseSource()
            let task = Task { await calibration.capture(using: source) }
            await source.waitUntilStarted()
            if reset { calibration.resetForNewFile() } else { calibration.cancel(); task.cancel() }
            await source.complete(pose(pitch: .pi / 2))
            #expect(!(await task.value))
            #expect(calibration.pose == nil); #expect(calibration.status == .idle)
        }
    }
    @Test func directionsRemainEphemeral() throws {
        var settings = VRSettings(); settings.yawDegrees = 30; settings.pitchDegrees = 90; settings.rollDegrees = 45
        let data = try JSONEncoder().encode(VRFormat(settings))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("yaw") && !text.contains("pitch") && !text.contains("roll") && !text.contains("position"))
        let restored = try JSONDecoder().decode(VRFormat.self, from: data).settings
        #expect(restored.yawDegrees == 0 && restored.pitchDegrees == 0 && restored.rollDegrees == 0)
    }
}
