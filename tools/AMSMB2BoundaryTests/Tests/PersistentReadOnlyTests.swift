import Foundation
import Testing
import SMB2
@testable import AMSMB2

private final class OfflineOpenManager: SMB2Manager, @unchecked Sendable {
    override func openReadOnlyHandle(atPath path: String) async throws -> any SMB2ReadOnlyHandle {
        throw SMB2ReadOnlyHandleError.unsupportedCapability
    }
}

@Suite(.serialized)
struct PersistentReadOnlyTests {
    @Test func openEntrySupportsOfflineOverride() async throws {
        let manager: SMB2Manager = try #require(OfflineOpenManager(url: URL(string: "smb://synthetic.invalid")!, credential: nil))
        await #expect(throws: SMB2ReadOnlyHandleError.unsupportedCapability) {
            try await manager.openReadOnlyHandle(atPath: "synthetic")
        }
    }

    @Test func fallbackRequiresExplicitUnsupportedCreateResponse() {
        for status: UInt32 in [0xC00000BB, 0xC0000002] {
            #expect(SMB2ReadOnlyHandleError.isUnsupportedCreate(SMB2OperationFailure(origin: .response, ntStatus: status)))
            #expect(!SMB2ReadOnlyHandleError.isUnsupportedCreate(SMB2OperationFailure(origin: .wait, ntStatus: status)))
        }
        for status: UInt32 in [0xC0000022, 0xC0000034, 0xC000000D, 0xC0000043] {
            #expect(!SMB2ReadOnlyHandleError.isUnsupportedCreate(SMB2OperationFailure(origin: .response, ntStatus: status)))
        }
        #expect(!SMB2ReadOnlyHandleError.isUnsupportedCreate(POSIXError(.ENOTSUP)))
    }

    @Test func boundedPositionedReadsContinueShortPositiveAndStopAtEOF() throws {
        var requests: [(UInt64, Int)] = []
        let result = try SMB2ReadOnlyRanges.read(range: 100..<110, maximum: 4, checkCancellation: {}) { offset, length in
            requests.append((offset, length))
            return offset == 104 ? Data() : Data(repeating: 7, count: 2)
        }
        #expect(result.count == 4)
        #expect(requests.map(\.0) == [100, 102, 104])
        #expect(requests.map(\.1) == [4, 4, 4])
        let tail = try SMB2ReadOnlyRanges.read(range: (UInt64.max - 5)..<UInt64.max, maximum: 3, checkCancellation: {}) { _, length in
            Data(repeating: 0, count: length)
        }
        #expect(tail.count == 5)
    }

    @Test func rangeBoundAndCancellationNeverSubmitExtraChunks() throws {
        #expect(throws: SMB2ReadOnlyHandleError.invalidRange) {
            try SMB2ReadOnlyRanges.read(range: 0..<(2 * 1024 * 1024 + 1), maximum: 4, checkCancellation: {}) { _, _ in
                Issue.record("Oversized range reached backend")
                return Data()
            }
        }
        var cancelled = false
        var calls = 0
        #expect(throws: CancellationError.self) {
            try SMB2ReadOnlyRanges.read(range: 0..<10, maximum: 4, checkCancellation: {
                if cancelled { throw CancellationError() }
            }) { _, length in
                calls += 1
                cancelled = true
                return Data(repeating: 0, count: length)
            }
        }
        #expect(calls == 1)
    }

    @Test func invalidatedOriginalHandleClosesLocallyWithoutFreedPointerAccess() async throws {
        let client = try SMB2Client(timeout: 1)
        let file = try SMB2FileHandle(fileDescriptor: compound_file_id, on: client)
        let manager = try #require(SMB2Manager(url: URL(string: "smb://synthetic.invalid")!, credential: nil))
        let handle = SMB2PersistentReadHandle(manager: manager, file: file, initialAttributes: [.fileSizeKey: 12])
        client.invalidateLocally() // Frees C handle; absolutely no SMB RPC may follow.
        let initial = try await handle.attributes()
        #expect(initial[.fileSizeKey] as? Int == 12)
        do {
            _ = try await handle.attributes()
            Issue.record("fstat accepted invalidated context")
        } catch let failure as SMB2OperationFailure {
            #expect(failure.origin == .contextUnavailable)
        }
        do {
            try await handle.close()
            Issue.record("Local abandonment claimed successful remote close")
        } catch let failure as SMB2OperationFailure {
            #expect(failure.origin == .contextUnavailable)
        }
        do {
            try await handle.close() // Same failure, without another RPC.
            Issue.record("Repeated close concealed previous failure")
        } catch let failure as SMB2OperationFailure {
            #expect(failure.origin == .contextUnavailable)
        }
        await #expect(throws: SMB2ReadOnlyHandleError.closed) { try await handle.read(range: 0..<1) }
        await manager.retireLocallyAfterDraining()
    }

    @Test func missingClientOpenDoesNotConnect() async throws {
        let manager = try #require(SMB2Manager(url: URL(string: "smb://synthetic.invalid")!, credential: nil))
        do {
            _ = try await manager.openReadOnlyHandle(atPath: "synthetic")
            Issue.record("Unexpected open")
        } catch let failure as SMB2OperationFailure {
            #expect(failure.origin == .contextUnavailable)
        }
        await manager.retireLocallyAfterDraining()
    }
}
