import Foundation
import CryptoKit

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
    public let revision: String
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
        return MediaInspection(fileSize: header.fileSize, headerKind: identify(header.data),
                               revision: String(header.fileSize) + ":" + SHA256.hash(data: header.data).map { String(format: "%02x", $0) }.joined())
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

/// Bounded random access for the media resource loader. No implicit whole-file download.
public protocol MediaByteSource: MediaSource {
    func fileSize(for file: MediaFile) async throws -> UInt64
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data
}
public extension MediaByteSource {
    func header(for file: MediaFile) async throws -> MediaHeader {
        let size = try await fileSize(for: file)
        let data = try await read(file, range: 0..<min(size, UInt64(MediaInspector.headerLimit)))
        return MediaHeader(fileSize: size, data: data)
    }
}

/// Project-generated color frames. No private or downloaded media.
public struct DemoMediaSource: MediaByteSource {
    public init() {}
    private func bytes(for file: MediaFile) throws -> Data {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        var resource = file.components.last == "格式標記示範.mp4" ? "SyntheticVR" : "Synthetic"
        #if DEBUG && targetEnvironment(simulator) && VISTA_SIMULATOR_SOFTWARE_DECODE
        if file.components.last == "H264 播放測試.mp4" { resource = "SyntheticSeek" }
        if file.components.last == "HEVC 播放測試.mp4" { resource = "SyntheticHEVC" }
        #endif
        guard let url = bundle.url(forResource: resource, withExtension: "mp4") else { throw MediaInspectionError.unavailable }
        return try Data(contentsOf: url)
    }
    public func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(try bytes(for: file).count) }
    public func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        try Task.checkCancellation()
        let data = try bytes(for: file)
        guard range.upperBound <= data.count, range.count <= 1_048_576 else { throw MediaInspectionError.invalidResponse }
        return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
}
