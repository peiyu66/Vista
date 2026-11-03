import Foundation
import Testing
@testable import VistaCore

private struct HeaderSource: MediaSource {
    let value: MediaHeader
    func header(for file: MediaFile) async throws -> MediaHeader { value }
}
private actor DelayedHeaderSource: MediaSource {
    var started = false
    private var continuation: CheckedContinuation<MediaHeader, Never>?
    func header(for file: MediaFile) async throws -> MediaHeader {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: MediaHeader(fileSize: 0, data: Data())); continuation = nil }
}
struct MediaInspectionTests {
    private var mp4: Data { Data([0, 0, 0, 20] + Array("ftypisom".utf8) + [0, 0, 0, 0] + Array("isom".utf8)) }
    @Test func validatesShareRelativeIdentity() throws {
        #expect(try MediaFile(components: ["影片", "clip.mp4"]).relativePath == "影片/clip.mp4")
        for path in [[], [""], [".."], [".hidden"], ["/absolute"], ["a/b"], ["a\\b"], ["bad\n"]] {
            #expect(throws: MediaInspectionError.self) { try MediaFile(components: path) }
        }
    }
    @Test func identifiesHeadersWithoutAssumingDecodeSupport() {
        #expect(MediaInspector.identify(mp4) == .isoBaseMedia)
        var quickTime = mp4; quickTime.replaceSubrange(8..<12, with: Array("qt  ".utf8))
        #expect(MediaInspector.identify(quickTime) == .quickTime)
        #expect(MediaInspector.identify(Data([0x1a, 0x45, 0xdf, 0xa3])) == .ebml)
        #expect(MediaInspector.identify(Data("movie.mp4".utf8)) == .unknown)
        for length in 0..<mp4.count { #expect(MediaInspector.identify(mp4.prefix(length)) == .unknown) }
        var invalidSize = mp4; invalidSize[3] = 19
        #expect(MediaInspector.identify(invalidSize) == .unknown)
        invalidSize[0] = 255
        #expect(MediaInspector.identify(invalidSize) == .unknown)
    }
    @Test func boundsHeaderAndPreservesLargeFileSize() async throws {
        let file = try MediaFile(components: ["clip.mp4"])
        let result = try await MediaInspector.inspect(file, source: HeaderSource(value: MediaHeader(fileSize: 9_000_000_000, data: mp4)))
        #expect(result.fileSize == 9_000_000_000)
        #expect(result.headerKind == .isoBaseMedia)
        for header in [MediaHeader(fileSize: 0, data: mp4), MediaHeader(fileSize: 1_000_000, data: Data(count: MediaInspector.headerLimit + 1))] {
            await #expect(throws: MediaInspectionError.self) { try await MediaInspector.inspect(file, source: HeaderSource(value: header)) }
        }
        let empty = try await MediaInspector.inspect(file, source: HeaderSource(value: MediaHeader(fileSize: 0, data: Data())))
        #expect(empty.headerKind == .unknown)
    }
    @Test func cancelledInspectionDiscardsLateIO() async throws {
        let source = DelayedHeaderSource()
        let file = try MediaFile(components: ["clip.mp4"])
        let task = Task { try await MediaInspector.inspect(file, source: source) }
        while !(await source.started) { await Task.yield() }
        task.cancel()
        await source.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
