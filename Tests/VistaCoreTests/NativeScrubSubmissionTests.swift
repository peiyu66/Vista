import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

private struct ScrubSyntheticSource: MediaByteSource {
    let data: Data
    func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(data.count) }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        try Task.checkCancellation()
        return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
}

/// Shares the ordinary PlaybackView's actual synchronous submission seam. The
/// live Controller, Native seek supersession, and critical boundary records are
/// exercised; this is still not a SwiftUI gesture or visionOS UI test.
@Suite(.serialized) @MainActor struct NativeScrubControllerSubmissionTests {
    @Test(arguments: [false, true])
    func ordinarySliderPreservesRealSecondSeekWhilePreparing(paused: Bool) async throws {
        let source = ScrubSyntheticSource(data: try Data(contentsOf: Bundle.module.url(forResource: "SyntheticHEVC", withExtension: "mp4")!))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VistaScrubController-" + UUID().uuidString)
        let diagnostics = LifecycleDiagnostics(directory: directory, build: "seek-r2", mirror: false)
        let player = PlaybackController(engine: HardwarePlayback(muteAudioForTesting: true), diagnostics: diagnostics)
        defer { player.stop(); try? FileManager.default.removeItem(at: directory) }
        player.play(file: try MediaFile(components: ["generated-silent-scrub.mp4"]), source: source)
        try await wait { player.isPlaying && !player.isPreparing && player.pixelFrame != nil }
        #expect(player.trackInfo?.hasAudio == false)
        if paused { player.togglePause() }
        let owner = player.playbackGeneration
        var edit = PlaybackScrubInteraction()
        let before = try seekSubmissions(directory)
        edit.begin(owner: owner, position: player.position)
        let noChange = edit.finish(owner: owner) { target in player.seek(to: target) }
        let afterNoChange = try seekSubmissions(directory)
        #expect(!noChange && afterNoChange == before)
        #expect(player.isPaused == paused && !player.isPreparing)

        player.seek(to: 0.25)
        #expect(player.isPreparing)
        let first = try seekSubmissions(directory)
        #expect(first == before + 1)

        // No-change release while the first seek is pending must remain a no-op.
        edit.begin(owner: owner, position: player.position)
        let pendingNoChange = edit.finish(owner: owner) { target in player.seek(to: target) }
        let afterPendingNoChange = try seekSubmissions(directory)
        #expect(!pendingNoChange && afterPendingNoChange == first)
        #expect(player.isPreparing)

        // This is the same finish(submit:) called unconditionally by PlaybackView.
        // A preparing guard here would reproduce the rejected R1 behavior.
        edit.update(1.75, owner: owner, initialPosition: player.position)
        let changed = edit.finish(owner: owner) { target in player.seek(to: target) }
        let afterChanged = try seekSubmissions(directory)
        #expect(changed && afterChanged == first + 1)
        #expect(player.playbackGeneration == owner)
        try await wait { !player.isPreparing && player.position >= 0.75 }
        #expect(player.isPaused == paused)
        #expect(!edit.isActive)
        print("SCRUB_CONTROLLER_R2", "paused", paused, "firstPreparing", true,
              "acceptedSeekSubmissions", try seekSubmissions(directory) - before)
    }

    private func seekSubmissions(_ directory: URL) throws -> Int {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var count = 0
        for file in files where file.lastPathComponent.hasPrefix("critical-") && file.pathExtension == "jsonl" {
            for line in try Data(contentsOf: file).split(separator: 10) {
                let record = try JSONDecoder().decode(LifecycleRecord.self, from: Data(line))
                if record.event == .playbackBoundary, record.fields["scope"] == 2,
                   record.fields["phase"] == Double(PlaybackBoundaryStage.submitEntered.rawValue),
                   record.fields["cause"] == 2 { count += 1 }
            }
        }
        return count
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}

/// Exercises the submission model with a real muted Mac AVPlayer, not a SwiftUI
/// gesture or visionOS presentation test. No SMB, private media, or devices.
@Suite(.serialized) @MainActor struct NativeScrubSubmissionTests {
    @Test(arguments: [false, true])
    func unchangedEditPreservesPlaybackAndChangedEditStillSeeks(paused: Bool) async throws {
        let source = ScrubSyntheticSource(data: try Data(contentsOf: Bundle.module.url(forResource: "SyntheticSeek", withExtension: "mp4")!))
        let session = NativePlaybackSession(stallLimit: 5, muted: true)
        var frames = 0, position = 0.0
        let task = Task {
            try await session.play(file: MediaFile(components: ["generated-scrub.mp4"]), source: source,
                onInfo: { _ in }, onState: { _ in }, onFrame: { frame in
                    frames += 1; position = frame.time
                    if frames == 1, paused { session.pause() }
                })
        }
        do {
            try await wait { frames > 0 }
            let owner = UUID(), epoch = session.requestMetrics.epoch
            var edit = PlaybackScrubInteraction()
            edit.begin(owner: owner, position: position)
            if let target = edit.finish(owner: owner) { try await session.seek(to: target) }
            #expect(session.requestMetrics.epoch == epoch)
            #expect(session.isPlaybackPaused == paused)
            let before = session.experimentPlayerTime ?? -1
            if paused {
                try await Task.sleep(for: .milliseconds(100))
                #expect(abs((session.experimentPlayerTime ?? -2) - before) < 0.03)
            } else {
                try await wait { (session.experimentPlayerTime ?? -1) > before + 0.05 }
            }
            edit.update(2, owner: owner, initialPosition: position)
            let submitted = edit.finish(owner: owner)
            let target = try #require(submitted)
            try await session.seek(to: target, maximumBackward: 0)
            #expect(session.requestMetrics.epoch == epoch + 1)
            #expect(session.requestMetrics.seekSnapshot != nil)
            #expect(session.isPlaybackPaused == paused)
            print("SCRUB_NATIVE", "paused", paused, "noOpEpoch", epoch, "changedEpoch", session.requestMetrics.epoch)
        } catch {
            session.stop(); task.cancel(); _ = try? await task.value
            throw error
        }
        session.stop(); task.cancel(); _ = try? await task.value
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}
