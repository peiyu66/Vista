import Foundation
import CoreGraphics
import simd
import Testing
@testable import VistaCore

struct VRFisheyeTests {
    @Test func centeredEquidistantCardinalDirectionsAndAngles() {
        let mesh = VRMesh(projection: .equidistantFisheye180)
        #expect(mesh.positions.allSatisfy { $0.z <= 0.001 })
        let points: [(Int, Int, SIMD2<Float>)] = [(16,32,[0.5,0.5]), (16,0,[0,0.5]), (16,64,[1,0.5]),
                                                (0,32,[0.5,1]), (32,32,[0.5,0]), (16,48,[0.75,0.5]), (8,32,[0.5,0.75])]
        for (row, column, expected) in points {
            #expect(simd_distance(mesh.uv[row * 65 + column], expected) < 0.00001)
        }
        #expect(mesh.uv.allSatisfy { simd_distance($0, SIMD2(0.5, 0.5)) <= 0.50001 })
        #expect(mesh.uv.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }
    @Test func rectangularEyeUsesInscribedCircleRatherThanStretchedEllipse() throws {
        let wide = try #require(VRMesh(projection: .equidistantFisheye180, eyeWidth: 1000, eyeHeight: 500))
        let tall = try #require(VRMesh(projection: .equidistantFisheye180, eyeWidth: 500, eyeHeight: 1000))
        #expect(simd_distance(wide.uv[16 * 65 + 64], [0.75,0.5]) < 0.00001)
        #expect(simd_distance(wide.uv[32], [0.5,1]) < 0.00001)
        #expect(simd_distance(tall.uv[16 * 65 + 64], [1,0.5]) < 0.00001)
        #expect(simd_distance(tall.uv[32], [0.5,0.75]) < 0.00001)
        #expect(VRMesh(projection: .equidistantFisheye180, eyeWidth: 0, eyeHeight: 10) == nil)
        #expect(VRMesh(projection: .equidistantFisheye180, eyeWidth: 10, eyeHeight: -1) == nil)
        for projection in [VRProjection.equirectangular180, .equirectangular360] {
            let resized = try #require(VRMesh(projection: projection, eyeWidth: 1000, eyeHeight: 500))
            #expect(resized.uv == VRMesh(projection: projection).uv)
            #expect(resized.positions == VRMesh(projection: projection).positions)
        }
    }
    @Test func inverseProjectionRecoversHemisphereDirections() throws {
        for (width, height) in [(512,512), (1024,512), (512,1024)] {
            let mesh = try #require(VRMesh(projection: .equidistantFisheye180, eyeWidth: width, eyeHeight: height))
            let radius = Float(min(width, height)) / 2
            for (position, uv) in zip(mesh.positions, mesh.uv) {
                let p = SIMD2((uv.x - 0.5) * Float(width) / radius, (uv.y - 0.5) * Float(height) / radius)
                let r = simd_length(p), angle = r * .pi / 2
                let ray = r > 0.000001 ? SIMD3(p.x / r * sin(angle), p.y / r * sin(angle), -cos(angle)) : SIMD3<Float>(0,0,-1)
                #expect(simd_distance(ray, position / 100) < 0.00001)
            }
        }
    }
    @Test func calibrationChartEyeRegionsAndOrientation() throws {
        for layout in VRLayout.allCases {
            let image = try #require(VRFisheyeCalibration.image(layout: layout))
            #expect(image.width == (layout == .overUnder ? 512 : 1024))
            #expect(image.height == (layout == .overUnder ? 1024 : 512))
            let data = try #require(image.dataProvider?.data)
            let bytes = try #require(CFDataGetBytePtr(data))
            func color(_ x: Int, _ y: Int) -> [UInt8] {
                let base = y * image.bytesPerRow + x * 4
                return Array(UnsafeBufferPointer(start: bytes + base, count: 3))
            }
            #expect(color(0,0) == [0,0,0])
            let xOffset = layout == .mono ? 256 : 0
            #expect(color(270 + xOffset,120) == [25,155,45]) // Up is green, not vertically inverted.
            #expect(color(400 + xOffset,240) == [175,30,30])
            #expect(color(120 + xOffset,240) == [180,140,25])
            #expect(color(270 + xOffset,400) == [30,60,180])
            #expect(color(256 + xOffset,256) == [240,240,240])
            if layout == .sideBySide { #expect(color(768,256) == [240,50,220]) }
            if layout == .overUnder { #expect(color(256,768) == [240,50,220]) }
            var settings = VRSettings(); settings.projection = .equidistantFisheye180; settings.layout = layout
            let left = try #require(settings.crop(width: image.width, height: image.height, rightEye: false))
            let right = try #require(settings.crop(width: image.width, height: image.height, rightEye: true))
            #expect(left.width == (layout == .mono ? 1024 : 512) && left.height == 512)
            #expect(right.width == (layout == .mono ? 1024 : 512) && right.height == 512)
            settings.swapEyes = true
            #expect(settings.crop(width: image.width, height: image.height, rightEye: false) == right)
        }
    }
    @Test @MainActor func fishEyeManualFormatPersistsAndOldFormatsStillDecode() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("format.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try VRPreferenceStore(url: url), file = try MediaFile(components: ["fixture.mp4"])
        var settings = VRSettings(); settings.projection = .equidistantFisheye180; settings.layout = .sideBySide; settings.swapEyes = true
        try store.save(VRFormat(settings), source: .demo, file: file, revision: "v1")
        let restored = try VRPreferenceStore(url: url).load(source: .demo, file: file, revision: "v1")
        #expect(restored == VRFormat(settings))
        let legacy = Data("{\"projection\":\"equirectangular360\",\"layout\":\"overUnder\",\"swapEyes\":false}".utf8)
        #expect(try JSONDecoder().decode(VRFormat.self, from: legacy).projection == .equirectangular360)
    }
}
