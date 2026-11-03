// Vista MIT. Accepts only the bounded JSON emitted by the trusted-fixture parser experiment.
import Foundation
import CoreMedia
import VideoToolbox

struct Packet: Decodable { let time: Int64; let hex: String }
struct Input: Decodable { let codec: String; let privateHex: String; let samples: [Packet] }
enum Failure: Error { case invalid, hardwareUnavailable, decoding }
func check(_ condition: Bool) throws { if !condition { throw Failure.invalid } }
func bytes(_ text: String) throws -> Data {
    let chars = Array(text.utf8)
    try check(chars.count <= 131072 && chars.count % 2 == 0)
    func digit(_ c: UInt8) throws -> UInt8 {
        if (48...57).contains(c) { return c - 48 }
        if (97...102).contains(c) { return c - 87 }
        throw Failure.invalid
    }
    return try Data(stride(from: 0, to: chars.count, by: 2).map { try digit(chars[$0]) * 16 + digit(chars[$0 + 1]) })
}
final class Output: @unchecked Sendable {
    let lock = NSLock()
    var frames = 0
    var failed = false
    func receive(_ status: OSStatus, _ pixel: CVPixelBuffer?) {
        lock.lock(); defer { lock.unlock() }
        if status == noErr, let pixel, CVPixelBufferGetWidth(pixel) == 64, CVPixelBufferGetHeight(pixel) == 64 { frames += 1 }
        else { failed = true }
    }
}
func verify(_ session: VTDecompressionSession) throws {
    var value: CFTypeRef?
    let result = withUnsafeMutablePointer(to: &value) {
        VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: $0)
    }
    guard result == noErr, value as? Bool == true else { throw Failure.hardwareUnavailable }
}
@main struct HardwareProbe {
    static func main() throws {
        try check(CommandLine.arguments.count == 2)
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try check(size > 0 && size <= 1_048_576)
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: url))
        try check(input.samples.count == 24)
        let hevc = input.codec == "V_MPEGH/ISO/HEVC"
        try check(hevc || input.codec == "V_MPEG4/ISO/AVC")
        let config = try bytes(input.privateHex)
        try check(config.count <= 4096)
        let atoms: [String: Any] = [hevc ? "hvcC" : "avcC": config]
        var format: CMVideoFormatDescription?
        let result = CMVideoFormatDescriptionCreate(allocator: nil, codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            width: 64, height: 64,
            extensions: [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms] as CFDictionary,
            formatDescriptionOut: &format)
        try check(result == noErr && format != nil)
        var session: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: format!,
            decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
        guard created == noErr, let session else { print("MKV_HARDWARE_UNAVAILABLE", created); return }
        defer { VTDecompressionSessionInvalidate(session) }
        try verify(session)
        let output = Output()
        for packet in input.samples {
            let data = try bytes(packet.hex)
            try check(!data.isEmpty && packet.time >= 0 && packet.time <= 3_000_000_000)
            var block: CMBlockBuffer?
            try check(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                flags: 0, blockBufferOut: &block) == noErr)
            let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: data.count) }
            try check(copied == noErr)
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: packet.time, timescale: 1_000_000_000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            var sampleSize = data.count
            try check(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr)
            let decoded = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample!, flags: [], infoFlagsOut: nil) { status, _, pixel, _, _ in
                output.receive(status, pixel)
            }
            guard decoded == noErr, VTDecompressionSessionWaitForAsynchronousFrames(session) == noErr else { throw Failure.decoding }
            try verify(session)
        }
        try check(VTDecompressionSessionFinishDelayedFrames(session) == noErr)
        try check(VTDecompressionSessionWaitForAsynchronousFrames(session) == noErr)
        try verify(session)
        output.lock.lock(); defer { output.lock.unlock() }
        try check(!output.failed && output.frames == 24)
        print("MKV_ACTUAL_HARDWARE_VERIFIED", hevc ? "HEVC" : "H264", output.frames)
    }
}
