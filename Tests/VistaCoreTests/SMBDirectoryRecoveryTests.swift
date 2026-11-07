import Foundation
import Testing
@testable import AMSMB2
@testable import VistaCore
@testable import VistaSMB

/// One manually completed operation, with a distinct post-callback queue-drain event.
/// This substitute never invokes a library connect/read/disconnect or opens a socket.
private final class DirectoryRecoveryFixture: @unchecked Sendable {
    typealias Completion = @Sendable (Result<[[URLResourceKey:any Sendable]],any Error>)->Void
    private let lock=NSLock()
    private var completion:Completion?
    private var listCalls=0,retireCalls=0,invalidationCalls=0,disconnectCalls=0
    var normalFailure:(any Error)?
    let queueDrain=SMBOperationLeases()
    init() {precondition(queueDrain.acquire())}
    func capture(_ callback:@escaping Completion) {
        lock.lock();defer{lock.unlock()}
        precondition(completion==nil && listCalls==0,"Fixture permits only one directory operation")
        listCalls += 1;completion=callback
    }
    func returnRead(_ result:Result<[[URLResourceKey:any Sendable]],any Error>) {
        lock.lock();let callback=completion;completion=nil;lock.unlock()
        precondition(callback != nil)
        callback?(result)
    }
    func retireStarted() {lock.lock();retireCalls += 1;lock.unlock()}
    func invalidated() {lock.lock();invalidationCalls += 1;lock.unlock()}
    func disconnectStarted() {lock.lock();disconnectCalls += 1;lock.unlock()}
    var snapshot:(list:Int,retire:Int,invalidate:Int,disconnect:Int) {
        lock.lock();defer{lock.unlock()};return(listCalls,retireCalls,invalidationCalls,disconnectCalls)
    }
}

private final class DirectoryRecoveryManager: SMB2Manager, @unchecked Sendable {
    let fixture=DirectoryRecoveryFixture()
    override func contentsOfDirectory(atPath path:String,recursive:Bool=false,
        completionHandler:@Sendable @escaping (Result<[[URLResourceKey:any Sendable]],any Error>)->Void) {
        fixture.capture(completionHandler)
    }
    override func retireLocallyAfterDraining() async {
        fixture.retireStarted()
        await fixture.queueDrain.waitForDrain()
        fixture.invalidated()
    }
    override func disconnectShare(gracefully:Bool=false) async throws {
        fixture.disconnectStarted()
        await fixture.queueDrain.waitForDrain()
        if let failure=fixture.normalFailure {throw failure}
    }
}

private actor RecoveryRangeFixture: SMBRangeTransport {
    enum Operation {case attributes,range}
    var entered=false
    private var pending:CheckedContinuation<Void,Never>?
    private var ready:CheckedContinuation<Void,Never>?
    private func suspend() async {
        await withCheckedContinuation {continuation in
            pending=continuation;entered=true;ready?.resume();ready=nil
        }
    }
    func waitUntilEntered() async {
        if !entered {await withCheckedContinuation {ready=$0}}
    }
    func complete() {pending?.resume();pending=nil}
    func attributes(at path:String) async throws->[URLResourceKey:any Sendable] {
        await suspend()
        return [.fileSizeKey:UInt64(4),.fileResourceTypeKey:URLFileResourceType.regular]
    }
    func read(at path:String,range:Range<UInt64>) async throws->Data {
        await suspend();return Data(count:range.count)
    }
}

@Suite(.serialized)
struct SMBDirectoryRecoveryTests {
    private func diagnostics()->LifecycleDiagnostics {
        LifecycleDiagnostics(directory:FileManager.default.temporaryDirectory.appendingPathComponent("vista-recovery-tests-\(UUID().uuidString)"),mirror:false,criticalDurability:false)
    }

