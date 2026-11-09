import Testing
import Foundation
import simd
@testable import VistaCore

@Suite struct ManualAngleRulerTests {
    @Test func secondPointerCannotAcquireOrReleaseFirstPointerProtection() {
        var ownership=VRManualAngleDragOwnership()
        let first=UUID(),second=UUID()
        #expect(ownership.acquire(first)==true)
        #expect(ownership.acquire(second)==false)
        #expect(ownership.release(second)==false)
        #expect(ownership.owner==first)
        #expect(ownership.release(first)==true)
        #expect(ownership.acquire(second)==true)
        #expect(ownership.release(first)==false)
        #expect(ownership.owner==second)
        #expect(ownership.release(second)==true);#expect(ownership.owner==nil)
    }
    @Test func fifteenDegreeSnappingAndBothSigns() {
        for vertical in [false,true] {
            let step=vertical ? 30.0:60.0,sign=vertical ? -1.0:1.0
            for start in [-720.0,-180,0,15,180,720] {
                #expect(VRManualAngleDrag.value(start:start,translation:step*0.499,vertical:vertical)==start)
                #expect(VRManualAngleDrag.value(start:start,translation:step*0.5,vertical:vertical)==start+15*sign)
                #expect(VRManualAngleDrag.value(start:start,translation:-step*0.5,vertical:vertical)==start-15*sign)
                #expect(VRManualAngleDrag.value(start:start,translation:step*4,vertical:vertical)==start+60*sign)
            }
        }
        #expect(VRManualAngleDrag.value(start:15,translation:.nan,vertical:false)==15)
        #expect(VRManualAngleDrag.value(start:15,translation:.infinity,vertical:false)==15)
        #expect(VRManualAngleDrag.value(start:.nan,translation:0,vertical:false)==0)
        #expect(VRManualAngleDrag.value(start:Double.greatestFiniteMagnitude,translation:Double.greatestFiniteMagnitude,vertical:true).isFinite)
    }
    @Test func crossingDisplayEndsDoesNotClampManualRotation() {
        let value=VRManualAngleDrag.value(start:180,translation:60,vertical:false)
        #expect(value==195);#expect(VRManualAngleDisplay.text(value)=="-165°")
        #expect(VRManualAngleDrag.value(start:-360,translation:-120,vertical:false)==(-390))
    }
    @Test func cancelRestoresOnlyOwnedAxisAndRepeatedDragStartsFresh() {
        var drag=VRManualAngleDragTransaction(manual:15,context:1)
        #expect(drag.update(translation:60,vertical:false,manual:15,context:1,enabled:true)==30)
        #expect(drag.update(translation:120,vertical:false,manual:30,context:1,enabled:true)==45)
        #expect(drag.restoredValue(manual:45,context:1)==15)
        drag = .init(manual:15,context:1)
        #expect(drag.update(translation:-60,vertical:false,manual:15,context:1,enabled:true)==0)
    }
    @Test func newFileNeverReceivesOldDragOrOldRollbackEvenIfManualMatches() {
        var drag=VRManualAngleDragTransaction(manual:0,context:1)
        #expect(drag.update(translation:60,vertical:false,manual:0,context:1,enabled:true)==15)
        #expect(drag.update(translation:120,vertical:false,manual:15,context:2,enabled:true)==nil)
        #expect(drag.restoredValue(manual:15,context:2)==nil)
        #expect(drag.update(translation:180,vertical:false,manual:15,context:1,enabled:true)==nil)
    }
    @Test func newerButtonEditWinsAndDisabledDragCanRollBack() {
        var drag=VRManualAngleDragTransaction(manual:0,context:1)
        #expect(drag.update(translation:60,vertical:false,manual:0,context:1,enabled:true)==15)
        #expect(drag.update(translation:120,vertical:false,manual:30,context:1,enabled:true)==nil)
        #expect(drag.restoredValue(manual:30,context:1)==nil)
        drag = .init(manual:0,context:1)
        #expect(drag.update(translation:60,vertical:false,manual:0,context:1,enabled:true)==15)
        #expect(drag.update(translation:120,vertical:false,manual:15,context:1,enabled:false)==nil)
        #expect(drag.restoredValue(manual:15,context:1)==0)
        drag.invalidate()
        #expect(drag.update(translation:180,vertical:false,manual:0,context:1,enabled:true)==nil)
    }
    @Test @MainActor func automaticPitchStaysSeparateAndResetInvalidates() async {
        let calibration=VRViewCalibration()
        _ = await calibration.capture(using:AnglePose())
        #expect(calibration.automaticPitchDegrees==15)
        var settings=VRSettings();settings.yawDegrees=30;settings.rollDegrees=45
        let generation=calibration.directionGeneration
        var drag=VRManualAngleDragTransaction(manual:settings.pitchDegrees,context:generation)
        settings.pitchDegrees=drag.update(translation:-30,vertical:true,manual:settings.pitchDegrees,context:generation,enabled:true)!
        #expect(settings.pitchDegrees==15)
        #expect(calibration.videoSettings(for:settings).pitchDegrees==30)
        #expect(settings.yawDegrees==30);#expect(settings.rollDegrees==45)
        settings.pitchDegrees=drag.restoredValue(manual:settings.pitchDegrees,context:generation)!
        #expect(calibration.videoSettings(for:settings).pitchDegrees==15)
        calibration.resetDirection(&settings)
        #expect(calibration.directionGeneration != generation)
        #expect(drag.restoredValue(manual:0,context:calibration.directionGeneration)==nil)
        let reset=calibration.directionGeneration;calibration.resetForNewFile()
        #expect(calibration.directionGeneration != reset)
    }
}
private struct AnglePose:VRInitialPoseProvider {
    func sample() async throws->VRInitialPose? {
        var matrix=matrix_identity_float4x4
        let rotation=simd_float4x4(VRInitialPose.manualRotation(yaw:0,pitch:45,roll:0))
        matrix=rotation
        return VRInitialPose(matrix:matrix)
    }
}
