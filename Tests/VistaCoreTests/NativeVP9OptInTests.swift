import Foundation
import Testing
import CoreVideo
@testable import VistaCore
@testable import VistaMedia

private actor NativeVP9MemorySource: MediaByteSource {
    let data: Data
    var sizeCalls = 0
    var reads = 0
    var maximumRange: UInt64 = 0

    init(_ name: String) throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "mp4"))
        data = try Data(contentsOf: url)
    }

    func fileSize(for file: MediaFile) async throws -> UInt64 {
        sizeCalls += 1
        return UInt64(data.count)
    }

    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        try Task.checkCancellation()
        guard range.upperBound <= data.count else { throw MediaInspectionError.invalidResponse }
        reads += 1
        maximumRange = max(maximumRange, range.upperBound - range.lowerBound)
        return Data(data[Int(range.lowerBound)..<Int(range.upperBound)])
    }

    func counters() -> (Int, Int, UInt64) { (sizeCalls, reads, maximumRange) }
}

@Suite(.serialized)
struct NativeVP9OptInTests {
    @Test @MainActor func registrationAvailabilityIsNotPlaybackCapability() {
        #if os(visionOS)
        if #available(visionOS 26.2, *) {
            #expect(NativeSupplementalVideoDecoders.vp9RegistrationRequested)
        } else {
            #expect(!NativeSupplementalVideoDecoders.vp9RegistrationRequested)
        }
        #elseif os(macOS)
        #expect(NativeSupplementalVideoDecoders.vp9RegistrationRequested)
        #endif
        #expect(NativePlaybackSession().decoderDescription == "解碼方式：系統管理（未知）")
    }

    // These are Mac executions of the real NativePlaybackSession/ResourceBridge seam.
    // They do not claim visionOS runtime, real SMB, audible sync, or hardware decoding.
    #if os(macOS)
    @Test @MainActor func vp9WithAACStartsSeeksStopsAndReopens() async throws {
        let session = NativePlaybackSession(stallLimit: 5, muted: true)
        for cycle in 0..<2 {
            let source = try NativeVP9MemorySource("NativeVP9AV")
            var frames: [Double] = []
            var infoSeen = false
            let playback = Task {
                try await session.play(file: MediaFile(components: ["synthetic.mp4"]), source: source,
                    onInfo: { info in
                        #expect(info.codec == "vp09")
                        #expect(info.width == 640 && info.height == 360 && info.hasAudio)
                        infoSeen = true
                    }, onState: { _ in }, onFrame: { frame in
                        #expect(CVPixelBufferGetWidth(frame.pixel) == 640)
                        #expect(CVPixelBufferGetHeight(frame.pixel) == 360)
                        frames.append(frame.time)
                    })
            }
            do {
                let firstDeadline = ContinuousClock.now.advanced(by: .seconds(8))
                while frames.count < 3 && ContinuousClock.now < firstDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(infoSeen && frames.count >= 3)
                session.pause()
                let pausedFrames = frames.count
                try await Task.sleep(for: .milliseconds(80))
                #expect(frames.count == pausedFrames)
                try await session.seek(to: 2, maximumBackward: 0, maximumForward: 0)
                let seekStart = frames.count
                session.resume()
                let seekDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                while frames.count < seekStart + 3 && ContinuousClock.now < seekDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(frames.count >= seekStart + 3)
                #expect(frames[seekStart] >= 2 && frames[seekStart] < 2.2)
                #expect(session.decoderDescription == "解碼方式：系統管理（未知）")
                session.stop()
                await #expect(throws: CancellationError.self) { try await playback.value }
                let stoppedCount = frames.count
                try await Task.sleep(for: .milliseconds(80))
                #expect(frames.count == stoppedCount)
                let counters = await source.counters()
                #expect(counters.1 > 0 && counters.2 <= MediaReadPlan.nativeChunkBytes)
                print("NATIVE_VP9_CANDIDATE", "cycle", cycle, "frames", frames.count,
                      "seekFirstPTS", frames[seekStart], "reads", counters.1,
                      "maxRange", counters.2, "decoder", "unknown", "realSMB", false)
            } catch {
                session.stop()
                playback.cancel()
                _ = try? await playback.value
                throw error
            }
        }
    }

    @Test(arguments: ["SyntheticSeek", "SyntheticHEVC"])
    @MainActor func existingCodecsStillProduceFrames(resource: String) async throws {
        let source = try NativeVP9MemorySource(resource)
        let session = NativePlaybackSession(stallLimit: 5, muted: true)
        var count = 0
        let playback = Task {
            try await session.play(file: MediaFile(components: ["synthetic.mp4"]), source: source,
                onInfo: { _ in }, onState: { _ in }, onFrame: { _ in
                    count += 1
                    if count == 3 { session.stop() }
                })
        }
        await #expect(throws: CancellationError.self) { try await playback.value }
        #expect(count == 3)
        print("NATIVE_VP9_EXISTING_CODEC", resource, "frames", count, "decoder", "unknown")
    }
    #endif

    @Test @MainActor func mkvStillRejectedBeforeSourceRead() async throws {
        let source = try NativeVP9MemorySource("NativeVP9AV")
        let session = NativePlaybackSession(muted: true)
        await #expect(throws: NativePlaybackSession.Failure.unsupported) {
            try await session.play(file: MediaFile(components: ["unsupported.mkv"]), source: source,
                onInfo: { _ in Issue.record("Unexpected MKV metadata") },
                onState: { _ in }, onFrame: { _ in Issue.record("Unexpected MKV frame") })
        }
        let counters = await source.counters()
        #expect(counters.0 == 0 && counters.1 == 0)
    }
}
