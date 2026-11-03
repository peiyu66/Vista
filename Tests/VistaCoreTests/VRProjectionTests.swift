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


@MainActor struct VRPreferenceTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("formats.json")
    }
    @Test func restoresFormatButNotDirectionAndKeepsNamesPrivate() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = VRPreferenceSource.smb(server: "PRIVATE-HOST", share: "PRIVATE-SHARE", account: "PRIVATE-ACCOUNT")
        let file = try MediaFile(components: ["PRIVATE-FOLDER", "PRIVATE-MOVIE.mp4"])
        var settings = VRSettings(); settings.projection = .equirectangular360
        settings.layout = .overUnder; settings.swapEyes = true; settings.yawDegrees = 90
        let store = try VRPreferenceStore(url: url)
        try store.save(VRFormat(settings), source: source, file: file, revision: "PRIVATE-REVISION")
        let reopened = try VRPreferenceStore(url: url)
        let saved = try #require(try reopened.load(source: source, file: file, revision: "PRIVATE-REVISION"))
        #expect(saved == VRFormat(settings)); #expect(saved.settings.yawDegrees == 0)
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.uppercased().contains("PRIVATE")); #expect(!raw.contains("yaw"))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        try reopened.save(nil, source: source, file: file, revision: "PRIVATE-REVISION")
        #expect(try VRPreferenceStore(url: url).load(source: source, file: file, revision: "PRIVATE-REVISION") == nil)
    }
    @Test func sourceRenameAndRevisionBoundaries() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try VRPreferenceStore(url: url)
        let source = VRPreferenceSource.smb(server: "HOST", share: "Videos", account: "reader")
        let file = try MediaFile(components: ["a", "movie.mp4"])
        let format = VRFormat(VRSettings())
        try store.save(format, source: source, file: file, revision: "v1")
        #expect(try store.load(source: .smb(server: " host ", share: "Videos", account: "reader"), file: file, revision: "v1") == format)
        for other in [VRPreferenceSource.demo, .smb(server: "alias", share: "Videos", account: "reader"),
                      .smb(server: "HOST", share: "Other", account: "reader"), .smb(server: "HOST", share: "Videos", account: "other")] {
            #expect(try store.load(source: other, file: file, revision: "v1") == nil)
        }
        #expect(try store.load(source: source, file: MediaFile(components: ["a", "renamed.mp4"]), revision: "v1") == nil)
        #expect(try store.load(source: source, file: MediaFile(components: ["b", "movie.mp4"]), revision: "v1") == nil)
        #expect(try store.load(source: source, file: file, revision: "v2") == nil)
        try store.save(format, source: source, file: file, revision: "v2")
        #expect(try store.load(source: source, file: file, revision: "v1") == nil)
    }
    @Test func corruptAndFutureArchivesAreNotOverwritten() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for data in [Data("broken".utf8), Data("{\"version\":2,\"secret\":\"\",\"records\":{}}".utf8)] {
            try data.write(to: url)
            #expect(throws: (any Error).self) { try VRPreferenceStore(url: url) }
            #expect(try Data(contentsOf: url) == data)
        }
    }
    @Test func failedWriteDoesNotPublishInMemoryRecord() throws {
        let url = temporaryURL()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try VRPreferenceStore(url: url)
        // A regular file in place of the directory makes the write fail deterministically.
        try Data("fixture".utf8).write(to: folder)
        let file = try MediaFile(components: ["fixture.mp4"])
        #expect(throws: (any Error).self) {
            try store.save(VRFormat(VRSettings()), source: .demo, file: file, revision: "v1")
        }
        #expect(try store.load(source: .demo, file: file, revision: "v1") == nil)
    }
    @Test func inspectionRevisionDetectsSizeOrHeaderChanges() async throws {
        struct Source: MediaSource {
            let size: UInt64; let bytes: Data
            func header(for file: MediaFile) async throws -> MediaHeader { MediaHeader(fileSize: size, data: bytes) }
        }
        let file = try MediaFile(components: ["fixture.mp4"])
        let a = try await MediaInspector.inspect(file, source: Source(size: 10, bytes: Data([1, 2])))
        let b = try await MediaInspector.inspect(file, source: Source(size: 11, bytes: Data([1, 2])))
        let c = try await MediaInspector.inspect(file, source: Source(size: 10, bytes: Data([1, 3])))
        #expect(a.revision != b.revision); #expect(a.revision != c.revision)
    }
}
