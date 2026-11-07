import Foundation
import Darwin
import Testing
import SMB2
import SMB2.Raw
@testable import AMSMB2

@Suite(.serialized)
struct FailureBoundaryTests {
    private func failure(_ body: () throws -> Void) throws -> SMB2OperationFailure {
        do {
            try body()
            Issue.record("Expected a typed failure")
            return SMB2OperationFailure(origin: .submission)
        } catch let error as SMB2OperationFailure {
            return error
        }
    }

    // A local pipe supplies only a valid fd for the callback guard. No socket,
    // SMB request, poll loop, timeout, remote share or authentication is used.
    private func callbackClient() throws -> (SMB2Client, Int32) {
        let client = try SMB2Client(timeout: 60)
        var fds = [Int32](repeating: -1, count: 2)
        guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
        client.context!.pointee.fd = fds[0]
        return (client, fds[1])
    }

    @Test(arguments: [Int32(-1), -5, -701])
    func serviceFailureIsNotPermission(_ result: Int32) throws {
        let client = try SMB2Client(timeout: 60)
        let error = try failure { try client.handleServiceResult(result) }
        #expect(error.origin == .serviceInvalidated)
        #expect(error.result == result)
        #expect(error.posixCode == nil)
        #expect(error.ntStatus == nil)
        #expect(client.context == nil)
    }

    @Test func serviceSuccessKeepsContext() throws {
        let client = try SMB2Client(timeout: 60)
        try client.handleServiceResult(0)
        #expect(client.context != nil)
        client.invalidateLocally()
    }

    @Test(arguments: [EPERM, EACCES, ENOENT, ECANCELED])
    func submissionPreservesCode(_ code: Int32) throws {
        let client = try SMB2Client(timeout: 60)
        defer { client.invalidateLocally() }
        let error = try failure { try client.async_await { _, _ in -code } }
        #expect(error.origin == .submission)
        #expect(error.result == -code)
        #expect(error.posixCode == code)
        #expect(error.ntStatus == nil)
    }

    @Test(arguments: [EPERM, EACCES, ENOENT, ECANCELED, ECONNRESET])
    func callbackPreservesRealResponse(_ code: Int32) throws {
        let (client, writeFD) = try callbackClient()
        defer { client.invalidateLocally(); close(writeFD) }
        let error = try failure {
            try client.async_await { context, callback in
                SMB2Client.generic_handler(context, -code, nil, callback)
                return 0
            }
        }
        #expect(error.origin == .response)
        #expect(error.result == -code)
        #expect(error.posixCode == code)
        #expect(error.ntStatus == nil)
    }

    @Test func pduStatusComesFromCallback() throws {
        let (client, writeFD) = try callbackClient()
        defer { client.invalidateLocally(); close(writeFD) }
        // A stale, different context nterror must not replace the callback status.
        client.context!.pointee.nterror = Int32(bitPattern: SMB2_STATUS_OBJECT_NAME_NOT_FOUND)
        let error = try failure {
            try client.async_await_pdu { context, callback in
                let pdu = smb2_cmd_echo_async(context, SMB2Client.generic_handler, callback)
                SMB2Client.generic_handler(context, Int32(bitPattern: SMB2_STATUS_ACCESS_DENIED), nil, callback)
                return pdu
            }
        }
        #expect(error.origin == .response)
        #expect(error.ntStatus == SMB2_STATUS_ACCESS_DENIED)
        #expect(error.posixCode == EACCES)
    }

    @Test func missingPDUIsSubmissionWithoutStaleStatus() throws {
        let client = try SMB2Client(timeout: 60)
        defer { client.invalidateLocally() }
        client.context!.pointee.nterror = Int32(bitPattern: SMB2_STATUS_ACCESS_DENIED)
        let error = try failure { try client.async_await_pdu { _, _ in nil } }
        #expect(error.origin == .submission)
        #expect(error.posixCode == nil)
        #expect(error.ntStatus == nil)
    }

    @Test func contextUnavailableIsTyped() throws {
        let client = try SMB2Client(timeout: 60)
        client.invalidateLocally()
        let error = try failure { try client.echo() }
        #expect(error.origin == .contextUnavailable)
        #expect(error.posixCode == ENOTCONN)
    }

    @Test func asyncWaitFailureDestroysPendingCallbackBeforeReturn() throws {
        let client = try SMB2Client(timeout: 60)
        // fd is -1 from initialization, so wait fails immediately, without poll
        // or timeout. A single queued artificial callback exercises cleanup.
        let error = try failure {
            try client.async_await { context, callback in
                guard let pdu = smb2_cmd_echo_async(context, SMB2Client.generic_handler, callback) else {
                    throw POSIXError(.ENOMEM)
                }
                smb2_queue_pdu(context, pdu)
                return 0
            }
        }
        #expect(error.origin == .contextUnavailable)
        #expect(error.posixCode == ENOTCONN)
        #expect(client.context == nil)
    }

    @Test func pduWaitFailureDestroysPendingCallbackBeforeReturn() throws {
        let client = try SMB2Client(timeout: 60)
        let error = try failure {
            try client.async_await_pdu { context, callback in
                smb2_cmd_echo_async(context, SMB2Client.generic_handler, callback)
            }
        }
        #expect(error.origin == .contextUnavailable)
        #expect(error.posixCode == ENOTCONN)
        #expect(client.context == nil)
    }

