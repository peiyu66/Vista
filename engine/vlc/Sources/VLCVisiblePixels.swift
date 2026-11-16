#if VISTA_VLC_CANDIDATE
import Foundation
import CoreVideo

/// Exact visible-sample copy only when the decoder's buffer includes coded padding.
/// No scaling, color conversion, mutation of decoder-owned pixels, or retained input.
/// Confined to VLCAppEngine's serial actor, never run on MainActor.
final class VLCVisiblePixels {
    enum Failure:Error{case backpressure}
    private var pool:CVPixelBufferPool?
    private var key:[Int]=[]
    private(set) var copies:UInt64=0,allocationFailures:UInt64=0
    private(set) var maximumMS=0.0
    static let allocationLimit=8
    func reset(){pool=nil;key=[]}
    func prepare(_ input:CVPixelBuffer,format p:VLCProbeFormat)throws->CVPixelBuffer {
        let width=Int(p.visible_width),height=Int(p.visible_height),x=Int(p.x_offset),y=Int(p.y_offset)
        let sourceWidth=CVPixelBufferGetWidth(input),sourceHeight=CVPixelBufferGetHeight(input)
        guard p.orientation==0,p.sar_num>0,p.sar_num==p.sar_den,width>0,height>0,
              x<=sourceWidth,y<=sourceHeight,width<=sourceWidth-x,height<=sourceHeight-y else{throw VLCPlaybackError.geometry}
        if x==0,y==0,width==sourceWidth,height==sourceHeight{return input}
        let type=CVPixelBufferGetPixelFormatType(input)
        let bytes:Int
        switch type {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:bytes=1
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:bytes=2
        default:throw VLCPlaybackError.geometry
        }
        guard x%2==0,y%2==0,CVPixelBufferGetPlaneCount(input)==2 else{throw VLCPlaybackError.geometry}
        let started=ProcessInfo.processInfo.systemUptime
        let next=[Int(type),width,height]
        if pool==nil || key != next {
            let attrs:[CFString:Any]=[kCVPixelBufferPixelFormatTypeKey:type,kCVPixelBufferWidthKey:width,kCVPixelBufferHeightKey:height,
                                     kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true]
            var created:CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault,nil,attrs as CFDictionary,&created)==kCVReturnSuccess,let created else{throw VLCPlaybackError.geometry}
            pool=created;key=next
        }
        var result:CVPixelBuffer?
        let aux=[kCVPixelBufferPoolAllocationThresholdKey:Self.allocationLimit] as CFDictionary
        let status=CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,pool!,aux,&result)
        if status==kCVReturnWouldExceedAllocationThreshold{allocationFailures += 1;throw Failure.backpressure}
        guard status==kCVReturnSuccess,let result else{allocationFailures += 1;throw VLCPlaybackError.geometry}
        guard CVPixelBufferLockBaseAddress(input,.readOnly)==kCVReturnSuccess else{throw VLCPlaybackError.geometry}
        defer{CVPixelBufferUnlockBaseAddress(input,.readOnly)}
        guard CVPixelBufferLockBaseAddress(result,[])==kCVReturnSuccess else{throw VLCPlaybackError.geometry}
        defer{CVPixelBufferUnlockBaseAddress(result,[])}
        for plane in 0..<2 {
            let divisor=plane==0 ? 1:2,components=plane==0 ? 1:2
            let planeX=x/divisor,planeY=y/divisor,rows=(height+divisor-1)/divisor,columns=(width+divisor-1)/divisor
            let rowBytes=columns*components*bytes,offset=planeX*components*bytes
            let sourceStride=CVPixelBufferGetBytesPerRowOfPlane(input,plane),destStride=CVPixelBufferGetBytesPerRowOfPlane(result,plane)
            guard planeX+columns<=CVPixelBufferGetWidthOfPlane(input,plane),planeY+rows<=CVPixelBufferGetHeightOfPlane(input,plane),
                  offset+rowBytes<=sourceStride,rowBytes<=destStride,
                  let source=CVPixelBufferGetBaseAddressOfPlane(input,plane),let dest=CVPixelBufferGetBaseAddressOfPlane(result,plane) else{throw VLCPlaybackError.geometry}
            for row in 0..<rows{memcpy(dest.advanced(by:row*destStride),source.advanced(by:(planeY+row)*sourceStride+offset),rowBytes)}
        }
        CVBufferPropagateAttachments(input,result)
        CVBufferSetAttachment(result,kCVImageBufferCleanApertureKey,
            [kCVImageBufferCleanApertureWidthKey:width,kCVImageBufferCleanApertureHeightKey:height,
             kCVImageBufferCleanApertureHorizontalOffsetKey:0,kCVImageBufferCleanApertureVerticalOffsetKey:0] as CFDictionary,.shouldPropagate)
        copies += 1;maximumMS=max(maximumMS,(ProcessInfo.processInfo.systemUptime-started)*1000)
        return result
    }
}
#endif
