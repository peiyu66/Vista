import Foundation
import Testing
import CoreVideo
import CoreMedia
@testable import VistaCore
@testable import VistaMedia

private actor HEVCRangeSource: MediaByteSource {
    let data: Data
    var largestRead = 0
    init(large: Bool = false) throws {
        data = try Data(contentsOf: Bundle.module.url(forResource: large ? "Synthetic4KHEVC" : "SyntheticHEVC", withExtension: "mp4")!)
    }
    func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(data.count) }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        guard range.upperBound <= data.count else { throw PlaybackFailure.readFailed }
        largestRead = max(largestRead, Int(range.count))
        return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
}

struct HEVCPlaybackTests {
    @Test(arguments: [0.0, 1.0], [false, true])
    func hevcRangePlaybackRequiresHardware(start: Double, large: Bool) async throws {
        let source = try HEVCRangeSource(large: large)
        do {
            let report = try await HardwarePlayback().play(
                file: MediaFile(components: ["synthetic.mp4"]), source: source, startAt: start,
                onInfo: { info in
                    #expect(info.codec == "HEVC")
                    #expect(info.width == (large ? 3840 : 64) && info.height == (large ? 2160 : 64))
                    #expect(abs(info.duration - 2) < 0.01)
                    #expect(!info.hasAudio)
                }, onFrame: { frame in
                    #expect(frame.image.width == (large ? 3840 : 64) && frame.image.height == (large ? 2160 : 64))
                    #expect(frame.time >= start)
                })
            #expect(report.hardwareVerified)
            #expect(report.decodedFrames == (start == 0 ? 24 : 12))
            print("HEVC_HARDWARE_VERIFIED large=\(large) start=\(start) frames=\(report.decodedFrames)")
        } catch let failure as PlaybackFailure where failure.category == .hardwareUnavailable {
            // Unsupported hosts must fail closed; this marker is not playback success.
            print("HEVC_HARDWARE_UNAVAILABLE start=\(start): no software fallback")
        }
        #expect(await source.largestRead > 0)
        #expect(await source.largestRead <= 65_536)
    }
}

