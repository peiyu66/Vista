import Foundation
@preconcurrency import AVFoundation
@preconcurrency import VideoToolbox
import CoreImage
#if SWIFT_PACKAGE
import VistaCore
#endif

/// Isolated investigation: keep blocking AVFoundation reads off cooperative executors.
/// One call per reader is awaited; caller cancellation never resumes before copyNextSampleBuffer returns.
private enum BlockingVideoSampleRead {
    final class OutputBox:@unchecked Sendable {let output:AVAssetReaderTrackOutput;init(_ output:AVAssetReaderTrackOutput){self.output=output}}
    struct Packet:@unchecked Sendable {let sample:CMSampleBuffer?}
    private static let queue:OperationQueue = {
        let value=OperationQueue();value.name="Vista bounded video sample reads";value.maxConcurrentOperationCount=4;value.qualityOfService = .userInitiated;return value
    }()
    static func next(_ box:OutputBox) async throws->Packet {
        try Task.checkCancellation()
        let packet:Packet=await withCheckedContinuation {continuation in
            queue.addOperation {continuation.resume(returning:Packet(sample:box.output.copyNextSampleBuffer()))}
        }
        try Task.checkCancellation()
        return packet
    }
}

/// Inspect only bounded length prefixes and two-byte HEVC NAL headers; never decode video in software.
struct HEVCRandomAccess {
    var first = true
    var craTime:Double?
    static func vclTypes(byteCount:Int,lengthSize:Int,read:(Int,Int)throws->[UInt8])throws->Set<Int> {
        guard [1,2,4].contains(lengthSize),byteCount>0 else{throw PlaybackFailure.seekUnavailable}
        var offset=0,count=0,types=Set<Int>()
        while offset<byteCount {
            count += 1
            guard count<=4096,byteCount-offset>=lengthSize+2 else{throw PlaybackFailure.seekUnavailable}
            let prefix=try read(offset,lengthSize)
            guard prefix.count==lengthSize else{throw PlaybackFailure.seekUnavailable}
            let size=prefix.reduce(0){($0<<8)|Int($1)}
            guard size>=2,size<=byteCount-offset-lengthSize else{throw PlaybackFailure.seekUnavailable}
            let header=try read(offset+lengthSize,2)
            guard header.count==2,header[0]&0x80==0,header[1]&7 != 0,
                  header[0]&1==0,header[1]>>3==0 else{throw PlaybackFailure.seekUnavailable}
            let type=Int((header[0]>>1)&63)
            if type<32 {types.insert(type)}
            offset += lengthSize+size
        }
        guard types.count<=1 else{throw PlaybackFailure.seekUnavailable}
        return types
    }
    mutating func shouldSkip(types:Set<Int>,pts:Double)throws->Bool {
        guard let type=types.first else{return false}
        if first {first=false;craTime=type==21 ? pts:nil;return false}
        guard let craTime else{return false}
        if type==8 || type==9 {
            guard pts<craTime else{throw PlaybackFailure.seekUnavailable}
            return true
        }
        // RADL pictures can be decoded after random access; retain the gate until a trailing picture.
        if type != 6 && type != 7 {self.craTime=nil}
        return false
    }
    mutating func shouldSkip(_ sample:CMSampleBuffer,format:CMFormatDescription,pts:Double)throws->Bool {
        guard first || craTime != nil else{return false}
        var length:Int32=0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format,parameterSetIndex:0,parameterSetPointerOut:nil,parameterSetSizeOut:nil,parameterSetCountOut:nil,nalUnitHeaderLengthOut:&length)==noErr,
              let data=CMSampleBufferGetDataBuffer(sample) else{throw PlaybackFailure.seekUnavailable}
        let types=try Self.vclTypes(byteCount:CMBlockBufferGetDataLength(data),lengthSize:Int(length)) {offset,count in
            var bytes=[UInt8](repeating:0,count:count)
            let status=bytes.withUnsafeMutableBytes {CMBlockBufferCopyDataBytes(data,atOffset:offset,dataLength:count,destination:$0.baseAddress!)}
            guard status==noErr else{throw PlaybackFailure.seekUnavailable}
            return bytes
        }
        return try shouldSkip(types:types,pts:pts)
    }
}

