import Foundation
import Testing
@testable import VistaCore

@Suite(.serialized) @MainActor struct PrefetchWake128Tests {
    enum SyntheticError: Error { case failed }
    @MainActor final class Source: PlaybackCacheSource {
        let bytes = Data((0..<256).map { UInt8($0) })
        var stopped = false
        var gate: CheckedContinuation<Void, Never>?
        var blocked = false, fail = false
        var calls = 0, active = 0, maximum = 0
        var isPlaybackRecovering: Bool { false }
        var recoveryActiveStartedAt: TimeInterval? { nil }
        var recoveryActiveElapsed: TimeInterval { 0 }
        func playbackCacheEpoch() throws -> UInt64? { stopped ? nil : 1 }
        func fileSize(for file: MediaFile) async throws -> UInt64 { 256 }
        func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        func readForPrefetch(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
            calls += 1; active += 1; maximum = max(maximum, active)
            defer { active -= 1 }
            if blocked { await withCheckedContinuation { gate = $0 } }
            if fail { throw SyntheticError.failed }
            return try await read(file, range: range)
        }
        func setPlaybackSceneActive(_ active: Bool) {}
        func cancelPlayback() { stopped = true }
        func awaitPlaybackCleanup() async throws {}
        func release() { let held = gate; gate = nil; held?.resume() }
    }
    let file = try! MediaFile(components: ["generated.mp4"])
    func make(_ base: Source) -> PlaybackPrefetchSource {
        .init(file: file, source: base, configuration: .init(capacityBytes: 16, chunkBytes: 8, totalCapacityBytes: 128))
    }
    func until(_ condition: () -> Bool) async {
        for _ in 0..<100_000 { if condition() { return }; await Task.yield() }
        Issue.record("bounded synthetic wait expired")
    }
    func prime(_ w: PlaybackPrefetchSource) async throws {
        _ = try await w.fileSize(for: file); w.setPrefetchEnabled(false, reason: .pause)
        _ = try await w.read(file, range: 0..<8); _ = try await w.read(file, range: 8..<16)
        await until { w.recoveryActivity.busy == 0 }
    }
    @Test func fullCacheMarkersAfterPrefetchError() async throws {
        let b = Source(), w: PlaybackPrefetchSource
        w = make(b); try await prime(w)
        b.blocked = true; b.fail = true
        w.setPrefetchEnabled(true)
        await until { b.gate != nil }
        _ = try await w.read(file, range: 0..<8); _ = try await w.read(file, range: 8..<16)
        #expect(w.metrics.pendingCacheCompletions == 2)
        b.blocked = false; b.release()
        await until { w.recoveryActivity.busy == 0 }
        let f = w.rangeDiagnosticSnapshot().forward
        print("PREFETCH_ERROR calls=\(b.calls) cursor=\(String(describing: f.cursor)) markers=\(w.metrics.pendingCacheCompletions) maximum=\(b.maximum)")
        #expect(w.metrics.pendingCacheCompletions == 0 && f.cursor == nil && b.maximum == 1 && b.calls == 2)
        try await w.awaitPlaybackCleanup()
    }
    func holdMainActor(milliseconds: Int) {
        let end = ProcessInfo.processInfo.systemUptime + Double(milliseconds) / 1000
        while ProcessInfo.processInfo.systemUptime < end {}
    }
    @Test func cacheArrivalAfterGraceTimerBeforePumpResume() async throws {
        var orphaned = 0
        for _ in 0..<1 {
            let b = Source(), w: PlaybackPrefetchSource
            w = make(b); try await prime(w)
            w.setPrefetchEnabled(true)
            await until { w.recoveryActivity.busy & 16 != 0 }
            try await Task.sleep(for: .microseconds(500))
            holdMainActor(milliseconds: 5)
            _ = try await w.read(file, range: 0..<8)
            await until { w.recoveryActivity.busy == 0 }
            if w.metrics.pendingCacheCompletions > 0 {
                orphaned += 1
                let f = w.rangeDiagnosticSnapshot().forward
                print("GRACE_RACE calls=\(b.calls) enabled=\(f.enabled) cursor=\(String(describing: f.cursor)) target=\(String(describing: f.target)) reason=\(f.reason) reads=\(f.reads) markers=\(w.metrics.pendingCacheCompletions)")
            }
            #expect(w.metrics.pendingCacheCompletions == 0 && b.calls == 2 && b.maximum == 1)
            try await w.awaitPlaybackCleanup()
        }
        print("GRACE_RACE orphaned=\(orphaned)/1")
        #expect(orphaned == 0)
    }
}
