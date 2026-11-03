import Foundation
import CoreGraphics
import simd
import CryptoKit

public enum VRProjection: String, Codable, CaseIterable, Sendable {
    case equirectangular180, equirectangular360, equidistantFisheye180
    public var title: String {
        switch self {
        case .equirectangular180: "等距柱狀 180°"
        case .equirectangular360: "等距柱狀 360°"
        case .equidistantFisheye180: "等距魚眼 180°（置中圓）"
        }
    }
}
public enum VRLayout: String, Codable, CaseIterable, Sendable {
    case mono, sideBySide, overUnder
    public var title: String { switch self { case .mono: "單眼"; case .sideBySide: "左右排列"; case .overUnder: "上下排列" } }
}
public struct VRSettings: Codable, Hashable, Sendable {
    public var projection: VRProjection = .equirectangular180
    public var layout: VRLayout = .mono
    public var swapEyes = false
    public var yawDegrees: Double = 0
    public init() {}
    public func crop(width: Int, height: Int, rightEye: Bool) -> CGRect? {
        guard width > 0, height > 0 else { return nil }
        let second = rightEye != swapEyes
        switch layout {
        case .mono: return CGRect(x: 0, y: 0, width: width, height: height)
        case .sideBySide:
            guard width.isMultiple(of: 2) else { return nil }
            return CGRect(x: second ? width / 2 : 0, y: 0, width: width / 2, height: height)
        case .overUnder:
            guard height.isMultiple(of: 2) else { return nil }
            return CGRect(x: 0, y: second ? height / 2 : 0, width: width, height: height / 2)
        }
    }
}
public struct VRMesh: Sendable {
    public let positions: [SIMD3<Float>]
    public let normals: [SIMD3<Float>]
    public let uv: [SIMD2<Float>]
    public let indices: [UInt32]
    public init(projection: VRProjection) { self.init(projection: projection, eyeAspect: 1) }
    public init?(projection: VRProjection, eyeWidth: Int, eyeHeight: Int) {
        guard eyeWidth > 0, eyeHeight > 0 else { return nil }
        self.init(projection: projection, eyeAspect: Float(eyeWidth) / Float(eyeHeight))
    }
    private init(projection: VRProjection, eyeAspect: Float) {
        let columns = 64, rows = 32
        let span: Float = projection == .equirectangular360 ? 2 * .pi : .pi
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        for row in 0...rows {
            let v = Float(row) / Float(rows), latitude = Float.pi / 2 - v * .pi
            for column in 0...columns {
                let u = Float(column) / Float(columns), longitude = (u - 0.5) * span
                let direction = SIMD3<Float>(sin(longitude) * cos(latitude), sin(latitude), -cos(longitude) * cos(latitude))
                positions.append(direction * 100)
                normals.append(-direction)
                if projection == .equidistantFisheye180 {
                    let radial = hypot(direction.x, direction.y)
                    let angle = atan2(radial, max(0, -direction.z))
                    // r = f*theta; the 90-degree rim maps to the inscribed circle.
                    let scale = radial > 0.000001 ? angle / (.pi * radial) : 1 / Float.pi
                    uv.append(SIMD2(0.5 + direction.x * scale * min(1, 1 / eyeAspect),
                                    0.5 + direction.y * scale * min(1, eyeAspect)))
                } else { uv.append(SIMD2(u, 1 - v)) }
            }
        }
        for row in 0..<rows { for column in 0..<columns {
            let a = UInt32(row * (columns + 1) + column), b = a + 1, c = a + UInt32(columns + 1), d = c + 1
            indices += [a, c, b, b, c, d]
        } }
        self.positions = positions; self.normals = normals; self.uv = uv; self.indices = indices
    }
}


/// Persisted format deliberately excludes the session's viewing direction.
public struct VRFormat: Codable, Equatable, Sendable {
    public let projection: VRProjection
    public let layout: VRLayout
    public let swapEyes: Bool
    public init(_ settings: VRSettings) {
        projection = settings.projection; layout = settings.layout; swapEyes = settings.swapEyes
    }
    public var settings: VRSettings {
        var value = VRSettings()
        value.projection = projection; value.layout = layout; value.swapEyes = swapEyes
        return value
    }
}

public struct VRPreferenceSource: Sendable {
    fileprivate let components: [String]
    public static let demo = Self(components: ["demo-v1"])
    public static func smb(server: String, share: String, account: String) -> Self {
        Self(components: ["smb-v1", server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), share, account])
    }
}

/// Main-actor serialization; opaque identifiers are privacy minimization, not encryption.
@MainActor public final class VRPreferenceStore {
    private struct Record: Codable {
        let revision: String
        let format: VRFormat
    }
    private struct Archive: Codable {
        var version = 1
        var secret: Data
        var records: [String: Record] = [:]
    }
    public enum Failure: Error { case invalidArchive, capacity }
    private let url: URL
    private var archive: Archive
    public static let local: Result<VRPreferenceStore, Error> = Result {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true).appendingPathComponent("Vista", isDirectory: true)
        return try VRPreferenceStore(url: folder.appendingPathComponent("vr-formats-v1.json"))
    }
    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 2_097_152 else { throw Failure.invalidArchive }
            archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
            guard archive.version == 1, archive.secret.count == 32, archive.records.count <= 5000 else {
                throw Failure.invalidArchive
            }
        } else {
            let key = SymmetricKey(size: .bits256)
            archive = Archive(secret: key.withUnsafeBytes { Data($0) })
        }
    }
    private func digest(_ parts: [String]) throws -> String {
        let bytes = try JSONEncoder().encode(parts)
        return HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: archive.secret))
            .map { String(format: "%02x", $0) }.joined()
    }
    public func load(source: VRPreferenceSource, file: MediaFile, revision: String) throws -> VRFormat? {
        let key = try digest(source.components + file.components)
        guard let record = archive.records[key], record.revision == (try digest(["revision", revision])) else { return nil }
        return record.format
    }
    public func save(_ format: VRFormat?, source: VRPreferenceSource, file: MediaFile, revision: String) throws {
        let key = try digest(source.components + file.components)
        var next = archive
        if let format {
            guard next.records[key] != nil || next.records.count < 5000 else { throw Failure.capacity }
            next.records[key] = Record(revision: try digest(["revision", revision]), format: format)
        } else { next.records.removeValue(forKey: key) }
        let bytes = try JSONEncoder().encode(next)
        guard bytes.count <= 2_097_152 else { throw Failure.capacity }
        var folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        #if os(visionOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        archive = next
    }
}
