import Testing
import simd
@testable import VistaCore

@Suite struct ControllerWorldFrameTests {
    private let identity=simd_quatf(angle:0,axis:[0,1,0])
    private let up=SIMD3<Float>(0,1,0)
    private func expectWorldUpright(_ q:simd_quatf) {
        #expect(abs(q.act(SIMD3<Float>(0,0,1)).y)<0.00001)
        #expect(simd_length(q.act(up)-up)<0.00001)
        #expect(abs(q.act(SIMD3<Float>(1,0,0)).y)<0.00001)
    }

    @Test func resetAndInitialFacingDoNotAimUpFromHeightDifference() {
        let old=VRControllerPlacement.facing(position:VRControllerPlacement.origin)
        #expect(old.act(SIMD3<Float>(0,0,1)).y>0.10)
        let fresh=VRControllerWorldFrame.facing(position:VRControllerPlacement.origin,viewer:.zero,frame:identity,previous:identity)
        expectWorldUpright(fresh)
        for viewerHeight:Float in [-1.7,0,1.7] {
            let reset=VRControllerWorldFrame.facing(position:VRControllerPlacement.origin,viewer:[0,viewerHeight,0],frame:identity,previous:old)
            expectWorldUpright(reset)
            #expect(abs(simd_dot(reset.vector,fresh.vector))>0.99999)
        }
    }

    @Test func sittingReclinedAndRolledHeadsDoNotChangeWorldVertical() {
        let parents=[identity,VRInitialPose.manualRotation(yaw:40,pitch:25,roll:-20),
            VRInitialPose.manualRotation(yaw:-70,pitch:35,roll:60)*VRInitialPose.manualRotation(yaw:30,pitch:-10,roll:25)]
        for parent in parents {for yaw:Double in [-175,-90,0,90,175] {for pitch:Double in [0,30,60,90] {for roll:Double in [-45,0,45] {
            let head=VRInitialPose.manualRotation(yaw:yaw,pitch:pitch,roll:roll)
            let frame=VRControllerWorldFrame.frame(parentWorld:parent)
            let viewerWorld=SIMD3<Float>(0.4,1.6,-0.2),parentOrigin=SIMD3<Float>(-1,0.4,0.3)
            let viewer=parent.inverse.act(viewerWorld-parentOrigin)
            for degrees:Float in [-175,-90,-45,0,45,90,175] {for height:Float in [-1.7,-0.83,0,0.67,1.7] {
                let a=degrees * .pi/180,relative=SIMD3<Float>(1.6*sin(a),height,-1.6*cos(a))
                let position=parent.inverse.act(viewerWorld+relative-parentOrigin)
                let local=VRControllerWorldFrame.facing(position:position,viewer:viewer,frame:frame,previous:parent.inverse * head)
                let world=parent * local
                expectWorldUpright(world)
                let direction=simd_normalize(SIMD3<Float>(-relative.x,0,-relative.z))
                #expect(simd_dot(world.act(SIMD3<Float>(0,0,1)),direction)>0.99999)
            }}
        }}}}
    }

    @Test func dragAndReleaseAreWorldUprightContinuousAndSpeedLimited() {
        let parents=[identity,VRInitialPose.manualRotation(yaw:40,pitch:25,roll:-20),
            VRInitialPose.manualRotation(yaw:-70,pitch:35,roll:60)*VRInitialPose.manualRotation(yaw:30,pitch:-10,roll:25)]
        for parent in parents {
            let frame=VRControllerWorldFrame.frame(parentWorld:parent)
            var current=frame * simd_quatf(angle:0.2,axis:up)
            for step in 0...720 {
                let t=Float(step)/720,yaw=(-175+350*t)*Float.pi/180
                let position=parent.inverse.act(SIMD3<Float>(1.6*sin(yaw),0.8*sin(t*12),-1.6*cos(yaw)))
                let target=VRControllerWorldFrame.facing(position:position,viewer:.zero,frame:frame,previous:current)
                let next=VRControllerWorldFrame.approaching(current,target:target,frame:frame,elapsed:1/60)
                expectWorldUpright(parent * next)
                let angle=2*acos(min(1,abs(simd_dot(current.vector,next.vector))))
                #expect(angle<=Float.pi*1.5/60+0.0001)
                let release=VRControllerWorldFrame.interpolating(next,target:target,frame:frame,fraction:0)
                #expect(abs(simd_dot(release.vector,next.vector))>0.99999)
                for fraction:Float in [0,0.1,0.5,0.9,1] {
                    expectWorldUpright(parent * VRControllerWorldFrame.interpolating(next,target:target,frame:frame,fraction:fraction))
                }
                current=next
            }
        }
    }

