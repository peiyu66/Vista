import Foundation

/// Validated AVFoundation request bounds; iteration never allocates a list of all chunks.
public struct MediaReadPlan: Sequence, Sendable {
    public static let chunkLimit: UInt64 = 65_536
    /// Native AVPlayer candidate: fixed demand ceiling, always clipped to the request and EOF.
    public static let maximumChunkBytes: UInt64 = 2_097_152
    public static let nativeChunkBytes: UInt64 = maximumChunkBytes
    public let range: Range<UInt64>
    public let chunkBytes:UInt64
    public init(requestedOffset: Int64, currentOffset: Int64, requestedLength: Int,
                toEnd: Bool, fileSize: UInt64, chunkBytes:UInt64 = MediaReadPlan.chunkLimit) throws {
        guard chunkBytes>0,chunkBytes<=Self.maximumChunkBytes,requestedOffset >= 0, currentOffset >= requestedOffset, requestedLength >= 0,
              fileSize <= Int64.max else { throw MediaInspectionError.invalidResponse }
        let start = UInt64(currentOffset)
        let (requestedEnd, overflow) = UInt64(requestedOffset).addingReportingOverflow(UInt64(requestedLength))
        guard !overflow, UInt64(requestedOffset) <= fileSize else { throw MediaInspectionError.invalidResponse }
        let end = toEnd ? fileSize : Swift.min(fileSize, requestedEnd)
        guard start <= end else { throw MediaInspectionError.invalidResponse }
        range = start..<end
        self.chunkBytes=chunkBytes
    }
    public struct Iterator: IteratorProtocol {
        var remaining: Range<UInt64>
        let chunkBytes:UInt64
        public mutating func next() -> Range<UInt64>? {
            guard !remaining.isEmpty else { return nil }
            let end = remaining.lowerBound + Swift.min(chunkBytes, remaining.upperBound - remaining.lowerBound)
            let chunk = remaining.lowerBound..<end
            remaining = end..<remaining.upperBound
            return chunk
        }
    }
    public func makeIterator() -> Iterator { Iterator(remaining: range,chunkBytes:chunkBytes) }
}