    @Test func knownFailuresNeverAuthorizeRecovery() {
        let cases:[(any Error,SMBDirectoryReadFailure)]=[
            (CancellationError(),.cancelled),
            (URLError(.cancelled),.cancelled),
            (POSIXError(.ECANCELED),.cancelled),
            (POSIXError(.ENOENT),.notFound),
            (POSIXError(.ENOTDIR),.notFound),
            (POSIXError(.EACCES),.permissionDenied),
            (URLError(.userAuthenticationRequired),.authenticationRequired),
            (SMBDirectoryReadFailure.retired,.retired),
            (SMB2OperationFailure(origin:.response,result:-EPERM,posixCode:EPERM),.permissionDenied),
            (SMB2OperationFailure(origin:.response,result:-EACCES,posixCode:EACCES),.permissionDenied),
            (SMB2OperationFailure(origin:.response,result:-ENOENT,posixCode:ENOENT),.notFound),
            (SMB2OperationFailure(origin:.response,ntStatus:0xC000006D),.authenticationRequired),
            (SMB2OperationFailure(origin:.response,result:-ECONNREFUSED,posixCode:ECONNREFUSED),.authenticationRequired),
            (SMB2OperationFailure(origin:.response,ntStatus:0xC0000022),.permissionDenied),
            (SMB2OperationFailure(origin:.response,ntStatus:0xC0000061),.permissionDenied),
            (SMB2OperationFailure(origin:.response,ntStatus:0xC00000CA),.permissionDenied),
            (SMB2OperationFailure(origin:.response,ntStatus:0xC000003A),.notFound),
            (SMB2OperationFailure(origin:.response,ntStatus:0xC0000103),.notFound),
            (SMB2OperationFailure(origin:.response,ntStatus:0xC0000120),.cancelled),
            (SMB2OperationFailure(origin:.response,result:-ENOTSUP,posixCode:ENOTSUP),.serverRejected)
        ]
        for (error,expected) in cases {
            let actual=SMBDirectoryProvider.recoveryDisposition(for:error)
            #expect(actual==expected)
            #expect(!actual.allowsFreshRecovery)
        }
    }

    @Test func uncertainSessionFailuresAreEligibleWithoutInventingDisconnectCause() {
        let cases:[(any Error,SMBDirectoryReadFailure)]=[
            (SMB2OperationFailure(origin:.serviceInvalidated,result:-1),.serviceInvalidated),
            (SMB2OperationFailure(origin:.contextUnavailable),.contextUnavailable),
            (SMB2OperationFailure(origin:.submission,result:-1,posixCode:EPERM),.unclassifiedSessionFailure),
            (SMB2OperationFailure(origin:.wait,result:-ETIMEDOUT,posixCode:ETIMEDOUT),.unclassifiedSessionFailure),
            (SMB2OperationFailure(origin:.wait,posixCode:ECONNRESET),.transportFailure),
            (SMB2OperationFailure(origin:.response,ntStatus:0xC0000203),.contextUnavailable),
            (SMB2OperationFailure(origin:.response,result:-ETIMEDOUT,posixCode:ETIMEDOUT),.unclassifiedSessionFailure),
            (SMB2OperationFailure(origin:.response,result:-ENETRESET,posixCode:ENETRESET),.unclassifiedSessionFailure),
            (SMB2OperationFailure(origin:.response,result:-EPIPE,posixCode:EPIPE),.unclassifiedSessionFailure),
            (SMB2OperationFailure(origin:.response,result:-ECONNRESET,posixCode:ECONNRESET),.unclassifiedSessionFailure),
            (SMB2OperationFailure(origin:.response,result:-ENOTCONN,posixCode:ENOTCONN),.unclassifiedSessionFailure),
            (SMB2OperationFailure(origin:.response,result:-EIO,posixCode:EIO),.unclassifiedSessionFailure),
            (SMB2OperationFailure(origin:.response,ntStatus:0xDEADBEEF),.unclassifiedSessionFailure),
            (POSIXError(.EPERM),.unclassifiedSessionFailure),
            (POSIXError(.ETIMEDOUT),.unclassifiedSessionFailure),
            (URLError(.timedOut),.unclassifiedSessionFailure),
            (URLError(.networkConnectionLost),.transportFailure),
            (NSError(domain:"synthetic-unknown",code:1),.unclassifiedSessionFailure)
        ]
        for (error,expected) in cases {
            let actual=SMBDirectoryProvider.recoveryDisposition(for:error)
            #expect(actual==expected)
            #expect(actual.allowsFreshRecovery)
        }
        #expect(SMBDirectoryReadFailure.serviceInvalidated.rawValue==7)
        #expect(SMBDirectoryReadFailure.unclassifiedSessionFailure.rawValue==10)
    }

