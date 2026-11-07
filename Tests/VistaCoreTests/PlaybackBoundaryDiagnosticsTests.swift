import Foundation
import Testing
@testable import VistaCore

private func playbackDiagnosticDirectory()->URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("VistaPlaybackBoundaryTest-"+UUID().uuidString)
}
private func playbackDiagnosticRecords(_ directory:URL,critical:Bool=true)throws->[LifecycleRecord] {
    try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
        .filter{$0.pathExtension=="jsonl" && $0.lastPathComponent.hasPrefix("critical-")==critical}
        .flatMap{try Data(contentsOf:$0).split(separator:10).map{try JSONDecoder().decode(LifecycleRecord.self,from:Data($0))}}
        .sorted{$0.sequence<$1.sequence}
}

/// Local numeric observations and temporary files only. No player, renderer, socket, NAS, or device.
@MainActor struct PlaybackBoundaryDiagnosticsTests {
    @Test func fixedStagesHaveStableNumericValues() {
        let stages:[PlaybackBoundaryStage]=[.generationChanged,.sceneEntered,.sceneReturned,.pauseEntered,.pauseReturned,
            .frameObserved,.submitEntered,.submitQueued,.submitReturned,.workerEntered,.requiresFlushObserved,
            .recoveryDecision,.flushEntered,.flushReturned,.sampleEntered,.sampleReturned,.enqueueEntered,.enqueueReturned,
            .resultEnabled,.discarded,.failure,.stopEntered,.stopReturned,.readinessWaitEntered,.readinessWaitReturned,
            .materialEntered,.materialReturned,.workerExited,.upstreamPauseEntered,.upstreamPauseReturned]
        #expect(stages.map(\.rawValue)==Array(1...30))
        #expect(PlaybackBoundaryStage.allCases==stages)
    }

