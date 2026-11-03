import Foundation

/// A share-relative file identity. Never accepts an absolute path or traversal.
public struct MediaFile: Sendable, Equatable {
    public let components: [String]
    public init(components: [String]) throws {
        guard !components.isEmpty, components.allSatisfy({
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/") && !$0.contains("\\") &&
            !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) else { throw MediaInspectionError.invalidFile }
        self.components = components
    }
    public var relativePath: String { components.joined(separator: "/") }
}

public enum MediaInspectionError: Error { case invalidFile, unavailable, invalidResponse }
public struct MediaHeader: Sendable {
    public let fileSize: UInt64
    public let data: Data
    public init(fileSize: UInt64, data: Data) { self.fileSize = fileSize; self.data = data }
}
public protocol MediaSource: Sendable {
    /// Read no more than MediaInspector.headerLimit bytes, without persisting file data.
    func header(for file: MediaFile) async throws -> MediaHeader
}
public struct MediaInspection: Sendable, Equatable {
    public enum HeaderKind: String, Sendable {
        case isoBaseMedia = "ISO BMFF（MP4 家族）"
        case quickTime = "QuickTime"
        case ebml = "EBML（仍需辨識容器）"
        case unknown = "尚未辨識"
    }
    public let fileSize: UInt64
    public let headerKind: HeaderKind
}
public enum MediaInspector {
    public static let headerLimit = 65_536
    public static func inspect(_ file: MediaFile, source: any MediaSource) async throws -> MediaInspection {
        try Task.checkCancellation()
        let header = try await source.header(for: file)
        try Task.checkCancellation()
        guard header.data.count <= headerLimit, UInt64(header.data.count) <= header.fileSize else {
            throw MediaInspectionError.invalidResponse
        }
        return MediaInspection(fileSize: header.fileSize, headerKind: identify(header.data))
    }
    /// Header identification only; never infers codecs, valid tracks or decode support.
    public static func identify(_ data: Data) -> MediaInspection.HeaderKind {
        let bytes = Array(data.prefix(headerLimit))
        if bytes.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) { return .ebml }
        // Accept a complete leading ftyp box; malformed/truncated/other layouts stay unknown.
        guard bytes.count >= 16, Array(bytes[4..<8]) == Array("ftyp".utf8) else { return .unknown }
        let size = bytes.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard size >= 16, size <= UInt64(bytes.count), (size - 16) % 4 == 0 else { return .unknown }
        return Array(bytes[8..<12]) == Array("qt  ".utf8) ? .quickTime : .isoBaseMedia
    }
}

/// Synthetic header for the visibly labeled demo, never a playable movie.
public struct DemoMediaSource: MediaSource {
    public init() {}
    public func header(for file: MediaFile) async throws -> MediaHeader {
        try await Task.sleep(for: .milliseconds(120))
        let bytes = Data([0, 0, 0, 20] + Array("ftypisom".utf8) + [0, 0, 0, 0] + Array("isom".utf8))
        return MediaHeader(fileSize: UInt64(bytes.count), data: bytes)
    }
}