    @Test func typedMetadataErrorsPreserveServerResponseMeaning() {
        let expected:[(Int32,FinderTagState)]=[(ENOENT,.unavailable),(ENODATA,.unavailable),
            (ENOTSUP,.unsupported),(EACCES,.denied),(EPERM,.denied)]
        for (code,state) in expected {
            #expect(SMBDirectoryProvider.tagFailure(SMB2OperationFailure(origin:.response,result:-code,posixCode:code))==state)
            #expect(SMBDirectoryProvider.tagFailure(SMB2OperationFailure(origin:.submission,result:-code,posixCode:code)) == .failed)
        }
        #expect(SMBDirectoryProvider.tagFailure(SMB2OperationFailure(origin:.serviceInvalidated,result:-1)) == .failed)
    }

    @Test func diagnosticsPreserveOnlyNumericOriginAndDefinedErrno() {
        let service=SMBDirectoryProvider.diagnosticFailure(for:SMB2OperationFailure(origin:.serviceInvalidated,result:-1))
        #expect(service.domain==0 && service.code==0 && service.origin==1)
        #expect(!service.isCancellation && !service.isTimeout)
        let denied=SMBDirectoryProvider.diagnosticFailure(for:SMB2OperationFailure(origin:.response,result:-EPERM,posixCode:EPERM))
        #expect(denied.domain==1 && denied.code==Int(EPERM) && denied.origin==3)
        let timeout=SMBDirectoryProvider.diagnosticFailure(for:SMB2OperationFailure(origin:.wait,posixCode:ETIMEDOUT))
        #expect(timeout.isTimeout && timeout.origin==4)
        let cancelled=SMBDirectoryProvider.diagnosticFailure(for:SMB2OperationFailure(origin:.response,ntStatus:0xC0000120))
        #expect(cancelled.isCancellation && cancelled.domain==0 && cancelled.code==0)
        let unavailable=SMBDirectoryProvider.diagnosticFailure(for:SMB2OperationFailure(origin:.contextUnavailable))
        #expect(unavailable.domain==0 && unavailable.code==0 && unavailable.origin==5)
        #expect(LifecycleFailure(CancellationError()).isCancellation)
    }

    @Test func leaseCloseRejectsNewWorkAndCancellationCannotFakeDrain() async {
        // Sequential single-operation model for every provider operation family.
        for _ in ["page","tags","finder","attributes","range"] {
            let leases=SMBOperationLeases()
            #expect(leases.acquire())
            leases.close()
            #expect(!leases.acquire())
            let drain=Task {await leases.waitForDrain()}
            while leases.snapshot.waiting==0 {await Task.yield()}
            drain.cancel()
            #expect(leases.snapshot.active==1)
            #expect(leases.snapshot.waiting==1)
            leases.release() // Explicit original callback completion, never task cancellation.
            await drain.value
            #expect(leases.snapshot.active==0)
            #expect(leases.snapshot.waiting==0)
        }
    }

