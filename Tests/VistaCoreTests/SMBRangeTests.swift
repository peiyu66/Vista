import Foundation
import Testing
@testable import VistaCore
@testable import VistaSMB
@testable import VistaMedia

private actor RangeTransport: SMBRangeTransport {
    enum Mode { case normal, short, long, failed, delayed }
    let mode: Mode
    let attributesValue: [URLResourceKey: any Sendable]
    var calls: [Range<UInt64>] = []
    private var continuation: CheckedContinuation<Data, Never>?
    init(_ mode: Mode = .normal, size: NSNumber = NSNumber(value: UInt64(8_000_000_000)), type: URLFileResourceType = .regular) {
        self.mode = mode
        attributesValue = [.fileSizeKey: size, .fileResourceTypeKey: type]
    }
    func attributes(at path: String) async throws -> [URLResourceKey: any Sendable] { attributesValue }
    func read(at path: String, range: Range<UInt64>) async throws -> Data {
        calls.append(range)
        let data = Data(repeating: UInt8(range.lowerBound % 255), count: Int(range.count))
        switch mode {
        case .normal: return data
        case .short: return data.dropLast()
        case .long: return data + Data([0])
        case .failed: throw NSError(domain: "fixture-secret-path", code: 1)
        case .delayed: return await withCheckedContinuation { continuation = $0 }
        }
    }
    func release() { continuation?.resume(returning: Data(count: Int(calls.last!.count))); continuation = nil }
}

/// Virtual MP4 with a large free box before the original tail moov. No large file is allocated.
private actor TailIndexTransport: SMBRangeTransport {
    let prefix: Data
    let tail: Data
    let tailOffset: UInt64
    let size: UInt64
    var calls: [Range<UInt64>] = []
    var bytesRead = 0
    init(movie: Data, gap: UInt64) {
        let offset = movie.range(of: Data("moov".utf8))!.lowerBound - 4
        let extendedSize = Data((0..<8).map { UInt8((gap >> ((7 - $0) * 8)) & 255) })
        prefix = movie.prefix(offset) + Data([0, 0, 0, 1]) + Data("free".utf8) + extendedSize
        tail = Data(movie.suffix(from: offset))
        tailOffset = UInt64(offset) + UInt64(gap)
        size = UInt64(movie.count) + UInt64(gap)
    }
    func attributes(at path: String) async throws -> [URLResourceKey: any Sendable] {
        [.fileSizeKey: NSNumber(value: size), .fileResourceTypeKey: URLFileResourceType.regular]
    }
    func read(at path: String, range: Range<UInt64>) async throws -> Data {
        guard range.upperBound <= size, range.count <= 65_536, bytesRead + range.count <= 2 * 1024 * 1024 else {
            throw MediaInspectionError.invalidResponse
        }
        try await Task.sleep(for: .milliseconds(2))
        calls.append(range); bytesRead += range.count
        var result = Data(count: Int(range.count))
        for (offset, piece) in [(UInt64(0), prefix), (tailOffset, tail)] {
            let lower = max(offset, range.lowerBound)
            let upper = min(offset + UInt64(piece.count), range.upperBound)
            if lower < upper {
                result.replaceSubrange(Int(lower - range.lowerBound)..<Int(upper - range.lowerBound), with: piece[Int(lower - offset)..<Int(upper - offset)])
            }
        }
        return result
    }
}

