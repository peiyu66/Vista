import Foundation
import Testing
@testable import VistaCore
@testable import VistaSMB

private func diagnosticDirectory()->URL {FileManager.default.temporaryDirectory.appendingPathComponent("VistaDiagnosticTest-"+UUID().uuidString)}
private func diagnosticRecords(_ directory:URL,critical:Bool=false)throws->[LifecycleRecord] {
    try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter{$0.pathExtension=="jsonl" && $0.lastPathComponent.hasPrefix("critical-")==critical}.flatMap {url in
        try Data(contentsOf:url).split(separator:10).map{try JSONDecoder().decode(LifecycleRecord.self,from:Data($0))}
    }.sorted{$0.sequence<$1.sequence}
}
struct LifecycleDiagnosticsTests {
    @Test func typedRecordsRejectPrivateTextAndNonfiniteValues()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,build:"SECRET/account/movie.mp4",mirror:false,criticalDurability:false)
        let token=store.begin(.listDirectory,session:17)
        store.finish(token,failure:LifecycleFailure(NSError(domain:"SECRET/host/password",code:123,userInfo:[NSLocalizedDescriptionKey:"SECRET/path",NSFilePathErrorKey:"SECRET/movie.mp4"])))
        store.record(.scenePhase,[.scope:1,.phase:.nan,.previousPhase:.infinity,.durationMS:1e20])
        store.drainForTesting()
        let records=try diagnosticRecords(dir)
        #expect(records.count==4 && records.allSatisfy{$0.build=="0"})
        #expect(records.last?.fields==["scope":1])
        let failure=try #require(records.first{$0.event == .apiError})
        #expect(failure.fields["errorDomain"]==0 && failure.fields["errorCode"]==0)
        #expect(!String(decoding:try JSONEncoder().encode(records),as:UTF8.self).contains("SECRET"))
    }
    @Test func errorsClassifyOnlyKnownCodesAndActualTimeouts() {
        let timeout=LifecycleFailure(NSError(domain:NSPOSIXErrorDomain,code:Int(ETIMEDOUT)))
        #expect(timeout.domain==1 && timeout.isTimeout)
        #expect(LifecycleFailure(URLError(.timedOut)).isTimeout)
        #expect(!LifecycleFailure(URLError(.networkConnectionLost)).isTimeout)
        #expect(LifecycleFailure(CancellationError()).isCancellation)
        #expect(LifecycleFailure(URLError(.cancelled)).isCancellation)
        #expect(LifecycleFailure(NSError(domain:NSPOSIXErrorDomain,code:Int.max)).code==0)
    }
    @Test func processIdentityAndSequenceDistinguishRuns()throws {
        let a=diagnosticDirectory(),b=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:a);try? FileManager.default.removeItem(at:b)}
        let first=LifecycleDiagnostics(directory:a,build:"59",mirror:false,criticalDurability:false),second=LifecycleDiagnostics(directory:b,build:"59",mirror:false,criticalDurability:false)
        first.record(.viewAppear);first.record(.viewDisappear);first.drainForTesting();second.drainForTesting()
        let records=try diagnosticRecords(a)
        #expect(records.filter{$0.event == .processStart}.count==1)
        #expect(records.map(\.sequence)==[1,2,3])
        #expect(records.allSatisfy{$0.run==first.run && $0.pid==ProcessInfo.processInfo.processIdentifier && $0.build=="59"})
        #expect(first.run != second.run && records.allSatisfy{$0.wallTime>0 && $0.uptime>0})
    }
    @Test func pairedReadSamplingAndUnsampledErrorsAreExplicit()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false,criticalDurability:false)
        let a=store.begin(.rangeRead,session:8);store.finish(a)
        let b=store.begin(.rangeRead,session:8);store.finish(b)
        let c=store.begin(.rangeRead,session:8);store.finish(c,failure:LifecycleFailure(URLError(.timedOut)))
        store.drainForTesting();let records=try diagnosticRecords(dir)
        #expect(records.filter{$0.event == .apiStart}.count==1)
        #expect(records.filter{$0.event == .apiReturned}.count==1)
        let error=try #require(records.first{$0.event == .apiError})
        #expect(error.fields["request"]==Double(c.request) && error.fields["sampledStart"]==0 && error.fields["timeout"]==1)
        #expect(records.allSatisfy{$0.fields["request"] != Double(b.request)})
        #expect(store.status.omitted==3)
    }
    @Test func metadataAbsenceIsSampledButTimeoutAlwaysSurvives()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false,criticalDurability:false)
        for operation in [LifecycleOperation.tagRead,.finderInfo] {
            let a=store.begin(operation);store.finish(a,failure:LifecycleFailure(NSError(domain:NSPOSIXErrorDomain,code:Int(ENOENT))))
            let b=store.begin(operation);store.finish(b,failure:LifecycleFailure(NSError(domain:NSPOSIXErrorDomain,code:Int(ENODATA))))
            let c=store.begin(operation);store.finish(c,failure:LifecycleFailure(NSError(domain:NSPOSIXErrorDomain,code:Int(ETIMEDOUT))))
        }
        store.drainForTesting();let records=try diagnosticRecords(dir)
        #expect(records.filter{$0.event == .apiStart}.count==2)
        #expect(records.filter{$0.event == .apiError}.count==4)
        #expect(records.filter{$0.fields["timeout"]==1}.allSatisfy{$0.fields["sampledStart"]==0})
        #expect(store.status.omitted==6)
    }
    @Test func taskContextIsCapturedAcrossCallbackBoundary()async throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false,criticalDurability:false)
        let token=await LifecycleContext.$request.withValue(.init(navigation:42,request:43)) {
            await Task.yield();return store.begin(.listDirectory,session:44)
        }
        #expect(LifecycleContext.navigation==0)
        store.finish(token);store.drainForTesting()
        let records=try diagnosticRecords(dir).filter{$0.event != .processStart}
        #expect(records.count==2 && records.allSatisfy{$0.fields["navigation"]==42 && $0.fields["parentRequest"]==43 && $0.fields["session"]==44})
    }
    @Test func boundedQueueRetainsPriorityWithoutCallerDiskWait()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,pendingLimit:2,mirror:false,criticalDurability:false);store.drainForTesting()
        store.withPausedWriterForTesting {
            store.record(.cacheHit,[.request:1],priority:false)
            store.record(.cacheHit,[.request:2],priority:false)
            store.record(.requestError,[.request:3])
            store.record(.scenePhase,[.request:4])
            store.record(.cacheHit,[.request:5],priority:false)
            #expect(store.status.pending==2 && store.status.dropped==3)
        }
        store.drainForTesting();let records=try diagnosticRecords(dir)
        #expect(records.map(\.event)==[.processStart,.requestError,.scenePhase])
        #expect(records.last?.dropped==2) // Counters describe loss known when each record was enqueued.
        store.record(.viewAppear);store.drainForTesting()
        #expect(try diagnosticRecords(dir).last?.dropped==3)
    }
    @Test func rotationRetentionAndPermissionsAreBounded()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let stale=dir.appendingPathComponent("previous-3.jsonl");try Data("STALE".utf8).write(to:stale)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-8*86400)],ofItemAtPath:stale.path)
        let store=LifecycleDiagnostics(directory:dir,fileLimit:4096,mirror:false,criticalDurability:false);store.drainForTesting()
        #expect(!FileManager.default.fileExists(atPath:stale.path))
        for i in 0..<100 {store.record(.scenePhase,[.phase:Double(i%3)]);store.drainForTesting()}
        let files=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)
        #expect(files.count==4)
        for file in files {
            #expect(try Data(contentsOf:file).count<=4096)
            #expect((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue==0o600)
        }
        #expect(try diagnosticRecords(dir).last?.sequence==101)
        #expect(store.status.writerFailures==0)
    }
    @Test func filesystemFailureDoesNotEscapeIntoApplication()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        try Data().write(to:dir)
        let store=LifecycleDiagnostics(directory:dir,mirror:false,criticalDurability:false)
        store.record(.browseIntent);store.drainForTesting()
        #expect(store.status.writerFailures==2 && store.status.pending==0)
    }
}

