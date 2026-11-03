import Foundation
import Testing
import CoreGraphics
@testable import VistaCore
@testable import VistaMedia

@MainActor private final class SeekFrames { var times: [Double] = []; var pixels: [Double: Data] = [:] }
struct SeekTests {
    @Test(arguments: [1.1, 1.99]) @MainActor func seekStartsAtRequestedPosition(target: Double) async throws {
        let frames = SeekFrames()
        let result = try await HardwarePlayback(muteAudioForTesting: true).play(
            file: MediaFile(components: ["synthetic.mp4"]), source: DemoMediaSource(), startAt: target,
            onInfo: { _ in }, onFrame: { frames.times.append($0.time) })
        #expect(result.hardwareVerified)
        #expect(!frames.times.isEmpty)
        #expect(frames.times.allSatisfy { $0 >= target })
        #expect(result.prerollFrames > 0)
        print("SEEK", target, "FIRST", frames.times.first!, "PREROLL", result.prerollFrames, "START", result.decodingStartTime)
    }
}

private actor SeekFixtureSource: MediaByteSource {
    private let data: Data
    private var gate: CheckedContinuation<Void, Never>?
    private var shouldBlock = false
    private(set) var isBlocked = false
    private(set) var sizeCalls = 0
    init() throws { data = try Data(contentsOf: Bundle.module.url(forResource: "SyntheticSeek", withExtension: "mp4")!) }
    func armGate() { shouldBlock = true }
    func release() { gate?.resume(); gate = nil; isBlocked = false }
    func fileSize(for file: MediaFile) async throws -> UInt64 {
        sizeCalls += 1
        return UInt64(data.count)
    }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        if shouldBlock {
            shouldBlock = false; isBlocked = true
            await withCheckedContinuation { gate = $0 }
        }
        guard range.upperBound <= data.count, range.count <= 65_536 else { throw MediaInspectionError.unavailable }
        return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
}
private enum SeekTestFailure: Error { case timeout }
@MainActor private func waitFor(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw SeekTestFailure.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}
struct SeekControllerTests {
    @Test @MainActor func pausedSeekIntoFinalSilentFrameStaysPaused() async throws {
        let controller = PlaybackController(engine: HardwarePlayback(muteAudioForTesting: true))
        controller.play(file: try MediaFile(components: ["synthetic.mp4"]), source: DemoMediaSource())
        defer { controller.stop() }
        try await waitFor { !controller.isPreparing }
        controller.togglePause()
        controller.seek(to: 1.99)
        try await waitFor { !controller.isPreparing }
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.frame != nil)
        #expect(controller.isPaused && controller.isPlaying)
        #expect(controller.position == 1.99)
        controller.togglePause()
        try await waitFor { !controller.isPlaying }
        #expect(controller.message == "播放結束")
    }

    @Test @MainActor func seekPixelsMatchContinuousHardwareDecode() async throws {
        let reference = SeekFrames()
        let engine = HardwarePlayback(muteAudioForTesting: true)
        _ = try await engine.play(file: MediaFile(components: ["synthetic.mp4"]), source: DemoMediaSource(),
            onInfo: { _ in }, onFrame: { frame in
                reference.pixels[frame.time] = frame.image.dataProvider?.data as Data?
            })
        let lastTime = try #require(reference.pixels.keys.max())
        for target in [1.1, 1.99] {
            _ = try await engine.play(file: MediaFile(components: ["synthetic.mp4"]), source: DemoMediaSource(), startAt: target,
                onInfo: { _ in }, onFrame: { frame in
                    let expected = reference.pixels[frame.time] ?? reference.pixels[lastTime]
                    #expect(frame.image.dataProvider?.data as Data? == expected)
                })
        }
    }
    @Test @MainActor func indexedSeekPrerollsFromLaterSyncFrameWithAudio() async throws {
        let frames = SeekFrames()
        let result = try await HardwarePlayback(muteAudioForTesting: true).play(
            file: MediaFile(components: ["synthetic.mp4"]), source: SeekFixtureSource(), startAt: 4.2,
            onInfo: { #expect($0.hasAudio) }, onFrame: { frames.times.append($0.time) })
        #expect(result.hardwareVerified)
        #expect(result.decodingStartTime > 3)
        #expect(result.decodingStartTime <= 4.2)
        #expect(result.prerollFrames > 0)
        #expect(frames.times.allSatisfy { $0 >= 4.2 })
        #expect((85_000...88_000).contains(result.audioSamples))
        print("INDEXED_SEEK_START", result.decodingStartTime, "PREROLL", result.prerollFrames, "AUDIO", result.audioSamples)
    }
    @Test @MainActor func pausedSeekKeepsPreviewAndResumes() async throws {
        let controller = PlaybackController(engine: HardwarePlayback(muteAudioForTesting: true))
        controller.play(file: try MediaFile(components: ["synthetic.mp4"]), source: try SeekFixtureSource())
        defer { controller.stop() }
        try await waitFor { !controller.isPreparing }
        #expect(controller.frame != nil)
        controller.togglePause()
        controller.seek(to: 4.2)
        try await waitFor { !controller.isPreparing }
        #expect(controller.frame != nil)
        #expect(controller.isPaused)
        let time = controller.position
        #expect(time >= 4.2)
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.position == time)
        controller.togglePause()
        try await waitFor { controller.position > time || !controller.isPlaying }
        #expect(controller.position > time)
        controller.skip(by: 10)
        #expect(!controller.isPlaying)
        #expect(controller.position == controller.trackInfo?.duration)
        controller.skip(by: -10)
        try await waitFor { !controller.isPreparing }
        #expect(controller.frame != nil)
        #expect(controller.position < 1)
    }
    @Test @MainActor func rapidReplacementWaitsForOldIOAndOnlyLatestWins() async throws {
        let source = try SeekFixtureSource()
        let controller = PlaybackController(engine: HardwarePlayback(muteAudioForTesting: true))
        controller.play(file: try MediaFile(components: ["synthetic.mp4"]), source: source)
        defer { controller.stop() }
        try await waitFor { !controller.isPreparing }
        controller.togglePause()
        await source.armGate()
        controller.seek(to: 4.2)
        try await waitFor { await source.isBlocked }
        let calls = await source.sizeCalls
        controller.seek(to: 1.1)
        controller.seek(to: 3.2)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await source.sizeCalls == calls)
        #expect(controller.position == 3.2)
        #expect(controller.frame == nil)
        await source.release()
        try await waitFor { !controller.isPreparing }
        #expect(controller.isPaused)
        #expect(controller.frame != nil)
        #expect((3.2...3.4).contains(controller.position))
        #expect(await source.sizeCalls == calls + 1)
    }
    @Test func invalidSeekDoesNotReadMedia() async throws {
        let source = try SeekFixtureSource()
        for target in [-1.0, Double.nan, .infinity] {
            await #expect(throws: PlaybackFailure.seekUnavailable) {
                try await HardwarePlayback().play(file: MediaFile(components: ["synthetic.mp4"]), source: source,
                    startAt: target, onInfo: { _ in }, onFrame: { _ in Issue.record("Unexpected frame") })
            }
        }
        #expect(await source.sizeCalls == 0)
    }
}
