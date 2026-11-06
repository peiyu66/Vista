import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

private func word(_ value: UInt32) -> Data {
    Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
}
private func box(_ type: String, _ payload: Data) -> Data { word(UInt32(payload.count + 8)) + Data(type.utf8) + payload }
private func spherical(bounds: [UInt32] = [0,0,0,0], pose: UInt32 = 0, mapping: String = "equi") -> Data {
    let header = box("svhd", Data(repeating: 0, count: 4) + Data("fixture\0".utf8))
    let projection = box("prhd", word(0) + word(pose) + word(0) + word(0))
        + box(mapping, word(0) + bounds.reduce(into: Data()) { $0.append(word($1)) })
    return box("sv3d", header + box("proj", projection))
}
private func stereo(_ mode: UInt8) -> Data { box("st3d", word(0) + Data([mode])) }
private func movie(_ tags: Data, tracks: Int = 1, legacy: Bool = false, rotated: Bool = false) -> Data {
    var header = Data(repeating: 0, count: 40)
    for value: UInt32 in [rotated ? 0 : 65536,0,0,0,65536,0,0,0,1 << 30] { header.append(word(value)) }
    header.append(Data(repeating: 0, count: 8))
    let entry = box("avc1", Data(repeating: 0, count: 78) + tags)
    let descriptor = box("stsd", word(0) + word(1) + entry)
    let handler = box("hdlr", word(0) + word(0) + Data("vide".utf8) + Data(repeating: 0, count: 12))
    let uuid = Data([0xff,0xcc,0x82,0x63,0xf8,0x55,0x4a,0x93,0x88,0x14,0x58,0x7a,0x02,0x52,0x1f,0xdd])
    let track = box("trak", box("tkhd", header) + box("mdia", handler + box("minf", box("stbl", descriptor))) + (legacy ? box("uuid", uuid) : Data()))
    return box("moov", (0..<tracks).reduce(into: Data()) { result, _ in result.append(track) })
}
private let ftyp = box("ftyp", Data("isom".utf8) + word(0) + Data("isom".utf8))
private struct Bytes: MediaByteSource {
    let data: Data
    func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(data.count) }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        guard range.upperBound <= data.count else { throw MediaInspectionError.invalidResponse }
        return Data(data[Int(range.lowerBound)..<Int(range.upperBound)])
    }
}
private actor SparseMovie: MediaByteSource {
    let tail: Data
    let gap: UInt64 = 4_294_967_296
    var ranges: [Range<UInt64>] = []
    init(tail: Data) { self.tail = tail }
    func fileSize(for file: MediaFile) async throws -> UInt64 { UInt64(ftyp.count) + gap + UInt64(tail.count) }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        ranges.append(range)
        let base = UInt64(ftyp.count)
        if range.upperBound <= base { return Data(ftyp[Int(range.lowerBound)..<Int(range.upperBound)]) }
        if range.lowerBound >= base + gap {
            return Data(tail[Int(range.lowerBound - base - gap)..<Int(range.upperBound - base - gap)])
        }
        let header = word(1) + Data("mdat".utf8) + word(1) + word(0)
        guard range.lowerBound >= base, range.upperBound <= base + 16 else { throw MediaInspectionError.invalidResponse }
        return Data(header[Int(range.lowerBound - base)..<Int(range.upperBound - base)])
    }
}
struct VRMetadataTests {
    private let file = try! MediaFile(components: ["fixture.mp4"])
    private func inspect(_ data: Data) async throws -> VRMetadataResult {
        try await VRMetadataInspector.inspect(file, source: Bytes(data: data))
    }
    @Test func recognizedProjectionAndStereoModes() async throws {
        for (bounds, projection) in [([UInt32](repeating: 0, count: 4), VRProjection.equirectangular360),
                                      ([0,0,1 << 30,1 << 30], .equirectangular180)] {
            for (mode, layout) in [(UInt8(0), VRLayout.mono), (1, .overUnder), (2, .sideBySide)] {
                var settings = VRSettings(); settings.projection = projection; settings.layout = layout
                #expect(try await inspect(ftyp + movie(stereo(mode) + spherical(bounds: bounds))) == .recognized(VRFormat(settings)))
            }
        }
    }
    @Test func absentPartialAndDuplicateTagsDoNotGuess() async throws {
        #expect(try await inspect(ftyp + movie(Data())) == .missing)
        #expect(try await inspect(ftyp + movie(stereo(2))) == .partial(.init(layout:.sideBySide)))
        #expect(try await inspect(ftyp + movie(spherical())) == .partial(.init(projection:.equirectangular360)))
        #expect(try await inspect(ftyp + movie(stereo(1) + stereo(2) + spherical())) == .conflicting)
        #expect(try await inspect(ftyp + movie(stereo(1) + spherical() + spherical())) == .conflicting)
        #expect(try await inspect(ftyp + movie(stereo(1) + spherical()) + movie(Data())) == .conflicting)
        // Box names inside compressed data or unrelated boxes cannot count as metadata.
        #expect(try await inspect(ftyp + box("mdat", stereo(2) + spherical()) + movie(Data())) == .missing)
    }
    @Test func unsupportedConventionsDoNotBecomeSuccessfulDetection() async throws {
        for tags in [stereo(4), stereo(4) + spherical(), stereo(3) + spherical(), stereo(255) + spherical(), stereo(2) + spherical(mapping: "mshp"),
                     stereo(2) + spherical(bounds: [1,0,0,0]), stereo(2) + spherical(pose: 65536),
                     box("st3d", word(1 << 24) + Data([2])) + spherical()] {
            #expect(try await inspect(ftyp + movie(tags)) == .unsupported)
        }
        #expect(try await inspect(ftyp + movie(stereo(2) + spherical(), legacy: true)) == .unsupported)
        #expect(try await inspect(ftyp + movie(stereo(2) + spherical(), rotated: true)) == .unsupported)
        #expect(try await inspect(ftyp + movie(stereo(2) + spherical(), tracks: 2)) == .unsupported)
        #expect(try await inspect(ftyp + movie(stereo(2) + spherical()) + box("moof", Data())) == .unsupported)
    }
    @Test func malformedSizesAndReadLimitsFailSafely() async throws {
        for bytes in [Data([0]), word(4) + Data("moov".utf8), word(UInt32.max) + Data("moov".utf8),
                      word(1) + Data("moov".utf8) + Data(repeating: 255, count: 8),
                      ftyp + movie(stereo(2) + box("sv3d", Data([0])))] {
            #expect(try await inspect(bytes) == .invalid)
        }
        let excessive = (0..<65).reduce(into: Data()) { result, _ in result.append(box("free", Data())) }
        #expect(try await inspect(excessive) == .limitExceeded)
        #expect(try await inspect(ftyp + box("moov", Data(repeating: 0, count: VRMetadataInspector.movieLimit + 1))) == .limitExceeded)
        let truncated = ftyp + movie(stereo(2) + spherical()).dropLast()
        #expect(try await inspect(truncated) == .invalid)
    }
    @Test func tailMetadataSkipsFourGiBPayload() async throws {
        let source = SparseMovie(tail: movie(stereo(2) + spherical()))
        let result = try await VRMetadataInspector.inspect(file, source: source)
        #expect(result.format?.projection == .equirectangular360)
        #expect(result.format?.layout == .sideBySide)
        let ranges = await source.ranges
        #expect(ranges.reduce(UInt64(0)) { $0 + ($1.upperBound - $1.lowerBound) } < 1024)
        #expect(ranges.allSatisfy { $0.count <= 65_536 })
    }
    @Test func manualChoiceWinsAndAutomaticResultsAreNotManual() {
        var automatic = VRSettings(); automatic.projection = .equirectangular360; automatic.layout = .overUnder
        var choice = VRFormatChoice(metadata: .recognized(VRFormat(automatic)))
        #expect(choice.confirmed); #expect(choice.manual == nil)
        let manual = VRFormat(VRSettings())
        choice.manual = manual
        #expect(choice.format == manual)
        choice.metadata = .conflicting
        #expect(choice.format == manual); #expect(choice.confirmed)
        choice.manual = nil
        #expect(!choice.confirmed)
        choice.metadata = .recognized(VRFormat(automatic))
        #expect(choice.format == VRFormat(automatic)); #expect(choice.manual == nil)
    }
    @Test func cancellationPropagatesAndShortReadDoesNotSucceed() async throws {
        struct Broken: MediaByteSource {
            func fileSize(for file: MediaFile) async throws -> UInt64 { 100 }
            func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data { Data() }
        }
        #expect(try await VRMetadataInspector.inspect(file, source: Broken()) == .invalid)
        let task = Task {
            try Task.checkCancellation()
            return try await VRMetadataInspector.inspect(file, source: Bytes(data: ftyp + movie(stereo(2) + spherical())))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func taggedSyntheticMovieStillUsesHardwareDecoder() async throws {
        let file = try MediaFile(components: ["格式標記示範.mp4"])
        let metadata = try await VRMetadataInspector.inspect(file, source: DemoMediaSource())
        #expect(metadata.format?.projection == .equirectangular360)
        #expect(metadata.format?.layout == .overUnder)
        do {
            let report = try await HardwarePlayback().play(file: file, source: DemoMediaSource(), onInfo: { _ in }, onFrame: { _ in })
            #expect(report.hardwareVerified); #expect(report.decodedFrames == 24)
            print("TAGGED_SYNTHETIC_HARDWARE_FRAMES", report.decodedFrames)
        } catch let failure as PlaybackFailure where failure.category == .hardwareUnavailable { print("TAGGED_SYNTHETIC_HARDWARE_UNAVAILABLE") }
    }
}