/// Sequential local value transport only. No SMB2Manager, sockets, NAS, or overlapping requests.
private struct DiagnosticValueTransport:SMBRangeTransport {
    enum Mode:Sendable {case success,timeout,shortReply}
    let mode:Mode
    func attributes(at path:String)async throws->[URLResourceKey:any Sendable] {
        if mode == .timeout {throw NSError(domain:NSPOSIXErrorDomain,code:Int(ETIMEDOUT),userInfo:[NSFilePathErrorKey:path])}
        return [.fileSizeKey:UInt64(8),.fileResourceTypeKey:URLFileResourceType.regular]
    }
    func read(at path:String,range:Range<UInt64>)async throws->Data {
        if mode == .timeout {throw NSError(domain:NSPOSIXErrorDomain,code:Int(ETIMEDOUT),userInfo:[NSFilePathErrorKey:path])}
        return Data(count:mode == .shortReply ? max(0,Int(range.count)-1):Int(range.count))
    }
}
struct LifecycleReaderDiagnosticsTests {
    @Test func sequentialSuccessPreservesValuesAndPairs()async throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false,criticalDurability:false)
        let reader=SMBMediaReader(transport:DiagnosticValueTransport(mode:.success),diagnostics:store,session:7)
        let file=try MediaFile(components:["PRIVATE-synthetic.mp4"])
        #expect(try await reader.fileSize(for:file)==8)
        #expect(try await reader.read(file,range:0..<4).count==4)
        await reader.close();store.drainForTesting()
        let records=try diagnosticRecords(dir)
        #expect(records.filter{$0.event == .apiStart}.count==2 && records.filter{$0.event == .apiReturned}.count==2)
        #expect(records.last?.event == .readerClosed && records.last?.fields["active"]==0)
        #expect(!String(decoding:try JSONEncoder().encode(records),as:UTF8.self).contains("PRIVATE"))
    }
    @Test func rawTimeoutIsRecordedBeforeExistingErrorMapping()async throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false,criticalDurability:false)
        let reader=SMBMediaReader(transport:DiagnosticValueTransport(mode:.timeout),diagnostics:store,session:8)
        let file=try MediaFile(components:["PRIVATE-synthetic.mp4"])
        await #expect(throws:MediaInspectionError.self){try await reader.fileSize(for:file)}
        await #expect(throws:MediaInspectionError.self){try await reader.read(file,range:0..<4)}
        store.drainForTesting();let records=try diagnosticRecords(dir)
        #expect(records.filter{$0.event == .apiError}.count==2)
        #expect(records.filter{$0.event == .apiError}.allSatisfy{$0.fields["errorDomain"]==1 && $0.fields["errorCode"]==Double(ETIMEDOUT) && $0.fields["timeout"]==1})
        #expect(!String(decoding:try JSONEncoder().encode(records),as:UTF8.self).contains("PRIVATE"))
    }
    @Test func transportReturnIsDistinctFromCallerValidation()async throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false,criticalDurability:false)
        let reader=SMBMediaReader(transport:DiagnosticValueTransport(mode:.shortReply),diagnostics:store)
        let file=try MediaFile(components:["synthetic.mp4"])
        await #expect(throws:MediaInspectionError.self){try await reader.read(file,range:0..<4)}
        store.drainForTesting();let records=try diagnosticRecords(dir)
        #expect(records.filter{$0.event == .apiReturned}.count==1 && records.allSatisfy{$0.event != .apiError})
    }
    @Test func closedReaderDoesNotReportUnstartedTransportCall()async throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false,criticalDurability:false)
        let reader=SMBMediaReader(transport:DiagnosticValueTransport(mode:.success),diagnostics:store)
        await reader.close()
        let file=try MediaFile(components:["synthetic.mp4"])
        await #expect(throws:MediaInspectionError.self){try await reader.read(file,range:0..<4)}
        store.drainForTesting()
        #expect(try diagnosticRecords(dir).allSatisfy{$0.event != .apiStart})
    }
}

