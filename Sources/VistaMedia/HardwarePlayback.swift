import Foundation
@preconcurrency import AVFoundation
@preconcurrency import VideoToolbox
import CoreImage
#if SWIFT_PACKAGE
import VistaCore
#endif

public enum PlaybackFailure: Error, Equatable {
    case unsupportedContainer, unsupportedTrack, hardwareUnavailable, readFailed, decodeFailed
    public var message: String {
        switch self {
        case .unsupportedContainer: "目前僅提供 MP4／MOV 視訊播放，這個容器尚未支援。"
        case .unsupportedTrack: "無法辨識可播放的單一視訊軌道。"
        case .hardwareUnavailable: "無法確認硬體解碼，已停止播放。"
        case .readFailed: "無法讀取影片。請確認連線及檔案後重試。"
        case .decodeFailed: "影片解碼失敗，已停止播放。"
        }
    }
}
public struct VideoTrackInfo: Sendable, Equatable {
    public let codec: String
    public let width: Int32
    public let height: Int32
    public let duration: Double
}
public struct VideoFrame: @unchecked Sendable {
    public let image: CGImage
    public let time: Double
}
public struct PlaybackReport: Sendable {
    public let decodedFrames: Int
    public let hardwareVerified: Bool
}

/// AVFoundation receives only a session-local opaque URL, never SMB credentials or paths.
@MainActor private final class ResourceBridge: NSObject, AVAssetResourceLoaderDelegate {
    let source: any MediaByteSource
    let file: MediaFile
    let size: UInt64
    let contentType: String
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(source: any MediaByteSource, file: MediaFile, size: UInt64, contentType: String) {
        self.source = source; self.file = file; self.size = size; self.contentType = contentType
    }
    nonisolated func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        MainActor.assumeIsolated { load(request) }
    }
    private func load(_ request: AVAssetResourceLoadingRequest) -> Bool {
        guard tasks.count < 8 else { request.finishLoading(with: PlaybackFailure.readFailed); return true }
        let id = ObjectIdentifier(request)
        tasks[id] = Task {
            defer { tasks[id] = nil }
            do {
                try Task.checkCancellation()
                request.contentInformationRequest?.contentType = contentType
                request.contentInformationRequest?.contentLength = Int64(size)
                request.contentInformationRequest?.isByteRangeAccessSupported = true
                if let dataRequest = request.dataRequest {
                    guard dataRequest.requestedOffset >= 0, dataRequest.currentOffset >= 0, dataRequest.requestedLength >= 0 else { throw PlaybackFailure.readFailed }
                    var offset = UInt64(dataRequest.currentOffset)
                    let (requestedEnd, overflow) = UInt64(dataRequest.requestedOffset).addingReportingOverflow(UInt64(dataRequest.requestedLength))
                    guard !overflow, offset <= size else { throw PlaybackFailure.readFailed }
                    let end = dataRequest.requestsAllDataToEndOfResource ? size : min(size, requestedEnd)
                    while offset < end {
                        try Task.checkCancellation()
                        let next = offset + min(65_536, end - offset)
                        let data = try await source.read(file, range: offset..<next)
                        try Task.checkCancellation()
                        guard data.count == Int(next - offset) else { throw PlaybackFailure.readFailed }
                        dataRequest.respond(with: data)
                        offset = next
                    }
                }
                if !Task.isCancelled { request.finishLoading() }
            } catch { if !Task.isCancelled { request.finishLoading(with: PlaybackFailure.readFailed) } }
        }
        return true
    }
    nonisolated func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        MainActor.assumeIsolated { tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel() }
    }
    func stop() { tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
}

private struct PixelFrame: @unchecked Sendable { let pixel: CVPixelBuffer; let pts: CMTime }
private final class FrameInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [PixelFrame] = []
    private var failed = false
    func receive(status: OSStatus, pixel: CVPixelBuffer?, pts: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard status == noErr, let pixel, frames.count < 32 else { failed = true; return }
        frames.append(PixelFrame(pixel: pixel, pts: pts))
    }
    func take() throws -> [PixelFrame] {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { throw PlaybackFailure.decodeFailed }
        defer { frames.removeAll(keepingCapacity: true) }
        return frames.sorted { CMTimeCompare($0.pts, $1.pts) < 0 }
    }
}