/// Opt-in build policy: never enabled by a runtime preference or on a physical device.
public enum PlaybackDecodingPolicy {
    #if DEBUG && targetEnvironment(simulator) && VISTA_SIMULATOR_SOFTWARE_DECODE
    public static let simulatorSoftwareTest = true
    #else
    public static let simulatorSoftwareTest = false
    #endif
    public static var decoderSpecification: CFDictionary {
        if simulatorSoftwareTest {
            return [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false] as CFDictionary
        }
        return [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
    }
}

/// Closed stage vocabulary and numeric fields only: never includes source URLs or NSError userInfo.
public enum PlaybackDiagnosticStage: String, Sendable {
    case videoCreate, hardwareCheck, videoSubmit, videoWait, videoDrain, videoCallback, videoMissingPixel
    case videoInboxLimit, videoBufferLimit, videoCompressedLimit, videoEmptySamples, videoPTS, videoImage, videoNoFrames
    case videoReaderStart, videoReaderEnd
    case audioTracks, audioFormat, audioReaderCreate, audioReaderAdd, audioReaderStart, audioReaderEnd
    case audioPacket, audioFormatChanged, audioRenderer, audioStopped, audioSession
    case audioFlushed, audioConfiguration, audioInterruption, audioClockInvalid, audioClockStalled, audioLead, videoBufferingTimeout
}
public enum PlaybackFailure: Error, Equatable {
    case unsupportedContainer, unsupportedTrack, unsupportedCodec, hardwareUnavailable, readFailed, decodeFailed, audioFailed, seekUnavailable
    indirect case diagnostic(PlaybackFailure, PlaybackDiagnosticStage, status: Int?, deltaMS: Int?)
    public func diagnosed(_ stage: PlaybackDiagnosticStage, status: Int? = nil, deltaMS: Int? = nil) -> PlaybackFailure {
        .diagnostic(self, stage, status: status, deltaMS: deltaMS)
    }
    public var category: PlaybackFailure {
        if case let .diagnostic(base, _, _, _) = self { return base.category }
        return self
    }
    public var message: String {
        switch self {
        case let .diagnostic(base, stage, status, deltaMS):
            base.message + "\n[" + stage.rawValue
                + (status.map { " code=\($0)" } ?? "")
                + (deltaMS.map { " Δ=\($0)ms" } ?? "") + "]"
        case .unsupportedContainer: "目前僅提供 MP4／MOV 視訊播放，這個容器尚未支援。"
        case .unsupportedCodec: "這個視訊編碼尚未支援，已停止播放。"
        case .unsupportedTrack: "無法辨識可播放的單一視訊軌道。"
        case .hardwareUnavailable: "無法確認硬體解碼，已停止播放。"
        case .readFailed: "無法讀取影片。請確認連線及檔案後重試。"
        case .seekUnavailable: "無法安全跳轉至這個位置。請換個位置或從頭播放。"
        case .audioFailed: "音訊播放或同步失敗，已停止播放。"
        case .decodeFailed: "影片解碼失敗，已停止播放。"
        }
    }
}
public struct VideoTrackInfo: Sendable, Equatable {
    public let codec: String
    public let width: Int32
    public let height: Int32
    public let duration: Double
    public let hasAudio: Bool
}
/// Retains one decoded buffer; never stores source identifiers. Only the isolated renderer experiment requests it.
public final class DecodedVideoFrame: @unchecked Sendable {
    public let pixel:CVPixelBuffer
    public let time:Double
    public let transform:CGAffineTransform
    public let session:UUID
    public init(pixel:CVPixelBuffer,time:Double,transform:CGAffineTransform = .identity,session:UUID) {
        self.pixel=pixel;self.time=time;self.transform=transform;self.session=session
    }
    public func makeImage(context:CIContext)->CGImage? {
        let image=CIImage(cvPixelBuffer:pixel).transformed(by:transform)
        return context.createCGImage(image,from:image.extent)
    }
}
public struct VideoFrame: @unchecked Sendable {
    public let image: CGImage
    public let time: Double
}
public enum ResourceReadPolicy {
    #if VISTA_LARGER_READ_CHUNKS
    public static let chunkBytes:UInt64=262_144
    #else
    public static let chunkBytes:UInt64=MediaReadPlan.chunkLimit
    #endif
}
public struct SeekTargetTolerance:Sendable {
    public let maximumBackward:Double
    public let minimum:Double
    public init(maximumBackward:Double=0,minimum:Double=0) {self.maximumBackward=maximumBackward;self.minimum=minimum}
    public static let exact=SeekTargetTolerance()
    public func resolved(requested:Double,syncTime:Double)->Double {
        guard requested.isFinite,syncTime.isFinite,maximumBackward.isFinite,minimum.isFinite,
              maximumBackward>0,maximumBackward<=1,syncTime>=max(0,minimum),
              syncTime<=requested,requested-syncTime<=maximumBackward else{return requested}
        return syncTime
    }
}
public enum PlaybackSeekingPolicy {
    #if VISTA_APPROXIMATE_SEEK_EXPERIMENT
    public static let nearby=true
    #else
    public static let nearby=false
    #endif
}
public enum PlaybackPreparationStage:String,Sendable { case source="來源就緒", metadata="軌道就緒", decoder="解碼器就緒",audio="音訊與時鐘就緒",reader="讀取器啟動",samples="首批壓縮影格" }
public struct FirstFrameWork:Sendable {
    public let sampleReadSeconds:Double
    public let decodeSeconds:Double
    public let prerollFrames:Int
    public let decodingStart:Double
}
public struct PlaybackReport: Sendable {
    public let decodedFrames: Int
    public let hardwareVerified: Bool
    public let audioSamples: Int
    public let decodingStartTime: Double
    public let prerollFrames: Int
    public let peakVideoWorkingBytes: Int
    public let droppedVideoFrames: Int
    public let peakBufferedVideoBytes: Int
    /// Wall time in synchronous stages, excluding intentional presentation pacing.
    public let decodeWaitSeconds: Double
    public let imageConversionSeconds: Double
    public let sampleReadSeconds: Double
    public let firstFrameWork:FirstFrameWork?

}

/// AVFoundation receives only a session-local opaque URL, never SMB credentials or paths.
@MainActor final class ResourceBridge: NSObject, AVAssetResourceLoaderDelegate {
    let source: any MediaByteSource
    let file: MediaFile
    let size: UInt64
    let contentType: String
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var stopped = false
    private var cleanup = false
    private var traceIDs:[ObjectIdentifier:Int]=[:]
    private let trace:ReadCancellationTrace?
    private let chunkBytes:UInt64
    var onReadFailure:(()->Void)?
    var onReadProgress:(()->Void)?
    // Aggregate diagnostics only; never include a URL, path, or payload.
    var onRangeBegin:(()->Int)?
    var onRangeEnd:((Int,Int,Double,Bool)->Void)?
    #if VISTA_ANON_IO_EXPERIMENT
    var onAnonymousBegin:(()->UInt64?)?
    var onAnonymousEnd:((UInt64?,Int,Bool,Bool)->Void)?
    #endif
    init(source: any MediaByteSource, file: MediaFile, size: UInt64, contentType: String,trace:ReadCancellationTrace? = nil,chunkBytes:UInt64 = MediaReadPlan.chunkLimit) {
        self.source = source; self.file = file; self.size = size; self.contentType = contentType;self.trace=trace;self.chunkBytes=chunkBytes
    }
    nonisolated func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        MainActor.assumeIsolated { load(request) }
    }
    static func shouldReportReadFailure(_ error:any Error,taskCancelled:Bool,requestCancelled:Bool,stopped:Bool)->Bool {
        !taskCancelled && !requestCancelled && !stopped && !(error is CancellationError)
    }
    private func load(_ request: AVAssetResourceLoadingRequest) -> Bool {
        guard !stopped, tasks.count < 8 else { if !stopped {onReadFailure?()};request.finishLoading(with: PlaybackFailure.readFailed); return true }
        let id = ObjectIdentifier(request)
        let traceID=trace?.begin()
        traceIDs[id]=traceID
        tasks[id] = Task {
            defer { tasks[id] = nil;traceIDs[id]=nil;if let traceID {trace?.finish(traceID)} }
            do {
                try Task.checkCancellation()
                request.contentInformationRequest?.contentType = contentType
                request.contentInformationRequest?.contentLength = Int64(size)
                request.contentInformationRequest?.isByteRangeAccessSupported = true
                if let dataRequest = request.dataRequest {
                    let plan = try MediaReadPlan(requestedOffset: dataRequest.requestedOffset,
                                                 currentOffset: dataRequest.currentOffset,
                                                 requestedLength: dataRequest.requestedLength,
                                                 toEnd: dataRequest.requestsAllDataToEndOfResource, fileSize: size,chunkBytes:chunkBytes)
                    for range in plan {
                        try Task.checkCancellation()
                        let data:Data
                        if let traceID {trace?.reading(traceID,true)}
                        let epoch=onRangeBegin?() ?? 0,started=ProcessInfo.processInfo.systemUptime
                        #if VISTA_ANON_IO_EXPERIMENT
                        let anonymousID=onAnonymousBegin?()
                        #endif
                        do {data=try await source.read(file,range:range)}
                        catch {
                            #if VISTA_ANON_IO_EXPERIMENT
                            let cancelled=error is CancellationError || Task.isCancelled || stopped || request.isCancelled
                            onAnonymousEnd?(anonymousID,0,cancelled,!cancelled)
                            #endif
                            onRangeEnd?(epoch,0,ProcessInfo.processInfo.systemUptime-started,true)
                            if let traceID,error is CancellationError {trace?.readCancelled(traceID)};throw error
                        }
                        #if VISTA_ANON_IO_EXPERIMENT
                        onAnonymousEnd?(anonymousID,data.count,Task.isCancelled,data.count != Int(range.upperBound-range.lowerBound))
                        #endif
                        onRangeEnd?(epoch,data.count,ProcessInfo.processInfo.systemUptime-started,Task.isCancelled)
                        if let traceID {trace?.reading(traceID,false)}
                        try Task.checkCancellation()
                        guard !stopped,!request.isCancelled else{throw CancellationError()}
                        guard data.count == Int(range.upperBound - range.lowerBound) else { throw PlaybackFailure.readFailed }
                        dataRequest.respond(with: data)
                        onReadProgress?()
                        if let traceID {trace?.delivered(traceID,data.count)}
                        // Let cancellation/seek callbacks run before issuing more speculative I/O.
                        await Task.yield()
                    }
                }
                if !Task.isCancelled,!stopped,!request.isCancelled { request.finishLoading() }
            } catch {
                if Self.shouldReportReadFailure(error,taskCancelled:Task.isCancelled,requestCancelled:request.isCancelled,stopped:stopped) {
                    onReadFailure?();request.finishLoading(with: PlaybackFailure.readFailed)
                }
            }
        }
        return true
    }
    nonisolated func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        MainActor.assumeIsolated {
            let id=ObjectIdentifier(request)
            if let traceID=traceIDs[id] {trace?.cancel(traceID,cleanup:cleanup)}
            tasks[id]?.cancel()
        }
    }
    #if SWIFT_PACKAGE
    // Test-only observation; reuse is not wired into the App.
    var experimentActiveReads:Int {tasks.count}
    #endif
    func beginCleanup() {cleanup=true}
    func stop() async {
        cleanup=true
        for id in traceIDs.values {trace?.cancel(id,cleanup:true)}
        stopped = true
        let pending = Array(tasks.values)
        pending.forEach { $0.cancel() }
        tasks.removeAll()
        for task in pending { await task.value }
    }
}

