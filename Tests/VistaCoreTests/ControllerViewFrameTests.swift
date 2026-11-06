import Testing
import simd
@testable import VistaCore

@Suite struct ControllerViewFrameTests {
    @Test func gravityLevelIsNotViewerLevelAtSides() {
        let head=VRInitialPose.manualRotation(yaw:0,pitch:35,roll:0)
        let front=VRControllerPlacement.facing(position:[0,-0.18,-1.6])
        let side=VRControllerPlacement.facing(position:[1.6,-0.18,0])
        #expect(abs(head.inverse.act(front.act([1,0,0])).y)<0.0001)
        #expect(abs(head.inverse.act(side.act([1,0,0])).y)>0.5)
    }
    @Test func sideHeightAndNestedParentsUseViewerUp() {
        let heads=[VRInitialPose.manualRotation(yaw:0,pitch:0,roll:0),
                   VRInitialPose.manualRotation(yaw:25,pitch:35,roll:12),
                   VRInitialPose.manualRotation(yaw:-70,pitch:75,roll:-20)]
        let parents=[simd_quatf(angle:0,axis:[0,1,0]),VRInitialPose.manualRotation(yaw:60,pitch:20,roll:-30),
            VRInitialPose.manualRotation(yaw:-40,pitch:25,roll:15)*VRInitialPose.manualRotation(yaw:80,pitch:-30,roll:45)]
        for head in heads {for parent in parents {
            let frame=VRControllerViewFrame.localFrame(viewerWorld:head,parentWorld:parent)
            for degrees:Float in [-175,-90,-45,0,45,90,175] {for height:Float in [-0.7,0,0.7] {
                let a=degrees * .pi/180
                let viewPosition=SIMD3<Float>(1.6*sin(a),height,-1.6*cos(a))
                let viewerWorld=SIMD3<Float>(0.3,1.6,-0.2),parentOrigin=SIMD3<Float>(-1,0.2,0.5)
                let viewer=parent.inverse.act(viewerWorld-parentOrigin)
                let position=parent.inverse.act(viewerWorld+head.act(viewPosition)-parentOrigin)
                let q=VRControllerViewFrame.facing(position:position,viewer:viewer,frame:frame,previous:frame)
                let inView=head.inverse * parent * q
                #expect(abs(inView.act([1,0,0]).y)<0.0001)
                #expect(inView.act([0,1,0]).y>0)
                #expect(simd_dot(inView.act([0,0,1]),simd_normalize(-viewPosition))>0.9999)
            }}
        }}
    }
    @Test func interpolationAndDragKeepHorizontalThroughBothRearLimits() {
        let parent=VRInitialPose.manualRotation(yaw:45,pitch:20,roll:-30)
        let head=VRInitialPose.manualRotation(yaw:-20,pitch:40,roll:10)
        let frame=VRControllerViewFrame.localFrame(viewerWorld:head,parentWorld:parent)
        var current=frame
        for x:Float in [-175,-90,45,90,175] {
            let a=x * .pi/180
            let position=frame.act([1.6*sin(a),0.5,-1.6*cos(a)])
            let target=VRControllerViewFrame.facing(position:position,viewer:.zero,frame:frame,previous:current)
            let start=current
            for step in 0...100 {
                let release=VRControllerViewFrame.interpolating(start,target:target,frame:frame,fraction:Float(step)/100)
                #expect(abs((head.inverse * parent * release).act([1,0,0]).y)<0.0001)
                current=VRControllerViewFrame.approaching(current,target:target,frame:frame,elapsed:0.016)
                #expect(abs((head.inverse * parent * current).act([1,0,0]).y)<0.0001)
            }
            #expect(abs(simd_dot(current.vector,target.vector))>0.999)
        }
    }
    @Test func poleKeepsPreviousAndPlacementLimitsRemainIndependent() {
        let frame=VRInitialPose.manualRotation(yaw:40,pitch:45,roll:20)
        let previous=frame * simd_quatf(angle:0.4,axis:[0,1,0])
        let result=VRControllerViewFrame.facing(position:frame.act([0,2,0]),viewer:.zero,frame:frame,previous:previous)
        #expect(abs(simd_dot(previous.vector,result.vector))>0.99999)
        let limit=VRControllerPlacement.origin+VRControllerPlacement.constrained([100,100,100])
        #expect(limit.y<=0.67)
        #expect(abs(atan2(limit.x,-limit.z))<=VRControllerPlacement.maximumYaw+0.00001)
        #expect(abs(VRControllerPlacement.initialYaw - .pi/4)<0.00001)
    }
    @Test func movingViewerAndControlRemainLevelWithNoReleaseFrameChange() {
        let parent=VRInitialPose.manualRotation(yaw:42,pitch:24,roll:-17)
        var current=simd_quatf(angle:0,axis:[0,1,0])
        for step in 0...720 {
            let t=Float(step)/720
            let head=VRInitialPose.manualRotation(yaw:Double(120*sin(t*6)),pitch:Double(25+20*sin(t*9)),roll:Double(10*sin(t*5)))
            let frame=VRControllerViewFrame.localFrame(viewerWorld:head,parentWorld:parent)
            let yaw=(-175+350*t)*Float.pi/180
            let position=frame.act([1.6*sin(yaw),0.6*sin(t*12),-1.6*cos(yaw)])
            let target=VRControllerViewFrame.facing(position:position,viewer:.zero,frame:frame,previous:current)
            current=VRControllerViewFrame.approaching(current,target:target,frame:frame,elapsed:0.016)
            #expect(abs((frame.inverse*current).act([1,0,0]).y)<0.0001)
            #expect((frame.inverse*current).act([0,1,0]).y>0)
            let release=VRControllerViewFrame.interpolating(current,target:target,frame:frame,fraction:0)
            #expect(abs(simd_dot(current.vector,release.vector))>0.99999)
        }
    }

}

struct BackgroundInteractionTests {
    @Test func exclusiveResolvedEventsAndBlockedInteractions() {
        for taps in [0,1,2,3,4] {
            for active in [false,true] {for background in [false,true] {for moving in [false,true] {for scrubbing in [false,true] {for pattern in [false,true] {
                let action=VRBackgroundInteraction.action(taps:taps,isBackground:background,active:active,testPattern:pattern,moving:moving,scrubbing:scrubbing)
                if !active || !background || moving || scrubbing || pattern || taps == 0 || taps == 4 {#expect(action == .none)}
                else {#expect(action == (taps == 3 ? .recenterVideo : (taps == 2 ? .reset:.toggle)))}
            }}}}}
        }
    }
}

struct ManualAngleDisplayTests {
    @Test func wrappingAndDirections() {
        for (a,b) in [(0.0,0),(15,15),(-15,-15),(360,0),(-360,0),(375,15),(-375,-15),(195,-165),(-195,165),(720,0)] {
            #expect(VRManualAngleDisplay.normalized(a)==b)
        }
        #expect(VRManualAngleDisplay.text(15)=="+15°")
        #expect(VRManualAngleDisplay.text(-15)=="-15°")
        #expect(VRManualAngleDisplay.text(.nan)=="0°")
    }
}
