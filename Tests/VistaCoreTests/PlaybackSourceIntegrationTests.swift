import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia
@testable import VistaSMB

/// In-memory transport only. Recovery flags model the source/Native handshake, not SMB.
private enum IntegrationReadError:Error,Equatable {case transport,cleanup}
@MainActor private final class IntegrationRecoverySource:PlaybackRecoveryControlling {
    let data:Data
    var isPlaybackRecovering=false
    var recoveryActiveElapsed:TimeInterval=0
    var recoveryActiveStartedAt:TimeInterval? {
        isPlaybackRecovering && sceneActive ? ProcessInfo.processInfo.systemUptime-recoveryActiveElapsed:nil
    }
    var sceneActive=true
    var cancelled=false
    var holdCleanup=false,cleanupEntered=false,cleanupFinished=false
    var cleanupFailure:IntegrationReadError?
    var cleanupCancelled=false
    private var cleanupWaiter:CheckedContinuation<Void,Never>?
    var reads=0
    var recoverFirstRead=false
    var failNextRead=false
    var recoveryDelay:Duration = .milliseconds(450)
    var expiredRecovery=false
    init(data:Data=Data()) {self.data=data}
    func setPlaybackSceneActive(_ active:Bool) {sceneActive=active}
    func cancelPlayback() {cancelled=true;isPlaybackRecovering=false}
    func awaitPlaybackCleanup()async throws {
        cleanupEntered=true
        if holdCleanup {await withCheckedContinuation {cleanupWaiter=$0}}
        if cleanupCancelled {throw CancellationError()}
        if let cleanupFailure {throw cleanupFailure}
        cleanupFinished=true
    }
    func completeCleanup() {holdCleanup=false;cleanupWaiter?.resume();cleanupWaiter=nil}
    func fileSize(for file:MediaFile)async throws->UInt64 {
        guard !cancelled else{throw CancellationError()}
        return UInt64(data.count)
    }
    func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data {
        guard !cancelled else{throw CancellationError()}
        reads += 1
        if failNextRead {failNextRead=false;throw IntegrationReadError.transport}
        if recoverFirstRead && reads==1 {
            isPlaybackRecovering=true
            recoveryActiveElapsed=expiredRecovery ? PlaybackSourceRecoveryPolicy.activeBudget:0
            defer {isPlaybackRecovering=false}
            try await Task.sleep(for:recoveryDelay)
        }
        try Task.checkCancellation()
        guard !cancelled else{throw CancellationError()}
        guard range.upperBound<=UInt64(data.count) else{throw PlaybackFailure.readFailed}
        return data.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))
    }
}

/// Synthetic pagination through the production directory runner and recovery policy.
/// No provider, socket, NAS, credentials or physical device is created.
@MainActor private final class IntegrationPlaybackDirectory {
    final class Session:Sendable {
        let number:Int
        init(_ number:Int) {self.number=number}
    }
    let runner=DirectoryReadRecovery<Session>()
    let borrowed=Session(1),fresh=Session(2)
    let allEntries=(1...4).map{FileEntry("synthetic-\($0).mp4",.video)}
    var borrowedFailure:SMBDirectoryReadFailure?
    var playbackActive=true,current=true
    var entries:[FileEntry]=[]
    var nextOffset:Int?=0
    var connections=0,retirements=0
    var reads:[(session:Int,offset:Int)]=[]
    func loadMore()async throws {
        guard let offset=nextOffset else{return}
        let result=try await runner.readPage(key:"synthetic-share",offset:offset,isCurrent:{self.current},
            makeInitial:{self.borrowed},makeRecovery:{self.connections += 1;return self.fresh},
            read:{session,pageOffset in
                self.reads.append((session.number,pageOffset))
                if session === self.borrowed,let failure=self.borrowedFailure {throw failure}
                let end=min(pageOffset+2,self.allEntries.count)
                return DirectoryPage(entries:Array(self.allEntries[pageOffset..<end]),nextOffset:end<self.allEntries.count ? end:nil)
            },retire:{_ in self.retirements += 1},
            shouldRecover:{SMBDirectoryProvider.recoveryDisposition(for:$0).permitsDirectoryRecovery(playbackActive:self.playbackActive)})
        // Match ShortcutBrowser's snapshot reset before applying fresh offset zero.
        if result.restarted {entries=[]}
        entries += result.page.entries
        nextOffset=result.page.nextOffset
    }
    func adjacent(currentID:String,backward:Bool)async throws->FileEntry? {
        while nextOffset != nil {try await loadMore()}
        return OrderedVideoNavigation.adjacent(in:entries,currentID:currentID,backward:backward)
    }
}

