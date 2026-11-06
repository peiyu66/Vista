import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

private actor SyntheticRangeSource: MediaByteSource {
    var largestRead = 0
    var reads = 0
    let broken: Bool
    init(broken: Bool = false) { self.broken = broken }
    func fileSize(for file: MediaFile) async throws -> UInt64 { try await DemoMediaSource().fileSize(for: file) }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        reads += 1; largestRead = max(largestRead, Int(range.count))
        return broken ? Data() : try await DemoMediaSource().read(file, range: range)
    }
}
@MainActor private final class PlaybackCancellation {
    var task: Task<PlaybackReport, Error>?
    var frames = 0
}
struct HardwarePlaybackTests {
    @Test @MainActor func cancellationAfterFirstFrameStopsPlayback() async throws {
        let control = PlaybackCancellation()
        let file = try MediaFile(components: ["synthetic.mp4"])
        let task = Task {
            try await HardwarePlayback().play(file: file, source: DemoMediaSource(), onInfo: { _ in }, onFrame: { _ in
                control.frames += 1
                control.task?.cancel()
            })
        }
        control.task = task
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { #expect(control.frames == 1); print("SYNTHETIC_CANCELLED_AFTER_FRAMES", control.frames) }
        catch let failure as PlaybackFailure where failure.category == .hardwareUnavailable { #expect(control.frames == 0); print("SYNTHETIC_CANCEL_HARDWARE_UNAVAILABLE") }
        control.task = nil
    }

    @Test func syntheticMovieUsesVerifiedHardwareOrFailsClosed() async throws {
        let source = SyntheticRangeSource()
        let file = try MediaFile(components: ["synthetic.mp4"])
        do {
            let report = try await HardwarePlayback().play(file: file, source: source, onInfo: { info in
                #expect(info.codec == "H.264"); #expect(info.width == 64); #expect(info.height == 64)
            }, onFrame: { frame in #expect(frame.image.width == 64) })
            #expect(report.hardwareVerified)
            #expect(report.decodedFrames == 24)
            print("SYNTHETIC_HARDWARE_FRAMES", report.decodedFrames)
        } catch let failure as PlaybackFailure where failure.category == .hardwareUnavailable {
            print("SYNTHETIC_HARDWARE_UNAVAILABLE: no software fallback")
        }
        #expect(await source.reads > 0)
        #expect(await source.largestRead <= 65_536)
    }
    @Test func unsupportedContainerDoesNotReadSource() async throws {
        let source = SyntheticRangeSource()
        await #expect(throws: PlaybackFailure.unsupportedContainer) {
            try await HardwarePlayback().play(file: MediaFile(components: ["unsupported.mkv"]), source: source, onInfo: { _ in }, onFrame: { _ in })
        }
        #expect(await source.reads == 0)
    }
    @Test func truncatedRangeFailsWithoutDrawing() async throws {
        await #expect(throws: PlaybackFailure.readFailed) {
            try await HardwarePlayback().play(file: MediaFile(components: ["broken.mp4"]), source: SyntheticRangeSource(broken: true), onInfo: { _ in }, onFrame: { _ in Issue.record("Unexpected frame") })
        }
    }
}