private actor LargeH264Source: MediaByteSource {
    let data: Data
    init() throws { data = try Data(contentsOf: Bundle.module.url(forResource: "Synthetic4KH264", withExtension: "mp4")!) }
    func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(data.count) }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        guard range.upperBound <= data.count else { throw PlaybackFailure.readFailed }
        return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
}
struct VideoBufferRegressionTests {
    @Test(arguments: [0.0, 1.0]) func largeH264WithReordering(start: Double) async throws {
        let report = try await HardwarePlayback().play(file: MediaFile(components: ["synthetic.mp4"]),
            source: LargeH264Source(), startAt: start, onInfo: { #expect($0.codec == "H.264" && $0.width == 3840) },
            onFrame: { #expect($0.time >= start) })
        #expect(report.hardwareVerified)
        #expect(report.decodedFrames == (start == 0 ? 24 : 12))
        #expect(report.peakBufferedVideoBytes < 25 * 1024 * 1024)
        print("H264_4K_BUFFER", start, report.peakBufferedVideoBytes, "WORKING", report.peakVideoWorkingBytes)
    }
}

struct VideoBufferBoundaryTests {
    @Test func readyDeliveryIsNotPersistentBacklog() throws {
        let frameBytes = 48 * 1024 * 1024
        let retained = try VideoReorderBudget.checkedBytes(pixelSizes: [frameBytes, frameBytes], compressed: 1024)
        let delivery = try VideoReorderBudget.checkedBytes(pixelSizes: [frameBytes], compressed: 0)
        #expect(retained + delivery <= 2 * VideoReorderBudget.totalBytes)
        let pts = [0.083, 0.167, 0.25]
        let ready = VideoReorderBudget.readyCount(sortedPTS: pts, upcomingPTS: [0.333, 0.417])
        #expect(ready == 3)
        #expect(try VideoReorderBudget.checkedBytes(pixelSizes: Array(repeating: frameBytes, count: pts.count - ready), compressed: 1024) == 1024)
        // The same images must fail if an earlier not-yet-decoded frame blocks them.
        let blocked = VideoReorderBudget.readyCount(sortedPTS: pts, upcomingPTS: [0.04])
        #expect(blocked == 0)
        #expect(throws: PlaybackFailure.decodeFailed.diagnosed(.videoBufferLimit)) {
            try VideoReorderBudget.checkedBytes(pixelSizes: Array(repeating: frameBytes, count: pts.count - blocked), compressed: 1024)
        }
    }
    @Test func unchangedMemoryLimitRejectsOverflowAndExcessFrames() throws {
        let maxBytes = VideoReorderBudget.totalBytes
        #expect(try VideoReorderBudget.checkedBytes(pixelSizes: [maxBytes - 1], compressed: 1) == maxBytes)
        #expect(throws: PlaybackFailure.decodeFailed.diagnosed(.videoBufferLimit)) {
            try VideoReorderBudget.checkedBytes(pixelSizes: [maxBytes], compressed: 1)
        }
        #expect(throws: PlaybackFailure.decodeFailed.diagnosed(.videoBufferLimit)) {
            try VideoReorderBudget.checkedBytes(pixelSizes: Array(repeating: 1, count: 33), compressed: 0)
        }
        #expect(throws: PlaybackFailure.decodeFailed.diagnosed(.videoBufferLimit)) {
            try VideoReorderBudget.checkedBytes(pixelSizes: [], compressed: 32 * 1024 * 1024 + 1)
        }
    }
    @Test func compressedLookaheadReleasesFramesWithoutWaitingForDTS() throws {
        // After a displayed first frame, three 48MiB decoded images would exceed 128MiB.
        // This models storage only; it is not a claim of actual 8K device playback.
        let bytes = 48 * 1024 * 1024
        #expect(throws: PlaybackFailure.decodeFailed.diagnosed(.videoBufferLimit)) {
            try VideoReorderBudget.checkedBytes(pixelSizes: [bytes, bytes, bytes], compressed: 0)
        }
        let future = [0.25, 0.083, 0.167, 0.5, 0.333, 0.417]
        var pending: [Double] = []
        var delivered = [0.0]
        for index in future.indices {
            pending.append(future[index]); pending.sort()
            let count = VideoReorderBudget.readyCount(sortedPTS: pending, upcomingPTS: Array(future.dropFirst(index + 1)))
            delivered.append(contentsOf: pending.prefix(count)); pending.removeFirst(count)
        }
        #expect(delivered == delivered.sorted())
        #expect(pending.isEmpty)
        #expect(VideoReorderBudget.readyCount(sortedPTS: [0.1, 0.3], upcomingPTS: [0.2, 0.4]) == 1)
    }
}

struct DecoderInboxTests {
    @Test func callbackBudgetFailsBeforeRetainingAnUnboundedBatch() throws {
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 4096, 4096, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        let buffer = try #require(pixel)
        let size = CVPixelBufferGetDataSize(buffer)
        let count = VideoReorderBudget.totalBytes / size
        #expect(count > 0 && count < 32)
        let inbox = FrameInbox()
        for index in 0..<count {
            inbox.receive(status: 0, pixel: buffer, pts: CMTime(value: Int64(index), timescale: 12))
        }
        #expect(try inbox.take().count == count)
        // take() must reset byte accounting; an over-budget batch must fail closed.
        for index in 0...count {
            inbox.receive(status: 0, pixel: buffer, pts: CMTime(value: Int64(index), timescale: 12))
        }
        #expect(throws: PlaybackFailure.decodeFailed.diagnosed(.videoBufferLimit)) { try inbox.take() }
        let failed = FrameInbox()
        failed.receive(status: -12909, pixel: nil, pts: .zero)
        #expect(throws: PlaybackFailure.decodeFailed.diagnosed(.videoCallback, status: -12909)) { try failed.take() }
    }
}