struct SMBRangeTests {
    @Test func readPlanCoversOffsetsAndEOFLazily() throws {
        let plan = try MediaReadPlan(requestedOffset: 4_294_967_296, currentOffset: 4_294_967_299, requestedLength: 131_075, toEnd: false, fileSize: 8_000_000_000)
        #expect(Array(plan) == [4_294_967_299..<4_295_032_835, 4_295_032_835..<4_295_098_371])
        let tail = try MediaReadPlan(requestedOffset: 10, currentOffset: 12, requestedLength: 1, toEnd: true, fileSize: 20)
        #expect(Array(tail) == [12..<20])
        let eof = try MediaReadPlan(requestedOffset: 20, currentOffset: 20, requestedLength: 200, toEnd: false, fileSize: 20)
        #expect(Array(eof).isEmpty)
        for parameters in [(-1, 0, 1), (4, 3, 1), (0, 2, 1), (0, 0, -1)] {
            #expect(throws: MediaInspectionError.self) {
                try MediaReadPlan(requestedOffset: Int64(parameters.0), currentOffset: Int64(parameters.1), requestedLength: parameters.2, toEnd: false, fileSize: 20)
            }
        }
    }
    @Test func adapterForwardsExact64BitRangesAndRejectsOversizedReads() async throws {
        let transport = RangeTransport()
        let reader = SMBMediaReader(transport: transport)
        let file = try MediaFile(components: ["fixture.mp4"])
        #expect(try await reader.fileSize(for: file) == 8_000_000_000)
        let range: Range<UInt64> = 4_294_967_299..<4_294_967_309
        let data = try await reader.read(file, range: range)
        #expect(data.count == 10)
        #expect(await transport.calls == [range])
        #expect(try await reader.read(file, range: 5..<5).isEmpty)
        await #expect(throws: MediaInspectionError.self) { try await reader.read(file, range: 0..<(MediaReadPlan.maximumChunkBytes+1)) }
        await #expect(throws: MediaInspectionError.self) { try await reader.read(file, range: UInt64(Int64.max)..<UInt64(Int64.max) + 1) }
        #expect(await transport.calls.count == 1)
    }
    @Test func adapterRejectsShortOverlongAndPrivateErrors() async throws {
        let file = try MediaFile(components: ["fixture.mp4"])
        for mode in [RangeTransport.Mode.short, .long, .failed] {
            let reader = SMBMediaReader(transport: RangeTransport(mode))
            do { _ = try await reader.read(file, range: 0..<4); Issue.record("Expected failure") }
            catch { #expect(error is MediaInspectionError); #expect(!String(describing: error).contains("fixture-secret-path")) }
        }
        for transport in [RangeTransport(size: -1), RangeTransport(size: NSNumber(value: UInt64.max)), RangeTransport(type: .directory)] {
            await #expect(throws: MediaInspectionError.self) { try await SMBMediaReader(transport: transport).fileSize(for: file) }
        }
    }
    @Test func adapterDiscardsInFlightReadsAfterCloseOrCancel() async throws {
        let file = try MediaFile(components: ["fixture.mp4"])
        for close in [true, false] {
            let transport = RangeTransport(.delayed)
            let reader = SMBMediaReader(transport: transport)
            let task = Task { try await reader.read(file, range: 0..<4) }
            while await transport.calls.isEmpty { await Task.yield() }
            if close { await reader.close() } else { task.cancel() }
            await transport.release()
            if close { await #expect(throws: MediaInspectionError.self) { try await task.value } }
            else { await #expect(throws: CancellationError.self) { try await task.value } }
        }
    }
    @Test(arguments: [UInt64(16 * 1024 * 1024), UInt64(4_294_967_296)])
    func tailIndexMovieUsesPositionedReadsThroughSMBAdapter(gap: UInt64) async throws {
        let file = try MediaFile(components: ["tail-index.mp4"])
        let demo = DemoMediaSource()
        let length = try await demo.fileSize(for: file)
        let transport = TailIndexTransport(movie: try await demo.read(file, range: 0..<length), gap: gap)
        let reader = SMBMediaReader(transport: transport)
        do {
            let report = try await HardwarePlayback().play(file: file, source: reader, onInfo: { info in #expect(info.codec == "H.264") }, onFrame: { _ in })
            #expect(report.hardwareVerified); #expect(report.decodedFrames == 24)
            print("TAIL_INDEX_HARDWARE_FRAMES", report.decodedFrames)
        } catch PlaybackFailure.hardwareUnavailable { print("TAIL_INDEX_HARDWARE_UNAVAILABLE") }
        let calls = await transport.calls
        #expect(calls.contains { $0.lowerBound >= gap })
        #expect(calls.allSatisfy { $0.count <= 65_536 })
        print("TAIL_INDEX_GAP", gap, "BYTES", await transport.bytesRead, "REQUESTS", calls.count)
    }
}
