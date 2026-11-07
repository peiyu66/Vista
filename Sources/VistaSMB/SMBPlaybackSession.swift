import Foundation
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

/// One authenticated provider, borrowed or owned by the caller's playback recovery wrapper.
/// This adapter makes no recovery decisions itself and never creates a second manager.
public final class SMBPlaybackSession: MediaByteSource, Sendable {
    public let provider: SMBDirectoryProvider

    public init(provider: SMBDirectoryProvider) { self.provider = provider }

    public func metadata(for file: MediaFile) async throws -> PlaybackSourceIdentity {
        try await provider.playbackMetadata(for: file)
    }

    public func fileSize(for file: MediaFile) async throws -> UInt64 {
        try await metadata(for: file).size
    }

    public func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        try await provider.playbackRead(file, range: range)
    }

    public func retireForPlaybackRecovery() async throws {
        do { try await provider.retireForPlaybackRecovery() }
        catch is CancellationError { throw CancellationError() }
        catch { throw Self.recoveryDisposition(for: error) }
    }

    /// Classification is eligibility only; the core wrapper owns the single bounded attempt.
    public static func recoveryDisposition(for error: any Error) -> SMBPlaybackReadFailure {
        SMBPlaybackReadFailure.classify(error)
    }
}
