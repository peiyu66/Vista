import Foundation
import AMSMB2
#if SWIFT_PACKAGE
import VistaCore
#endif

/// Fixed playback-only categories. No underlying server text, paths or credentials escape.
/// Unlike directory recovery, an unclassified failure cannot authorize playback reconnect.
public enum SMBPlaybackReadFailure: Int, Error, Sendable, Equatable {
    case cancelled = 1, retired, permissionDenied, authenticationRequired, notFound, serverRejected
    case serviceInvalidated, contextUnavailable, transportFailure, unclassifiedSessionFailure
    case invalidResponse, invalidRange, retiredByPlaybackRecovery

    public var allowsFreshRecovery: Bool {
        switch self {
        case .serviceInvalidated, .contextUnavailable, .transportFailure, .retiredByPlaybackRecovery: true
        default: false
        }
    }

    static func classify(_ error: any Error) -> Self {
        if let failure = error as? Self { return failure }
        if let failure = error as? SMB2ReadOnlyHandleError {
            switch failure {
            case .invalidRange: return .invalidRange
            case .closed: return .retired
            case .unsupportedCapability: return .serverRejected
            }
        }
        if error is MediaInspectionError { return .invalidResponse }
        if let failure = error as? PlaybackSourceRecoveryError {
            return failure == .invalidRange ? .invalidRange : .invalidResponse
        }
        let value = error as NSError
        if value.domain == NSURLErrorDomain, value.code == NSURLErrorBadServerResponse {
            return .invalidResponse
        }
        switch SMBDirectoryProvider.recoveryDisposition(for: error) {
        case .cancelled: return .cancelled
        case .retired: return .retired
        case .permissionDenied: return .permissionDenied
        case .authenticationRequired: return .authenticationRequired
        case .notFound: return .notFound
        case .serverRejected: return .serverRejected
        case .serviceInvalidated: return .serviceInvalidated
        case .contextUnavailable: return .contextUnavailable
        case .transportFailure: return .transportFailure
        case .unclassifiedSessionFailure: return .unclassifiedSessionFailure
        case .retiredByPlaybackRecovery: return .retiredByPlaybackRecovery
        }
    }
}

/// One file handle per playback; the browser's authenticated provider remains borrowed.
/// This adapter never reconnects. The existing core wrapper owns recovery decisions.
public final class SMBPlaybackSession: MediaByteSource, Sendable {
    public let provider: SMBDirectoryProvider
    private let reader: SMBMediaReader
    private let transport: SMBPlaybackHandleTransport

    public init(provider: SMBDirectoryProvider) {
        self.provider = provider
        let parts = provider.makePlaybackReader()
        reader = parts.reader; transport = parts.transport
    }

    public func metadata(for file: MediaFile) async throws -> PlaybackSourceIdentity {
        do { return try await reader.playbackMetadata(for: file) }
        catch is CancellationError { throw CancellationError() }
        catch { throw await provider.playbackFailure(error) }
    }

    public func fileSize(for file: MediaFile) async throws -> UInt64 {
        try await metadata(for: file).size
    }

    public func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        do { return try await reader.playbackRead(file, range: range) }
        catch is CancellationError { throw CancellationError() }
        catch { throw await provider.playbackFailure(error) }
    }

    /// Normal stop only closes this playback's file, never the borrowed directory connection.
    public func finishPlayback() async throws {
        await reader.close()
        do { try await provider.finishPlaybackTransport(transport) }
        catch { throw Self.recoveryDisposition(for: error) }
    }

    public func retireForPlaybackRecovery() async throws {
        await reader.close()
        do {
            // Preserve the existing no-RPC retirement: drain and invalidate the context first.
            try await provider.retireForPlaybackRecovery()
            try await transport.closeAfterProviderRetirement()
        } catch is CancellationError { throw CancellationError() }
        catch { throw Self.recoveryDisposition(for: error) }
    }

    /// Classification is eligibility only; the core wrapper owns the bounded fresh attempt.
    public static func recoveryDisposition(for error: any Error) -> SMBPlaybackReadFailure {
        SMBPlaybackReadFailure.classify(error)
    }
}

