import Foundation
import Observation
import simd

/// Ephemeral rigid pose. Never encoded, logged or included in per-file preferences.
public struct VRInitialPose: Sendable {
    public let position: SIMD3<Float>
    public let orientation: simd_quatf
    public init?(matrix: simd_float4x4) {
        let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
        guard columns.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }),
              abs(columns[0].w) < 0.001, abs(columns[1].w) < 0.001, abs(columns[2].w) < 0.001,
              abs(columns[3].w - 1) < 0.001 else { return nil }
        let axes = columns.prefix(3).map { SIMD3($0.x, $0.y, $0.z) }
        guard axes.allSatisfy({ abs(simd_length_squared($0) - 1) < 0.01 }),
              abs(simd_dot(axes[0], axes[1])) < 0.01, abs(simd_dot(axes[0], axes[2])) < 0.01,
              abs(simd_dot(axes[1], axes[2])) < 0.01 else { return nil }
        let rotation = simd_float3x3(columns: (axes[0], axes[1], axes[2]))
        guard simd_determinant(rotation) > 0.99 else { return nil }
        position = SIMD3(columns[3].x, columns[3].y, columns[3].z)
        orientation = simd_normalize(simd_quatf(rotation))
    }
    public static func manualRotation(yaw: Double, pitch: Double, roll: Double) -> simd_quatf {
        func radians(_ value: Double) -> Float {
            value.isFinite ? Float(value.truncatingRemainder(dividingBy: 360) * .pi / 180) : 0
        }
        return simd_quatf(angle: radians(yaw), axis: [0,1,0])
            * simd_quatf(angle: radians(pitch), axis: [1,0,0])
            * simd_quatf(angle: radians(roll), axis: [0,0,1])
    }
}
public protocol VRInitialPoseProvider: Sendable {
    /// Return one valid pose or nil. Implementations must stop acquisition when done/cancelled.
    func sample() async throws -> VRInitialPose?
}
@MainActor @Observable public final class VRViewCalibration {
    public enum Status: String, Sendable { case idle, capturing, ready, unavailable }
    public private(set) var status: Status = .idle
    public private(set) var pose: VRInitialPose?
    @ObservationIgnored private var generation = 0
    public init() {}
    public func resetForNewFile() { generation += 1; pose = nil; status = .idle }
    public func requestRecenter() { generation += 1; status = .idle }
    public func cancel() {
        generation += 1
        if status == .capturing { status = pose == nil ? .idle : .ready }
    }
    @discardableResult public func capture(using provider: any VRInitialPoseProvider) async -> Bool {
        guard status == .idle else { return false }
        generation += 1; let ticket = generation
        status = .capturing
        do {
            let result = try await provider.sample()
            try Task.checkCancellation()
            guard ticket == generation else { return false }
            if let result { pose = result; status = .ready; return true }
            status = .unavailable
        } catch {
            guard ticket == generation else { return false }
            status = Task.isCancelled ? (pose == nil ? .idle : .ready) : .unavailable
        }
        return false
    }
}
