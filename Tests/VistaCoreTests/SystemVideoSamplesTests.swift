import Foundation
import Testing
import AVFoundation
import CoreVideo
import CoreImage
import RealityKit
@testable import VistaCore
@testable import VistaMedia

private actor SystemFixture:MediaByteSource {
    let data:Data
    init(_ name:String)throws {data=try Data(contentsOf:Bundle.module.url(forResource:name,withExtension:"mp4")!)}
    func fileSize(for file:MediaFile)async throws->UInt64 {UInt64(data.count)}
    func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data {
        guard range.upperBound<=data.count,range.count<=65536 else{throw PlaybackFailure.readFailed}
        return data.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))
    }
}
@MainActor private final class PixelCapture {var last:DecodedVideoFrame?;var count=0;var times:[Double]=[]}
struct SystemVideoSamplesTests {
    func pixel()throws->CVPixelBuffer {
        var buffer:CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil,64,32,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&buffer)==kCVReturnSuccess)
        return try #require(buffer)
    }
    @Test func packingProjectionColorAndIdentityArePreserved()throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else {throw PlaybackFailure.unsupportedTrack}
        let pixel=try pixel()
        CVBufferSetAttachment(pixel,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_2020,.shouldPropagate)
        let builder=SystemVideoSamples()
        for layout in VRLayout.allCases {
            for projection in [VRProjection.equirectangular180,.equirectangular360] {
                var settings=VRSettings();settings.layout=layout;settings.projection=projection
                let frame=DecodedVideoFrame(pixel:pixel,time:1.2345,session:UUID())
                let sample=try builder.sample(frame,settings:settings)
                #expect(CMSampleBufferGetImageBuffer(sample) === pixel)
                #expect(abs(CMSampleBufferGetPresentationTimeStamp(sample).seconds-1.2345)<0.0001)
                let format=try #require(CMSampleBufferGetFormatDescription(sample))
                let ext=format.extensions
                if layout == .sideBySide {#expect(ext[.viewPackingKind] == .viewPackingKind(.sideBySide))}
                if layout == .overUnder {#expect(ext[.viewPackingKind] == .viewPackingKind(.overUnder))}
                if layout == .mono {#expect(ext[.viewPackingKind] == nil)}
                #expect(CMFormatDescriptionGetExtension(format,extensionKey:kCMFormatDescriptionExtension_ColorPrimaries) as? String == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
                #expect((sample.sampleAttachments[0][.displayImmediately] as? Bool) == true)
            }
        }
        CVBufferSetAttachment(pixel,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
        let changed=try builder.sample(DecodedVideoFrame(pixel:pixel,time:2,session:UUID()),settings:VRSettings())
        #expect(CMFormatDescriptionGetExtension(CMSampleBufferGetFormatDescription(changed)!,extensionKey:kCMFormatDescriptionExtension_ColorPrimaries) as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        builder.reset()
    }
    @Test func unsupportedFeaturesRequireExplicitLegacyPath()throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else {throw PlaybackFailure.unsupportedTrack}
        let buffer=try pixel(),builder=SystemVideoSamples()
        var settings=VRSettings()
        let frame=DecodedVideoFrame(pixel:buffer,time:0,session:UUID())
        #expect(SystemVideoSamples.supports(frame,settings:settings))
        settings.projection = .equidistantFisheye180
        #expect(!SystemVideoSamples.supports(frame,settings:settings))
        #expect(throws:PlaybackFailure.unsupportedTrack) {try builder.sample(frame,settings:settings)}
        settings.projection = .equirectangular180
        #expect(!SystemVideoSamples.supports(DecodedVideoFrame(pixel:buffer,time:0,transform:CGAffineTransform(rotationAngle:1),session:UUID()),settings:settings))
    }
    @Test(arguments:["Synthetic4KH264","Synthetic4KHEVC"])
    @MainActor func decodedPixelPackagingPreservesSurface(name:String)async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else {throw PlaybackFailure.unsupportedTrack}
        let capture=PixelCapture(),source=try SystemFixture(name)
        let report=try await HardwarePlayback().play(file:MediaFile(components:["synthetic.mp4"]),source:source,
            onInfo:{_ in},onFrame:{_ in Issue.record("Unexpected CGImage conversion")},onPixelFrame:{capture.last=$0;capture.count+=1})
        #expect(report.hardwareVerified && capture.count==24 && report.imageConversionSeconds==0)
        let frame=try #require(capture.last)
        #expect(CVPixelBufferGetIOSurface(frame.pixel) != nil)
        let builder=SystemVideoSamples()
        var settings=VRSettings();settings.layout = .sideBySide
        let sample=try builder.sample(frame,settings:settings)
        #expect(CMSampleBufferGetImageBuffer(sample) === frame.pixel)
    }
    @Test(arguments:["SyntheticSeek","SyntheticHEVC"])
    @MainActor func pixelSeekUsesExistingClockAndFreshSessions(name:String)async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else {throw PlaybackFailure.unsupportedTrack}
        let source=try SystemFixture(name),engine=HardwarePlayback(muteAudioForTesting:true),capture=PixelCapture()
        var sessions=Set<UUID>()
        for target in [0.123,1.1,0.501,1.9] {
            capture.times=[]
            let report=try await engine.play(file:MediaFile(components:["synthetic.mp4"]),source:source,startAt:target,
                onInfo:{_ in},onFrame:{_ in Issue.record("Unexpected image path")},onPixelFrame:{capture.last=$0;capture.times.append($0.time)})
            #expect(report.hardwareVerified && report.imageConversionSeconds==0)
            #expect(!capture.times.isEmpty && capture.times.allSatisfy {$0>=target})
            sessions.insert(try #require(capture.last).session)
        }
        #expect(sessions.count==4)
        weak var last=capture.last
        capture.last=nil
        #expect(last==nil)
    }
    @Test @MainActor func rendererFlushCyclesReleaseFrameWrappers()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{throw PlaybackFailure.unsupportedTrack}
        let pixel=try pixel()
        for _ in 0..<20 {
            let renderer=AVSampleBufferVideoRenderer()
            let material=VideoMaterial(videoRenderer:renderer)
            let builder=SystemVideoSamples()
            var frame:DecodedVideoFrame?=DecodedVideoFrame(pixel:pixel,time:0,session:UUID())
            weak var released=frame
            let sample=try builder.sample(frame!,settings:VRSettings())
            renderer.enqueue(sample)
            await renderer.flush(removingDisplayedImage:true)
            #expect(renderer.status != .failed)
            builder.reset();frame=nil
            #expect(released==nil)
            withExtendedLifetime(material) {}
        }
        // Proves flush completes and application frame wrappers release, not GPU RSS or displayed pixels.
    }

    @Test(arguments:["CalibrationSBS180","CalibrationSBS360","CalibrationOU180","CalibrationOU360"])
    func calibrationEyesAreDistinct(name:String) async throws {
        let asset=AVURLAsset(url:try #require(Bundle.module.url(forResource:name,withExtension:"mp4")))
        let generator=AVAssetImageGenerator(asset:asset)
        let image=try await generator.image(at:.zero).image
        var settings=VRSettings();settings.layout=name.contains("OU") ? .overUnder:.sideBySide
        for right in [false,true] {
            let cropped=try #require(image.cropping(to:settings.crop(width:image.width,height:image.height,rightEye:right)!))
            var bytes=[UInt8](repeating:0,count:4)
            let context=try #require(CGContext(data:&bytes,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cropped,in:CGRect(x:0,y:0,width:1,height:1))
            #expect(right ? Int(bytes[2])>Int(bytes[0])+50 : Int(bytes[0])>Int(bytes[2])+50)
        }
    }

}

