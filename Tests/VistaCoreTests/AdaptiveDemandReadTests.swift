import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import VistaCore
@testable import VistaMedia

struct FixedDemandReadPlanTests {
    private let chunk = MediaReadPlan.nativeChunkBytes
    @Test func exactRequestsNeverOverreadToFillOneMiB() throws {
        for length in [0, 2, 65_536, 262_144, 1_048_576, 2_097_152, 2_097_153, 4_194_427] {
            let plan = try MediaReadPlan(requestedOffset: 0, currentOffset: 0, requestedLength: length,
                                        toEnd: false, fileSize: 8_388_608, chunkBytes: chunk)
            let ranges = Array(plan)
            #expect(ranges.reduce(0) { $0 + $1.count } == length)
            #expect(ranges.allSatisfy { $0.count > 0 && $0.count <= Int(chunk) })
            #expect(ranges.last?.upperBound == UInt64(length) || length == 0)
            for i in ranges.indices.dropFirst() { #expect(ranges[i-1].upperBound == ranges[i].lowerBound) }
        }
    }
    @Test func currentOffsetAndEOFClipTheDemandPrecisely() throws {
        let plan = try MediaReadPlan(requestedOffset: 100, currentOffset: 500_000, requestedLength: 3_000_000,
                                    toEnd: false, fileSize: 2_900_123, chunkBytes: chunk)
        #expect(Array(plan) == [500_000..<2_597_152, 2_597_152..<2_900_123])
        let toEnd = try MediaReadPlan(requestedOffset: 0, currentOffset: 1_500_000, requestedLength: 2,
                                     toEnd: true, fileSize: 2_900_123, chunkBytes: chunk)
        #expect(Array(toEnd) == [1_500_000..<2_900_123])
    }
    @Test func patternedBytesRoundTripWithoutGapOverlapOrTrailingRead() throws {
        let data = Data((0..<4_194_427).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        for start in [0, 123, 1_200_000] {
            let plan = try MediaReadPlan(requestedOffset: Int64(start), currentOffset: Int64(start), requestedLength: data.count-start,
                                        toEnd: false, fileSize: UInt64(data.count), chunkBytes: chunk)
            var delivered = Data()
            for range in plan { delivered.append(data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))) }
            #expect(delivered == data.subdata(in: start..<data.count))
        }
    }
    @Test func independentPlansDoNotChangeEachOthersChunkLimit() throws {
        let a = try MediaReadPlan(requestedOffset: 0, currentOffset: 0, requestedLength: 4_194_321,
                                 toEnd: false, fileSize: 9_000_000, chunkBytes: chunk)
        let b = try MediaReadPlan(requestedOffset: 5_000_000, currentOffset: 5_000_000, requestedLength: 3,
                                 toEnd: false, fileSize: 9_000_000, chunkBytes: chunk)
        var iterator = a.makeIterator()
        #expect(iterator.next() == 0..<2_097_152)
        #expect(Array(b) == [5_000_000..<5_000_003])
        #expect(iterator.next() == 2_097_152..<4_194_304)
        #expect(iterator.next() == 4_194_304..<4_194_321)
        #expect(iterator.next() == nil)
    }
    @Test func largeOffsetsRemainBoundedAndInvalidPlansFailClosed() throws {
        let end = UInt64(Int64.max), start = end - chunk - 1
        let plan = try MediaReadPlan(requestedOffset: Int64(start), currentOffset: Int64(start), requestedLength: Int(chunk+1),
                                    toEnd: false, fileSize: end, chunkBytes: chunk)
        #expect(Array(plan) == [start..<(end-1), (end-1)..<end])
        #expect(throws: (any Error).self) { try MediaReadPlan(requestedOffset: -1, currentOffset: 0, requestedLength: 2, toEnd: false, fileSize: 100, chunkBytes: chunk) }
        #expect(throws: (any Error).self) { try MediaReadPlan(requestedOffset: 0, currentOffset: 101, requestedLength: 2, toEnd: false, fileSize: 100, chunkBytes: chunk) }
        #expect(throws: (any Error).self) { try MediaReadPlan(requestedOffset: 0, currentOffset: 0, requestedLength: 2, toEnd: false, fileSize: 100, chunkBytes: chunk+1) }
    }
    @Test func fixedSizeCostModelSeparatesThroughputAndSeekTail() {
        let bytes = 16 * 1_048_576.0
        let smallCalls = bytes / 1_048_576, largeCalls = bytes / Double(chunk)
        let smallTime = smallCalls * 0.008 + bytes / (20 * 1_048_576)
        let largeTime = largeCalls * 0.008 + bytes / (20 * 1_048_576)
        #expect(smallCalls == 16 && largeCalls == 8)
        #expect(abs(smallTime - 0.928) < 0.00001 && abs(largeTime - 0.864) < 0.00001)
        // Worst remaining data time of one already-started non-preemptible read,
        // not a guarantee for total seek latency, network timeouts, or queued work.
        let smallTail = 1_048_576.0 / (2 * 1_048_576), largeTail = Double(chunk) / (2 * 1_048_576)
        #expect(smallTail == 0.5 && largeTail == 1)
        print("FIXED_SERIAL_MODEL bytes", bytes, "baselineReads", smallCalls, "candidateReads", largeCalls,
              "baselineSeconds", smallTime, "candidateSeconds", largeTime,
              "twoMiBpsOldReadDataTailSeconds", largeTail, "realSMB", false)
    }
}