    @Test func destroyDiscardsExpiredCallbackBeforeDereference() throws {
        let (client, writeFD) = try callbackClient()
        defer { close(writeFD) }
        let pdu = try #require(smb2_cmd_echo_async(
            client.context, SMB2Client.generic_handler, UnsafeMutableRawPointer(bitPattern: 1)
        ))
        smb2_queue_pdu(client.context, pdu)
        client.invalidateLocally()
        #expect(client.context == nil)
        client.invalidateLocally() // Idempotent, no disconnect from deinit.
    }

    private final class CallbackState: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let allowReturn = DispatchSemaphore(value: 0)
        let retired = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var callbackReturned = false
        var retirementSawReturn = false
    }

    @Test func retirementWaitsForCallbackReturn() throws {
        let manager = try #require(SMB2Manager(url: URL(string: "smb://synthetic.invalid")!, credential: nil))
        let state = CallbackState()
        // With no client, echo completes locally with contextUnavailable.
        manager.echo { error in
            #expect((error as? SMB2OperationFailure)?.origin == .contextUnavailable)
            state.entered.signal()
            state.allowReturn.wait()
            state.lock.lock()
            state.callbackReturned = true
            state.lock.unlock()
        }
        state.entered.wait()
        manager.retireLocallyAfterDraining {
            state.lock.lock()
            state.retirementSawReturn = state.callbackReturned
            state.lock.unlock()
            state.retired.signal()
        }
        #expect(state.retired.wait(timeout: .now()) == .timedOut)
        state.allowReturn.signal()
        state.retired.wait()
        #expect(state.retirementSawReturn)
    }

    @Test func failureDescriptionContainsNoContextText() {
        let error = SMB2OperationFailure(origin: .serviceInvalidated, result: -1)
        #expect(error.errorDescription == "SMB operation failed (serviceInvalidated).")
    }

    @Test(arguments: [SMB2OperationFailure.Origin.submission, .response])
    func existingSymlinkFallbackAcceptsCommandCodes(_ origin: SMB2OperationFailure.Origin) {
        let error = SMB2OperationFailure(origin: origin, result: -ENOLINK, posixCode: ENOLINK)
        #expect(SMB2OperationFailure.matchesPOSIX(error, codes: .ENOLINK))
        #expect(!SMB2OperationFailure.matchesPOSIX(error, codes: .ENETRESET))
    }

    @Test(arguments: [SMB2OperationFailure.Origin.serviceInvalidated, .wait, .contextUnavailable])
    func symlinkFallbackRejectsNonCommandOrigins(_ origin: SMB2OperationFailure.Origin) {
        let error = SMB2OperationFailure(origin: origin, result: -ENOLINK, posixCode: ENOLINK)
        #expect(!SMB2OperationFailure.matchesPOSIX(error, codes: .ENOLINK))
    }

    @Test func existingSymlinkFallbackAcceptsLegacyPOSIX() {
        #expect(SMB2OperationFailure.matchesPOSIX(POSIXError(.ENOLINK), codes: .ENOLINK))
        #expect(SMB2OperationFailure.matchesPOSIX(POSIXError(.ENETRESET), codes: .ENOLINK, .ENETRESET))
        #expect(!SMB2OperationFailure.matchesPOSIX(POSIXError(.EACCES), codes: .ENOLINK))
    }

    @Test func localFileHandleCopiesIDAndSeeksWithoutNetwork() throws {
        let client = try SMB2Client(timeout: 60)
        defer { client.invalidateLocally() }
        let identifier = UUID()
        let file = try SMB2FileHandle(fileDescriptor: identifier.uuid, on: client)
        #expect(file.fileId == identifier)
        #expect(try file.lseek(offset: 12, whence: .set) == 12)
        #expect(try file.lseek(offset: 0, whence: .current) == 12)
        // Destroy before file deinit so the test never submits close RPC.
        client.invalidateLocally()
        #expect(file.fileId == UUID(uuid: compound_file_id))
        #expect(client.fileDescriptor == -1)
    }

    @Test func fileHandleCreationRejectsDestroyedContext() throws {
        let client = try SMB2Client(timeout: 60)
        client.invalidateLocally()
        let error = try failure {
            _ = try SMB2FileHandle(fileDescriptor: compound_file_id, on: client)
        }
        #expect(error.origin == .contextUnavailable)
    }

    @Test func localHandleMethodsRejectDestroyedContextBeforeDereference() throws {
        let client = try SMB2Client(timeout: 60)
        let file = try SMB2FileHandle(fileDescriptor: compound_file_id, on: client)
        client.invalidateLocally() // Frees the C fh; Swift wrapper now holds an expired pointer.
        #expect(try failure { _ = try file.lseek(offset: 0, whence: .current) }.origin == .contextUnavailable)
        #expect(try failure { _ = try file.read() }.origin == .contextUnavailable)
        #expect(try failure { _ = try file.pread(offset: 0) }.origin == .contextUnavailable)
        #expect(try failure {
            let _: AnyDecodableResponse = try file.fcntl(command: .srvRequestResumeKey)
        }.origin == .contextUnavailable)
    }
}
