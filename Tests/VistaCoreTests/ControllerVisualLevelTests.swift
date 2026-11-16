import Testing
import simd
@testable import VistaCore

struct ControllerWorldUpTests {
 @Test func pitchRollAreRemovedEvenBelowHeadingDeadband() {
  for degrees:Float in [0.00001,0.01,20,90] {
   let parent=VRInitialPose.manualRotation(yaw:45,pitch:20,roll:35)
   let frame=VRControllerWorldFrame.frame(parentWorld:parent)
   let start=frame*simd_quatf(angle:degrees * .pi/180,axis:[0,0,1])
   let result=parent*VRControllerWorldFrame.approaching(start,target:frame,frame:frame,elapsed:0)
   #expect(simd_distance(result.act([0,1,0]),[0,1,0])<0.00001)
  }
 }
 @Test func worldDefaultScalesEntireVectorAboutCalibratedViewer()throws {
  var a=matrix_identity_float4x4;a.columns.3=[0,0,0,1]
  var b=simd_float4x4(VRInitialPose.manualRotation(yaw:20,pitch:15,roll:10));b.columns.3=[0.1,1.6,-0.2,1]
  let entry=try #require(VRInitialPose(matrix:a)),viewer=try #require(VRInitialPose(matrix:b))
  let p=try #require(VRControllerReference.placement(entry:entry,vertical:viewer))
  let world=p.reference.position+p.reference.orientation.act(VRControllerPlacement.origin)
  #expect(simd_distance(world,viewer.position+(p.originalTarget-viewer.position)*(2/3))<0.000001)
 }
}
