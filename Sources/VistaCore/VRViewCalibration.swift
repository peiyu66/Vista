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

/// Ephemeral controller displacement in the frozen viewing coordinate system.
public enum VRControllerPlacement {
    public static let legacyHeightOrigin = SIMD3<Float>(0.65, -0.18, -1.5)
    public static let initialYaw:Float = 45 * .pi/180
    public static let origin:SIMD3<Float> = {
        let radius=hypot(legacyHeightOrigin.x,legacyHeightOrigin.z)
        return SIMD3(radius*sin(initialYaw),legacyHeightOrigin.y,-radius*cos(initialYaw))
    }()
    public static let maximumYaw:Float = 175 * .pi/180
    public static func constrained(_ offset: SIMD3<Float>, previous:SIMD3<Float>? = nil) -> SIMD3<Float> {
        guard offset.x.isFinite, offset.y.isFinite, offset.z.isFinite else { return .zero }
        let point=origin+offset
        let radius=hypot(point.x,point.z)
        let prior=previous ?? origin
        var yaw=radius>0.05 ? atan2(point.x,-point.z):atan2(prior.x,-prior.z)
        if previous != nil {
            let priorYaw=atan2(prior.x,-prior.z)
            if yaw-priorYaw > .pi {yaw -= 2 * .pi}
            if yaw-priorYaw < -.pi {yaw += 2 * .pi}
        }
        yaw=min(max(yaw,-maximumYaw),maximumYaw)
        let distance=min(max(radius,1),2.2)
        return SIMD3(distance*sin(yaw),min(max(point.y,-0.83),0.67),-distance*cos(yaw))-origin
    }
}

/// A planar capsule: no beveled box edge or protruding fill layer.
public enum VRControllerHandle {
    public static let width:Float = 0.132
    public static let height:Float = 0.008
    public static let gap:Float = 0.012
    public static var outline:[SIMD3<Float>] {
        let radius=height/2, center=(width-height)/2
        return (0..<34).map { index in
            let right=index<17
            let angle = Float(index % 17) * .pi/16 + (right ? -.pi/2 : .pi/2)
            return SIMD3((right ? center : -center)+radius*cos(angle),radius*sin(angle),0)
        }
    }
}

extension VRControllerPlacement {
    /// +Z faces the viewer. Keep the calibrated up axis, limit pitch, and preserve yaw at the poles.
    public static func facing(position:SIMD3<Float>, viewer:SIMD3<Float> = .zero,
                              previous:simd_quatf = simd_quatf())->simd_quatf {
        let direction=viewer-position
        guard direction.x.isFinite,direction.y.isFinite,direction.z.isFinite,
              simd_length_squared(direction)>0.0025 else{return previous}
        let horizontal=hypot(direction.x,direction.z)
        // Near vertical the horizontal direction is undefined: keep the previous stable attitude.
        guard horizontal>0.05 else{return previous}
        let yaw=atan2(direction.x,direction.z)
        let pitch = -min(max(atan2(direction.y,horizontal),-.pi/3),.pi/3)
        var result=simd_quatf(angle:yaw,axis:[0,1,0])*simd_quatf(angle:pitch,axis:[1,0,0])
        if simd_dot(result.vector,previous.vector)<0 {result=simd_quatf(vector:-result.vector)}
        return result
    }
}

/// Frame-rate independent, speed-limited controller turning; no position mutation.
extension VRControllerPlacement {
    public static func approaching(_ current:simd_quatf, target:simd_quatf, elapsed:Float)->simd_quatf {
        guard elapsed.isFinite,elapsed>0 else{return current}
        let dot=min(max(abs(simd_dot(current.vector,target.vector)),0),1)
        let angle=2*acos(dot)
        guard angle>0.00001 else{return target}
        let dt=min(elapsed,0.05)
        let a=current.act(SIMD3<Float>(0,0,1)),b=target.act(SIMD3<Float>(0,0,1))
        let yawDelta=atan2(sin(atan2(b.x,b.z)-atan2(a.x,a.z)),cos(atan2(b.x,b.z)-atan2(a.x,a.z)))
        let pitchDelta=atan2(b.y,hypot(b.x,b.z))-atan2(a.y,hypot(a.x,a.z))
        // Conservative arc-length bound also preserves the previous angular speed limit.
        let bound=max(angle,abs(yawDelta)+abs(pitchDelta))
        let amount=min(1-exp(-12*dt),(.pi*1.5*dt)/bound)
        return uprightInterpolation(current, target:target, fraction:amount)
    }
    /// Interpolate heading and pitch separately: quaternion slerp can introduce roll between upright endpoints.
    public static func uprightInterpolation(_ current:simd_quatf, target:simd_quatf, fraction:Float)->simd_quatf {
        guard fraction.isFinite else { return current }
        func angles(_ q:simd_quatf)->SIMD2<Float> {
            let front=q.act(SIMD3<Float>(0,0,1))
            let right=q.act(SIMD3<Float>(1,0,0))
            let yaw=hypot(front.x,front.z)>0.0001 ? atan2(front.x,front.z):atan2(-right.z,right.x)
            return SIMD2(yaw,-atan2(front.y,hypot(front.x,front.z)))
        }
        let a=angles(current),b=angles(target)
        let delta=atan2(sin(b.x-a.x),cos(b.x-a.x)),t=min(max(fraction,0),1)
        let pitch=min(max(a.y+(b.y-a.y)*t,-Float.pi/3),Float.pi/3)
        var q=simd_quatf(angle:a.x+delta*t,axis:[0,1,0])*simd_quatf(angle:pitch,axis:[1,0,0])
        if simd_dot(q.vector,current.vector)<0 {q=simd_quatf(vector:-q.vector)}
        return q
    }
    public static func grabbedPosition(pointer:SIMD3<Float>,localGrab:SIMD3<Float>,orientation:simd_quatf,previous:SIMD3<Float>? = nil)->SIMD3<Float> {
        origin+constrained(pointer-orientation.act(localGrab)-origin,previous:previous)
    }
}

