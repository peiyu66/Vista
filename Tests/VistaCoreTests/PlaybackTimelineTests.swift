import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

@MainActor private final class PlaybackObservation {
    var frames = 0
    var finished = false
}
struct PlaybackTimelineTests {
    @Test @MainActor func pauseBeforeFirstFrameAndResume() async throws {
        let timeline = PlaybackTimeline()
        let observed = PlaybackObservation()
        timeline.pause()
        let task = Task { try await timeline.present(at: 0) { observed.frames += 1 } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(observed.frames == 0)
        timeline.resume()
        try await task.value
        #expect(observed.frames == 1)
    }
    @Test @MainActor func pausedWallTimeDoesNotAdvancePresentation() async throws {
        let timeline = PlaybackTimeline()
        let observed = PlaybackObservation()
        try await timeline.present(at: 0) { observed.frames += 1 }
        timeline.pause()
        timeline.pause() // Repeated commands must not reset the pause start.
        let task = Task { try await timeline.present(at: 0.15) { observed.frames += 1 } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(observed.frames == 1)
        let resumed = ContinuousClock.now
        timeline.resume()
        timeline.resume()
        try await task.value
        #expect(resumed.duration(to: .now) >= .milliseconds(100))
        #expect(observed.frames == 2)
    }
    @Test @MainActor func pauseDuringScheduledFrameRecalculatesDeadline() async throws {
        let timeline = PlaybackTimeline()
        let observed = PlaybackObservation()
        try await timeline.present(at: 0) { observed.frames += 1 }
        let task = Task { try await timeline.present(at: 0.3) { observed.frames += 1 } }
        try await Task.sleep(for: .milliseconds(40))
        timeline.pause()
        try await Task.sleep(for: .milliseconds(350))
        #expect(observed.frames == 1)
        let resumed = ContinuousClock.now
        timeline.resume()
        try await task.value
        #expect(resumed.duration(to: .now) >= .milliseconds(150))
        #expect(observed.frames == 2)
    }
    @Test @MainActor func cancellationWhilePausedReleasesWaiter() async throws {
        let timeline = PlaybackTimeline()
        let observed = PlaybackObservation()
        timeline.pause()
        let task = Task { try await timeline.present(at: 0) { observed.frames += 1 } }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        timeline.resume()
        try await timeline.present(at: 0) { observed.frames += 1 }
        #expect(observed.frames == 1)
    }
    @Test(arguments: [false, true]) @MainActor
    func hardwarePlaybackCanPauseThenResumeOrCancel(cancel: Bool) async throws {
        let timeline = PlaybackTimeline()
        let observed = PlaybackObservation()
        let file = try MediaFile(components: ["synthetic.mp4"])
        let task = Task {
            defer { observed.finished = true }
            return try await HardwarePlayback().play(file: file, source: DemoMediaSource(), timeline: timeline,
                onInfo: { _ in }, onFrame: { _ in
                    observed.frames += 1
                    if observed.frames == 1 { timeline.pause() }
                })
        }
        while observed.frames == 0 && !observed.finished { try await Task.sleep(for: .milliseconds(5)) }
        if observed.finished {
            do { _ = try await task.value; Issue.record("Expected a paused first frame") }
            catch PlaybackFailure.hardwareUnavailable { print("PAUSE_TEST_HARDWARE_UNAVAILABLE") }
            return
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(observed.frames == 1)
        #expect(timeline.isPaused)
        if cancel {
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(observed.frames == 1)
            print("HARDWARE_CANCELLED_WHILE_PAUSED", observed.frames)
        } else {
            timeline.resume()
            let report = try await task.value
            #expect(report.hardwareVerified)
            #expect(observed.frames == 24)
            print("HARDWARE_PAUSE_RESUME_FRAMES", observed.frames)
        }
    }
}