/// One value-only actor call at a time. No SMB2Manager, network, socket, or admission/concurrency test.
private actor DiagnosticBoundaryValueProvider {
    enum Mode:Sendable {case success,cache,error,cancellation}
    func value(_ mode:Mode,store:LifecycleDiagnostics)async throws->Int {
        store.providerBoundary(.entered,operation:.listDirectory,session:9)
        defer {store.providerBoundary(.exited,operation:.listDirectory,session:9)}
        if mode == .cache {store.record(.cacheHit,[.session:9,.navigation:Double(LifecycleContext.navigation)]);return 7}
        if mode == .cancellation {throw CancellationError()}
        // A manually completed continuation models the caller boundary, not AMSMB2 internals.
        return try await withCheckedThrowingContinuation { continuation in
            if mode == .error {continuation.resume(throwing:NSError(domain:"PRIVATE-host/account",code:99,userInfo:[NSFilePathErrorKey:"PRIVATE/movie.mp4"]))}
            else {continuation.resume(returning:7)}
        }
    }
}
@MainActor private func diagnosticBoundaryTask(_ store:LifecycleDiagnostics,mode:DiagnosticBoundaryValueProvider.Mode)->Task<Int,any Error> {
    let values:[LifecycleField:Double]=[.scope:1,.request:43,.navigation:42,.generation:5]
    store.record(.requestStart,values)
    let task=Task {
        store.record(.taskEntered,values.merging([.cancelled:Task.isCancelled ? 1:0]){_,new in new})
        defer {store.record(.taskExited,values.merging([.cancelled:Task.isCancelled ? 1:0]){_,new in new})}
        return try await LifecycleContext.$request.withValue(.init(navigation:42,request:43)) {
            store.providerBoundary(.willCall,operation:.listDirectory)
            return try await DiagnosticBoundaryValueProvider().value(mode,store:store)
        }
    }
    store.record(.taskCreated,values)
    return task
}
struct LifecycleBoundaryDiagnosticsTests {
    @MainActor @Test func taskAndActorBoundariesPreserveValuesAndRequestIdentity()async throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,build:"60",mirror:false,criticalDurability:false)
        #expect(try await diagnosticBoundaryTask(store,mode:.success).value==7)
        store.drainForTesting();let records=try diagnosticRecords(dir)
        #expect(records.map(\.event)==[.processStart,.requestStart,.taskCreated,.taskEntered,.providerWillCall,.providerEntered,.providerExited,.taskExited])
        #expect(records.allSatisfy{$0.schema==4 && $0.build=="60"})
        #expect(records.filter{$0.event != .processStart}.allSatisfy{$0.fields["request"]==43 && $0.fields["navigation"]==42})
        #expect(records.filter{$0.event == .providerEntered || $0.event == .providerExited}.allSatisfy{$0.fields["session"]==9 && $0.fields["operation"]==3})
        #expect(LifecycleContext.request.request==0 && LifecycleContext.navigation==0)
    }
    @MainActor @Test func errorAndCancellationBothExitWithoutRewritingFailure()async throws {
        for mode in [DiagnosticBoundaryValueProvider.Mode.error,.cancellation] {
            let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
            let store=LifecycleDiagnostics(directory:dir,mirror:false,criticalDurability:false)
            do { _=try await diagnosticBoundaryTask(store,mode:mode).value;Issue.record("Expected unchanged error") }
            catch {
                if mode == .cancellation {#expect(error is CancellationError)}
                else {#expect((error as NSError).domain=="PRIVATE-host/account" && (error as NSError).code==99)}
            }
            store.drainForTesting();let records=try diagnosticRecords(dir)
            #expect(records.filter{$0.event == .providerExited}.count==1 && records.filter{$0.event == .taskExited}.count==1)
            #expect(records.suffix(2).map(\.event)==[.providerExited,.taskExited])
            #expect(!String(decoding:try JSONEncoder().encode(records),as:UTF8.self).contains("PRIVATE"))
        }
    }
    @MainActor @Test func alreadyCancelledTaskIsObservedWithoutAddingCancellationPolicy()async throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false,criticalDurability:false)
        let task=diagnosticBoundaryTask(store,mode:.success)
        task.cancel() // One synthetic Task, cancelled before its MainActor body can run.
        #expect(try await task.value==7) // Instrumentation must not add a check, throw, or skip.
        store.drainForTesting();let records=try diagnosticRecords(dir)
        let observed=records.filter{[LifecycleEvent.taskEntered,.providerWillCall,.providerEntered,.providerExited,.taskExited].contains($0.event)}
        #expect(observed.count==5 && observed.allSatisfy{$0.fields["cancelled"]==1})
        #expect(records.map(\.event).contains(.taskCreated))
    }
    @MainActor @Test func cachedProviderReturnDoesNotInventRPCEvents()async throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false,criticalDurability:false)
        #expect(try await diagnosticBoundaryTask(store,mode:.cache).value==7)
        store.drainForTesting();let records=try diagnosticRecords(dir)
        #expect(records.map(\.event).contains(.cacheHit))
        #expect(records.allSatisfy{$0.event != .apiStart && $0.event != .apiReturned})
        #expect(records.suffix(3).map(\.event)==[.cacheHit,.providerExited,.taskExited])
    }
    @Test func extendedSchemaStillReadsEarlierTypedRecords()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,build:"59",mirror:false,criticalDurability:false);store.drainForTesting()
        let record=try #require(diagnosticRecords(dir).first)
        var json=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(record)) as? [String:Any])
        json["schema"]=1
        let old=try JSONDecoder().decode(LifecycleRecord.self,from:JSONSerialization.data(withJSONObject:json))
        #expect(old.schema==1 && old.event == .processStart && old.build=="59")
    }
}