    @Test func allBoundariesHaveSynchronousNumericCriticalCopies()throws {
        let dir=playbackDiagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,build:"65",mirror:false)
        defer{store.drainForTesting()}
        let trace=PlaybackBoundaryTrace(scope:3,diagnostics:store)
        #expect(!trace.shouldRecord(.frameObserved))
        trace.begin(reason:2,generation:7)
        for stage in PlaybackBoundaryStage.allCases.dropFirst() {
            trace.record(stage,generation:7,fields:[.session:8,.ticket:9,.active:1])
        }
        // No drain: critical bytes must be visible as soon as each call returns.
        let records=try playbackDiagnosticRecords(dir).filter{$0.event == .playbackBoundary}
        #expect(records.count==30)
        #expect(records.map{$0.fields["phase"]}==(1...30).map{Double($0)})
        #expect(records.allSatisfy{$0.schema==4 && $0.build=="65" && $0.fields["trace"]==Double(trace.traceID)
            && $0.fields["epoch"]==1 && $0.fields["cause"]==2 && $0.fields["scope"]==3 && $0.fields["generation"]==7})
        #expect(records.dropFirst().allSatisfy{$0.fields["session"]==8 && $0.fields["ticket"]==9})
        #expect(store.status.syncWrites==31 && store.status.syncFailures==0)
        let json=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(records.last!)) as? [String:Any])
        let fields=try #require(json["fields"] as? [String:Any])
        #expect(fields.values.allSatisfy{$0 is NSNumber})
    }

    @Test func hotFramesDoNotReadSnapshotsOrReplenishAdmission()throws {
        let dir=playbackDiagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false)
        defer{store.drainForTesting()}
        let trace=PlaybackBoundaryTrace(scope:3,diagnostics:store)
        trace.begin(reason:1,generation:1)
        var getterReads=0
        func state()->Double {getterReads += 1;return 1}
        for generation in 1...10_000 {
            if trace.shouldRecord(.frameObserved) {
                trace.record(.frameObserved,generation:generation,fields:[.frameAvailable:state()])
            }
            trace.record(.submitEntered,generation:generation)
        }
        #expect(getterReads==1 && trace.epoch==1)
        let records=try playbackDiagnosticRecords(dir).filter{$0.event == .playbackBoundary}
        #expect(records.count==3 && records.allSatisfy{$0.fields["generation"]==1})
        #expect(!trace.shouldRecord(.frameObserved) && trace.shouldRecord(.failure))
    }

    @Test func repeatedStagesAreHardCappedAndOnlyBeginRefills()throws {
        let dir=playbackDiagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false)
        defer{store.drainForTesting()}
        let trace=PlaybackBoundaryTrace(scope:3,diagnostics:store)
        trace.begin(reason:1,generation:1)
        for generation in 1...1_000 {trace.record(.failure,generation:generation,once:false)}
        #expect(!trace.shouldRecord(.failure,once:false) && !trace.shouldRecord(.stopEntered))
        let before=try playbackDiagnosticRecords(dir).filter{$0.event == .playbackBoundary}
        #expect(before.count==PlaybackBoundaryTrace.eventLimitPerEpoch)
        trace.record(.frameObserved,generation:2)
        trace.begin(reason:2,generation:2)
        trace.record(.failure,generation:2)
        #expect(trace.shouldRecord(.stopEntered) && !trace.shouldRecord(.failure))
        let after=try playbackDiagnosticRecords(dir).filter{$0.event == .playbackBoundary}
        #expect(after.count==before.count+2 && trace.epoch==2)
        #expect(after.suffix(2).allSatisfy{$0.fields["epoch"]==2 && $0.fields["cause"]==2 && $0.fields["generation"]==2})
        #expect(after.allSatisfy{$0.fields["trace"]==Double(trace.traceID)})
    }

    @Test func correlationFieldsCannotBeReplacedBySnapshots()throws {
        let dir=playbackDiagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false)
        defer{store.drainForTesting()}
        let trace=PlaybackBoundaryTrace(scope:2,diagnostics:store)
        trace.begin(reason:3,generation:5)
        trace.record(.sceneEntered,generation:6,fields:[.scope:99,.phase:99,.trace:99,.epoch:99,.cause:99,.detail:12,.generation:99,
            .playing:1,.paused:0,.preparing:1,.frameAvailable:1,.requiresFlush:0,.rendererFailed:0,.acceptsSamples:1,
            .pending:0,.worker:1,.durationMS:.nan,.ticket:.infinity])
        let record=try #require(playbackDiagnosticRecords(dir).last)
        #expect(record.fields["scope"]==2 && record.fields["phase"]==2 && record.fields["trace"]==Double(trace.traceID))
        #expect(record.fields["epoch"]==1 && record.fields["cause"]==3 && record.fields["generation"]==6)
        #expect(record.fields["detail"]==12)
        #expect(record.fields["playing"]==1 && record.fields["paused"]==0 && record.fields["acceptsSamples"]==1)
        #expect(record.fields["durationMS"]==nil && record.fields["ticket"]==nil)
    }

    @Test func retainedContextPairsAcrossNewEpochAndKeepsIndependentBudget()async throws {
        let dir=playbackDiagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false)
        defer{store.drainForTesting()}
        let trace=PlaybackBoundaryTrace(scope:3,diagnostics:store)
        let old=trace.begin(reason:1,generation:7)
        trace.record(.flushEntered,generation:7,context:old)
        await Task.yield() // Observation ordering only; no renderer work or concurrent media access.
        let new=trace.begin(reason:2,generation:8)
        trace.record(.flushReturned,generation:8,context:new)
        #expect(trace.shouldRecord(.flushReturned,context:old))
        trace.record(.flushReturned,generation:7,context:old)
        #expect(!trace.shouldRecord(.flushReturned,context:old))
        #expect(trace.context() === new && old.epoch==1 && new.epoch==2)
        for _ in 0..<100 {trace.record(.failure,generation:7,once:false,context:old)}
        #expect(!trace.shouldRecord(.stopReturned,context:old) && trace.shouldRecord(.stopReturned,context:new))
        trace.record(.stopReturned,generation:8,context:new)
        let records=try playbackDiagnosticRecords(dir).filter{$0.event == .playbackBoundary}
        #expect(records.filter{$0.fields["epoch"]==1}.count==PlaybackBoundaryTrace.eventLimitPerEpoch)
        let returns=records.filter{$0.fields["phase"]==Double(PlaybackBoundaryStage.flushReturned.rawValue)}
        #expect(returns.count==2)
        #expect(returns[0].fields["epoch"]==2 && returns[0].fields["generation"]==8 && returns[0].fields["cause"]==2)
        #expect(returns[1].fields["epoch"]==1 && returns[1].fields["generation"]==7 && returns[1].fields["cause"]==1)
    }

    @Test func contextCannotCrossTraceAndOldContextsAreNotRetained()throws {
        let dir=playbackDiagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false)
        defer{store.drainForTesting()}
        let first=PlaybackBoundaryTrace(scope:2,diagnostics:store),second=PlaybackBoundaryTrace(scope:3,diagnostics:store)
        var old:PlaybackBoundaryTrace.Context?=first.begin(reason:1,generation:1)
        weak var retained=old
        second.begin(reason:2,generation:2)
        #expect(!second.shouldRecord(.flushReturned,context:old))
        second.record(.flushReturned,generation:1,context:old)
        first.begin(reason:3,generation:3)
        #expect(retained != nil)
        old=nil
        #expect(retained==nil)
        retained=nil
        #expect(try playbackDiagnosticRecords(dir).filter{$0.fields["phase"]==Double(PlaybackBoundaryStage.flushReturned.rawValue)}.isEmpty)
    }

    @Test func criticalCopyDoesNotWaitForTimelineQueue()throws {
        let dir=playbackDiagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,pendingLimit:2,mirror:false)
        defer{store.drainForTesting()}
        let trace=PlaybackBoundaryTrace(scope:3,diagnostics:store)
        store.withPausedWriterForTesting {
            trace.begin(reason:1,generation:1)
            trace.record(.pauseEntered,generation:1)
            trace.record(.pauseReturned,generation:1)
            #expect(store.status.pending==2 && store.status.dropped==1)
            #expect((try? playbackDiagnosticRecords(dir).filter{$0.event == .playbackBoundary}.count)==3)
        }
        store.drainForTesting()
        #expect(try playbackDiagnosticRecords(dir,critical:false).filter{$0.event == .playbackBoundary}.count==2)
    }

    @Test func synchronizationFailureDoesNotEscapeOrRetryOnFrames()throws {
        let dir=playbackDiagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false)
        defer{store.drainForTesting()}
        store.setCriticalSynchronizerForTesting{_ in throw CocoaError(.fileWriteUnknown)}
        let trace=PlaybackBoundaryTrace(scope:3,diagnostics:store)
        trace.begin(reason:1,generation:1)
        for _ in 0..<100 {trace.record(.frameObserved,generation:1)}
        #expect(store.status.syncFailures==2 && store.status.syncWrites==1)
        #expect(!trace.shouldRecord(.frameObserved))
        store.setCriticalSynchronizerForTesting(nil)
        trace.record(.enqueueReturned,generation:1)
        #expect(store.status.syncFailures==2 && store.status.syncWrites==2)
        let record=try #require(playbackDiagnosticRecords(dir).last)
        #expect(record.fields["phase"]==18 && record.syncFailures==2)
    }

    @Test func filesystemFailureRemainsContainedAndBounded()throws {
        let dir=playbackDiagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        try Data().write(to:dir)
        let store=LifecycleDiagnostics(directory:dir,mirror:false)
        let trace=PlaybackBoundaryTrace(scope:3,diagnostics:store)
        trace.begin(reason:1,generation:1)
        for _ in 0..<100 {trace.record(.submitEntered,generation:1)}
        store.drainForTesting()
        #expect(store.status.syncFailures==3 && store.status.writerFailures==3)
        #expect(store.status.pending==0 && !trace.shouldRecord(.submitEntered))
    }

    @Test func sessionIdentityIsSharedNumericBoundedAndNeverSerializesUUID()throws {
        let dir=playbackDiagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false)
        defer{store.drainForTesting()}
        let identities=PlaybackBoundarySessionIdentities()
        let session=UUID(),first=identities.session(session)
        #expect(first>0 && identities.session(session)==first)
        let controller=PlaybackBoundaryTrace(scope:2,diagnostics:store),presenter=PlaybackBoundaryTrace(scope:3,diagnostics:store)
        #expect(controller.traceID != presenter.traceID)
        // Session and trace are separate namespaces; a numeric collision across fields is harmless.
        #expect(first==1 && controller.traceID==1)
        for trace in [controller,presenter] {
            trace.begin(reason:1,generation:1)
            trace.record(.frameObserved,generation:1,fields:[.session:Double(identities.session(session))])
        }
        let records=try playbackDiagnosticRecords(dir)
        #expect(records.filter{$0.fields["phase"]==6}.allSatisfy{$0.fields["session"]==Double(first)})
        #expect(!String(decoding:try JSONEncoder().encode(records),as:UTF8.self).contains(session.uuidString))
        for _ in 0..<PlaybackBoundarySessionIdentities.capacity { _=identities.session(UUID()) }
        #expect(identities.count==PlaybackBoundarySessionIdentities.capacity)
        #expect(identities.session(session) != first && identities.count==PlaybackBoundarySessionIdentities.capacity)
    }

    @Test func publicSessionIdentityHasStableMappingWithoutLoggerArgument() {
        let session=UUID(),first=PlaybackBoundaryIdentity.session(session)
        #expect(first>0 && PlaybackBoundaryIdentity.session(session)==first)
        #expect(PlaybackBoundaryIdentity.session(UUID()) != first)
    }

    @Test func stageDetailsRemainSeparateFromRetainedEpochCause()throws {
        let dir=playbackDiagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false)
        defer{store.drainForTesting()}
        let trace=PlaybackBoundaryTrace(scope:3,diagnostics:store)
        let original=trace.begin(reason:3,generation:1)
        trace.record(.flushEntered,generation:1,fields:[.detail:11],context:original)
        trace.begin(reason:5,generation:2)
        trace.record(.flushReturned,generation:2,fields:[.cause:99,.detail:12],context:original)
        let boundaries=try playbackDiagnosticRecords(dir).filter{
            $0.fields["phase"]==Double(PlaybackBoundaryStage.flushEntered.rawValue)
                || $0.fields["phase"]==Double(PlaybackBoundaryStage.flushReturned.rawValue)
        }
        #expect(boundaries.count==2)
        #expect(boundaries.map{$0.fields["detail"]}==[11,12])
        #expect(boundaries.allSatisfy{$0.fields["cause"]==3 && $0.fields["epoch"]==1})
    }
}
