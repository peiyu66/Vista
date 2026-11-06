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

struct VRControllerPlacementTests {
    @Test func displacementIsBoundedAndDoesNotFollowTheHead() {
        let origin = VRControllerPlacement.origin
        #expect(simd_length(VRControllerPlacement.constrained(.zero))<0.000001)
        let extreme=origin+VRControllerPlacement.constrained([100,-100,100])
        #expect(abs(hypot(extreme.x,extreme.z)-2.2)<0.00001)
        #expect(abs(extreme.y+0.83)<0.00001)
        #expect(VRControllerPlacement.constrained([-.infinity, 0, 0]) == .zero)
        // A small unconstrained drag retains its displacement at the new front-right origin.
        let delta=SIMD3<Float>(-0.1,0.2,0.1)
        let moved = origin + VRControllerPlacement.constrained(delta)
        #expect(simd_distance(moved,origin+delta)<0.001)
        #expect(moved.z<0 && moved.x>0)
        #expect(abs(hypot(origin.x,origin.z)-hypot(Float(0.65),Float(1.5)))<0.001)
    }
}

struct VRControllerFacingTests {
    @Test func facesBothSidesWithoutRollingAndSurvivesVerticalDegeneracy() {
        for position:SIMD3<Float> in [[1.5,-0.2,-1],[-1.5,0.4,-1],[0,-0.18,-1.5]] {
            let q=VRControllerPlacement.facing(position:position)
            #expect(simd_dot(q.act([0,0,1]),simd_normalize(-position))>0.9999)
            #expect(abs(q.act([1,0,0]).y)<0.00001)
            #expect(q.act([0,1,0]).y>0)
        }
        let previous=VRControllerPlacement.facing(position:[1,0,-1])
        for position:SIMD3<Float> in [[0,5,0],[0,-5,0],[0,0,0],[.nan,0,-1]] {
            #expect(VRControllerPlacement.facing(position:position,previous:previous).vector==previous.vector)
        }
        let high=VRControllerPlacement.facing(position:[0,10,-0.1])
        #expect(high.act([0,1,0]).y>=0.4999)
    }
    @Test func yawCrossingUsesShortestQuaternionArc() {
        let a=VRControllerPlacement.facing(position:[0.001,0,1])
        let b=VRControllerPlacement.facing(position:[-0.001,0,1],previous:a)
        #expect(simd_dot(a.vector,b.vector)>0.999)
        #expect(simd_slerp(a,b,0.5).act([0,0,1]).z < -0.999)
    }
    @Test func capsuleHasRoundEndsAndNoDepth() {
        let points=VRControllerHandle.outline
        #expect(points.count==34 && points.allSatisfy {$0.z==0})
        #expect(abs(points.map(\.x).max()!-VRControllerHandle.width/2)<0.000001)
        #expect(abs(points.map(\.y).max()!-VRControllerHandle.height/2)<0.000001)
        for i in points.indices {
            #expect(simd_cross(points[i],points[(i+1)%points.count]).z>0)
        }
    }
}

struct VRControllerLiveFacingTests {
    @Test func turnIsBoundedAndConvergesAcrossSides() {
        var q=VRControllerPlacement.facing(position:[-1,0,-1])
        let target=VRControllerPlacement.facing(position:[1,0,-1],previous:q)
        for _ in 0..<120 {
            let next=VRControllerPlacement.approaching(q,target:target,elapsed:1/60)
            let step=2*acos(min(1,abs(simd_dot(q.vector,next.vector))))
            #expect(step <= .pi*1.5/60+0.001)
            #expect(next.vector.x.isFinite && next.act([0,1,0]).y>0)
            q=next
        }
        #expect(abs(simd_dot(q.vector,target.vector))>0.99999)
        #expect(VRControllerPlacement.approaching(q,target:target,elapsed:.nan).vector==q.vector)
    }
    @Test func grabbedPointStaysUnderPointerWhileTurning() {
        let pointer=SIMD3<Float>(0.5,-0.4,-1.5),grab=SIMD3<Float>(0,-0.2,0)
        for yaw:Float in [-0.7,0,0.7] {
            let q=simd_quatf(angle:yaw,axis:[0,1,0])*simd_quatf(angle:0.2,axis:[1,0,0])
            let position=VRControllerPlacement.grabbedPosition(pointer:pointer,localGrab:grab,orientation:q)
            #expect(simd_length(position+q.act(grab)-pointer)<0.00001)
        }
    }
    @Test func longFrameAndPoleDoNotFlip() {
        let q=VRControllerPlacement.facing(position:[0.001,0,1])
        let target=VRControllerPlacement.facing(position:[-0.001,0,1],previous:q)
        let next=VRControllerPlacement.approaching(q,target:target,elapsed:10)
        #expect(simd_dot(q.vector,next.vector)>0.999)
        let pole=VRControllerPlacement.facing(position:[0,5,0],previous:next)
        #expect(pole.vector==next.vector)
        let constrained=VRControllerPlacement.grabbedPosition(pointer:[100,100,100],localGrab:.zero,orientation:q)
        #expect(constrained==VRControllerPlacement.origin+VRControllerPlacement.constrained([100,100,100]-VRControllerPlacement.origin))
    }
}

