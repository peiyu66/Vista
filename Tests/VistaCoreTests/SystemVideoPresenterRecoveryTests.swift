import Foundation
import Testing
import AVFoundation
import CoreVideo
@testable import VistaCore
@testable import VistaMedia

/// No network, decoder, physical device, or GPU presentation. These controls exercise
/// the production presenter's real async worker through its Debug-only renderer seam.
@available(macOS 15.0,visionOS 2.0,*)
@MainActor private final class ControlledRenderer {
    let diagnosticDirectory=FileManager.default.temporaryDirectory.appendingPathComponent("VistaPresenterTrace-"+UUID().uuidString)
    lazy var diagnostics=LifecycleDiagnostics(directory:diagnosticDirectory,build:"65",fileLimit:1_048_576,
                                               mirror:false,criticalFileLimit:1_048_576)
    var requiresReads=0,failedReads=0,readyReads=0,immediateFlushes=0
    var requiresFlush=false,failed=false,ready=true,holdFlushes=false,keepFailureAfterFlush=false
    var flushes=0,inFlight=0,maxInFlight=0,enqueuedTimes:[Double]=[]
    var enqueuedPacking:[String?]=[]
    var enqueuedDuringFlush=false
    var onEnqueue:(()->Void)?
    var removeImageFlags:[Bool]=[]
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    var io:SystemVideoPresenter.TestIO {
        .init(requiresFlush:{self.requiresReads += 1;return self.requiresFlush},
              failed:{self.failedReads += 1;return self.failed},ready:{self.readyReads += 1;return self.ready},
              flush:{removing in await self.flush(removing)},flushImmediately:{self.immediateFlushes += 1;self.clearFailure()},
              enqueue:{sample in
                  self.onEnqueue?()
                  self.enqueuedDuringFlush = self.enqueuedDuringFlush || self.inFlight>0
                  self.enqueuedTimes.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                  self.enqueuedPacking.append(CMSampleBufferGetFormatDescription(sample).flatMap {
                      CMFormatDescriptionGetExtension($0,extensionKey:kCMFormatDescriptionExtension_ViewPackingKind) as? String
                  })
              })
    }
    private func clearFailure(){if !keepFailureAfterFlush {requiresFlush=false;failed=false}}
    private func flush(_ removing:Bool)async {
        flushes += 1;inFlight += 1;maxInFlight=max(maxInFlight,inFlight);removeImageFlags.append(removing)
        if holdFlushes {await withCheckedContinuation {waiters.append($0)}}
        clearFailure();inFlight -= 1
    }
    func criticalRecords()throws->[LifecycleRecord] {
        // Read the synchronous copy directly; do not drain the asynchronous writer first.
        try Data(contentsOf:diagnosticDirectory.appendingPathComponent("critical-current.jsonl"))
            .split(separator:10).map {try JSONDecoder().decode(LifecycleRecord.self,from:Data($0))}
            .filter {$0.event == .playbackBoundary && $0.fields["scope"] == 3}
    }
    func releaseNext(){if !waiters.isEmpty {waiters.removeFirst().resume()}}
    func finish(){holdFlushes=false;let pending=waiters;waiters=[];pending.forEach{$0.resume()}}
}