struct PackingPixelMatrixTests {
 @Test(arguments:["CalibrationSBS180","CalibrationOU180"])
 func everyManualModeUsesItsOwnEyeRegions(name:String)async throws {
  let asset=AVURLAsset(url:try #require(Bundle.module.url(forResource:name,withExtension:"mp4")))
  let image=try await AVAssetImageGenerator(asset:asset).image(at:.zero).image
  func rgb(_ rect:CGRect)throws->[Int] {
   let cropped=try #require(image.cropping(to:rect));var bytes=[UInt8](repeating:0,count:4)
   let context=try #require(CGContext(data:&bytes,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
   context.draw(cropped,in:CGRect(x:0,y:0,width:1,height:1));return bytes.prefix(3).map(Int.init)
  }
  for layout in [VRLayout.sideBySide,.overUnder,.mono] {
   var settings=VRSettings();settings.layout=layout
   let left=try rgb(try #require(settings.crop(width:image.width,height:image.height,rightEye:false)))
   let right=try rgb(try #require(settings.crop(width:image.width,height:image.height,rightEye:true)))
   let correct=layout == (name.contains("SBS") ? .sideBySide:.overUnder)
   if correct {#expect(left[0]>left[2]+50);#expect(right[2]>right[0]+50)}
   else {#expect(abs(left[0]-right[0])<30);#expect(abs(left[2]-right[2])<30)}
   print("PACKING_PIXEL_MATRIX",name,layout.rawValue,left,right,"referenceCropNotRenderedEyes")
  }
 }
}