/// Typed log recording only; no manager, credentials, cache implementation, or network operation.
struct LifecycleBrowseStepDiagnosticsTests {
    @Test func cacheDecisionKeepsUIIdentityAndDoesNotInventRPC()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,build:"62",mirror:false,criticalDurability:false)
        LifecycleContext.$request.withValue(.init(navigation:42,request:43)) {
            store.directoryCache(hit:false,session:9)
            store.directoryCache(hit:true,session:9)
        }
        store.drainForTesting();let records=try diagnosticRecords(dir).filter{$0.event != .processStart}
        #expect(records.map(\.event)==[.cacheMiss,.cacheHit])
        #expect(records.allSatisfy{$0.schema==4 && $0.fields==["operation":3,"session":9,"request":43,"navigation":42]})
        #expect(store.status.omitted==0 && store.status.dropped==0 && store.status.writerFailures==0)
    }
    @Test func sessionChoicesRemainDistinctAndOnlyNumeric()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,build:"62",mirror:false,criticalDurability:false)
        let current:[LifecycleField:Double]=[.scope:1,.request:43,.navigation:42,.generation:5]
        let parent:[LifecycleField:Double]=[.scope:2,.request:44,.navigation:42,.generation:5]
        store.record(.sessionLookup,current);store.record(.sessionCreateRequested,current)
        store.record(.sessionLookup,parent);store.record(.sessionReused,parent)
        store.drainForTesting();let records=try diagnosticRecords(dir).filter{$0.event != .processStart}
        #expect(records.map(\.event)==[.sessionLookup,.sessionCreateRequested,.sessionLookup,.sessionReused])
        #expect(records.map{$0.fields["request"]}==[43,43,44,44])
        #expect(records.allSatisfy{Set($0.fields.keys)==Set(["scope","request","navigation","generation"])})
        #expect(records.allSatisfy{$0.event != .apiStart && $0.event != .apiReturned})
    }
    @Test func schemaTwoRecordsRemainReadable()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,build:"60",mirror:false,criticalDurability:false)
        store.record(.taskEntered,[.request:43]);store.drainForTesting()
        let record=try #require(diagnosticRecords(dir).last)
        var json=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(record)) as? [String:Any])
        json["schema"]=2
        let previous=try JSONDecoder().decode(LifecycleRecord.self,from:JSONSerialization.data(withJSONObject:json))
        #expect(previous.schema==2 && previous.build=="60" && previous.event == .taskEntered && previous.fields["request"]==43)
    }
}


