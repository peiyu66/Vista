// Vista-owned test fixture generator; no external media or production transcoding.
// swiftc -parse-as-library tools/GenerateSyntheticMovie.swift -o /tmp/vista-fixture
// /tmp/vista-fixture /tmp/Synthetic.mp4
import Foundation
import AVFoundation

@main struct GenerateSyntheticMovie {
    @MainActor static func main() async throws {
        guard (2...3).contains(CommandLine.arguments.count) else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        guard CommandLine.arguments.count == 2 || ["--audio", "--seek", "--hevc", "--controls", "--hevc-4k", "--h264-4k", "--hevc-8k"].contains(CommandLine.arguments[2]) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let ultra = CommandLine.arguments.last == "--hevc-8k"
        let largeHEVC = ultra || CommandLine.arguments.last == "--hevc-4k"
        let large = largeHEVC || CommandLine.arguments.last == "--h264-4k"
        let width = ultra ? 7680 : large ? 3840 : 64, height = ultra ? 3840 : large ? 2160 : 64
        let hevcFixture = largeHEVC || CommandLine.arguments.last == "--hevc"
        let seekFixture = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--seek"
        let includeAudio = seekFixture || (CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--audio")
        let frameCount = ultra ? 12 : CommandLine.arguments.last == "--controls" ? 360 : (seekFixture ? 72 : 24)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hevcFixture ? AVVideoCodecType.hevc : AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: seekFixture ? 12 : 240,
                                             AVVideoAllowFrameReorderingKey: true]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        if includeAudio { guard writer.canAdd(audio) else { throw CocoaError(.fileWriteUnknown) }; writer.add(audio) }
        guard writer.startWriting() else { throw CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        @MainActor func writeVideo() async throws {
            for index in 0..<frameCount {
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw CocoaError(.fileWriteUnknown) }
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw CocoaError(.fileWriteUnknown) }
                CVPixelBufferLockBaseAddress(buffer, [])
                memset(CVPixelBufferGetBaseAddress(buffer), Int32((index * 10) % 256), CVPixelBufferGetBytesPerRow(buffer) * height)
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 12)) else { throw CocoaError(.fileWriteUnknown) }
            }
            input.markAsFinished()
        }
        @MainActor func writeAudio() async throws {
            if includeAudio {
                var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                    mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                    mBitsPerChannel: 16, mReserved: 0)
                var format: CMAudioFormatDescription?
                guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                    magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
                    let format else { throw CocoaError(.fileWriteUnknown) }
                for start in stride(from: 0, to: frameCount * 4000, by: 1024) {
                    while !audio.isReadyForMoreMediaData {
                        guard writer.status == .writing else { throw CocoaError(.fileWriteUnknown) }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    let count = min(1024, frameCount * 4000 - start)
                    let samples = (0..<count).map { Int16(sin(Double(start + $0) * 2 * .pi * 440 / 48_000) * 1000) }
                    var block: CMBlockBuffer?
                    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2,
                        blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: count * 2,
                        flags: 0, blockBufferOut: &block) == noErr, let block else { throw CocoaError(.fileWriteUnknown) }
                    let copied = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 2) }
                    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                        presentationTimeStamp: CMTime(value: Int64(start), timescale: 48_000), decodeTimeStamp: .invalid)
                    var sample: CMSampleBuffer?
                    var size = 2
                    guard copied == noErr, CMSampleBufferCreateReady(allocator: nil, dataBuffer: block,
                        formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
                        let sample, audio.append(sample) else { throw CocoaError(.fileWriteUnknown) }
                }
                audio.markAsFinished()
            }
        }
        async let video: Void = writeVideo()
        async let sound: Void = writeAudio()
        _ = try await (video, sound)
        await writer.finishWriting()
        guard writer.status == .completed else { throw CocoaError(.fileWriteUnknown) }
    }
}
