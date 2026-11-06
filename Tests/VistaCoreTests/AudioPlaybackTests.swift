import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import VistaCore
@testable import VistaMedia

private struct AudioFixtureSource: MediaByteSource {
    func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(try data().count) }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        let value = try data()
        guard range.upperBound <= value.count, range.count <= 65_536 else { throw MediaInspectionError.unavailable }
        return value.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
    private func data() throws -> Data { try Data(contentsOf: Bundle.module.url(forResource: "SyntheticAV", withExtension: "mp4")!) }
}
@MainActor private final class AudioObservation { var frames = 0; var finished = false; var maximumSkew = 0.0 }
struct AudioPlaybackTests {
    @Test @MainActor func delayedVideoAfterFirstFrameDropsStaleFrameAndRecovers() async throws {
        let asset=AVURLAsset(url:Bundle.module.url(forResource:"SyntheticAV",withExtension:"mp4")!)
        let track=try #require(try await asset.loadTracks(withMediaType:.audio).first)
        let clock=PlaybackAudioClock(muted:true)
        let audio=try AudioPlayback(asset:asset,track:track,clock:clock)
        let timeline=PlaybackTimeline()
        timeline.attachAudio(clock,feed:{try await audio.pump(through:$0)})
        do {
            try await timeline.present(at:0) {}
            try await audio.pump(through:1.5)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while clock.time < 0.75 {
                guard ContinuousClock.now < deadline else { throw PlaybackFailure.audioFailed.diagnosed(.audioClockStalled) }
                try await audio.pump(through: clock.time + 0.5)
                try await Task.sleep(for: .milliseconds(10))
            }
            let displayed = try await timeline.present(at: 0.04) { Issue.record("Obsolete frame must not display") }
            #expect(!displayed)
            #expect(timeline.droppedVideoFrames == 1)
            #expect(try await timeline.skipLateVideoFrame(at: 0.04))
            #expect(timeline.droppedVideoFrames == 2)
            var recovered = false
            let current = clock.time
            let resumed = try await timeline.present(at: current) { recovered = true }
            #expect(resumed && recovered)
            #expect(abs(clock.time - current) < 0.1)
            print("SYNTHETIC_AUDIO_LEAD_RECOVERED_AFTER_FIRST_FRAME")
        } catch {await audio.stop();timeline.detachAudio();throw error}
        await audio.stop();timeline.detachAudio()
    }
    @Test func boundedCatchUpAndDiagnostics() throws {
        var recovery = AudioVideoCatchUp()
        let now = ContinuousClock.now
        #expect(try !recovery.shouldDrop(audio: 10.499, video: 10, now: now))
        #expect(try recovery.shouldDrop(audio: 10.5, video: 10, now: now))
        #expect(try recovery.shouldDrop(audio: 10.4, video: 10, now: now))
        #expect(try !recovery.shouldDrop(audio: 10.09, video: 10, now: now))
        #expect(recovery.consecutiveDrops == 0)
        for _ in 0..<120 { #expect(try recovery.shouldDrop(audio: 11, video: 10, now: now)) }
        #expect(throws: PlaybackFailure.audioFailed.diagnosed(.audioLead, deltaMS: 1000)) {
            try recovery.shouldDrop(audio: 11, video: 10, now: now)
        }
        recovery.reset()
        #expect(try recovery.shouldDrop(audio: 11, video: 10, now: now))
        #expect(throws: PlaybackFailure.audioFailed.diagnosed(.audioLead, deltaMS: 1000)) {
            try recovery.shouldDrop(audio: 11, video: 10, now: now.advanced(by: .seconds(3)))
        }
        #expect(throws: PlaybackFailure.audioFailed.diagnosed(.audioClockInvalid)) {
            try recovery.shouldDrop(audio: .nan, video: 10, now: now)
        }
        #expect(throws: PlaybackFailure.decodeFailed.diagnosed(.videoPTS)) {
            try recovery.shouldDrop(audio: 10, video: .nan, now: now)
        }
        #expect(PlaybackFailure.hardwareUnavailable.diagnosed(.hardwareCheck, status: 0).category == .hardwareUnavailable)
        #expect(PlaybackFailure.decodeFailed.diagnosed(.videoSubmit, status: -12909).message ==
            "影片解碼失敗，已停止播放。\n[videoSubmit code=-12909]")
    }
    @Test func unsupportedAudioLayoutsAreRejected() throws {
        for (channels, rate, accepted): (UInt32, Double, Bool) in [(1, 48_000, true), (2, 44_100, true), (6, 48_000, false), (2, 96_000, false)] {
            var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: channels * 2, mFramesPerPacket: 1, mBytesPerFrame: channels * 2,
                mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
            var format: CMAudioFormatDescription?
            #expect(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0,
                layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr)
            #expect(AudioPlayback.supported(try #require(format)) == accepted)
        }
    }

    @Test @MainActor func audioContinuesAcrossSparseVideoFrames() async throws {
        let asset = AVURLAsset(url: Bundle.module.url(forResource: "SyntheticAV", withExtension: "mp4")!)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let clock = PlaybackAudioClock(muted: true)
        let audio = try AudioPlayback(asset: asset, track: track, clock: clock)
        let timeline = PlaybackTimeline()
        timeline.attachAudio(clock, feed: { try await audio.pump(through: $0) })
        do {
            try await timeline.present(at: 0) {}
            let initial = await audio.sampleCount
            #expect(initial > 0 && initial < 48_000)
            try await timeline.present(at: 2) {}
            #expect(await audio.sampleCount == 96_000)
            #expect(abs(clock.time - 2) < 0.1)
        } catch { await audio.stop(); timeline.detachAudio(); throw error }
        await audio.stop(); timeline.detachAudio()
        #expect(throws: PlaybackFailure.audioFailed.diagnosed(.audioStopped)) { try clock.start() }
    }

    @Test @MainActor func syntheticAACUsesAudioClockAndHardwareVideo() async throws {
        let observed = AudioObservation()
        let timeline = PlaybackTimeline()
        let report = try await HardwarePlayback(muteAudioForTesting: true).play(
            file: MediaFile(components: ["synthetic.mp4"]), source: AudioFixtureSource(), timeline: timeline,
            onInfo: { #expect($0.hasAudio) }, onFrame: { frame in
                observed.frames += 1
                observed.maximumSkew = max(observed.maximumSkew, abs((timeline.audioTime ?? -1) - frame.time))
            })
        #expect(report.hardwareVerified)
        #expect(report.decodedFrames == 24)
        #expect(report.audioSamples >= 96_000)
        #expect(observed.maximumSkew < 0.15)
        print("AAC_HARDWARE_VIDEO", report.decodedFrames, "PCM_SAMPLES", report.audioSamples, "MAX_CALLBACK_CLOCK_SKEW", observed.maximumSkew)
    }
    @Test(arguments: [false, true]) @MainActor func audioClockPausesWithVideoAndCancellationStops(cancel: Bool) async throws {
        let timeline = PlaybackTimeline()
        let observed = AudioObservation()
        let task = Task {
            defer { observed.finished = true }
            return try await HardwarePlayback(muteAudioForTesting: true).play(
                file: MediaFile(components: ["synthetic.mp4"]), source: AudioFixtureSource(), timeline: timeline,
                onInfo: { _ in }, onFrame: { _ in
                    observed.frames += 1
                    if observed.frames == 4 { timeline.pause() }
                })
        }
        while observed.frames < 4 && !observed.finished { try await Task.sleep(for: .milliseconds(5)) }
        if observed.finished { _ = try await task.value; Issue.record("Expected paused playback"); return }
        let pausedTime = try #require(timeline.audioTime)
        try await Task.sleep(for: .milliseconds(200))
        #expect(abs(try #require(timeline.audioTime) - pausedTime) < 0.02)
        #expect(observed.frames == 4)
        if cancel {
            timeline.stopAudio()
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(observed.frames == 4)
        } else {
            timeline.resume()
            let report = try await task.value
            #expect(report.decodedFrames == 24)
            #expect(report.audioSamples == 96_000)
        }
    }
}
