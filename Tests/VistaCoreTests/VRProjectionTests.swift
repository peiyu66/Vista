import Foundation
import CoreGraphics
import simd
import Testing
@testable import VistaCore

struct VRProjectionTests {
    @Test func eyeRegionsAndSwapAreExplicit() {
        var settings = VRSettings()
        #expect(settings.crop(width: 400, height: 200, rightEye: true) == CGRect(x: 0, y: 0, width: 400, height: 200))
        settings.layout = .sideBySide
        #expect(settings.crop(width: 400, height: 200, rightEye: false) == CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(settings.crop(width: 400, height: 200, rightEye: true) == CGRect(x: 200, y: 0, width: 200, height: 200))
        settings.swapEyes = true
        #expect(settings.crop(width: 400, height: 200, rightEye: false) == CGRect(x: 200, y: 0, width: 200, height: 200))
        settings.layout = .overUnder; settings.swapEyes = false
        #expect(settings.crop(width: 400, height: 200, rightEye: false) == CGRect(x: 0, y: 0, width: 400, height: 100))
        #expect(settings.crop(width: 400, height: 200, rightEye: true) == CGRect(x: 0, y: 100, width: 400, height: 100))
    }
    @Test func invalidSplitDimensionsDoNotDropPixels() {
        var settings = VRSettings()
        #expect(settings.crop(width: 0, height: 100, rightEye: false) == nil)
        settings.layout = .sideBySide
        #expect(settings.crop(width: 401, height: 200, rightEye: false) == nil)
        settings.layout = .overUnder
        #expect(settings.crop(width: 400, height: 201, rightEye: false) == nil)
    }
    @Test(arguments: VRProjection.allCases) func projectionCoverageAndTextureOrientation(projection: VRProjection) {
        let mesh = VRMesh(projection: projection)
        #expect(mesh.positions.count == 65 * 33)
        #expect(mesh.indices.count == 64 * 32 * 6)
        let center = 16 * 65 + 32
        #expect(simd_distance(mesh.positions[center], SIMD3(0, 0, -100)) < 0.001)
        #expect(mesh.uv[center] == SIMD2(0.5, 0.5))
        #expect(mesh.uv[0] == SIMD2(0, 1))
        #expect(mesh.uv.last == SIMD2(1, 0))
        if projection == .equirectangular180 {
            #expect(mesh.positions.allSatisfy { $0.z <= 0.001 })
        } else {
            #expect(simd_distance(mesh.positions[16 * 65], mesh.positions[16 * 65 + 64]) < 0.001)
            #expect(mesh.positions[16 * 65].z > 99)
        }
    }
    @Test func trianglesFaceTheViewerInsideSphere() {
        let mesh = VRMesh(projection: .equirectangular360)
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.positions[Int(mesh.indices[i])], b = mesh.positions[Int(mesh.indices[i + 1])], c = mesh.positions[Int(mesh.indices[i + 2])]
            let cross = simd_cross(b - a, c - a)
            if simd_length(cross) > 0.01 { #expect(simd_dot(cross, a + b + c) < 0) }
        }
        #expect(zip(mesh.positions, mesh.normals).allSatisfy { abs(simd_dot($0, $1) + 100) < 0.001 })
    }
}
