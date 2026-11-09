import Foundation
import Testing
@testable import VistaCore
@testable import VistaSMB

private actor TwoMiBTransportFixture: SMBRangeTransport {
    enum Reply: Sendable, Equatable { case exact, short, long }
    let reply: Reply
    private(set) var ranges: [Range<UInt64>] = []
    init(_ reply: Reply = .exact) { self.reply = reply }
    func attributes(at path: String) async throws -> [URLResourceKey: any Sendable] {
        [.fileSizeKey: NSNumber(value: UInt64(8_000_000_000)), .fileResourceTypeKey: URLFileResourceType.regular]
    }
    func read(at path: String, range: Range<UInt64>) async throws -> Data {
        ranges.append(range)
        let size = range.count + (reply == .short ? -1 : reply == .long ? 1 : 0)
        return Data((0..<size).map { UInt8(truncatingIfNeeded: range.lowerBound + UInt64($0)) })
    }
}
private final class TypedTwoMiBSource: MediaByteSource {
    let reader: SMBMediaReader
    init(reader: SMBMediaReader) { self.reader = reader }
    func fileSize(for file: MediaFile) async throws -> UInt64 { try await reader.fileSize(for: file) }
    func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data { try await reader.playbackRead(file, range: range) }
}

@MainActor struct TwoMiBDemandBoundaryTests {
    private enum Failure: Error { case unexpectedRecovery }
    private let cap = MediaReadPlan.maximumChunkBytes
    private func expected(_ range: Range<UInt64>) -> Data {
        Data(range.map { UInt8(truncatingIfNeeded: $0) })
    }
    @Test func fullTwoMiBPassesEveryDemandLayerAndOversizeNeverReachesTransport() async throws {
        let file = try MediaFile(components: ["synthetic.mp4"])
        let transport = TwoMiBTransportFixture(), reader: SMBMediaReader
        reader = SMBMediaReader(transport: transport)
        let range = UInt64(4_294_967_299)..<(4_294_967_299 + cap)
        #expect(try await reader.read(file, range: range) == expected(range))
        #expect(try await reader.playbackRead(file, range: range) == expected(range))
        await #expect(throws: MediaInspectionError.self) { try await reader.read(file, range: UInt64(0)..<(cap+1)) }
        await #expect(throws: SMBPlaybackReadFailure.invalidRange) { try await reader.playbackRead(file, range: UInt64(0)..<(cap+1)) }
        #expect(await transport.ranges.count == 2)
        let identity = PlaybackSourceIdentity(size: 8_000_000_000, modificationDate: Date(timeIntervalSince1970: 100), creationDate: Date(timeIntervalSince1970: 50))
        let recovering = PlaybackRecoveringSource(file: file, initial: TypedTwoMiBSource(reader: reader), metadata: { _,_ in identity },
            makeFresh: { throw Failure.unexpectedRecovery }, retire: { _ in }, shouldRecover: { _ in false }, isCurrent: { true }, diagnostics: nil)
        let wrapped = PlaybackPrefetchSource(file: file, source: recovering)
        #expect(try await wrapped.fileSize(for: file) == identity.size)
        #expect(try await wrapped.read(file, range: range) == expected(range))
        await #expect(throws: PlaybackSourceRecoveryError.invalidRange) { try await wrapped.read(file, range: UInt64(0)..<(cap+1)) }
        await #expect(throws: PlaybackSourceRecoveryError.invalidRange) { try await recovering.read(file, range: UInt64(0)..<(cap+1)) }
        #expect(await transport.ranges == [range, range, range])
        try await wrapped.awaitPlaybackCleanup()
    }
    @Test func twoMiBShortAndOverlongRepliesStillFailClosed() async throws {
        let file = try MediaFile(components: ["synthetic.mp4"])
        for mode in [TwoMiBTransportFixture.Reply.short, .long] {
            let reader = SMBMediaReader(transport: TwoMiBTransportFixture(mode))
            await #expect(throws: SMBPlaybackReadFailure.invalidResponse) { try await reader.playbackRead(file, range: 0..<cap) }
            await #expect(throws: MediaInspectionError.self) { try await reader.read(file, range: 0..<cap) }
        }
    }
    @Test func localFileReadsExactTwoMiBAndShortTailWithoutBroadeningPathRules() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data((0..<Int(cap+137)).map { UInt8(truncatingIfNeeded: $0) })
        try data.write(to: root.appendingPathComponent("synthetic.mp4"))
        let file = try MediaFile(components: ["synthetic.mp4"]), source = LocalDirectoryProvider(testRoot: root)
        #expect(try await source.read(file, range: 0..<cap) == data.prefix(Int(cap)))
        #expect(try await source.read(file, range: cap..<(cap+137)) == data.suffix(137))
        await #expect(throws: LocalFolderFailure.invalidPath) { try await source.read(file, range: UInt64(0)..<(cap+1)) }
    }
}