    @Test func pagePreservesOriginalErrorAndRetirementWaitsForDistinctQueueDrain() async throws {
        let manager=try #require(DirectoryRecoveryManager(url:URL(string:"smb://fixture.invalid")!,credential:nil))
        let provider=SMBDirectoryProvider(manager:manager,diagnostics:diagnostics(),session:1)
        let original=SMB2OperationFailure(origin:.serviceInvalidated,result:-1)
        let page=Task {try await provider.page(at:DirectoryPath(),offset:0)}
        while manager.fixture.snapshot.list==0 {await Task.yield()}
        manager.fixture.returnRead(.failure(original))
        do {_=try await page.value;Issue.record("Expected original list failure")}
        catch {#expect(error as? SMB2OperationFailure == original)}

        // Swift page has returned, but the fake queue has not completed its callback tail.
        let retirement=Task {try await provider.retireForDirectoryRecovery()}
        while manager.fixture.snapshot.retire==0 {await Task.yield()}
        #expect(manager.fixture.snapshot.invalidate==0)
        retirement.cancel()
        await #expect(throws:SMBDirectoryReadFailure.retired) {try await provider.page(at:DirectoryPath(),offset:0)}
        await #expect(throws:SMBDirectoryReadFailure.retired) {try await provider.tags(at:DirectoryPath())}
        await #expect(throws:SMBDirectoryReadFailure.retired) {try await provider.hasFinderEvidence(paths:["fixture"])}
        let file=try MediaFile(components:["fixture.mp4"])
        await #expect(throws:MediaInspectionError.unavailable) {try await provider.fileSize(for:file)}
        await #expect(throws:MediaInspectionError.unavailable) {try await provider.read(file,range:0..<1)}
        #expect(manager.fixture.snapshot.list==1)
        #expect(manager.fixture.snapshot.invalidate==0)
        manager.fixture.queueDrain.release()
        try await retirement.value
        try await provider.retireForDirectoryRecovery()
        #expect(manager.fixture.snapshot.retire==1)
        #expect(manager.fixture.snapshot.invalidate==1)
    }

    @Test func mediaLeaseRemainsUntilSingleManualTransportCompletes() async throws {
        let file=try MediaFile(components:["fixture.mp4"])
        for operation in [RecoveryRangeFixture.Operation.attributes,.range] {
            let leases=SMBOperationLeases(),transport=RecoveryRangeFixture()
            let reader=SMBMediaReader(transport:transport,diagnostics:diagnostics(),leases:leases)
            let read=Task {
                switch operation {
                case .attributes:_=try await reader.fileSize(for:file)
                case .range:_=try await reader.read(file,range:0..<4)
                }
            }
            await transport.waitUntilEntered()
            #expect(leases.snapshot.active==1)
            read.cancel();leases.close();await reader.close()
            let drain=Task {await leases.waitForDrain()}
            while leases.snapshot.waiting==0 {await Task.yield()}
            #expect(leases.snapshot.active==1)
            await transport.complete()
            await #expect(throws:CancellationError.self) {try await read.value}
            await drain.value
            #expect(leases.snapshot.active==0)
        }
    }

    @Test func cancelledPageCannotRetireBeforeItsCallbackReturns() async throws {
        let leases=SMBOperationLeases()
        let manager=try #require(DirectoryRecoveryManager(url:URL(string:"smb://fixture.invalid")!,credential:nil))
        let provider=SMBDirectoryProvider(manager:manager,diagnostics:diagnostics(),session:1,leases:leases)
        let page=Task {try await provider.page(at:DirectoryPath(),offset:0)}
        while manager.fixture.snapshot.list==0 {await Task.yield()}
        page.cancel()
        let retirement=Task {try await provider.retireForDirectoryRecovery()}
        while leases.snapshot.accepting {await Task.yield()}
        #expect(leases.snapshot.active==1)
        #expect(manager.fixture.snapshot.retire==0)
        manager.fixture.returnRead(.failure(SMB2OperationFailure(origin:.serviceInvalidated,result:-1)))
        await #expect(throws:CancellationError.self) {try await page.value}
        while manager.fixture.snapshot.retire==0 {await Task.yield()}
        #expect(leases.snapshot.active==0)
        #expect(manager.fixture.snapshot.invalidate==0)
        manager.fixture.queueDrain.release()
        try await retirement.value
        #expect(manager.fixture.snapshot.invalidate==1)
    }

    @Test func cancelledConnectEntrypointsDoNotAllocateOrConnect() async {
        for fresh in [false,true] {
            let task=Task {
                withUnsafeCurrentTask {$0?.cancel()}
                let input=ConnectionInput(server:"fixture.invalid",share:"fixture",username:"fixture")
                if fresh {_=try await SMBDirectoryProvider.connectFreshForRecovery(input:input,password:"")}
                else {_=try await SMBDirectoryProvider.connect(input:input,password:"")}
            }
            await #expect(throws:CancellationError.self) {try await task.value}
        }
    }

    @Test func recoveryJoinsEarlierNormalCleanupAndPropagatesItsFailure() async throws {
        for fail in [false,true] {
            let manager=try #require(DirectoryRecoveryManager(url:URL(string:"smb://fixture.invalid")!,credential:nil))
            let failure=SMB2OperationFailure(origin:.serviceInvalidated,result:-1)
            manager.fixture.normalFailure=fail ? failure:nil
            let provider=SMBDirectoryProvider(manager:manager,diagnostics:diagnostics(),session:1)
            let ordinary=Task {await provider.disconnect()}
            while manager.fixture.snapshot.disconnect==0 {await Task.yield()}
            let recovery=Task {try await provider.retireForDirectoryRecovery()}
            manager.fixture.queueDrain.release()
            await ordinary.value
            if fail {
                do {try await recovery.value;Issue.record("Recovery must see failed prior cleanup")}
                catch {#expect(error as? SMB2OperationFailure == failure)}
            } else {try await recovery.value}
            #expect(manager.fixture.snapshot.disconnect==1)
            #expect(manager.fixture.snapshot.retire==0)
            #expect(manager.fixture.snapshot.list==0)
        }
    }
}