/// Bound the app-owned compressed + decoded reorder storage, independent of codec.
/// Decoder internals, CI images and GPU textures are not included in this budget.
enum VideoReorderBudget {
    static let totalBytes = 128 * 1024 * 1024
    static let compressedBytes = 32 * 1024 * 1024
    static func checkedBytes(pixelSizes: [Int], compressed: Int) throws -> Int {
        guard pixelSizes.count <= 32, compressed >= 0, compressed <= compressedBytes else {
            throw PlaybackFailure.decodeFailed.diagnosed(.videoBufferLimit)
        }
        var total = compressed
        for size in pixelSizes {
            guard size >= 0, size <= totalBytes - total else {
                throw PlaybackFailure.decodeFailed.diagnosed(.videoBufferLimit)
            }
            total += size
        }
        return total
    }
    static func readyCount(sortedPTS: [Double], upcomingPTS: [Double]) -> Int {
        let future = upcomingPTS.min() ?? .infinity
        return sortedPTS.prefix { $0 <= future }.count
    }
}

struct PixelFrame: @unchecked Sendable { let pixel: CVPixelBuffer; let pts: CMTime }
final class FrameInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [PixelFrame] = []
    private var bytes = 0
    private var failure: PlaybackFailure?
    private let metrics:PlaybackMetrics?
    init(metrics:PlaybackMetrics? = nil) {self.metrics=metrics}
    func receive(status: OSStatus, pixel: CVPixelBuffer?, pts: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil else { return }
        guard status == noErr else { failure = PlaybackFailure.decodeFailed.diagnosed(.videoCallback, status: Int(status)); return }
        guard let pixel else { failure = PlaybackFailure.decodeFailed.diagnosed(.videoMissingPixel); return }
        guard frames.count < 32 else { failure = PlaybackFailure.decodeFailed.diagnosed(.videoInboxLimit, status: frames.count); return }
        let size = CVPixelBufferGetDataSize(pixel)
        guard size <= VideoReorderBudget.totalBytes - bytes else {
            failure = PlaybackFailure.decodeFailed.diagnosed(.videoBufferLimit)
            frames.removeAll(); bytes = 0
            return
        }
        bytes += size
        metrics?.mark(.decoded)
        frames.append(PixelFrame(pixel: pixel, pts: pts))
    }
    func take() throws -> [PixelFrame] {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        defer { frames.removeAll(keepingCapacity: true); bytes = 0 }
        return frames.sorted { CMTimeCompare($0.pts, $1.pts) < 0 }
    }
}