/// Horizontal orbit uses entry heading; the initial world height retains the pre-Build18 placement.
public enum VRControllerReference {
    public static func pose(entry:VRInitialPose,vertical:VRInitialPose?=nil,horizontal:simd_quatf?=nil)->VRInitialPose? {
        let heading=horizontal ?? entry.orientation
        let forward=heading.act(SIMD3<Float>(0,0,-1))
        let right=heading.act(SIMD3<Float>(1,0,0))
        let yaw:Float
        if hypot(forward.x,forward.z)>0.001 {yaw=atan2(-forward.x,-forward.z)}
        else {yaw=atan2(-right.z,right.x)}
        let rotation=simd_quatf(angle:yaw,axis:[0,1,0])
        let legacy=vertical ?? entry
        let oldCenter=legacy.position+legacy.orientation.act(VRControllerPlacement.legacyHeightOrigin)
        var position=entry.position;position.y=oldCenter.y-VRControllerPlacement.origin.y
        var matrix=simd_float4x4(rotation);matrix.columns.3=SIMD4(position,1)
        return VRInitialPose(matrix:matrix)
    }
}

/// Re-express an existing controller transform without moving it in scene coordinates.
public enum VRControllerContinuity {
 public static func rebased(local:simd_float4x4,oldReference:simd_float4x4,newReference:simd_float4x4)->simd_float4x4 {
  simd_inverse(newReference) * oldReference * local
 }
}

/// Orientation math in a captured viewer frame, independent of the placement parent's axes.
/// Placement limits remain in the video-heading frame; only the panel attitude uses this frame.
public enum VRControllerViewFrame {
    public static func localFrame(viewerWorld:simd_quatf,parentWorld:simd_quatf)->simd_quatf {
        func valid(_ q:simd_quatf)->simd_quatf {
            let length=simd_length_squared(q.vector)
            return length.isFinite && length>0.000001 ? simd_normalize(q):simd_quatf(angle:0,axis:[0,1,0])
        }
        return simd_normalize(valid(parentWorld).inverse * valid(viewerWorld))
    }
    public static func facing(position:SIMD3<Float>,viewer:SIMD3<Float>,frame:simd_quatf,previous:simd_quatf)->simd_quatf {
        frame * VRControllerPlacement.facing(position:frame.inverse.act(position-viewer),
            previous:frame.inverse * previous)
    }
    public static func approaching(_ current:simd_quatf,target:simd_quatf,frame:simd_quatf,elapsed:Float)->simd_quatf {
        frame * VRControllerPlacement.approaching(frame.inverse * current,target:frame.inverse * target,elapsed:elapsed)
    }
    public static func interpolating(_ current:simd_quatf,target:simd_quatf,frame:simd_quatf,fraction:Float)->simd_quatf {
        frame * VRControllerPlacement.uprightInterpolation(frame.inverse * current,target:frame.inverse * target,fraction:fraction)
    }
}

/// Called only after SwiftUI resolves exclusive single/double taps on background entities.
public enum VRBackgroundInteraction {
    public enum Action:Equatable,Sendable {case none,toggle,reset,recenterVideo}
    public static func action(taps:Int,isBackground:Bool,active:Bool,testPattern:Bool,moving:Bool,scrubbing:Bool)->Action {
        guard isBackground,active,!testPattern,!moving,!scrubbing else{return .none}
        switch taps {case 1:return .toggle;case 2:return .reset;case 3:return .recenterVideo;default:return .none}
    }
}

/// Display only: manual offset relative to the captured video frame, never world heading.
public enum VRManualAngleDisplay {
    public static func normalized(_ degrees:Double)->Int {
        guard degrees.isFinite else{return 0}
        var n=degrees.truncatingRemainder(dividingBy:360)
        if n>180 {n-=360};if n < -180 {n+=360}
        return Int(n.rounded())
    }
    public static func text(_ degrees:Double)->String {
        let n=normalized(degrees);return n>0 ? "+\(n)°":"\(n)°"
    }
}
