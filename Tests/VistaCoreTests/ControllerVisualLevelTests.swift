import Testing
import simd
@testable import VistaCore

@Suite struct ControllerVisualLevelTests {
    private let identity=simd_quatf(angle:0,axis:[0,1,0]),front=SIMD3<Float>(0,0,1)
    private func rotation(_ yaw:Float,_ pitch:Float,_ roll:Float)->simd_quatf {
        simd_quatf(angle:yaw * .pi/180,axis:[0,1,0])*simd_quatf(angle:pitch * .pi/180,axis:[1,0,0])*simd_quatf(angle:roll * .pi/180,axis:[0,0,1])
    }
    private func expectLevel(_ world:simd_quatf,relative:SIMD3<Float>,head:simd_quatf) {
        let c=head.inverse.act(relative),r=head.inverse.act(world.act(SIMD3<Float>(1,0,0)))
        #expect(abs((-c.z)*r.y+c.y*r.z)<0.00001)
        #expect((-c.z)*r.x+c.x*r.z>0)
    }
    private func distance(_ a:simd_quatf,_ b:simd_quatf)->Float {
        2*acos(min(1,abs(simd_dot(simd_normalize(a).vector,simd_normalize(b).vector))))
    }
    @Test func sittingThroughReclinedTargetsFaceViewerInThreeDimensionsAndStayLevel() {
        // Artificial poses only. Neither the head nor the projection frame identifies a filmed-room floor.
        for pitch:Double in [0,60,85,90,100] {for roll:Double in [-20,0,20] {
            let head=VRInitialPose.manualRotation(yaw:25,pitch:pitch,roll:roll)
            for cameraCenter:SIMD3<Float> in [[-1,0,-1.6],[0,0,-1.6],[1,0.4,-1.6]] {
                let relative=head.act(cameraCenter)
                for parent in [identity,VRInitialPose.manualRotation(yaw:40,pitch:20,roll:-15)] {
                    let frame=VRControllerWorldFrame.frame(parentWorld:parent),viewer=SIMD3<Float>(0.2,1.4,-0.1)
                    let position=viewer+parent.inverse.act(relative)
                    let q=VRControllerVisualLevel.facing(position:position,viewer:viewer,frame:frame,viewingHead:head,previous:identity)
                    #expect(simd_length((parent*q).act(front)+simd_normalize(relative))<0.00001)
                    expectLevel(parent*q,relative:relative,head:head)
                    #expect(simd_length(position-viewer-parent.inverse.act(relative))<0.00001)
                }
            }
        }}
        // Synthetic demonstration of discarded height, not a replay of the user's 75-degree estimate.
        let head=VRInitialPose.manualRotation(yaw:0,pitch:75,roll:0),center=head.act(SIMD3<Float>(0,0,-1.6))
        let old=VRControllerWorldFrame.facing(position:center,viewer:.zero,frame:identity,previous:identity)
        let new=VRControllerVisualLevel.facing(position:center,viewer:.zero,frame:identity,viewingHead:head,previous:old)
        #expect(abs(distance(old,new)*180 / .pi-75)<0.001)
        #expect(abs(new.act(front).y)>0.9)
    }
    @Test func unavailableViewTransportsPreviousAttitudeWithoutDiscardingHeight() {
        let previous=rotation(20,-30,35),position=SIMD3<Float>(1.1,1.2,-1.1),normal = -simd_normalize(position)
        let expected=simd_quatf(from:previous.act(front),to:normal)*previous
        let invalid=[nil,simd_quatf(vector:[.nan,0,0,1]),VRInitialPose.manualRotation(yaw:180,pitch:0,roll:0)] as [simd_quatf?]
        for head in invalid {
            let q=VRControllerVisualLevel.facing(position:position,viewer:.zero,frame:identity,viewingHead:head,previous:previous)
            #expect(abs(simd_dot(q.vector,expected.vector))>0.99999)
            #expect(simd_length(q.act(front)-normal)<0.00001)
        }
        let coincident=VRControllerVisualLevel.facing(position:.zero,viewer:.zero,frame:identity,viewingHead:nil,previous:previous)
        #expect(abs(simd_dot(coincident.vector,previous.vector))>0.99999)
    }
    @Test func fixedProjectionFrameKeepsDragAndReleaseLevelWithoutErasingPitch() {
        let head=VRInitialPose.manualRotation(yaw:20,pitch:85,roll:10)
        let parent=VRInitialPose.manualRotation(yaw:40,pitch:20,roll:-15),worldFrame=VRControllerWorldFrame.frame(parentWorld:parent)
        let relative=head.act(SIMD3<Float>(0,0,-1.6)),position=parent.inverse.act(relative)
        let frame=VRControllerVisualLevel.levelingFrame(position:position,viewer:.zero,frame:worldFrame,viewingHead:head)
        let start=frame*rotation(60,45,0),target=frame
        for fraction:Float in [0,0.1,0.25,0.5,0.75,0.9,1] {
            let q=VRControllerVisualLevel.interpolating(start,target:target,frame:frame,fraction:fraction)
            expectLevel(parent*q,relative:relative,head:head)
            if fraction==0 {#expect(abs(simd_dot(q.vector,start.vector))>0.99999)}
            if fraction==1 {#expect(abs(simd_dot(q.vector,target.vector))>0.99999)}
        }
        var current=start
        for _ in 0..<120 {
            let next=VRControllerVisualLevel.approaching(current,target:target,frame:frame,elapsed:1/60)
            #expect(distance(current,next)<=Float.pi*1.5/60+0.0001)
            expectLevel(parent*next,relative:relative,head:head);current=next
        }
        #expect(abs(simd_dot(current.vector,target.vector))>0.99999)
        #expect(abs((parent*current).act(front).y)>0.9)
        // Numerical local Euler pole, not a special body posture.
        let edge=frame*rotation(0,90,0),step=VRControllerVisualLevel.approaching(edge,target:target,frame:frame,elapsed:1/60)
        #expect(step.vector.x.isFinite && step.vector.y.isFinite && step.vector.z.isFinite && step.vector.w.isFinite)
        #expect(distance(edge,step)<=Float.pi*1.5/60+0.0001)
    }
    @Test func leftToCenterToRightTargetsStayLevelAndMovingSamplesStaySpeedLimited() {
        for pitch:Double in [0,85,90] {
            let head=VRInitialPose.manualRotation(yaw:0,pitch:pitch,roll:0),height:Float=pitch==0 ? -0.18:1.5
            var current=identity
            for degrees in stride(from:-80,through:80,by:2) {
                let a=Float(degrees)*Float.pi/180,position=SIMD3<Float>(1.635*sin(a),height,-1.635*cos(a))
                let target=VRControllerVisualLevel.facing(position:position,viewer:.zero,frame:identity,viewingHead:head,previous:current)
                #expect(simd_length(target.act(front)+simd_normalize(position))<0.00001)
                expectLevel(target,relative:position,head:head)
                let frame=VRControllerVisualLevel.levelingFrame(position:position,viewer:.zero,frame:identity,viewingHead:head)
                let next=VRControllerVisualLevel.approaching(current,target:target,frame:frame,elapsed:1/60)
                #expect(distance(current,next)<=Float.pi*1.5/60+0.0001);current=next
            }
        }
        // Changing samples may leave residual roll temporarily; preserve it and take the shortest path.
        let start=rotation(179,20,179),target=rotation(-179,25,-179)
        let mid=VRControllerVisualLevel.interpolating(start,target:target,frame:identity,fraction:0.5)
        #expect(abs(simd_dot(mid.vector,rotation(180,22.5,180).vector))>0.99999)
    }
    @Test func originalGrabAndCrossFileContinuitySupportFullFacing() {
        let center=VRControllerPlacement.origin,grab=SIMD3<Float>(0.03,-0.2,0)
        let q=VRControllerVisualLevel.facing(position:center,viewer:.zero,frame:identity,viewingHead:identity,previous:identity)
        let pointer=center+q.act(grab),result=VRControllerPlacement.grabbedPosition(pointer:pointer,localGrab:grab,orientation:q,previous:center)
        #expect(simd_length(result-center)<0.00001)
        var local=simd_float4x4(q);local.columns.3=SIMD4(center,1)
        let old=simd_float4x4(rotation(10,0,0)),new=simd_float4x4(rotation(50,0,0))
        let rebased=VRControllerContinuity.rebased(local:local,oldReference:old,newReference:new)
        for i in 0..<4 {#expect(simd_length((new*rebased)[i]-(old*local)[i])<0.00001)}
        #expect(abs(VRControllerPlacement.initialYaw - .pi/4)<0.00001)
    }
    @Test func staleOrCancelledResetCannotCommitOrClearNewRequest() {
        var gate=VRControllerResetRequest();let old=gate.begin(),new=gate.begin(),staleFinished=gate.finish(old)
        #expect(!staleFinished);#expect(gate.isCurrent(new));gate.cancel()
        let cancelledFinished=gate.finish(new);#expect(!cancelledFinished)
        let valid=gate.begin(),finished=gate.finish(valid);#expect(finished);#expect(!gate.isCurrent(valid))
        let duplicateFinished=gate.finish(valid);#expect(!duplicateFinished)
    }
}