/// The only video decoder in this path is a require-hardware VideoToolbox session.
/// AVAssetReader supplies compressed samples (nil output settings); CoreImage only renders decoded pixels.
public actor HardwarePlayback {
    public init() {}
    public func play(file: MediaFile, source: any MediaByteSource,
                     onInfo: @MainActor @Sendable (VideoTrackInfo) -> Void,
                     onFrame: @MainActor @Sendable (VideoFrame) -> Void) async throws -> PlaybackReport {
        let ext = (file.components.last! as NSString).pathExtension.lowercased()
        guard ["mp4", "m4v", "mov"].contains(ext) else { throw PlaybackFailure.unsupportedContainer }
        let size: UInt64
        do { size = try await source.fileSize(for: file) } catch is CancellationError { throw CancellationError() }
        catch { throw PlaybackFailure.readFailed }
        guard size > 0, size <= Int64.max else { throw PlaybackFailure.readFailed }
        let bridge = await ResourceBridge(source: source, file: file, size: size, contentType: ext == "mov" ? "com.apple.quicktime-movie" : "public.mpeg-4")
        let asset = AVURLAsset(url: URL(string: "vista-media://session/movie.\(ext)")!)
        await MainActor.run { asset.resourceLoader.setDelegate(bridge, queue: .main) }
        do {
            let report = try await decode(asset: asset, onInfo: onInfo, onFrame: onFrame)
            asset.cancelLoading(); await bridge.stop(); return report
        } catch {
            asset.cancelLoading(); await bridge.stop()
            if Task.isCancelled { throw CancellationError() }
            throw (error as? PlaybackFailure) ?? .readFailed
        }
    }
    private func decode(asset: AVURLAsset,
                        onInfo: @MainActor @Sendable (VideoTrackInfo) -> Void,
                        onFrame: @MainActor @Sendable (VideoFrame) -> Void) async throws -> PlaybackReport {
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
        default: throw PlaybackFailure.unsupportedTrack }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let duration = try await asset.load(.duration).seconds
        let transform = try await track.load(.preferredTransform)
        guard duration.isFinite, duration > 0, dimensions.width > 0, dimensions.height > 0 else { throw PlaybackFailure.unsupportedTrack }
        await onInfo(VideoTrackInfo(codec: codecName, width: dimensions.width, height: dimensions.height, duration: duration))
        try Task.checkCancellation()
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
            decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
        guard status == noErr, let session else { throw PlaybackFailure.hardwareUnavailable }
        defer { VTDecompressionSessionInvalidate(session) }
        try verifyHardware(session)
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PlaybackFailure.unsupportedTrack }
        reader.add(output)
        guard reader.startReading() else { throw PlaybackFailure.readFailed }
        let inbox = FrameInbox()
        let context = CIContext(options: [.cacheIntermediates: false])
        let clock = ContinuousClock()
        var origin: ContinuousClock.Instant?
        var firstPTS = 0.0
        var lastPTS = -Double.infinity
        var rendered = 0
        var emptySamples = 0
        var pending: [PixelFrame] = []
        var lastDTS = -Double.infinity
        func render(_ frames: [PixelFrame], isolation: isolated HardwarePlayback) async throws {
            for frame in frames {
                try Task.checkCancellation()
                let pts = frame.pts.seconds
                guard pts.isFinite, pts >= lastPTS, pts >= 0, pts <= duration + 1 else { throw PlaybackFailure.decodeFailed }
                if origin == nil { origin = clock.now; firstPTS = pts }
                let deadline = origin!.advanced(by: .seconds(pts - firstPTS))
                try await clock.sleep(until: deadline)
                let image = CIImage(cvPixelBuffer: frame.pixel).transformed(by: transform)
                guard let cgImage = context.createCGImage(image, from: image.extent) else { throw PlaybackFailure.decodeFailed }
                try Task.checkCancellation()
                await onFrame(VideoFrame(image: cgImage, time: pts))
                lastPTS = pts; rendered += 1
            }
        }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if CMSampleBufferGetNumSamples(sample) == 0 {
                emptySamples += 1
                guard emptySamples < 1024 else { throw PlaybackFailure.decodeFailed }
                continue
            }
            emptySamples = 0
            guard let sampleFormat = CMSampleBufferGetFormatDescription(sample), CMFormatDescriptionEqual(format, otherFormatDescription: sampleFormat) else { throw PlaybackFailure.unsupportedTrack }
            let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._EnableTemporalProcessing], infoFlagsOut: nil) { status, _, pixel, pts, _ in
                inbox.receive(status: status, pixel: pixel, pts: pts)
            }
            guard result == noErr, VTDecompressionSessionWaitForAsynchronousFrames(session) == noErr else { throw PlaybackFailure.decodeFailed }
            try verifyHardware(session)
            let dts = CMSampleBufferGetOutputDecodeTimeStamp(sample)
            let safeTime = dts.isValid ? dts.seconds : CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds
            guard safeTime.isFinite, safeTime >= lastDTS else { throw PlaybackFailure.unsupportedTrack }
            lastDTS = safeTime
            pending.append(contentsOf: try inbox.take())
            guard pending.count <= 32, pending.reduce(0, { $0 + CVPixelBufferGetDataSize($1.pixel) }) <= 128 * 1024 * 1024 else { throw PlaybackFailure.decodeFailed }
            pending.sort { CMTimeCompare($0.pts, $1.pts) < 0 }
            let ready = pending.prefix { $0.pts.seconds <= safeTime }
            try await render(Array(ready), isolation: self)
            pending.removeFirst(ready.count)
        }
        guard reader.status == .completed else { throw PlaybackFailure.readFailed }
        guard VTDecompressionSessionFinishDelayedFrames(session) == noErr,
              VTDecompressionSessionWaitForAsynchronousFrames(session) == noErr else { throw PlaybackFailure.decodeFailed }
        try verifyHardware(session)
        pending.append(contentsOf: try inbox.take())
        guard pending.count <= 32, pending.reduce(0, { $0 + CVPixelBufferGetDataSize($1.pixel) }) <= 128 * 1024 * 1024 else { throw PlaybackFailure.decodeFailed }
        pending.sort { CMTimeCompare($0.pts, $1.pts) < 0 }
        try await render(pending, isolation: self)
        guard rendered > 0 else { throw PlaybackFailure.decodeFailed }
        return PlaybackReport(decodedFrames: rendered, hardwareVerified: true)
    }
    private func verifyHardware(_ session: VTDecompressionSession) throws {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: $0)
        }
        guard status == noErr, value as? Bool == true else { throw PlaybackFailure.hardwareUnavailable }
    }
}