@Suite(.serialized) @MainActor struct SystemVideoPresenterRecoveryTests {
    private enum Failure:Error {case timeout}
    private func until(_ condition:()->Bool)async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(3))
        while !condition() {
            if ContinuousClock.now>=deadline {throw Failure.timeout}
            try await Task.sleep(for:.milliseconds(1))
        }
    }
    private func frame(_ time:Double,session:UUID)throws->DecodedVideoFrame {
        var pixel:CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil,64,32,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pixel)==kCVReturnSuccess)
        return DecodedVideoFrame(pixel:try #require(pixel),time:time,session:session)
    }
    @available(macOS 26.0,visionOS 26.0,*)
    private func running()async throws->(SystemVideoPresenter,ControlledRenderer,DecodedVideoFrame) {
        let io=ControlledRenderer(),frame=try frame(1,session:UUID())
        let presenter=SystemVideoPresenter(diagnostics:io.diagnostics)
        presenter.testIO=io.io;presenter.submit(frame,settings:VRSettings())
        try await until{presenter.ready && !presenter.testWorkerActive}
        return(presenter,io,frame)
    }
    @Test func inactiveRetainsFrameAndExplicitRecoveryPausesBeforeEnqueue()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{return}
        let(p,io,frame)=try await running();defer{io.finish();p.stop()}
        var paused=false,interruptions=0
        p.onRecoverableInterruption={session in
            #expect(session==frame.session);paused=true;interruptions += 1;return true
        }
        let before=io.enqueuedTimes.count
        io.onEnqueue={#expect(paused && interruptions==1)}
        p.setSceneActive(false);io.requiresFlush=true;io.failed=true
        p.submit(frame,settings:VRSettings())
        try await Task.sleep(for:.milliseconds(20))
        #expect(io.enqueuedTimes.count==before && !p.ready)
        p.setSceneActive(true);p.submit(frame,settings:VRSettings())
        try await until{p.ready && !p.testWorkerActive}
        #expect(paused && interruptions==1)
        #expect(io.enqueuedTimes.count==before+1 && io.enqueuedTimes.last==1)
        #expect(p.error==nil && !io.enqueuedDuringFlush && io.maxInFlight==1)
    }
    @Test func inactiveActiveDuringRecoveryFlushDropsOldSubmission()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{return}
        let(p,io,old)=try await running();defer{io.finish();p.stop()}
        let baselineFlushes=io.flushes,before=io.enqueuedTimes.count
        io.holdFlushes=true;io.requiresFlush=true;io.failed=true;p.submit(old,settings:VRSettings())
        try await until{io.inFlight==1}
        p.setSceneActive(false);p.setSceneActive(true)
        let newest=try frame(2,session:old.session);p.submit(newest,settings:VRSettings())
        io.releaseNext()
        try await until{io.flushes==baselineFlushes+2 && io.inFlight==1}
        io.releaseNext();try await until{p.ready && !p.testWorkerActive}
        #expect(Array(io.enqueuedTimes.dropFirst(before)) == [2])
        #expect(p.lastSubmittedSession==old.session && !io.enqueuedDuringFlush && io.maxInFlight==1)
    }
    @Test func newSessionAndPackingDuringFlushWinOverRetainedFrame()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{return}
        let(p,io,old)=try await running();defer{io.finish();p.stop()}
        let baselineFlushes=io.flushes,before=io.enqueuedTimes.count
        io.holdFlushes=true;io.requiresFlush=true;io.failed=true;p.submit(old,settings:VRSettings())
        try await until{io.inFlight==1}
        let next=try frame(3,session:UUID());var settings=VRSettings();settings.layout = .sideBySide
        p.submit(next,settings:settings);io.releaseNext()
        try await until{io.flushes==baselineFlushes+2 && io.inFlight==1}
        io.releaseNext();try await until{p.ready && !p.testWorkerActive}
        #expect(Array(io.enqueuedTimes.dropFirst(before)) == [3])
        #expect(p.lastSubmittedSession==next.session && io.enqueuedPacking.last! != nil)
        #expect(p.testRendererReplacementCount==1 && io.removeImageFlags.last==true)
        #expect(!io.enqueuedDuringFlush && io.maxInFlight==1)
    }
    @Test func stopThenNewFrameDuringWorkerTailFlushIsSerialized()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{return}
        let(p,io,old)=try await running();defer{io.finish();p.stop()}
        let baselineFlushes=io.flushes,before=io.enqueuedTimes.count
        io.holdFlushes=true;io.requiresFlush=true;io.failed=true;p.submit(old,settings:VRSettings())
        try await until{io.inFlight==1};p.stop();io.releaseNext()
        try await until{io.flushes==baselineFlushes+2 && io.inFlight==1}
        let next=try frame(4,session:UUID());p.submit(next,settings:VRSettings());io.releaseNext()
        try await until{io.flushes==baselineFlushes+3 && io.inFlight==1}
        io.releaseNext();try await until{p.ready && !p.testWorkerActive}
        #expect(Array(io.enqueuedTimes.dropFirst(before)) == [4])
        #expect(p.lastSubmittedSession==next.session && !io.enqueuedDuringFlush && io.maxInFlight==1)
    }
    @Test func ordinaryFatalFailureBlocksSameSessionButNewSessionCanStart()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{return}
        let(p,io,old)=try await running();defer{io.finish();p.stop()}
        let before=io.enqueuedTimes.count
        let previousSequence=try io.criticalRecords().last!.sequence
        var changedSettings=VRSettings();changedSettings.layout = .sideBySide
        io.failed=true;p.submit(old,settings:changedSettings)
        #expect(p.error != nil && !p.ready)
        let records=try io.criticalRecords().filter {$0.sequence>previousSequence}
        try ordered([.submitEntered,.failure,.submitReturned],in:records)
        let entered=try #require(records.first {$0.fields["phase"] == Double(PlaybackBoundaryStage.submitEntered.rawValue)})
        let returned=try #require(records.first {$0.fields["phase"] == Double(PlaybackBoundaryStage.submitReturned.rawValue)})
        let failure=try #require(records.first {$0.fields["phase"] == Double(PlaybackBoundaryStage.failure.rawValue)})
        #expect(entered.fields["epoch"]==returned.fields["epoch"] && entered.fields["trace"]==returned.fields["trace"])
        #expect(entered.fields["cause"]==2 && returned.fields["cause"]==2)
        #expect(failure.fields["cause"]==5 && failure.fields["epoch"] != entered.fields["epoch"])
        io.failed=false;p.submit(old,settings:VRSettings())
        #expect(io.enqueuedTimes.count==before)
        let next=try frame(5,session:UUID());p.submit(next,settings:VRSettings())
        try await until{p.ready && !p.testWorkerActive}
        #expect(p.error==nil && p.lastSubmittedSession==next.session)
    }
    @Test func requiresFlushRemainingAfterOneAttemptBecomesExplicitFailure()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{return}
        let(p,io,old)=try await running();defer{io.finish();p.stop()}
        let baselineFlushes=io.flushes,before=io.enqueuedTimes.count
        io.keepFailureAfterFlush=true;io.requiresFlush=true;io.failed=false
        p.submit(old,settings:VRSettings())
        try await until{p.error != nil && !p.testWorkerActive}
        #expect(!p.ready && io.enqueuedTimes.count==before)
        #expect(io.flushes==baselineFlushes+2) // One recovery and serial failure cleanup.
        let records=try io.criticalRecords()
        let decisions=records.filter {$0.fields["phase"] == Double(PlaybackBoundaryStage.recoveryDecision.rawValue)}
        #expect(decisions.compactMap {$0.fields["outcome"]} == [1,2])
        try ordered([.recoveryDecision,.failure,.flushEntered,.flushReturned],in:Array(records.drop { $0.sequence < decisions.last!.sequence }))
        try await Task.sleep(for:.milliseconds(30))
        #expect(io.flushes==baselineFlushes+2)
    }
    @Test func pausedIdleMonitorRecoversWithoutAnotherSubmit()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{return}
        let(p,io,old)=try await running();defer{io.finish();p.stop()}
        let before=io.enqueuedTimes.count
        var interruptions=0
        p.onRecoverableInterruption={session in
            #expect(session==old.session);interruptions += 1;return true
        }
        io.onEnqueue={#expect(interruptions==1)}
        io.requiresFlush=true;io.failed=true
        try await until{io.enqueuedTimes.count==before+1 && p.ready && !p.testWorkerActive}
        #expect(interruptions==1 && p.error==nil && !io.requiresFlush)
        #expect(!io.enqueuedDuringFlush && io.maxInFlight==1)
    }
    @Test func pausedIdleMonitorReportsFatalErrorWithoutRetry()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{return}
        let(p,io,_)=try await running();defer{io.finish();p.stop()}
        let before=io.enqueuedTimes.count,flushes=io.flushes
        var interruptions=0
        p.onRecoverableInterruption={_ in interruptions += 1;return true}
        io.failed=true
        try await until{p.error != nil}
        #expect(!p.ready && interruptions==0 && io.enqueuedTimes.count==before && io.flushes==flushes)
    }
    @Test func staleUpstreamRejectionStopsWithoutReplayingRetainedFrame()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{return}
        let(p,io,old)=try await running();defer{io.finish();p.stop()}
        let before=io.enqueuedTimes.count
        p.onRecoverableInterruption={_ in false}
        io.requiresFlush=true;io.failed=true;p.submit(old,settings:VRSettings())
        try await until{!p.testWorkerActive}
        #expect(!p.ready && io.enqueuedTimes.count==before)
        let records=try io.criticalRecords()
        try ordered([.upstreamPauseEntered,.upstreamPauseReturned,.recoveryDecision,.stopEntered,.stopReturned],in:records)
        #expect(records.last {$0.fields["phase"] == Double(PlaybackBoundaryStage.recoveryDecision.rawValue)}?.fields["outcome"]==3)
    }
    private func ordered(_ stages:[PlaybackBoundaryStage],in records:[LifecycleRecord])throws {
        var cursor=records.startIndex
        for stage in stages {
            let found=try #require(records[cursor...].firstIndex {$0.fields["phase"] == Double(stage.rawValue)})
            cursor=records.index(after:found)
        }
    }
    @Test func firstFrameAndImmediateStopHaveDurableOrderedBoundariesWithoutExtraReads()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{return}
        let io=ControlledRenderer(),p=SystemVideoPresenter(diagnostics:io.diagnostics)
        defer{io.finish();p.stop()}
        let first=try frame(1,session:UUID())
        io.onEnqueue={
            // Original Build61 first-frame control-flow reads: one before flush,
            // two readiness checks, then failure and requires-flush admission.
            #expect(io.requiresReads==2 && io.failedReads==1 && io.readyReads==2)
        }
        p.testIO=io.io;p.submit(first,settings:VRSettings())
        try await until{p.ready && !p.testWorkerActive}
        let records=try io.criticalRecords()
        try ordered([.submitEntered,.submitQueued,.submitReturned,.workerEntered,
                     .requiresFlushObserved,.flushEntered,.flushReturned,.materialEntered,.materialReturned,
                     .readinessWaitEntered,.readinessWaitReturned,.sampleEntered,.sampleReturned,
                     .enqueueEntered,.enqueueReturned,.resultEnabled,.workerExited],in:records)
        #expect(Set(records.compactMap {$0.fields["epoch"]}).count==1)
        p.stop()
        let stopRecords=try io.criticalRecords().filter {$0.sequence > (records.last?.sequence ?? 0)}
        try ordered([.stopEntered,.generationChanged,.flushEntered,.flushReturned,.stopReturned],in:stopRecords)
        #expect(io.immediateFlushes==1)
        #expect(stopRecords.filter {$0.fields["phase"] == Double(PlaybackBoundaryStage.flushReturned.rawValue)}.first?.fields["detail"]==13)
        #expect(io.diagnostics.status.syncFailures==0)
    }
    @Test func foregroundRetainedFrameAndRecoveryPauseHaveDurableBoundaries()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{return}
        let(p,io,old)=try await running();defer{io.finish();p.stop()}
        let before=try io.criticalRecords().last!.sequence
        p.setSceneActive(false);p.setSceneActive(true);p.submit(old,settings:VRSettings())
        try await until{p.ready && !p.testWorkerActive}
        let foreground=try io.criticalRecords().filter {$0.sequence>before}
        try ordered([.sceneEntered,.sceneReturned,.submitEntered,.submitQueued,.submitReturned,
                     .workerEntered,.flushEntered,.flushReturned,.sampleEntered,.sampleReturned,
                     .enqueueEntered,.enqueueReturned,.resultEnabled,.workerExited],in:foreground)
        #expect(io.enqueuedTimes==[1,1])
        let beforeRecovery=foreground.last!.sequence
        var paused=false
        p.onRecoverableInterruption={session in #expect(session==old.session);paused=true;return true}
        io.onEnqueue={#expect(paused)}
        io.requiresFlush=true;io.failed=true;p.submit(old,settings:VRSettings())
        try await until{p.ready && !p.testWorkerActive && io.enqueuedTimes.count==3}
        let recovered=try io.criticalRecords().filter {$0.sequence>beforeRecovery}
        try ordered([.requiresFlushObserved,.upstreamPauseEntered,.upstreamPauseReturned,.recoveryDecision,
                     .flushEntered,.flushReturned,.sampleEntered,.sampleReturned,.enqueueEntered,
                     .enqueueReturned,.resultEnabled],in:recovered)
        #expect(recovered.first {$0.fields["phase"] == Double(PlaybackBoundaryStage.recoveryDecision.rawValue)}?.fields["outcome"]==1)
        #expect(!io.enqueuedDuringFlush && io.maxInFlight==1 && paused)
    }
    @Test func delayedFlushKeepsOriginalEpochAndDiscardsStaleGenerationDurably()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{return}
        let(p,io,old)=try await running();defer{io.finish();p.stop()}
        io.holdFlushes=true;io.requiresFlush=true;io.failed=true;p.submit(old,settings:VRSettings())
        try await until{io.inFlight==1}
        let started=try #require(io.criticalRecords().last {$0.fields["phase"] == Double(PlaybackBoundaryStage.flushEntered.rawValue)})
        p.setSceneActive(false);p.setSceneActive(true)
        let newest=try frame(2,session:old.session);p.submit(newest,settings:VRSettings())
        io.releaseNext();try await until{io.flushes==3 && io.inFlight==1}
        let during=try io.criticalRecords()
        let returned=try #require(during.first {$0.sequence>started.sequence && $0.fields["phase"] == Double(PlaybackBoundaryStage.flushReturned.rawValue)})
        let discarded=try #require(during.first {$0.sequence>returned.sequence && $0.fields["phase"] == Double(PlaybackBoundaryStage.discarded.rawValue)})
        #expect(returned.fields["epoch"]==started.fields["epoch"] && returned.fields["trace"]==started.fields["trace"])
        #expect(returned.fields["ticket"]==started.fields["ticket"] && returned.fields["generation"] != started.fields["generation"])
        #expect(discarded.fields["epoch"]==started.fields["epoch"] && discarded.fields["detail"]==23)
        io.releaseNext();try await until{p.ready && !p.testWorkerActive}
        #expect(io.enqueuedTimes==[1,2] && !io.enqueuedDuringFlush && io.maxInFlight==1)
    }
    @Test func asynchronousFailureAndStopAreDurableWithoutRecovery()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{return}
        let(p,io,_)=try await running();defer{io.finish();p.stop()}
        let before=try io.criticalRecords().last!.sequence
        io.failed=true;try await until{p.error != nil}
        p.stop()
        let records=try io.criticalRecords().filter {$0.sequence>before}
        try ordered([.failure,.stopEntered,.flushEntered,.flushReturned,.stopReturned],in:records)
        #expect(records.first {$0.fields["phase"] == Double(PlaybackBoundaryStage.failure.rawValue)}?.fields["detail"]==36)
        #expect(records.first {$0.fields["phase"] == Double(PlaybackBoundaryStage.failure.rawValue)}?.fields["rendererFailed"]==1)
        #expect(!records.contains {$0.fields["phase"] == Double(PlaybackBoundaryStage.recoveryDecision.rawValue)})
        #expect(io.enqueuedTimes==[1] && !p.ready && io.immediateFlushes==1)
    }
    @Test func ordinaryFramesAndDuplicateSceneStateDoNotRefillTraceBudget()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{return}
        let(p,io,old)=try await running();defer{io.finish();p.stop()}
        let before=try io.criticalRecords()
        for _ in 0..<12 {
            p.setSceneActive(true);p.submit(old,settings:VRSettings())
            try await until{!p.testWorkerActive}
        }
        let after=try io.criticalRecords()
        #expect(after.count==before.count)
        #expect(Set(after.compactMap {$0.fields["epoch"]}).count==1)
        #expect(io.enqueuedTimes.count==13)
    }

    @Test func exhaustedTracePreservesFirstFailureAndEffectiveStopWithoutRepeatedRefill()async throws {
        guard #available(macOS 26.0,visionOS 26.0,*) else{return}
        let(p,io,old)=try await running();defer{io.finish();p.stop()}
        p.exhaustTraceBudgetForTesting()
        let exhausted=try io.criticalRecords()
        #expect(exhausted.count==PlaybackBoundaryTrace.eventLimitPerEpoch)
        let initialEpoch=try #require(exhausted.last?.fields["epoch"])
        // Exhaustion must not turn a subsequent ordinary frame into a new window.
        for _ in 0..<2 {
            p.submit(old,settings:VRSettings())
            try await until{!p.testWorkerActive}
        }
        #expect(try io.criticalRecords().count==exhausted.count)
        #expect(io.enqueuedTimes.count==3)

        // Exercise the production fatal-error branch, not a direct fail test hook.
        io.failed=true;p.submit(old,settings:VRSettings())
        #expect(p.error != nil && !p.ready)
        let failureRecords=try io.criticalRecords().filter {$0.sequence>exhausted.last!.sequence}
        let failure=try #require(failureRecords.first {$0.fields["phase"] == Double(PlaybackBoundaryStage.failure.rawValue)})
        #expect(failure.fields["cause"]==5 && failure.fields["epoch"] != initialEpoch)
        let failedEpoch=try #require(failure.fields["epoch"])
        for _ in 0..<12 {p.submit(old,settings:VRSettings())}
        #expect(try io.criticalRecords().last?.fields["epoch"]==failedEpoch)
        #expect(io.enqueuedTimes.count==3)

        p.exhaustTraceBudgetForTesting()
        let beforeStop=try io.criticalRecords()
        #expect(beforeStop.filter {$0.fields["epoch"]==failedEpoch}.count==PlaybackBoundaryTrace.eventLimitPerEpoch)
        p.stop()
        let stopRecords=try io.criticalRecords().filter {$0.sequence>beforeStop.last!.sequence}
        try ordered([.stopEntered,.generationChanged,.flushEntered,.flushReturned,.stopReturned],in:stopRecords)
        #expect(stopRecords.allSatisfy {$0.fields["cause"]==6 && $0.fields["epoch"] != failedEpoch})
        #expect(io.immediateFlushes==1)
        let afterStop=try io.criticalRecords().count
        for _ in 0..<12 {p.stop()}
        #expect(try io.criticalRecords().count==afterStop)
        #expect(io.immediateFlushes==1)
    }

}
