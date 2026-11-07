import Foundation
import CoreFoundation
import AMSMB2
#if SWIFT_PACKAGE
import VistaCore
#endif

/// Internal seam for transport fault tests; production always uses the authenticated manager.
protocol SMBRangeTransport: Sendable {
    func attributes(at path: String) async throws -> [URLResourceKey: any Sendable]
    func read(at path: String, range: Range<UInt64>) async throws -> Data
}
struct AMSMBRangeTransport: SMBRangeTransport {
    let manager: SMB2Manager
    func attributes(at path: String) async throws -> [URLResourceKey: any Sendable] {
        try await manager.attributesOfItem(atPath: path)
    }
    func read(at path: String, range: Range<UInt64>) async throws -> Data {
        try await manager.contents(atPath: path, range: range, progress: nil)
    }
}

/// Exactly one requested range per transport call. Short/overlong replies fail closed.
actor SMBMediaReader: MediaByteSource {
    private let transport: any SMBRangeTransport
    private var closed = false
    private let diagnostics:LifecycleDiagnostics
    private let diagnosticSession:UInt64
    private var activeCalls=0
    private let operationLeases:SMBOperationLeases
    init(transport:any SMBRangeTransport,diagnostics:LifecycleDiagnostics = .shared,session:UInt64=0,leases:SMBOperationLeases=SMBOperationLeases()) {self.transport=transport;self.diagnostics=diagnostics;diagnosticSession=session;operationLeases=leases}
    func fileSize(for file: MediaFile) async throws -> UInt64 {
        try Task.checkCancellation()
        guard !closed else { throw MediaInspectionError.unavailable }
        guard operationLeases.acquire() else {throw MediaInspectionError.unavailable}
        defer {operationLeases.release()}
        let operation=diagnostics.begin(.attributes,session:diagnosticSession)
        activeCalls += 1;defer{activeCalls -= 1};var returned=false
        do {
            let attributes = try await transport.attributes(at: file.relativePath)
            returned=true;diagnostics.finish(operation)
            try Task.checkCancellation()
            guard !closed, attributes[.fileResourceTypeKey] as? URLFileResourceType == .regular,
                  let size = attributes[.fileSizeKey] as? UInt64, size <= Int64.max else { throw MediaInspectionError.invalidResponse }
            return size
        } catch is CancellationError {if !returned {diagnostics.finish(operation,failure:SMBDirectoryProvider.diagnosticFailure(for:CancellationError()))};throw CancellationError()}
        catch {if !returned {diagnostics.finish(operation,failure:SMBDirectoryProvider.diagnosticFailure(for:error))};throw MediaInspectionError.unavailable}
    }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw MediaInspectionError.unavailable }
        guard range.upperBound <= Int64.max, range.upperBound - range.lowerBound <= 1_048_576 else {
            throw MediaInspectionError.invalidResponse
        }
        if range.isEmpty { return Data() }
        guard operationLeases.acquire() else {throw MediaInspectionError.unavailable}
        defer {operationLeases.release()}
        let operation=diagnostics.begin(.rangeRead,session:diagnosticSession)
        activeCalls += 1;defer{activeCalls -= 1};var returned=false
        do {
            let data = try await transport.read(at: file.relativePath, range: range)
            returned=true;diagnostics.finish(operation)
            try Task.checkCancellation()
            guard !closed, UInt64(data.count) == range.upperBound - range.lowerBound else { throw MediaInspectionError.invalidResponse }
            return data
        } catch is CancellationError {if !returned {diagnostics.finish(operation,failure:SMBDirectoryProvider.diagnosticFailure(for:CancellationError()))};throw CancellationError()}
        catch {if !returned {diagnostics.finish(operation,failure:SMBDirectoryProvider.diagnosticFailure(for:error))};throw MediaInspectionError.unavailable}
    }

    /// One stat supplies the whole comparison token. This is a change detector, not a
    /// server snapshot or a guarantee that the file cannot change between stat and read.
    func playbackMetadata(for file: MediaFile) async throws -> PlaybackSourceIdentity {
        try Task.checkCancellation()
        guard !closed, operationLeases.acquire() else { throw SMBPlaybackReadFailure.retired }
        defer { operationLeases.release() }
        let operation = diagnostics.begin(.attributes, session: diagnosticSession)
        activeCalls += 1; defer { activeCalls -= 1 }; var returned = false
        do {
            let attributes = try await transport.attributes(at: file.relativePath)
            returned = true; diagnostics.finish(operation)
            try Task.checkCancellation()
            guard !closed else { throw SMBPlaybackReadFailure.retired }
            func unsignedInteger(_ key: URLResourceKey) -> UInt64? {
                guard let value = attributes[key] as? UInt64,
                      let number = attributes[key] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
                return value
            }
            guard attributes[.fileResourceTypeKey] as? URLFileResourceType == .regular,
                  let size = unsignedInteger(.fileSizeKey), size <= Int64.max else {
                throw SMBPlaybackReadFailure.invalidResponse
            }
            // Missing timestamps must not prevent ordinary reads on this same session.
            // The recovery wrapper refuses cross-session continuation without a complete
            // fingerprint. An absent/invalid server timestamp is not invented as an identity.
            func timestamp(_ key: URLResourceKey) -> Date? {
                guard let value = attributes[key] as? Date,
                      value.timeIntervalSince1970.isFinite, value.timeIntervalSince1970 > 0 else { return nil }
                return value
            }
            // documentIdentifier comes from smb2_stat_64.smb2_ino, not an open SMBFileId.
            // Servers may return zero when no stable identifier is available.
            let inode = unsignedInteger(.documentIdentifierKey)
            let identity = PlaybackSourceIdentity(size: size, modificationDate: timestamp(.contentModificationDateKey),
                creationDate: timestamp(.creationDateKey), changeDate: timestamp(.attributeModificationDateKey),
                stableIdentifier: inode.flatMap { $0 == 0 ? nil : String($0) })
            return identity
        } catch is CancellationError {
            if !returned { diagnostics.finish(operation, failure: SMBDirectoryProvider.diagnosticFailure(for: CancellationError())) }
            throw CancellationError()
        } catch {
            if !returned { diagnostics.finish(operation, failure: SMBDirectoryProvider.diagnosticFailure(for: error)) }
            try Task.checkCancellation()
            throw SMBPlaybackSession.recoveryDisposition(for: error)
        }
    }

    /// Keeps typed provenance only for playback. The existing public inspection/read paths
    /// above deliberately retain their compatibility mapping to MediaInspectionError.
    func playbackRead(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw SMBPlaybackReadFailure.retired }
        guard range.upperBound <= Int64.max, range.upperBound - range.lowerBound <= 1_048_576 else {
            throw SMBPlaybackReadFailure.invalidRange
        }
        if range.isEmpty { return Data() }
        guard operationLeases.acquire() else { throw SMBPlaybackReadFailure.retired }
        defer { operationLeases.release() }
        let operation = diagnostics.begin(.rangeRead, session: diagnosticSession)
        activeCalls += 1; defer { activeCalls -= 1 }; var returned = false
        do {
            let data = try await transport.read(at: file.relativePath, range: range)
            returned = true; diagnostics.finish(operation)
            try Task.checkCancellation()
            guard !closed else { throw SMBPlaybackReadFailure.retired }
            guard UInt64(data.count) == range.upperBound - range.lowerBound else {
                throw SMBPlaybackReadFailure.invalidResponse
            }
            return data
        } catch is CancellationError {
            if !returned { diagnostics.finish(operation, failure: SMBDirectoryProvider.diagnosticFailure(for: CancellationError())) }
            throw CancellationError()
        } catch {
            if !returned { diagnostics.finish(operation, failure: SMBDirectoryProvider.diagnosticFailure(for: error)) }
            try Task.checkCancellation()
            throw SMBPlaybackSession.recoveryDisposition(for: error)
        }
    }
    func close() {diagnostics.record(.readerClosed,[.session:Double(diagnosticSession),.active:Double(activeCalls)]);closed=true}
}
