import Foundation
@preconcurrency import AVFoundation
import CoreVideo
#if SWIFT_PACKAGE
import VistaCore
#endif

/// Isolated APMP sample packaging experiment; does not choose a decoder or a playback clock.
@available(macOS 26.0, visionOS 26.0, *)
public final class SystemVideoSamples {
    private var base:CMFormatDescription?
    private var format:CMFormatDescription?
    private var settings:VRSettings?
    public init() {}
    public func reset() {base=nil;format=nil;settings=nil}
    public static func fallbackReason(_ frame:DecodedVideoFrame,settings:VRSettings)->String? {
        if frame.transform != .identity {return "影片旋轉"}
        if settings.projection == .equidistantFisheye180 {return "魚眼投影"}
        if settings.crop(width:CVPixelBufferGetWidth(frame.pixel),height:CVPixelBufferGetHeight(frame.pixel),rightEye:false) == nil {return "影格尺寸"}
        return nil
    }
    public static func supports(_ frame:DecodedVideoFrame,settings:VRSettings)->Bool {fallbackReason(frame,settings:settings)==nil}
    public func sample(_ frame:DecodedVideoFrame,settings value:VRSettings) throws -> CMSampleBuffer {
        guard Self.supports(frame,settings:value),frame.time.isFinite,frame.time>=0 else {throw PlaybackFailure.unsupportedTrack}
        let original=try CMVideoFormatDescription(imageBuffer:frame.pixel)
        if base == nil || !CMFormatDescriptionEqual(base!,otherFormatDescription:original) || settings != value {
            var ext=original.extensions
            if value.layout == .sideBySide {ext[.viewPackingKind] = .viewPackingKind(.sideBySide)}
            if value.layout == .overUnder {ext[.viewPackingKind] = .viewPackingKind(.overUnder)}
            ext[.projectionKind] = .projectionKind(value.projection == .equirectangular360 ? .equirectangular:.halfEquirectangular)
            ext[.horizontalFieldOfView] = .number(UInt32(value.projection == .equirectangular360 ? 360_000:180_000))
            format=try CMVideoFormatDescription(videoCodecType:original.mediaSubType,width:Int(original.dimensions.width),height:Int(original.dimensions.height),extensions:ext)
            base=original;settings=value
        }
        let timing=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:CMTime(seconds:frame.time,preferredTimescale:60_000),decodeTimeStamp:.invalid)
        let sample=try CMSampleBuffer(imageBuffer:frame.pixel,formatDescription:format!,sampleTiming:timing)
        // Vista's existing audio/continuous timeline already released this frame at its presentation time.
        sample.sampleAttachments[0][.displayImmediately] = true
        return sample
    }
}
