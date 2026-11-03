import Foundation
import CoreGraphics
import simd

public enum VRProjection: String, Codable, CaseIterable, Sendable {
    case equirectangular180, equirectangular360
    public var title: String { self == .equirectangular180 ? "等距柱狀 180°" : "等距柱狀 360°" }
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
    public init(projection: VRProjection) {
        let columns = 64, rows = 32
        let span: Float = projection == .equirectangular180 ? .pi : 2 * .pi
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        for row in 0...rows {
            let v = Float(row) / Float(rows), latitude = Float.pi / 2 - v * .pi
            for column in 0...columns {
                let u = Float(column) / Float(columns), longitude = (u - 0.5) * span
                let direction = SIMD3<Float>(sin(longitude) * cos(latitude), sin(latitude), -cos(longitude) * cos(latitude))
                positions.append(direction * 100)
                normals.append(-direction)
                uv.append(SIMD2(u, 1 - v))
            }
        }
        for row in 0..<rows { for column in 0..<columns {
            let a = UInt32(row * (columns + 1) + column), b = a + 1, c = a + UInt32(columns + 1), d = c + 1
            indices += [a, c, b, b, c, d]
        } }
        self.positions = positions; self.normals = normals; self.uv = uv; self.indices = indices
    }
}