/// Demand-only transport. A session binds one path; no handle survives into a different movie.
/// All reads still enter the existing provider leases/diagnostics through SMBMediaReader.
actor SMBPlaybackHandleTransport: SMBRangeTransport {
    private let manager: SMB2Manager
    private let operations = SMBOperationLeases()
    private var path: String?
    private var handle: (any SMB2ReadOnlyHandle)?
    private var opening: Task<any SMB2ReadOnlyHandle, any Error>?
    private var openingFailure: (any Error)?
    private var legacyFallback = false
    private var stopped = false
    private var cleanup: Task<Void, any Error>?

    init(manager: SMB2Manager) { self.manager = manager }

    private func resolve(_ requestedPath: String) async throws -> (any SMB2ReadOnlyHandle)? {
        try Task.checkCancellation()
        guard !stopped else { throw SMBPlaybackReadFailure.retired }
        if let path, path != requestedPath { throw SMBPlaybackReadFailure.invalidRange }
        path = requestedPath
        if legacyFallback { return nil }
        if let handle { return handle }
        if let openingFailure { throw openingFailure }
        let task: Task<any SMB2ReadOnlyHandle, any Error>
        if let opening { task = opening }
        else {
            let manager = manager
            task = Task { try await manager.openReadOnlyHandle(atPath: requestedPath) }
            opening = task
        }
        do {
            let opened = try await task.value
            handle = opened; opening = nil
            try Task.checkCancellation()
            guard !stopped else { throw SMBPlaybackReadFailure.retired }
            return opened
        } catch SMB2ReadOnlyHandleError.unsupportedCapability {
            // Never hold a less-permissive persistent handle. Only a specific unsupported
            // CREATE capability response permits the original per-range path for this movie.
            opening = nil; legacyFallback = true
            try Task.checkCancellation()
            guard !stopped else { throw SMBPlaybackReadFailure.retired }
            return nil
        } catch {
            if handle == nil { openingFailure = error; opening = nil }
            throw error
        }
    }

    func attributes(at path: String) async throws -> [URLResourceKey: any Sendable] {
        guard !stopped, operations.acquire() else { throw SMBPlaybackReadFailure.retired }
        defer { operations.release() }
        let file = try await resolve(path)
        let attributes: [URLResourceKey: any Sendable]
        if let file { attributes = try await file.attributes() }
        else { attributes = try await manager.attributesOfItem(atPath: path) }
        try Task.checkCancellation()
        guard !stopped else { throw SMBPlaybackReadFailure.retired }
        return attributes
    }

    func read(at path: String, range: Range<UInt64>) async throws -> Data {
        guard !stopped, operations.acquire() else { throw SMBPlaybackReadFailure.retired }
        defer { operations.release() }
        let file = try await resolve(path)
        let data: Data
        if let file { data = try await file.read(range: range) }
        else { data = try await manager.contents(atPath: path, range: range, progress: nil) }
        try Task.checkCancellation()
        guard !stopped else { throw SMBPlaybackReadFailure.retired }
        return data
    }

    /// Only callers that already completed provider retirement may use this path.
    /// The C context has gone: local abandonment is expected, not a remote-close receipt.
    func closeAfterProviderRetirement() async throws {
        do { try await close() }
        catch let failure as SMB2OperationFailure where failure.origin == .contextUnavailable { }
    }

    func close() async throws {
        if let cleanup { return try await cleanup.value }
        stopped = true; operations.close()
        let task = Task {
            // The actual open/read/metadata return owns release, never caller cancellation.
            await self.operations.waitForDrain()
            if let file = self.handle { try await file.close() }
            self.handle = nil
        }
        cleanup = task
        try await task.value
    }
}