/// The only video decoder in this path is a require-hardware VideoToolbox session.
/// AVAssetReader supplies compressed samples (nil output settings); CoreImage only renders decoded pixels.
public actor HardwarePlayback {
    private let muteAudio: Bool
    public init() { muteAudio = false }
    init(muteAudioForTesting: Bool) { muteAudio = muteAudioForTesting }
    public func play(file: MediaFile, source: any MediaByteSource, startAt: Double = 0, timeline suppliedTimeline: PlaybackTimeline? = nil, metrics:PlaybackMetrics? = nil,
                     onInfo: @MainActor @Sendable (VideoTrackInfo) -> Void,
                     onFrame: @MainActor @Sendable (VideoFrame) -> Void,
                     onPixelFrame: (@MainActor @Sendable (DecodedVideoFrame) -> Void)? = nil,
                     onPreparation: (@MainActor @Sendable (PlaybackPreparationStage)->Void)? = nil,
                     resourceReadChunkBytes:UInt64 = ResourceReadPolicy.chunkBytes,seekTolerance:SeekTargetTolerance = .exact,
                     onSeekResolved:(@MainActor @Sendable (Double,Double)->Void)? = nil) async throws -> PlaybackReport {
        guard resourceReadChunkBytes>0,resourceReadChunkBytes<=1_048_576,startAt.isFinite, startAt >= 0 else { throw PlaybackFailure.seekUnavailable }
        let ext = (file.components.last! as NSString).pathExtension.lowercased()
        guard ["mp4", "m4v", "mov"].contains(ext) else { throw PlaybackFailure.unsupportedContainer }
        let size: UInt64
        do { size = try await source.fileSize(for: file) } catch is CancellationError { throw CancellationError() }
        catch { throw PlaybackFailure.readFailed }
        try Task.checkCancellation()
        guard size > 0, size <= Int64.max else { throw PlaybackFailure.readFailed }
        await onPreparation?(.source)
        let measuredSource:any MediaByteSource
        if let metrics {measuredSource=MeasuredMediaSource(base:source,metrics:metrics)} else {measuredSource=source}
        let bridge = await ResourceBridge(source: measuredSource, file: file, size: size, contentType: ext == "mov" ? "com.apple.quicktime-movie" : "public.mpeg-4",trace:metrics?.cancellationTrace,chunkBytes:resourceReadChunkBytes)
        let asset = AVURLAsset(url: URL(string: "vista-media://session/movie.\(ext)")!)
        await MainActor.run { asset.resourceLoader.setDelegate(bridge, queue: .main) }
        do {
            let timeline = if let suppliedTimeline { suppliedTimeline } else { await PlaybackTimeline() }
            let report = try await decode(asset: asset, startAt: startAt, timeline: timeline, metrics:metrics, onInfo: onInfo, onFrame: onFrame, onPixelFrame:onPixelFrame,onPreparation:onPreparation,seekTolerance:seekTolerance,onSeekResolved:onSeekResolved)
            await bridge.beginCleanup();asset.cancelLoading(); await bridge.stop(); return report
        } catch {
            await bridge.beginCleanup();asset.cancelLoading(); await bridge.stop()
            if Task.isCancelled { throw CancellationError() }
            throw (error as? PlaybackFailure) ?? .readFailed
        }
    }
    func decode(asset: AVURLAsset, startAt: Double, timeline: PlaybackTimeline, metrics:PlaybackMetrics?,
                        onInfo: @MainActor @Sendable (VideoTrackInfo) -> Void,
                        onFrame: @MainActor @Sendable (VideoFrame) -> Void,
                     onPixelFrame: (@MainActor @Sendable (DecodedVideoFrame) -> Void)? = nil,
                     onPreparation: (@MainActor @Sendable (PlaybackPreparationStage)->Void)? = nil,seekTolerance:SeekTargetTolerance,onSeekResolved:(@MainActor @Sendable (Double,Double)->Void)?) async throws -> PlaybackReport {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, !(try await asset.load(.hasProtectedContent)) else { throw PlaybackFailure.unsupportedTrack }
        let track = tracks[0]
        let formats = try await track.load(.formatDescriptions)
        guard formats.count == 1, let format = formats.first else { throw PlaybackFailure.unsupportedTrack }
        let codec = CMFormatDescriptionGetMediaSubType(format)
        let codecName: String
        switch codec { case kCMVideoCodecType_H264: codecName = "H.264"
        case kCMVideoCodecType_HEVC: codecName = "HEVC"
        case kCMVideoCodecType_VP9: codecName = "VP9"
        default: throw PlaybackFailure.unsupportedCodec }
        if PlaybackDecodingPolicy.simulatorSoftwareTest && codec != kCMVideoCodecType_H264 && codec != kCMVideoCodecType_HEVC {
            throw PlaybackFailure.unsupportedCodec
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let duration = try await asset.load(.duration).seconds
        let transform = try await track.load(.preferredTransform)
        guard duration.isFinite, duration > 0, dimensions.width > 0, dimensions.height > 0 else { throw PlaybackFailure.unsupportedTrack }
        guard startAt < duration else { throw PlaybackFailure.seekUnavailable }
        await timeline.prepare(at: startAt)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count <= 1 else { throw PlaybackFailure.audioFailed.diagnosed(.audioTracks, status: audioTracks.count) }
        if let audioTrack = audioTracks.first {
            let audioFormats = try await audioTrack.load(.formatDescriptions)
            guard audioFormats.count == 1, let audioFormat = audioFormats.first,
                  AudioPlayback.supported(audioFormat) else { throw PlaybackFailure.audioFailed.diagnosed(.audioFormat) }
        }
        await onInfo(VideoTrackInfo(codec: codecName, width: dimensions.width, height: dimensions.height, duration: duration, hasAudio: !audioTracks.isEmpty))
        await onPreparation?(.metadata)
        try Task.checkCancellation()
        var session: VTDecompressionSession?
        // The system renderer needs shareable decoded storage. Preserve native pixel format and legacy output policy.
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
            decoderSpecification: PlaybackDecodingPolicy.decoderSpecification,
            imageBufferAttributes: onPixelFrame == nil ? nil : [kCVPixelBufferIOSurfacePropertiesKey: [:],kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, outputCallback: nil, decompressionSessionOut: &session)
        guard status == noErr, let session else { throw PlaybackFailure.hardwareUnavailable.diagnosed(.videoCreate, status: Int(status)) }
        defer { VTDecompressionSessionInvalidate(session) }
        try verifyHardware(session,metrics:metrics)
        await onPreparation?(.decoder)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: startAt, preferredTimescale: 60_000), duration: .positiveInfinity)
        defer { reader.cancelReading() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PlaybackFailure.unsupportedTrack }
        reader.add(output)
        guard reader.startReading() else { throw PlaybackFailure.readFailed.diagnosed(.videoReaderStart,status:(reader.error as NSError?)?.code) }
        await onPreparation?(.reader)
        let sampleOutput=BlockingVideoSampleRead.OutputBox(output)
        var first:CMSampleBuffer?
        for _ in 0..<1024 {
            try Task.checkCancellation()
            guard let sample=try await BlockingVideoSampleRead.next(sampleOutput).sample else{break}
            if CMSampleBufferGetNumSamples(sample)>0 {first=sample;break}
        }
        guard let first,let firstFormat=CMSampleBufferGetFormatDescription(first),CMFormatDescriptionEqual(format,otherFormatDescription:firstFormat) else {throw PlaybackFailure.seekUnavailable}
        try Task.checkCancellation()
        let syncTime=CMSampleBufferGetOutputPresentationTimeStamp(first).seconds
        guard syncTime.isFinite else {throw PlaybackFailure.seekUnavailable}
        if startAt>0 {
            let flags=(CMSampleBufferGetSampleAttachmentsArray(first,createIfNecessary:false) as? [[String:Any]])?.first ?? [:]
            guard flags[kCMSampleAttachmentKey_NotSync as String] as? Bool != true,
                  flags[kCMSampleAttachmentKey_PartialSync as String] as? Bool != true,
                  flags[kCMSampleAttachmentKey_DependsOnOthers as String] as? Bool != true,
                  syncTime<=startAt,startAt-syncTime<=30 else {throw PlaybackFailure.seekUnavailable}
        }
        let resolvedStart=seekTolerance.resolved(requested:startAt,syncTime:syncTime)
        await timeline.prepare(at:resolvedStart)
        await onSeekResolved?(startAt,resolvedStart)
        let audio: AudioPlayback?
        if let audioTrack = audioTracks.first {
            let clock = await PlaybackAudioClock(muted: muteAudio, startAt: resolvedStart)
            let prepared = try AudioPlayback(asset: asset, track: audioTrack, clock: clock, startAt: resolvedStart)
            audio = prepared
            await timeline.attachAudio(clock, feed: { try await prepared.pump(through: $0) })
        } else { audio = nil }
        await onPreparation?(.audio)
        do {
            let report = try await readVideo(asset: asset, track: track, format: format, session: session,
                                            transform: transform, duration: duration, startAt: resolvedStart, timeline: timeline,reader:reader,sampleOutput:sampleOutput,first:first,
                                            audio: audio, metrics:metrics, onFrame: onFrame, onPixelFrame:onPixelFrame,onPreparation:onPreparation)
            await audio?.stop(); await timeline.detachAudio()
            return report
        } catch {
            await audio?.stop(); await timeline.detachAudio()
            throw error
        }
    }
    private func readVideo(asset: AVURLAsset, track: AVAssetTrack, format: CMFormatDescription,
                           session: VTDecompressionSession, transform: CGAffineTransform, duration: Double, startAt: Double,
                           timeline: PlaybackTimeline,reader:AVAssetReader,sampleOutput:BlockingVideoSampleRead.OutputBox,first:CMSampleBuffer, audio: AudioPlayback?, metrics:PlaybackMetrics?,
                           onFrame: @MainActor @Sendable (VideoFrame) -> Void,
                     onPixelFrame: (@MainActor @Sendable (DecodedVideoFrame) -> Void)? = nil,
                     onPreparation: (@MainActor @Sendable (PlaybackPreparationStage)->Void)? = nil) async throws -> PlaybackReport {
        let inbox = FrameInbox(metrics:metrics)
        let context = CIContext(options: [.cacheIntermediates: false])
        var lastPTS = -Double.infinity
        var rendered = 0
        var emptySamples = 0
        var firstSampleTime: Double?
        var randomAccess=HEVCRandomAccess()
        var prerollFrames = 0
        var prerollSamples = 0
        var prerollBytes = 0
        var lastPreroll: PixelFrame?
        var pending: [PixelFrame] = []
        var decodeWaitSeconds = 0.0
        var imageConversionSeconds = 0.0
        var sampleReadSeconds = 0.0
        var peakBufferedVideoBytes = 0
        var peakVideoWorkingBytes = 0
        var firstFrameWork:FirstFrameWork?
        var lastDTS = -Double.infinity
        // Keep the existing 16-sample reorder horizon in compressed form rather
        // than retaining sixteen full-resolution decoded pixel buffers.
        guard CMSampleBufferGetTotalSampleSize(first)<=32*1024*1024 else {throw PlaybackFailure.decodeFailed.diagnosed(.videoCompressedLimit)}
        var upcoming: [CMSampleBuffer] = [first]
        var upcomingBytes = CMSampleBufferGetTotalSampleSize(first)
        func nextSample(isolation:isolated HardwarePlayback) async throws -> CMSampleBuffer? {
            while upcoming.count < 17 {
                try Task.checkCancellation()
                guard let sample = try await BlockingVideoSampleRead.next(sampleOutput).sample else { break }
                if CMSampleBufferGetNumSamples(sample) == 0 {
                    emptySamples += 1
                    guard emptySamples < 1024 else { throw PlaybackFailure.decodeFailed.diagnosed(.videoEmptySamples) }
                    continue
                }
                emptySamples = 0
                let bytes = CMSampleBufferGetTotalSampleSize(sample)
                guard bytes <= 32 * 1024 * 1024 - upcomingBytes,
                      bytes <= 128 * 1024 * 1024 - upcomingBytes - pending.reduce(0, { $0 + CVPixelBufferGetDataSize($1.pixel) }) else { throw PlaybackFailure.decodeFailed.diagnosed(.videoCompressedLimit) }
                guard CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds.isFinite else { throw PlaybackFailure.unsupportedTrack }
                upcoming.append(sample); upcomingBytes += bytes
            }
            guard !upcoming.isEmpty else { return nil }
            let sample = upcoming.removeFirst()
            upcomingBytes -= CMSampleBufferGetTotalSampleSize(sample)
            return sample
        }
        let renderSession=UUID()
        func render(_ frames: [PixelFrame], isolation: isolated HardwarePlayback) async throws {
            for frame in frames {
                try Task.checkCancellation()
                let pts = frame.pts.seconds
                guard pts.isFinite, pts >= lastPTS, pts >= 0, pts <= duration + 1 else { throw PlaybackFailure.decodeFailed.diagnosed(.videoPTS) }
                if pts < startAt {
                    lastPreroll = frame
                    lastPTS = pts
                    prerollFrames += 1
                    continue
                }
                lastPreroll = nil
                if try await timeline.skipLateVideoFrame(at: pts) {
                    lastPTS = pts
                    continue
                }
                if let onPixelFrame {
                    let next=DecodedVideoFrame(pixel:frame.pixel,time:pts,transform:transform,session:renderSession)
                    let displayed=try await timeline.present(at:pts) {onPixelFrame(next)}
                    lastPTS=pts
                    if displayed {
                        if firstFrameWork == nil {firstFrameWork=FirstFrameWork(sampleReadSeconds:sampleReadSeconds,decodeSeconds:decodeWaitSeconds,prerollFrames:prerollFrames,decodingStart:firstSampleTime ?? 0)}
                        rendered += 1
                    }
                    continue
                }
                let conversionStart = ProcessInfo.processInfo.systemUptime
                let image = CIImage(cvPixelBuffer: frame.pixel).transformed(by: transform)
                guard let cgImage = context.createCGImage(image, from: image.extent) else { throw PlaybackFailure.decodeFailed.diagnosed(.videoImage) }
                let conversionSeconds=ProcessInfo.processInfo.systemUptime - conversionStart
                imageConversionSeconds += conversionSeconds
                metrics?.record(.image,seconds:conversionSeconds)
                try Task.checkCancellation()
                let next = VideoFrame(image: cgImage, time: pts)
                let displayed = try await timeline.present(at: pts) { onFrame(next) }
                lastPTS = pts
                if displayed { rendered += 1 }
            }
        }
        while true {
            try await timeline.waitUntilRunning()
            let work=await timeline.beginVideoWork()
            let readStart = ProcessInfo.processInfo.systemUptime
            let readSample = try await nextSample(isolation:self)
            sampleReadSeconds += ProcessInfo.processInfo.systemUptime - readStart
            guard let sample = readSample else {await timeline.endVideoWork(work);break}
            try Task.checkCancellation()
            if CMSampleBufferGetNumSamples(sample) == 0 {
                emptySamples += 1
                guard emptySamples < 1024 else { throw PlaybackFailure.decodeFailed.diagnosed(.videoEmptySamples) }
                await timeline.endVideoWork(work)
                continue
            }
            emptySamples = 0
            guard let sampleFormat = CMSampleBufferGetFormatDescription(sample), CMFormatDescriptionEqual(format, otherFormatDescription: sampleFormat) else { throw PlaybackFailure.unsupportedTrack }
            let sampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds
            guard sampleTime.isFinite else { throw PlaybackFailure.seekUnavailable }
            if firstSampleTime == nil {
                await onPreparation?(.samples)
                firstSampleTime = sampleTime
                if startAt > 0 {
                    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
                    let flags = attachments?.first ?? [:]
                    guard flags[kCMSampleAttachmentKey_NotSync as String] as? Bool != true,
                          flags[kCMSampleAttachmentKey_PartialSync as String] as? Bool != true,
                          flags[kCMSampleAttachmentKey_DependsOnOthers as String] as? Bool != true,
                          sampleTime <= startAt, startAt - sampleTime <= 30 else { throw PlaybackFailure.seekUnavailable }
                }
            }
            if sampleTime < startAt {
                prerollSamples += 1
                prerollBytes += CMSampleBufferGetTotalSampleSize(sample)
                guard prerollSamples <= 4096, prerollBytes <= 128 * 1024 * 1024 else { throw PlaybackFailure.seekUnavailable }
            }
            if startAt>0,CMFormatDescriptionGetMediaSubType(format)==kCMVideoCodecType_HEVC,
               try randomAccess.shouldSkip(sample,format:format,pts:sampleTime) {await timeline.endVideoWork(work);continue}
            // Presentation ordering is handled in the bounded queue below.
            let decodeStart = ProcessInfo.processInfo.systemUptime
            let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, pixel, pts, _ in
                inbox.receive(status: status, pixel: pixel, pts: pts)
            }
            guard result == noErr else { throw PlaybackFailure.decodeFailed.diagnosed(.videoSubmit, status: Int(result)) }
            let waitStatus = VTDecompressionSessionWaitForAsynchronousFrames(session)
            guard waitStatus == noErr else { throw PlaybackFailure.decodeFailed.diagnosed(.videoWait, status: Int(waitStatus)) }
            let decodeSeconds=ProcessInfo.processInfo.systemUptime - decodeStart
            decodeWaitSeconds += decodeSeconds
            metrics?.record(.decode,seconds:decodeSeconds)
            try verifyHardware(session,metrics:metrics)
            let dts = CMSampleBufferGetOutputDecodeTimeStamp(sample)
            let safeTime = dts.isValid ? dts.seconds : CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds
            guard safeTime.isFinite, safeTime >= lastDTS else { throw PlaybackFailure.unsupportedTrack }
            lastDTS = safeTime
            // A decoder delivery is bounded separately from frames waiting for reordering.
            // Drain ready frames before charging the retained-queue budget: an immediately
            // presentable frame must not be mistaken for persistent reorder backlog.
            do {
                let received = try inbox.take()
                let deliveryBytes = try VideoReorderBudget.checkedBytes(pixelSizes: received.map { CVPixelBufferGetDataSize($0.pixel) }, compressed: 0)
                let retainedBytes = try VideoReorderBudget.checkedBytes(pixelSizes: pending.map { CVPixelBufferGetDataSize($0.pixel) }, compressed: upcomingBytes)
                peakVideoWorkingBytes = max(peakVideoWorkingBytes, retainedBytes + deliveryBytes)
                pending.append(contentsOf: received)
            }
            pending.sort { CMTimeCompare($0.pts, $1.pts) < 0 }
            let readyCount = VideoReorderBudget.readyCount(sortedPTS: pending.map { $0.pts.seconds },
                upcomingPTS: upcoming.map { CMSampleBufferGetOutputPresentationTimeStamp($0).seconds })
            // Bound what remains BEFORE waiting on presentation, including failure paths.
            peakBufferedVideoBytes = max(peakBufferedVideoBytes,
                try VideoReorderBudget.checkedBytes(pixelSizes: pending.dropFirst(readyCount).map { CVPixelBufferGetDataSize($0.pixel) }, compressed: upcomingBytes))
            await timeline.endVideoWork(work)
            for _ in 0..<readyCount {
                let frame = pending.removeFirst()
                try await render([frame], isolation: self)
            }
        }
        guard reader.status == .completed else { throw PlaybackFailure.readFailed.diagnosed(.videoReaderEnd, status: (reader.error as NSError?)?.code) }
        let drainStatus = VTDecompressionSessionFinishDelayedFrames(session)
        guard drainStatus == noErr else { throw PlaybackFailure.decodeFailed.diagnosed(.videoDrain, status: Int(drainStatus)) }
        let waitStatus = VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard waitStatus == noErr else { throw PlaybackFailure.decodeFailed.diagnosed(.videoWait, status: Int(waitStatus)) }
        try verifyHardware(session,metrics:metrics)
        do {
            let finalDelivery = try inbox.take()
            let finalBytes = try VideoReorderBudget.checkedBytes(pixelSizes: finalDelivery.map { CVPixelBufferGetDataSize($0.pixel) }, compressed: 0)
            let retainedBytes = try VideoReorderBudget.checkedBytes(pixelSizes: pending.map { CVPixelBufferGetDataSize($0.pixel) }, compressed: upcomingBytes)
            peakVideoWorkingBytes = max(peakVideoWorkingBytes, retainedBytes + finalBytes)
            pending.append(contentsOf: finalDelivery)
        }
        pending.sort { CMTimeCompare($0.pts, $1.pts) < 0 }
        while !pending.isEmpty {
            let frame = pending.removeFirst()
            try await render([frame], isolation: self)
        }
        // A request within the final frame's interval may have no later presentation timestamp.
        if rendered == 0, let lastPreroll {
            if let onPixelFrame {
                let next=DecodedVideoFrame(pixel:lastPreroll.pixel,time:startAt,transform:transform,session:renderSession)
                try await timeline.present(at:startAt) {onPixelFrame(next)}
            } else {
            let image = CIImage(cvPixelBuffer: lastPreroll.pixel).transformed(by: transform)
            guard let cgImage = context.createCGImage(image, from: image.extent) else { throw PlaybackFailure.decodeFailed.diagnosed(.videoImage) }
            let next = VideoFrame(image: cgImage, time: startAt)
            try await timeline.present(at: startAt) { onFrame(next) }
            }
            lastPTS = startAt; rendered = 1
        }
        guard rendered > 0 else { throw PlaybackFailure.decodeFailed.diagnosed(.videoNoFrames) }
        try await timeline.waitUntilRunning()
        if audio != nil {
            var position = max(lastPTS, await timeline.audioTime ?? lastPTS)
            while position < duration {
                position = min(duration, position + 0.05)
                try await timeline.waitUntilRunning()
                try await timeline.present(at: position) {}
            }
        }
        return PlaybackReport(decodedFrames: rendered, hardwareVerified: !PlaybackDecodingPolicy.simulatorSoftwareTest, audioSamples: await audio?.sampleCount ?? 0, decodingStartTime: firstSampleTime ?? 0, prerollFrames: prerollFrames, peakVideoWorkingBytes: peakVideoWorkingBytes, droppedVideoFrames: await timeline.droppedVideoFrames, peakBufferedVideoBytes: peakBufferedVideoBytes, decodeWaitSeconds: decodeWaitSeconds, imageConversionSeconds: imageConversionSeconds, sampleReadSeconds: sampleReadSeconds,firstFrameWork:firstFrameWork)
    }
    private func verifyHardware(_ session: VTDecompressionSession, metrics:PlaybackMetrics?) throws {
        if PlaybackDecodingPolicy.simulatorSoftwareTest { metrics?.setHardware(verified:false,softwareTest:true);return }
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: $0)
        }
        let verified=status == noErr && value as? Bool == true
        metrics?.setHardware(verified:verified,softwareTest:false)
        guard verified else { throw PlaybackFailure.hardwareUnavailable.diagnosed(.hardwareCheck, status: Int(status)) }
    }
}