@MainActor private final class FixedNativeFixture: MediaByteSource {
    let data: Data
    var reads = 0, largeReads = 0, maximumReads = 0, returnedBytes = 0
    var activeLength = 0, beganAt = 0.0, activeDuration = 0.0
    var serviceSeconds = 0.0
    var ranges: [Range<UInt64>] = []
    init(_ data: Data) { self.data = data }
    func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(data.count) }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        let start = ProcessInfo.processInfo.systemUptime
        let seconds = 0.008 + Double(range.count) / (20 * 1_048_576)
        activeLength = range.count; beganAt = start; activeDuration = seconds; ranges.append(range)
        defer { activeLength = 0 }
        // A model of non-preemptible current I/O: cancellation cannot shorten the
        // detached delay. No network, SMB handle, or admission stress is involved.
        let delay = Task.detached { try await Task.sleep(for: .seconds(seconds)) }
        try await delay.value
        try Task.checkCancellation()
        let value = data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        reads += 1; returnedBytes += value.count
        if value.count > 262_144 { largeReads += 1 }
        if value.count == Int(MediaReadPlan.nativeChunkBytes) { maximumReads += 1 }
        serviceSeconds += ProcessInfo.processInfo.systemUptime - start
        return value
    }
}

@Suite(.serialized) @MainActor struct NativeFixedDemandReadTests {
    private enum Failure: Error { case timeout, unexpectedRecovery }
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate() {
            guard ContinuousClock.now < end else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION"] != nil,
                   "Requires project-generated noise video, no NAS or physical device"))
    func fixedDemandWaitSeekAndPausedIntentRemainCorrect() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_STARVATION"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        for chunk: UInt64 in [1_048_576, 2_097_152] {
            let memory = FixedNativeFixture(data)
            let file = try MediaFile(components: ["generated.mp4"])
            let identity = PlaybackSourceIdentity(size: UInt64(data.count), modificationDate: Date(timeIntervalSince1970: 100), creationDate: Date(timeIntervalSince1970: 50))
            let recovering = PlaybackRecoveringSource(file: file, initial: memory, metadata: { _, _ in identity },
                makeFresh: { throw Failure.unexpectedRecovery }, retire: { _ in }, shouldRecover: { _ in false }, isCurrent: { true }, diagnostics: nil)
            let source = PlaybackPrefetchSource(file: file, source: recovering)
            let native = NativePlaybackSession(stallLimit: 8, muted: true)
            native.experimentDemandChunkBytes = chunk
            var frames = 0, lastPTS = 0.0
            let started = ProcessInfo.processInfo.systemUptime
            let task = Task { try await native.play(file: file, source: source, onInfo: { _ in }, onState: { _ in }, onFrame: { frame in frames += 1; lastPTS = frame.time }) }
            do {
                try await wait { frames >= 3 && memory.returnedBytes >= 8 * 1_048_576 && memory.activeLength == Int(chunk) }
                let metrics = native.anonymousLogValues()
                #expect(metrics[.currentDemandChunkBytes] == Double(chunk))
                #expect((metrics[.rawMaximumBytes] ?? 0) >= Double(MediaReadPlan.nativeChunkBytes))
                #expect(chunk == MediaReadPlan.nativeChunkBytes ? memory.maximumReads > 0 : memory.maximumReads == 0)
                print("NATIVE_FIXED_AB", chunk, "elapsed", ProcessInfo.processInfo.systemUptime-started,
                      "sourceReads", memory.reads, "sourceBytes", memory.returnedBytes, "sourceServiceSeconds", memory.serviceSeconds,
                      "maximumSourceReads", memory.maximumReads, "rawMaximum", metrics[.rawMaximumBytes] ?? 0)
                // Real AVPlayer seek while a modeled non-preemptible full-size read
                // is in flight. The already-started read is allowed to drain.
                let oldReadRemaining = max(0, memory.activeDuration - (ProcessInfo.processInfo.systemUptime-memory.beganAt))
                let target = 24.0
                let buffered = native.experimentPlayer?.currentItem?.loadedTimeRanges.contains { value in
                    let range = value.timeRangeValue
                    return range.start.seconds <= target && CMTimeRangeGetEnd(range).seconds > target
                } ?? false
                #expect(!buffered)
                let seekStart = ProcessInfo.processInfo.systemUptime
                try await native.seek(to: target, maximumBackward: 0)
                let seekSeconds = ProcessInfo.processInfo.systemUptime-seekStart
                #expect(native.experimentDemandChunkLimit == chunk)
                #expect(!native.isPlaybackPaused)
                let afterSeek = frames; try await wait { frames > afterSeek+2 }
                #expect(lastPTS >= target-0.01)
                let seekToFrames = ProcessInfo.processInfo.systemUptime-seekStart
                print("NATIVE_FIXED_SEEK", chunk, "seekSeconds", seekSeconds, "oldReadRemainingModelSeconds", oldReadRemaining,
                      "seekToFramesSeconds", seekToFrames, "targetWasBuffered", buffered, "framesResumed", true, "realSMB", false)
                let player = try #require(native.experimentPlayer)
                player.pause(); try await wait { native.speedStatus.waiting }
                try await Task.sleep(for: .milliseconds(1200))
                #expect(native.experimentDemandChunkLimit == chunk)
                player.play(); try await wait { !native.speedStatus.waiting }
                #expect(native.setSpeed(2.5)); native.pause()
                try await native.seek(to: 6, maximumBackward: 0)
                try await Task.sleep(for: .milliseconds(100))
                #expect(native.isPlaybackPaused && native.speedStatus.effectiveRate == 0 && native.selectedSpeed == 2.5)
                #expect(native.experimentDemandChunkLimit == chunk)
                source.setPlaybackSceneActive(false); native.setPlaybackSceneActive(false)
                source.setPlaybackSceneActive(true); native.setPlaybackSceneActive(true)
                #expect(native.isPlaybackPaused && native.experimentDemandChunkLimit == chunk)
                let before = frames; native.resume(); try await wait { frames > before+2 }
                source.handleMemoryPressure()
                #expect(native.experimentDemandChunkLimit == chunk)
                #expect(memory.ranges.allSatisfy { $0.count > 0 && $0.count <= Int(chunk) && $0.upperBound <= UInt64(data.count) })
            } catch {
                native.stop(); task.cancel(); _ = try? await task.value; try? await source.awaitPlaybackCleanup(); throw error
            }
            native.stop(); task.cancel(); _ = try? await task.value; try await source.awaitPlaybackCleanup()
        }
    }
}