/// Synchronous local-file diagnostics only; no SMB manager, network, or concurrent RPC test.
struct LifecycleDurableDiagnosticsTests {
    @Test func listStartAndSuccessOrFailureAreReadableBeforeReturning()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,build:"62",mirror:false)
        defer{store.drainForTesting()}
        let success=store.begin(.listDirectory,session:9)
        #expect(try diagnosticRecords(dir,critical:true).last?.event == .apiStart)
        store.finish(success)
        let returned=try #require(diagnosticRecords(dir,critical:true).last)
        #expect(returned.event == .apiReturned && returned.fields["outcome"]==0 && returned.schema==4)
        let failure=store.begin(.listDirectory,session:9)
        store.finish(failure,failure:LifecycleFailure(NSError(domain:NSPOSIXErrorDomain,code:Int(ETIMEDOUT),userInfo:[NSFilePathErrorKey:"PRIVATE/movie.mp4"])))
        let error=try #require(diagnosticRecords(dir,critical:true).last)
        #expect(error.event == .apiError && error.fields["timeout"]==1 && error.fields["request"]==Double(failure.request))
        #expect(store.status.syncWrites==5 && store.status.syncFailures==0)
        #expect(!String(decoding:try JSONEncoder().encode(diagnosticRecords(dir,critical:true)),as:UTF8.self).contains("PRIVATE"))
    }
    @Test func criticalCopyDoesNotWaitForSuspendedAsyncWriterOrGetEvicted()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,pendingLimit:2,mirror:false)
        defer{store.drainForTesting()}
        store.withPausedWriterForTesting {
            store.record(.viewAppear);store.record(.viewDisappear)
            store.record(.browseIntent,[.navigation:42])
            store.record(.requestStart,[.request:43,.navigation:42])
            let records=try? diagnosticRecords(dir,critical:true)
            #expect(records?.suffix(2).map(\.event)==[.browseIntent,.requestStart])
            #expect(store.status.dropped>=2 && store.status.syncFailures==0)
        }
    }
    @Test func frequentMediaAndMetadataErrorsRemainAsyncOnly()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false)
        defer{store.drainForTesting()}
        for operation in [LifecycleOperation.rangeRead,.tagRead,.finderInfo,.attributes] {
            let token=store.begin(operation)
            store.finish(token,failure:LifecycleFailure(URLError(.timedOut)))
        }
        #expect(try diagnosticRecords(dir,critical:true).map(\.event)==[.processStart])
        #expect(store.status.syncWrites==1 && store.status.syncFailures==0)
    }
    @Test func unavailableDirectoryAndSyncFailureDoNotEscapeCaller()throws {
        let unavailable=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:unavailable)}
        try Data().write(to:unavailable)
        let bad=LifecycleDiagnostics(directory:unavailable,mirror:false)
        defer{bad.drainForTesting()}
        let token=bad.begin(.listDirectory);bad.finish(token)
        #expect(bad.status.syncFailures==3 && bad.status.syncWrites==0)
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false)
        defer{store.drainForTesting()}
        store.setCriticalSynchronizerForTesting{_ in throw CocoaError(.fileWriteOutOfSpace)}
        store.record(.resultApplied,[.request:43])
        #expect(store.status.syncFailures==1 && store.status.syncWrites==1)
        store.setCriticalSynchronizerForTesting(nil)
        store.record(.taskExited,[.request:43])
        let next=try #require(diagnosticRecords(dir,critical:true).last)
        #expect(next.syncFailures==1 && store.status.syncWrites==2)
    }
    @Test func synchronousDelayIsObservedRatherThanPretendingToTimeOut()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false)
        defer{store.drainForTesting()}
        store.setCriticalSynchronizerForTesting{handle in Thread.sleep(forTimeInterval:0.08);try handle.synchronize()}
        let before=ProcessInfo.processInfo.systemUptime
        store.record(.providerEntered,[.operation:3,.request:43])
        let elapsed=ProcessInfo.processInfo.systemUptime-before
        #expect(elapsed>=0.075 && store.status.syncSlowWrites>=1 && store.status.syncMaxDurationMS>=75)
        #expect(try diagnosticRecords(dir,critical:true).last?.event == .providerEntered)
        store.setCriticalSynchronizerForTesting(nil)
    }
    @Test func criticalRotationIsBoundedPrivateAndKeepsLatestEvent()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false,criticalFileLimit:4096)
        defer{store.drainForTesting()}
        var durations:[Double]=[]
        for n in 1...60 {
            let started=ProcessInfo.processInfo.systemUptime
            store.record(.requestStart,[.request:Double(n)])
            durations.append((ProcessInfo.processInfo.systemUptime-started)*1000)
        }
        durations.sort()
        print("VISTA_CRITICAL_LATENCY_MS count=60 min=\(durations[0]) median=\(durations[30]) p95=\(durations[56]) max=\(durations[59])")
        let files=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("critical-")}
        #expect(files.count==4)
        for file in files {
            #expect(try Data(contentsOf:file).count<=4096)
            #expect((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue==0o600)
        }
        #expect(try diagnosticRecords(dir,critical:true).last?.fields["request"]==60)
        #expect(store.status.syncWrites==61 && store.status.syncFailures==0)
    }
    @Test func partialWriteFailureRemeasuresCapacityAndSeparatesDamagedLine()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false,criticalFileLimit:4096)
        defer{store.drainForTesting()}
        store.setCriticalWriterForTesting{handle,data in
            try handle.write(contentsOf:Data(data.prefix(32)))
            throw CocoaError(.fileWriteOutOfSpace)
        }
        for n in 1...130 {store.record(.requestStart,[.request:Double(n)])}
        #expect(store.status.syncFailures==130 && store.status.syncWrites==1)
        let files=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("critical-")}
        #expect(files.count<=4)
        for file in files {#expect(try Data(contentsOf:file).count<=4096)}
        store.setCriticalWriterForTesting(nil)
        store.record(.resultApplied,[.request:200])
        let data=try Data(contentsOf:dir.appendingPathComponent("critical-current.jsonl"))
        let valid=data.split(separator:10).compactMap{try? JSONDecoder().decode(LifecycleRecord.self,from:Data($0))}
        #expect(valid.last?.event == .resultApplied && valid.last?.fields["request"]==200)
        #expect(store.status.syncWrites==2)
    }
    @Test func optionalSyncCountersAllowPreviousSchemaRecords()throws {
        let dir=diagnosticDirectory();defer{try? FileManager.default.removeItem(at:dir)}
        let store=LifecycleDiagnostics(directory:dir,mirror:false)
        defer{store.drainForTesting()}
        let current=try #require(diagnosticRecords(dir,critical:true).first)
        var json=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(current)) as? [String:Any])
        json["schema"]=3
        for key in ["syncWrites","syncFailures","syncSlowWrites","syncMaxDurationMS"] {json.removeValue(forKey:key)}
        let previous=try JSONDecoder().decode(LifecycleRecord.self,from:JSONSerialization.data(withJSONObject:json))
        #expect(previous.schema==3 && previous.syncWrites==nil && previous.syncFailures==nil)
    }
}
