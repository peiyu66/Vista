//
//  OperationFailure.swift
//  AMSMB2
//
//  Local Vista integration: preserve failure provenance without server text.
//

import Foundation

/// A failure at the SMB operation boundary, without paths, credentials or server text.
public struct SMB2OperationFailure: Error, Sendable, Equatable, LocalizedError {
    public enum Origin: String, Sendable {
        /// smb2_service failed and the client context was destroyed. This does not
        /// identify the underlying cause or prove a physical network disconnect.
        case serviceInvalidated
        /// The request could not be submitted to libsmb2.
        case submission
        /// A command callback reported failure, rather than the service loop.
        case response
        /// Waiting for a command failed, including a poll failure or timeout.
        case wait
        /// No usable client/context was available for the operation.
        case contextUnavailable
    }

    public let origin: Origin
    /// The original return/callback value, if that boundary supplied one.
    public let result: Int32?
    /// A positive POSIX code only when that boundary defines one. In particular,
    /// smb2_service's generic -1 is not the POSIX permission code EPERM.
    public let posixCode: Int32?
    /// Present only for an actual raw PDU callback status. Never sampled from
    /// the context's mutable, potentially stale nterror field.
    public let ntStatus: UInt32?

    public init(origin: Origin, result: Int32? = nil, posixCode: Int32? = nil, ntStatus: UInt32? = nil) {
        self.origin = origin
        self.result = result
        self.posixCode = posixCode
        self.ntStatus = ntStatus
    }

    public var errorDescription: String? {
        "SMB operation failed (\(origin.rawValue))."
    }

    static func throwIfPOSIXFailure(_ result: Int32, origin: Origin) throws {
        guard result < 0 else { return }
        // Avoid overflow and avoid inventing a cancellation code for an unknown result.
        let code = Int32(exactly: -Int64(result))
        throw Self(origin: origin, result: result, posixCode: code)
    }

    /// Preserve existing operation-specific fallbacks for real command errors.
    /// Service-loop and wait failures must not look like server path responses.
    static func matchesPOSIX(_ error: any Error, codes: POSIXErrorCode...) -> Bool {
        if let failure = error as? Self {
            guard failure.origin == .response || failure.origin == .submission,
                  let code = failure.posixCode else { return false }
            return codes.contains { $0.rawValue == code }
        }
        guard let error = error as? POSIXError else { return false }
        return codes.contains(error.code)
    }
}
