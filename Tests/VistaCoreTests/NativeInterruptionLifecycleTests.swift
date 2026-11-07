import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

#if VISTA_NATIVE_PLAYER_EXPERIMENT
private struct InterruptionFixtureSource:MediaByteSource {
    let data:Data
    func fileSize(for file:MediaFile)async throws->UInt64 {UInt64(data.count)}
    func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data {
        try await Task.sleep(for:.milliseconds(20))
        guard range.upperBound<=UInt64(data.count) else{throw PlaybackFailure.readFailed}
        return data.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))
    }
}
@Suite(.serialized) @MainActor struct NativeInterruptionLifecycleTests {
    private enum Failure:Error {case timeout}
    private func wait(_ check:()->Bool)async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(8))
        while !check() {
            guard ContinuousClock.now<deadline else{throw Failure.timeout}
            try await Task.sleep(for:.milliseconds(5))
        }
    }
    private func source()throws->InterruptionFixtureSource {
        let path=try #require(ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_CONTROLS"])
        return InterruptionFixtureSource(data:try Data(contentsOf:URL(fileURLWithPath:path)))
    }
    @Test func stablePlaybackStaysPausedUntilExplicitResume()async throws {
        let controller=PlaybackController(),source=try source()
        controller.play(file:try MediaFile(components:["synthetic.mp4"]),source:source)
        defer{controller.stop()}
        try await wait{controller.isPlaying && !controller.isPreparing && controller.pixelFrame != nil}
        controller.pauseForBackground()
        try await wait{controller.isPaused && controller.speedStatus.effectiveRate==0}
        let session=try #require(controller.pixelFrame).session
        let position=controller.position
        controller.pauseForBackground()
        try await Task.sleep(for:.milliseconds(250))
        #expect(controller.isPlaying && controller.isPaused && controller.speedStatus.effectiveRate==0)
        #expect(controller.pixelFrame?.session==session && abs(controller.position-position)<0.05)
        controller.togglePause()
        try await wait{!controller.isPaused && controller.position>position+0.05}
        #expect(controller.pixelFrame?.session==session)
    }
    @Test func interruptionDuringInitialPreparationStopsWithoutLateFrame()async throws {
        let controller=PlaybackController(),source=try source()
        controller.play(file:try MediaFile(components:["synthetic.mp4"]),source:source)
        defer{controller.stop()}
        #expect(controller.isPlaying && controller.isPreparing && !controller.isPaused)
        controller.pauseForBackground()
        #expect(!controller.isPlaying && !controller.isPreparing && controller.pixelFrame==nil)
        try await Task.sleep(for:.milliseconds(200))
        #expect(!controller.isPlaying && !controller.isPreparing && controller.pixelFrame==nil)
        controller.pauseForBackground()
        #expect(!controller.isPlaying)
    }
    @Test func backgroundDuringSeekStopsAndAllowsNewPlayback()async throws {
        let source=try source(),controller=PlaybackController()
        let file=try MediaFile(components:["synthetic.mp4"])
        controller.play(file:file,source:source);defer{controller.stop()}
        try await wait{controller.isPlaying && !controller.isPreparing}
        controller.seek(to:60);#expect(controller.isPreparing)
        controller.pauseForBackground()
        #expect(!controller.isPlaying && !controller.isPreparing)
        try await Task.sleep(for:.milliseconds(150))
        #expect(!controller.isPlaying && controller.pixelFrame==nil)
        controller.play(file:file,source:source)
        try await wait{controller.isPlaying && !controller.isPreparing && controller.pixelFrame != nil}
        #expect(controller.position<1)
    }
}
#endif