struct VRControllerWideArcTests {
 @Test func bothRearEdgesClampWithoutWrappingAndRemainFacingViewer() {
  for sign:Float in [-1,1] {
   var previous=VRControllerPlacement.origin
   var facing=VRControllerPlacement.facing(position:previous)
   for degree in 0...190 {
    let a=Float(degree)*sign * .pi/180
    let wanted=SIMD3<Float>(1.6*sin(a),-0.18,-1.6*cos(a))
    let next=VRControllerPlacement.origin+VRControllerPlacement.constrained(wanted-VRControllerPlacement.origin,previous:previous)
    let yaw=atan2(next.x,-next.z)*180 / .pi
    #expect(abs(yaw)<=175.001)
    if degree>=175 {#expect(abs(yaw-175*sign)<0.001)}
    if degree>0 {#expect(simd_distance(previous,next)<0.03)}
    let target=VRControllerPlacement.facing(position:next,previous:facing)
    for _ in 0..<60 {facing=VRControllerPlacement.approaching(facing,target:target,elapsed:1/60)}
    #expect(simd_dot(facing.act([0,0,1]),simd_normalize(-next))>0.999)
    #expect(facing.act([0,1,0]).y>0)
    previous=next
   }
  }
 }
 @Test func recenteredCoordinatesAndNearOriginRemainFinite() {
  let origin=VRControllerPlacement.origin
  let centered=origin+VRControllerPlacement.constrained(.zero)
  #expect(simd_distance(centered,origin)<0.000001)
  let near=origin+VRControllerPlacement.constrained(-origin,previous:[1,0,1])
  #expect(abs(hypot(near.x,near.z)-1)<0.00001)
  #expect(abs(atan2(near.x,-near.z)-3 * .pi/4)<0.00001)
 }
}

struct ControllerFrontReferenceTests {
 @Test func entryFrontNotRightDefaultDefinesZeroForSeatedAndLying() {
  for yaw:Float in [-1,0,1] {for pitch:Float in [0,.pi/2] {for roll:Float in [0,.pi/2] {
   let reference=simd_quatf(angle:yaw,axis:[0,1,0])*simd_quatf(angle:pitch,axis:[1,0,0])*simd_quatf(angle:roll,axis:[0,0,1])
   let worldOrigin=SIMD3<Float>(1,1.5,2)
   for degrees:Float in [-175,0,175] {
    let a=degrees * .pi/180,local=SIMD3<Float>(1.5*sin(a),0,-1.5*cos(a))
    let world=worldOrigin+reference.act(local)
    let back=reference.inverse.act(world-worldOrigin)
    let constrained=VRControllerPlacement.origin+VRControllerPlacement.constrained(back-VRControllerPlacement.origin)
    #expect(abs(atan2(constrained.x,-constrained.z)*180 / .pi-degrees)<0.001)
   }
   let defaultYaw=atan2(VRControllerPlacement.origin.x,-VRControllerPlacement.origin.z)*180 / .pi
   #expect(abs(defaultYaw-45)<0.001)
  }}}
 }
}
struct ControllerHeightIsolationTests {
 @Test func legacyHeightAndHorizontalOrbitAreIndependent()throws {
  for yaw:Double in [-120,0,80] {for pitch:Double in [-45,0,70,90] {for roll:Double in [-90,0,90] {
   let q=VRInitialPose.manualRotation(yaw:yaw,pitch:pitch,roll:roll)
   var m=simd_float4x4(q);m.columns.3=SIMD4<Float>(0.1,1.6,-0.2,1)
   let entry=try #require(VRInitialPose(matrix:m)),ref=try #require(VRControllerReference.pose(entry:entry))
   let old=entry.position+entry.orientation.act(VRControllerPlacement.legacyHeightOrigin)
   let restored=ref.position+ref.orientation.act(VRControllerPlacement.origin)
   #expect(abs(old.y-restored.y)<0.0001)
   for angle:Float in [-175,0,175] {
    let r=angle * .pi/180;let point=SIMD3<Float>(1.6*sin(r),VRControllerPlacement.origin.y,-1.6*cos(r))
    let world=ref.position+ref.orientation.act(point)
    #expect(abs(world.y-restored.y)<0.0001)
    let local=ref.orientation.inverse.act(world-ref.position)
    #expect(abs(atan2(local.x,-local.z)-r)<0.0001)
   }
  }}}
 }
}

struct VideoFrontControllerTests {
 @Test func filmHeadingOverridesEntryGazeWithoutChangingHeight() throws {
  for gaze:Float in [-1,0,1] {
   var matrix=simd_float4x4(simd_quatf(angle:gaze,axis:[0,1,0]));matrix.columns.3=[0,1.6,0,1]
   let entry=try #require(VRInitialPose(matrix:matrix))
   for film:Float in [-2,0,2] {
    let rotation=simd_quatf(angle:film,axis:[0,1,0])
    let pose=try #require(VRControllerReference.pose(entry:entry,horizontal:rotation))
    let forward=pose.orientation.act(SIMD3<Float>(0,0,-1))
    #expect(simd_length(forward-rotation.act([0,0,-1]))<0.001)
    let oldY=(entry.position+entry.orientation.act(VRControllerPlacement.legacyHeightOrigin)).y
    for angle:Float in [-175,0,175] {
     let rad=angle * .pi/180,point=SIMD3<Float>(1.5*sin(rad),VRControllerPlacement.origin.y,-1.5*cos(rad))
     let offset=VRControllerPlacement.constrained(point-VRControllerPlacement.origin)
     let world=pose.position+pose.orientation.act(VRControllerPlacement.origin+offset)
     #expect(abs(world.y-oldY)<0.001)
     let local=rotation.inverse.act(world-pose.position)
     #expect(abs(atan2(local.x,-local.z)-rad)<0.001)
    }
   }
  }
 }
}

struct ControllerContinuityTests {
 @Test func nextPreviousAndRecenterPreserveWorldTransform() {
  let local=simd_float4x4(simd_quatf(angle:0.3,axis:[0,1,0]))
  var moved=local;moved.columns.3=[-1.2,0.4,0.2,1]
  var previous=matrix_identity_float4x4;previous.columns.3=[0,1.6,0,1]
  let original=previous*moved
  for angle:Float in [1,-1.5,0,2] {
   var next=simd_float4x4(simd_quatf(angle:angle,axis:[0,1,0]));next.columns.3=[0.2,1.4,0.1,1]
   moved=VRControllerContinuity.rebased(local:moved,oldReference:previous,newReference:next)
   let world=next*moved
   for column in 0..<4 {#expect(simd_length(world[column]-original[column])<0.0001)}
   previous=next
  }
 }
}

#if canImport(simd)
@Suite struct ControllerUprightTests {
 @Test func interpolationKeepsHandleHorizontalDuringCombinedYawPitch() {
  let start=VRControllerPlacement.facing(position:[-1,-0.8,-1])
  let target=VRControllerPlacement.facing(position:[1,0.6,1])
  // Prove the old interpolation can visibly tilt despite upright endpoints.
  #expect(abs(simd_slerp(start,target,0.5).act(SIMD3<Float>(1,0,0)).y)>0.01)
  for i in 0...100 {
   let q=VRControllerPlacement.uprightInterpolation(start,target:target,fraction:Float(i)/100)
   #expect(abs(q.act(SIMD3<Float>(1,0,0)).y)<0.00001)
   #expect(q.act(SIMD3<Float>(0,1,0)).y>0)
  }
 }
 @Test func dragAndReleaseAcrossBothLimitsRemainUpright() {
  var q=VRControllerPlacement.facing(position:VRControllerPlacement.origin)
  for degrees:Float in [-175,-120,-45,0,45,120,175] {
   for height:Float in [-0.83,0.67] {
    let yaw=degrees*Float.pi/180,position=SIMD3<Float>(1.5*sin(yaw),height,-1.5*cos(yaw))
    let target=VRControllerPlacement.facing(position:position,previous:q)
    for _ in 0..<180 {
     let next=VRControllerPlacement.approaching(q,target:target,elapsed:1/60)
     #expect(abs(next.act(SIMD3<Float>(1,0,0)).y)<0.00001)
     #expect(next.act(SIMD3<Float>(0,1,0)).y>0)
     q=next
    }
    #expect(simd_dot(q.act(SIMD3<Float>(0,0,1)),simd_normalize(-position))>0.999)
   }
  }
 }
}
#endif