@Suite(.serialized) @MainActor struct PlaybackSourceIntegrationTests {
    private enum Failure:Error {case timeout}
    private func wait(_ check:()->Bool)async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(8))
        while !check() {
            guard ContinuousClock.now<deadline else{throw Failure.timeout}
            try await Task.sleep(for:.milliseconds(5))
        }
    }
    private func fixture()throws->Data {
        try Data(contentsOf:Bundle.module.url(forResource:"SyntheticSeek",withExtension:"mp4")!)
    }
    @Test func preparedSourceReceivesSceneGateBeforePlaybackAndReplacementCancelsOnlyOldSource() {
        let controller=PlaybackController(),first=IntegrationRecoverySource(),second=IntegrationRecoverySource()
        controller.setPlaybackSceneActive(false)
        controller.bindPreparedSource(first)
        #expect(!first.sceneActive && !first.cancelled)
        controller.bindPreparedSource(first)
        #expect(!first.cancelled)
        controller.setPlaybackSceneActive(true)
        #expect(first.sceneActive && !controller.isPlaying)
        controller.bindPreparedSource(second)
        #expect(first.cancelled && !second.cancelled && second.sceneActive)
        controller.stop()
        #expect(second.cancelled)
    }
    @Test func replacementFactoryAndMetadataWaitForOwnedSourceCleanup()async throws {
        let controller=PlaybackController(),previous=IntegrationRecoverySource(),next=IntegrationRecoverySource()
        previous.holdCleanup=true
        controller.bindPreparedSource(previous)
        controller.bindPreparedSource(nil)
        #expect(previous.cancelled)
        var factories=0,metadataReads=0
        let preparation=Task {
            try await controller.awaitPreparedSourceCleanup()
            factories += 1
            controller.bindPreparedSource(next)
            _ = try await next.fileSize(for:MediaFile(components:["next.mp4"]))
            metadataReads += 1
        }
        try await wait{previous.cleanupEntered}
        #expect(factories==0 && metadataReads==0 && !previous.cleanupFinished)
        previous.completeCleanup()
        try await preparation.value
        #expect(previous.cleanupFinished && factories==1 && metadataReads==1 && !next.cancelled)
        controller.stop()
    }
    @Test func failedCleanupBlocksReplacementAndSubsequentPreparationAttempts()async throws {
        for cancelled in [false,true] {
            let controller=PlaybackController(),previous=IntegrationRecoverySource()
            previous.cleanupFailure = .cleanup;previous.cleanupCancelled=cancelled
            controller.bindPreparedSource(previous)
            controller.bindPreparedSource(nil)
            var factories=0
            for _ in 0..<2 {
                await #expect(throws:PlaybackController.PreparationFailure.sourceCleanup) {
                    try await controller.awaitPreparedSourceCleanup()
                    factories += 1
                }
            }
            #expect(previous.cancelled && previous.cleanupEntered && !previous.cleanupFinished && factories==0)
        }
    }
    @Test func bridgeDoesNotReportCancellationOrObsoleteRequestAsSourceFailure() {
        #expect(!ResourceBridge.shouldReportReadFailure(CancellationError(),taskCancelled:false,requestCancelled:false,stopped:false))
        #expect(!ResourceBridge.shouldReportReadFailure(PlaybackFailure.readFailed,taskCancelled:true,requestCancelled:false,stopped:false))
        #expect(!ResourceBridge.shouldReportReadFailure(PlaybackFailure.readFailed,taskCancelled:false,requestCancelled:true,stopped:false))
        #expect(!ResourceBridge.shouldReportReadFailure(PlaybackFailure.readFailed,taskCancelled:false,requestCancelled:false,stopped:true))
        #expect(ResourceBridge.shouldReportReadFailure(PlaybackFailure.readFailed,taskCancelled:false,requestCancelled:false,stopped:false))
    }
    @Test func recoveryReadDoesNotHitOrdinaryStallLimitAndThenDeliversFrame()async throws {
        let source=IntegrationRecoverySource(data:try fixture());source.recoverFirstRead=true
        let native=NativePlaybackSession(stallLimit:0.2,muted:true)
        var frames=0
        let task=Task {
            try await native.play(file:MediaFile(components:["synthetic.mp4"]),source:source,
                onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1;if frames==1 {native.stop()}})
        }
        await #expect(throws:CancellationError.self) {try await task.value}
        #expect(frames==1 && source.reads>0 && source.cancelled)
    }
    @Test func exhaustedRecoveryGraceFailsSourceAndCancelsLatePublication()async throws {
        let source=IntegrationRecoverySource(data:try fixture())
        source.recoverFirstRead=true;source.expiredRecovery=true
        let native=NativePlaybackSession(stallLimit:0.2,muted:true)
        var frames=0
        await #expect(throws:NativePlaybackSession.Failure.source) {
            try await native.play(file:MediaFile(components:["synthetic.mp4"]),source:source,
                onInfo:{_ in},onState:{_ in},onFrame:{_ in frames += 1})
        }
        #expect(source.cancelled && frames==0)
    }
    #if VISTA_NATIVE_PLAYER_EXPERIMENT
    @Test func activeRecoveryDoesNotResumePausedPlaybackOrReplaceRetainedFrameSession()async throws {
        let data=try fixture(),file=try MediaFile(components:["synthetic.mp4"])
        let borrowed=IntegrationRecoverySource(data:data),fresh=IntegrationRecoverySource(data:data)
        var connections=0,awaitingForeground=false
        let identity=PlaybackSourceIdentity(size:UInt64(data.count),modificationDate:Date(timeIntervalSince1970:100),creationDate:Date(timeIntervalSince1970:50))
        let source=PlaybackRecoveringSource(file:file,initial:borrowed,
            metadata:{_,_ in identity},makeFresh:{connections += 1;return fresh},
            retire:{$0.cancelPlayback()},shouldRecover:{$0 is IntegrationReadError},isCurrent:{true},diagnostics:nil,
            onRecoveryStage:{if $0 == .waitingForActive {awaitingForeground=true}})
        let controller=PlaybackController()
        controller.play(file:file,source:source)
        defer {controller.stop()}
        try await wait{controller.isPlaying && !controller.isPreparing && controller.pixelFrame != nil}
        controller.setPlaybackSceneActive(false);controller.pauseForBackground()
        try await wait{controller.isPaused && controller.speedStatus.effectiveRate==0}
        let frameSession=try #require(controller.pixelFrame).session,generation=controller.playbackGeneration
        let position=controller.position
        borrowed.failNextRead=true
        let readsBeforeBackgroundDemand=borrowed.reads
        awaitingForeground=false
        let pending=Task {try await source.read(file,range:0..<16)}
        // Background demand parks before transport or recovery. Foreground validation
        // then allows the original single recovery without changing the paused session.
        try await wait{awaitingForeground}
        #expect(connections==0 && borrowed.reads==readsBeforeBackgroundDemand)
        #expect(!source.isPlaybackRecovering && borrowed.failNextRead)
        controller.setPlaybackSceneActive(true)
        #expect(try await pending.value==data.prefix(16))
        try await Task.sleep(for:.milliseconds(120))
        #expect(connections==1 && borrowed.cancelled && !fresh.cancelled)
        #expect(controller.isPlaying && controller.isPaused && controller.speedStatus.effectiveRate==0)
        #expect(controller.pixelFrame?.session==frameSession && controller.playbackGeneration==generation)
        #expect(abs(controller.position-position)<0.05)
        controller.togglePause()
        try await wait{controller.position>position+0.05}
        #expect(controller.pixelFrame?.session==frameSession)
    }
    #endif
    @Test func playbackRetiredBorrowedDirectoryFinishesPaginationBeforeNextOrPrevious()async throws {
        for backward in [false,true] {
            let directory=IntegrationPlaybackDirectory()
            try await directory.loadMore()
            #expect(directory.entries.count==2 && directory.nextOffset==2)
            let selected=directory.entries[1]
            // This typed marker models the provider AFTER playback retirement really drained.
            directory.borrowedFailure = .retiredByPlaybackRecovery
            let adjacent=try await directory.adjacent(currentID:selected.id,backward:backward)
            #expect(adjacent?.id==directory.allEntries[backward ? 0:2].id)
            #expect(directory.playbackActive && directory.connections==1 && directory.retirements==1)
            #expect(directory.reads.map(\.session)==[1,1,2,2])
            #expect(directory.reads.map(\.offset)==[0,2,0,2])
            #expect(directory.entries==directory.allEntries && directory.nextOffset==nil)
            #expect(directory.runner.containsSession(directory.fresh,for:"synthetic-share"))
        }
    }
    @Test func activePlaybackKeepsEveryOtherDirectoryFailureOutOfRecovery()async throws {
        let blocked:[SMBDirectoryReadFailure]=[.cancelled,.retired,.permissionDenied,.authenticationRequired,.notFound,
            .serverRejected,.serviceInvalidated,.contextUnavailable,.transportFailure,.unclassifiedSessionFailure]
        for failure in blocked {
            let directory=IntegrationPlaybackDirectory()
            try await directory.loadMore()
            directory.borrowedFailure=failure
            await #expect(throws:failure) {
                _ = try await directory.adjacent(currentID:directory.entries[1].id,backward:false)
            }
            #expect(directory.connections==0 && directory.retirements==0)
            #expect(directory.runner.containsSession(directory.borrowed,for:"synthetic-share"))
            #expect(directory.entries.count==2 && directory.nextOffset==2)
        }
        // Dismissing playback retains the previously accepted directory eligibility.
        for failure in blocked+[.retiredByPlaybackRecovery] {
            #expect(failure.permitsDirectoryRecovery(playbackActive:false)==failure.allowsFreshRecovery)
        }
    }
    @Test func retiredPlaybackDirectoryStillRequiresCurrentOwnerBeforeRecovery()async throws {
        let directory=IntegrationPlaybackDirectory()
        try await directory.loadMore()
        directory.borrowedFailure = .retiredByPlaybackRecovery
        directory.current=false
        await #expect(throws:CancellationError.self) {
            _ = try await directory.adjacent(currentID:directory.entries[1].id,backward:false)
        }
        #expect(directory.connections==0 && directory.retirements==0)
        #expect(directory.runner.containsSession(directory.borrowed,for:"synthetic-share"))
    }
    @Test func appSourceContractsBindPerFilePreparationReplayAndImmersiveScene()throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view=try String(contentsOf:root.appendingPathComponent("VistaApp/PlaybackView.swift"),encoding:.utf8)
        let browser=try String(contentsOf:root.appendingPathComponent("VistaApp/ShortcutBrowser.swift"),encoding:.utf8)
        let immersive=try String(contentsOf:root.appendingPathComponent("VistaApp/VRPresentation.swift"),encoding:.utf8)
        #expect(view.contains(".task(id: playingSelection.id + \"#\" + String(attempt))"))
        #expect(view.contains("let prepared=try sourceFactory?(file) ?? source"))
        let barrier=try #require(view.range(of:"try await player.awaitPreparedSourceCleanup()"))
        let factory=try #require(view.range(of:"let prepared=try sourceFactory?(file) ?? source"))
        #expect(barrier.lowerBound<factory.lowerBound)
        #expect(view.contains("MediaInspector.inspect(file, source: prepared)"))
        #expect(view.contains("VRMetadataInspector.inspect(file, source: prepared)"))
        #expect(view.contains("guard let source=preparedSource else{return}"))
        #expect(view.contains("sourceFactory != nil && (preparedSourceUsed || preparedSource == nil)"))
        #expect(view.contains("replayAfterPreparation=true;attempt += 1"))
        #expect(view.contains("cancelPreparedSource();player.stop(discardTrackInfo:true)\n                autoplayReplacement = true"))
        #expect(browser.contains("self.playback?.id==playbackID"))
        #expect(browser.contains("latest.credentialID==source.credentialID"))
        #expect(browser.contains(".permitsDirectoryRecovery(playbackActive:playback != nil)"))
        #expect(browser.contains("shouldJoinExistingRecovery:{($0 as? SMBPlaybackReadFailure) == .retired}"))
        #expect(browser.contains("PlaybackRecoveringSource(file:file,initial:SMBPlaybackSession(provider:borrowed)"))
        #expect(immersive.contains("presentation.player?.setPlaybackSceneActive(phase == .active)"))
        #expect(immersive.contains("presentation.player?.setPlaybackSceneActive(scenePhase == .active)"))
        #expect(immersive.contains("if phase == .background {"))
        #expect(!browser.contains("setPlaybackSceneActive(diagnosticScenePhase"))
    }
}
