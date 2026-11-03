import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

private actor HEVCRangeSource: MediaByteSource {
    let data: Data
    var largestRead = 0
    init() throws {
        data = try Data(contentsOf: Bundle.module.url(forResource: "SyntheticHEVC", withExtension: "mp4")!)
    }
    func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(data.count) }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        guard range.upperBound <= data.count else { throw PlaybackFailure.readFailed }
        largestRead = max(largestRead, Int(range.count))
        return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
}

struct HEVCPlaybackTests {
    @Test(arguments: [0.0, 1.0])
    func hevcRangePlaybackRequiresHardware(start: Double) async throws {
        let source = try HEVCRangeSource()
        do {
            let report = try await HardwarePlayback().play(
                file: MediaFile(components: ["synthetic.mp4"]), source: source, startAt: start,
                onInfo: { info in
                    #expect(info.codec == "HEVC")
                    #expect(info.width == 64 && info.height == 64)
                    #expect(abs(info.duration - 2) < 0.01)
                    #expect(!info.hasAudio)
                }, onFrame: { frame in
                    #expect(frame.image.width == 64 && frame.image.height == 64)
                    #expect(frame.time >= start)
                })
            #expect(report.hardwareVerified)
            #expect(report.decodedFrames == (start == 0 ? 24 : 12))
            print("HEVC_HARDWARE_VERIFIED start=\(start) frames=\(report.decodedFrames)")
        } catch PlaybackFailure.hardwareUnavailable {
            // Unsupported hosts must fail closed; this marker is not playback success.
            print("HEVC_HARDWARE_UNAVAILABLE start=\(start): no software fallback")
        }
        #expect(await source.largestRead > 0)
        #expect(await source.largestRead <= 65_536)
    }
}
