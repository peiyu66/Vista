import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

#if VISTA_NATIVE_PLAYER_EXPERIMENT
/// Only generated local media and deterministic renderer I/O. No SMB or physical-device actions.
private struct BoundaryControllerSource:MediaByteSource {
    let data:Data
    var fails=false
    func fileSize(for file:MediaFile)async throws->UInt64 {
        if fails {throw NSError(domain:"PRIVATE_SOURCE_IDENTIFIER",code:987,userInfo:[NSLocalizedDescriptionKey:"PRIVATE_ERROR_DETAIL"])}
        return UInt64(data.count)
    }
    func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data {
        try await Task.sleep(for:.milliseconds(20))
        guard range.upperBound<=UInt64(data.count) else{throw PlaybackFailure.readFailed}
        return data.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))
    }
}

@Suite(.serialized) @MainActor struct PlaybackBoundaryControllerTests {
    private enum Failure:Error {case timeout}
    private func wait(_ check:()->Bool)async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(8))
        while !check() {
            guard ContinuousClock.now<deadline else{throw Failure.timeout}
            try await Task.sleep(for:.milliseconds(5))
        }
    }
    private func source()throws->BoundaryControllerSource {
        let path=try #require(ProcessInfo.processInfo.environment["VISTA_SYNTHETIC_CONTROLS"])
        return BoundaryControllerSource(data:try Data(contentsOf:URL(fileURLWithPath:path)))
    }
    private func directory()->URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("VistaControllerBoundary-"+UUID().uuidString)
    }
    private func controller(_ diagnostics:LifecycleDiagnostics)->PlaybackController {
        PlaybackController(engine:HardwarePlayback(muteAudioForTesting:true),diagnostics:diagnostics)
    }
    /// Intentionally reads the critical copy without draining the ordinary asynchronous writer.
    private func records(_ directory:URL,scope:Double=2)throws->[LifecycleRecord] {
        let files:[URL]=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
        let decoder=JSONDecoder()
        var result:[LifecycleRecord]=[]
        for file in files {
            guard file.lastPathComponent.hasPrefix("critical-"),file.pathExtension=="jsonl" else{continue}
            let data:Data=try Data(contentsOf:file)
            for line in data.split(separator:10) {
                let record:LifecycleRecord=try decoder.decode(LifecycleRecord.self,from:Data(line))
                if record.event == .playbackBoundary,record.fields["scope"]==scope {result.append(record)}
            }
        }
        result.sort{$0.sequence<$1.sequence}
        return result
    }
    private func stage(_ record:LifecycleRecord,_ stage:PlaybackBoundaryStage)->Bool {
        record.fields["phase"]==Double(stage.rawValue)
    }
    private func expectBounded(_ values:[LifecycleRecord]) {
        let windows=Dictionary(grouping:values){[$0.fields["trace"] ?? 0,$0.fields["epoch"] ?? 0]}
        #expect(windows.values.allSatisfy{$0.count<=PlaybackBoundaryTrace.eventLimitPerEpoch})
        #expect(values.allSatisfy{$0.fields.values.allSatisfy(\.isFinite)})
    }

    @Test func idlePauseGuardAndStopAreSynchronousNumericAndBounded()throws {
        let dir=directory();defer{try? FileManager.default.removeItem(at:dir)}
        let diagnostics=LifecycleDiagnostics(directory:dir,build:"65",mirror:false)
        let player=controller(diagnostics),originalGeneration=player.playbackGeneration
        #expect(try records(dir).isEmpty)
        var criticalReadFailure:(any Error)?
        diagnostics.withPausedWriterForTesting {
            do {
                player.pauseForBackground()
                let first=try records(dir)
                #expect(first.count==4)
                #expect(first.contains{stage($0,.pauseEntered)})
                #expect(first.contains{stage($0,.discarded) && $0.fields["outcome"]==1})
                #expect(first.contains{stage($0,.pauseReturned) && $0.fields["outcome"]==1})
                for _ in 0..<100 {player.pauseForBackground()}
                #expect(try records(dir).count==first.count)
            } catch {criticalReadFailure=error}
        }
        if let criticalReadFailure {throw criticalReadFailure}
        #expect(!player.isPlaying && !player.isPaused && !player.isPreparing)
        #expect(player.playbackGeneration==originalGeneration)
        player.stop()
        let stopped=try records(dir)
        let entered=try #require(stopped.last{stage($0,.stopEntered)})
        let returned=try #require(stopped.last{stage($0,.stopReturned)})
        #expect(entered.fields["epoch"]==returned.fields["epoch"])
        #expect(entered.fields["generation"]==0 && returned.fields["generation"]==1)
        #expect(returned.fields["playing"]==0 && returned.fields["preparing"]==0)
        #expect(player.playbackGeneration != originalGeneration)
        let text=String(decoding:try JSONEncoder().encode(stopped),as:UTF8.self)
        #expect(!text.contains(originalGeneration.uuidString) && !text.contains(player.playbackGeneration.uuidString))
        expectBounded(stopped)
        #expect(diagnostics.status.syncFailures==0)
    }

    @Test func preparingBackgroundPreservesOriginalStopAndPairedBoundaries()async throws {
        let dir=directory();defer{try? FileManager.default.removeItem(at:dir)}
        let diagnostics=LifecycleDiagnostics(directory:dir,build:"65",mirror:false)
        let player=controller(diagnostics)
        player.play(file:try MediaFile(components:["synthetic.mp4"]),source:try source())
        #expect(player.isPlaying && player.isPreparing && !player.isPaused)
        player.pauseForBackground()
        #expect(!player.isPlaying && !player.isPreparing && player.pixelFrame==nil)
        let values=try records(dir)
        let pauseIn=try #require(values.first{stage($0,.pauseEntered)})
        let pauseOut=try #require(values.first{stage($0,.pauseReturned)})
        let stopIn=try #require(values.first{stage($0,.stopEntered)})
        let stopOut=try #require(values.first{stage($0,.stopReturned)})
        #expect(pauseIn.fields["preparing"]==1 && pauseIn.fields["playing"]==1)
        #expect(pauseIn.fields["epoch"]==pauseOut.fields["epoch"] && pauseOut.fields["outcome"]==4)
        #expect(stopIn.fields["epoch"]==stopOut.fields["epoch"] && stopIn.fields["preparing"]==1)
        #expect(stopOut.fields["preparing"]==0 && stopOut.fields["frameAvailable"]==0)
        #expect(pauseIn.sequence<stopIn.sequence && stopIn.sequence<stopOut.sequence && stopOut.sequence<pauseOut.sequence)
        try await Task.sleep(for:.milliseconds(200))
        #expect(!player.isPlaying && !player.isPreparing && player.pixelFrame==nil)
        expectBounded(try records(dir))
    }

    @Test func ordinaryFramesDoNotReplenishAndPauseRequiresExplicitResume()async throws {
        let dir=directory();defer{try? FileManager.default.removeItem(at:dir)}
        let diagnostics=LifecycleDiagnostics(directory:dir,build:"65",mirror:false)
        let player=controller(diagnostics)
        player.play(file:try MediaFile(components:["synthetic.mp4"]),source:try source());defer{player.stop()}
        try await wait{player.isPlaying && !player.isPreparing && player.pixelFrame != nil}
        let initial=try records(dir),first=try #require(player.pixelFrame),position=player.position
        let received=try #require(initial.first{stage($0,.frameObserved)})
        let applied=try #require(initial.first{stage($0,.resultEnabled)})
        #expect(received.fields["session"]==Double(PlaybackBoundaryIdentity.session(first.session)))
        #expect(applied.fields["session"]==received.fields["session"] && received.sequence<applied.sequence)
        #expect(received.fields["preparing"]==1 && applied.fields["preparing"]==0 && applied.fields["frameAvailable"]==1)
        try await wait{player.position>position+0.15}
        #expect(try records(dir).count==initial.count)
        player.pauseForBackground()
        try await wait{player.isPaused && player.speedStatus.effectiveRate==0}
        let pausedPosition=player.position
        player.pauseForBackground()
        let duplicateCount=try records(dir).count
        for _ in 0..<50 {player.pauseForBackground()}
        try await Task.sleep(for:.milliseconds(150))
        #expect(try records(dir).count==duplicateCount)
        #expect(player.isPlaying && player.isPaused && abs(player.position-pausedPosition)<0.05)
        let pauses=try records(dir)
        let entered=try #require(pauses.first{stage($0,.pauseEntered) && $0.fields["cause"]==4})
        let returned=try #require(pauses.first{stage($0,.pauseReturned) && $0.fields["epoch"]==entered.fields["epoch"]})
        #expect(entered.fields["paused"]==0 && returned.fields["paused"]==1 && returned.fields["outcome"]==5)
        player.togglePause()
        try await wait{!player.isPaused && player.position>pausedPosition+0.05}
        #expect(player.pixelFrame?.session==first.session)
        let resumed=try records(dir)
        #expect(resumed.contains{stage($0,.upstreamPauseReturned) && $0.fields["outcome"]==6})
        expectBounded(resumed)
    }

    @Test func seekThenBackgroundStillStopsWithoutLateFrameAndCanRestart()async throws {
        let dir=directory();defer{try? FileManager.default.removeItem(at:dir)}
        let diagnostics=LifecycleDiagnostics(directory:dir,build:"65",mirror:false)
        let player=controller(diagnostics),fixture=try source(),file=try MediaFile(components:["synthetic.mp4"])
        player.play(file:file,source:fixture);defer{player.stop()}
        try await wait{player.isPlaying && !player.isPreparing}
        player.seek(to:60)
        #expect(player.isPreparing)
        let seeking=try records(dir)
        #expect(seeking.contains{stage($0,.submitEntered) && $0.fields["cause"]==2})
        player.pauseForBackground()
        #expect(!player.isPlaying && !player.isPreparing && player.pixelFrame==nil)
        try await Task.sleep(for:.milliseconds(150))
        #expect(!player.isPlaying && player.pixelFrame==nil)
        player.play(file:file,source:fixture)
        try await wait{player.isPlaying && !player.isPreparing && player.pixelFrame != nil}
        #expect(player.position<1)
        expectBounded(try records(dir))
    }

    @Test func seekToDurationPreservesStopAndReturnsInOriginalSeekEpoch()async throws {
        let dir=directory();defer{try? FileManager.default.removeItem(at:dir)}
        let diagnostics=LifecycleDiagnostics(directory:dir,build:"65",mirror:false)
        let player=controller(diagnostics)
        player.play(file:try MediaFile(components:["synthetic.mp4"]),source:try source())
        defer{player.stop()}
        try await wait{player.isPlaying && !player.isPreparing && player.pixelFrame != nil}
        let duration=try #require(player.trackInfo).duration
        let beforeGeneration=player.playbackGeneration
        player.seek(to:duration)
        #expect(!player.isPlaying && !player.isPreparing && player.pixelFrame==nil)
        #expect(player.position==duration && player.message=="播放結束")
        #expect(player.playbackGeneration != beforeGeneration)
        let values=try records(dir)
        let entered=try #require(values.first{stage($0,.submitEntered) && $0.fields["cause"]==2})
        let returned=try #require(values.first{stage($0,.submitReturned) && $0.fields["epoch"]==entered.fields["epoch"]})
        let stopped=try #require(values.first{stage($0,.stopReturned) && $0.fields["cause"]==5})
        #expect(returned.fields["cause"]==2 && returned.fields["outcome"]==7)
        #expect(returned.fields["playing"]==0 && returned.fields["preparing"]==0)
        #expect(entered.sequence<stopped.sequence && stopped.sequence<returned.sequence)
        #expect(stopped.fields["epoch"] != entered.fields["epoch"])
        try await Task.sleep(for:.milliseconds(150))
        #expect(!player.isPlaying && player.pixelFrame==nil && player.position==duration)
        expectBounded(try records(dir))
    }

    @Test func fatalSourceFailureRecordsNumericCleanupWithoutChangingOriginalFailureState()async throws {
        let dir=directory();defer{try? FileManager.default.removeItem(at:dir)}
        let diagnostics=LifecycleDiagnostics(directory:dir,build:"65",mirror:false)
        let player=controller(diagnostics)
        player.play(file:try MediaFile(components:["PRIVATE_FILE_IDENTIFIER.mp4"]),source:BoundaryControllerSource(data:Data(),fails:true))
        try await wait{!player.isPlaying && !player.isPreparing}
        let values=try records(dir)
        let failed=try #require(values.first{stage($0,.failure)})
        let stopped=try #require(values.first{stage($0,.stopReturned) && $0.fields["cause"]==7})
        #expect(failed.fields["outcome"]==2 && failed.fields["errorDomain"]==0 && failed.fields["errorCode"]==0)
        #expect(stopped.fields["outcome"]==2 && stopped.fields["playing"]==0 && stopped.fields["preparing"]==0)
        #expect(player.message=="來源讀取失敗，請確認連線後重新播放。")
        #expect(!String(decoding:try JSONEncoder().encode(values),as:UTF8.self).contains("PRIVATE_"))
        expectBounded(values)
    }

    /// Restored Build61 comparison. Local phase/TestIO only, not real scene or audible-output evidence.
    @Test func rendererInactivityAloneDoesNotPauseNativePlaybackButBackgroundStillDoes()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{Issue.record("Recovery comparison requires the current macOS renderer runtime");return}
        let dir=directory();defer{try? FileManager.default.removeItem(at:dir)}
        let diagnostics=LifecycleDiagnostics(directory:dir,build:"65",mirror:false)
        let player=controller(diagnostics),fixture=try source(),presenter=SystemVideoPresenter(diagnostics:diagnostics)
        var pauseRequests=0,enqueued=0
        presenter.testIO = .init(requiresFlush:{false},failed:{false},ready:{true},
            flush:{_ in},flushImmediately:{},enqueue:{_ in enqueued += 1})
        presenter.onRecoverableInterruption = { session in
            guard player.pixelFrame?.session == session else{return false}
            pauseRequests += 1;player.pauseForBackground()
            return player.isPlaying && !player.isPreparing && player.isPaused && player.pixelFrame?.session == session
        }
        player.play(file:try MediaFile(components:["synthetic.mp4"]),source:fixture)
        defer{presenter.stop();player.stop()}
        try await wait{player.isPlaying && !player.isPreparing && player.pixelFrame != nil}
        presenter.submit(try #require(player.pixelFrame),settings:VRSettings())
        try await wait{presenter.ready && !presenter.testWorkerActive}
        let position=player.position
        presenter.setSceneActive(false)
        try await wait{player.position>position+0.1}
        #expect(!player.isPaused && player.speedStatus.effectiveRate>0 && pauseRequests==0)
        presenter.setSceneActive(true)
        presenter.submit(try #require(player.pixelFrame),settings:VRSettings())
        try await wait{presenter.ready && !presenter.testWorkerActive}
        #expect(!player.isPaused && pauseRequests==0 && enqueued>=2)
        presenter.setSceneActive(false)
        player.pauseForBackground()
        try await wait{player.isPaused && player.speedStatus.effectiveRate==0}
        let pausedPosition=player.position
        presenter.setSceneActive(true)
        presenter.submit(try #require(player.pixelFrame),settings:VRSettings())
        try await wait{presenter.ready && !presenter.testWorkerActive}
        try await Task.sleep(for:.milliseconds(250))
        #expect(player.isPlaying && player.isPaused && player.speedStatus.effectiveRate==0)
        #expect(abs(player.position-pausedPosition)<0.05 && pauseRequests==0)
        let controllerSession=try #require(records(dir).first{stage($0,.frameObserved)}?.fields["session"])
        #expect(try records(dir,scope:3).contains{$0.fields["session"]==controllerSession})
        expectBounded(try records(dir))
    }
}
#endif