    @Test func undefinedHorizontalDirectionPreservesUprightYaw() {
        for parent in [identity,VRInitialPose.manualRotation(yaw:40,pitch:25,roll:-20)] {
            let frame=VRControllerWorldFrame.frame(parentWorld:parent)
            let previous=frame * simd_quatf(angle:0.6,axis:up)
            for world:SIMD3<Float> in [.zero,[0,2,0],[0,-2,0],[0.001,1,0.001],[.infinity,0,0],[.nan,1,0]] {
                let result=VRControllerWorldFrame.facing(position:parent.inverse.act(world),viewer:.zero,frame:frame,previous:previous)
                expectWorldUpright(parent * result)
                #expect(abs(simd_dot(previous.vector,result.vector))>0.99999)
            }
        }
        for invalid in [simd_quatf(),simd_quatf(vector:[.nan,0,0,1]),simd_quatf(vector:[.infinity,0,0,1])] {
            expectWorldUpright(VRControllerWorldFrame.frame(parentWorld:invalid))
        }
    }

    @Test func grabbedPointAndPlacementBoundsStayUnchanged() {
        for yaw:Float in [-2,-1,0,1,2] {
            let q=simd_quatf(angle:yaw,axis:up),grab=SIMD3<Float>(0.03,-0.2,0)
            let center=SIMD3<Float>(1.6*sin(yaw),0.2,-1.6*cos(yaw)),pointer=center+q.act(grab)
            let got=VRControllerPlacement.grabbedPosition(pointer:pointer,localGrab:grab,orientation:q,previous:center)
            #expect(simd_length(got-center)<0.00001)
        }
        let maximum=VRControllerPlacement.origin+VRControllerPlacement.constrained([100,100,100])
        #expect(abs(atan2(maximum.x,-maximum.z))<=VRControllerPlacement.maximumYaw+0.00001)
        #expect(maximum.y<=0.67)
        #expect(abs(VRControllerPlacement.initialYaw - .pi/4)<0.00001)
    }

    @Test func crossFileRebasePreservesWorldPoseAndUprightness() {
        var previous=simd_float4x4(identity);previous.columns.3=[0,1.6,0,1]
        var local=simd_float4x4(simd_quatf(angle:0.6,axis:up));local.columns.3=[-1.2,0.4,0.2,1]
        let original=previous*local
        for yaw:Float in [1,-1.5,0,2] {
            var next=simd_float4x4(simd_quatf(angle:yaw,axis:up));next.columns.3=[0.2,1.4,0.1,1]
            local=VRControllerContinuity.rebased(local:local,oldReference:previous,newReference:next)
            let world=next*local
            for column in 0..<4 {#expect(simd_length(world[column]-original[column])<0.0001)}
            expectWorldUpright(simd_quatf(world))
            previous=next
        }
    }

    @Test func worldVerticalExplicitlyDiffersFromViewerHorizontalAtSides() {
        let head=VRInitialPose.manualRotation(yaw:0,pitch:35,roll:0)
        let q=VRControllerWorldFrame.facing(position:[1.6,0,0],viewer:.zero,frame:identity,previous:identity)
        expectWorldUpright(q)
        // The new world-vertical requirement cannot also promise screen-horizontal edges here.
        #expect(abs(head.inverse.act(q.act(SIMD3<Float>(1,0,0))).y)>0.5)
    }
}
