import Foundation
import AVFoundation
import VideoToolbox
import Testing
@testable import VistaCore
@testable import VistaMedia

private actor VP9RangeSource: MediaByteSource {
    let data: Data
    init() throws { data = try Data(contentsOf: Bundle.module.url(forResource: "SyntheticVP9", withExtension: "mp4")!) }
    func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(data.count) }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        guard range.upperBound <= data.count else { throw PlaybackFailure.readFailed }
        return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
}

@MainActor private final class VP9Observation { var frames = 0; var recognized = false }

struct VP9CapabilityTests {
    @Test @MainActor func syntheticVP9RequiresActualHardware() async throws {
        let observed = VP9Observation()
        print("VP9_HARDWARE_CAPABILITY", VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9))
        do {
            let report = try await HardwarePlayback().play(
                file: MediaFile(components: ["synthetic.mp4"]), source: VP9RangeSource(),
                onInfo: { info in
                    #expect(info.codec == "VP9")
                    observed.recognized = info.codec == "VP9"
                    #expect(info.width == 64 && info.height == 64)
                }, onFrame: { frame in observed.frames += 1; #expect(frame.image.width == 64) })
            #expect(report.hardwareVerified)
            #expect(report.decodedFrames == 24)
            print("VP9_ACTUAL_HARDWARE_VERIFIED", report.decodedFrames)
        } catch let failure as PlaybackFailure where failure.category == .hardwareUnavailable {
            #expect(observed.frames == 0)
            #expect(observed.recognized)
            print("VP9_HARDWARE_UNAVAILABLE: no software fallback")
        } catch let failure as PlaybackFailure where failure.category == .readFailed {
            #expect(observed.frames == 0)
            print("VP9_SYSTEM_CONTAINER_UNAVAILABLE: no decoder fallback")
        }
    }

    // Diagnostic probe: OS capabilities may change. Passing this test does not mean MKV playback works.
    @Test func nativeMKVContainerProbeDoesNotDecode() async throws {
        let url = try #require(Bundle.module.url(forResource: "SyntheticVP9", withExtension: "mkv"))
        let asset = AVURLAsset(url: url)
        defer { asset.cancelLoading() }
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            print("MKV_NATIVE_VIDEO_TRACKS", tracks.count)
            if let track = tracks.first {
                let reader = try AVAssetReader(asset: asset)
                defer { reader.cancelReading() }
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                guard reader.canAdd(output) else { print("MKV_NATIVE_COMPRESSED_OUTPUT_UNAVAILABLE"); return }
                reader.add(output)
                guard reader.startReading() else { print("MKV_NATIVE_READER_UNAVAILABLE"); return }
                print("MKV_NATIVE_COMPRESSED_SAMPLE", output.copyNextSampleBuffer() != nil)
            }
        } catch {
            // Only public framework error domain/code; no URLs or userInfo.
            let error = error as NSError
            print("MKV_NATIVE_UNAVAILABLE", error.domain, error.code)
        }
    }
}
