import Foundation
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
    init(transport: any SMBRangeTransport) { self.transport = transport }
    func fileSize(for file: MediaFile) async throws -> UInt64 {
        try Task.checkCancellation()
        guard !closed else { throw MediaInspectionError.unavailable }
        do {
            let attributes = try await transport.attributes(at: file.relativePath)
            try Task.checkCancellation()
            guard !closed, attributes[.fileResourceTypeKey] as? URLFileResourceType == .regular,
                  let size = attributes[.fileSizeKey] as? UInt64, size <= Int64.max else { throw MediaInspectionError.invalidResponse }
            return size
        } catch is CancellationError { throw CancellationError() }
        catch { throw MediaInspectionError.unavailable }
    }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw MediaInspectionError.unavailable }
        guard range.upperBound <= Int64.max, range.upperBound - range.lowerBound <= 1_048_576 else {
            throw MediaInspectionError.invalidResponse
        }
        if range.isEmpty { return Data() }
        do {
            let data = try await transport.read(at: file.relativePath, range: range)
            try Task.checkCancellation()
            guard !closed, UInt64(data.count) == range.upperBound - range.lowerBound else { throw MediaInspectionError.invalidResponse }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch { throw MediaInspectionError.unavailable }
    }
    func close() { closed = true }
}
