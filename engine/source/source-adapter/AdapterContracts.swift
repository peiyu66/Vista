import Foundation

struct BridgeStamp: Equatable, Sendable, Codable {
    let playbackID: UUID
    let contentRevision: UUID
    let windowGeneration: UInt64
    init(playbackID: UUID, contentRevision: UUID, windowGeneration: UInt64) { self.playbackID = playbackID; self.contentRevision = contentRevision; self.windowGeneration = windowGeneration }
}
struct BridgeSourceQuiescenceWitness: Sendable, Codable {
    let stamp: BridgeStamp
    let outstandingSourceOperations: Int
    let confirmedBySourceOwner: Bool
    let provider: String
}
protocol BridgeSourceQuiescenceProvider: Sendable {
    func quiescenceWitness(for stamp: BridgeStamp) async -> BridgeSourceQuiescenceWitness?
}
struct BridgeDrainAck: Sendable, Codable {
    let stamp: BridgeStamp
    let sourceReadInvocationsReturned: Bool
    let parserOwnerPthreadJoined: Bool
    let uncancelledSourceTasksCompleted: Bool
    let sourceQuiescenceConfirmed: Bool
    let sourceWitness: BridgeSourceQuiescenceWitness?
    let sourceReadCalls: Int
    let sourceReturnCalls: Int
    // This covers this adapter's read invocations only, not unknown source-owned
    // background transport activity. Production needs that source owner's contract.
    let coversUnobservedSourceBackgroundTransport: Bool
    static func sourceConfirms(_ witness: BridgeSourceQuiescenceWitness?, stamp: BridgeStamp) -> Bool {
        witness?.stamp == stamp && witness?.outstandingSourceOperations == 0 && witness?.confirmedBySourceOwner == true
    }
    var fullyAcknowledged: Bool {
        sourceReadInvocationsReturned && parserOwnerPthreadJoined && uncancelledSourceTasksCompleted &&
        sourceQuiescenceConfirmed && Self.sourceConfirms(sourceWitness, stamp: stamp)
    }
}

// One operation owner per playback. A new parser generation requires a real source
// witness from the previous generation, not merely a returned Swift continuation.
protocol SourceOperationOwner: AnyObject, Sendable {
    var playbackID: UUID { get }
    var contentRevision: UUID { get }
    var knownSize: UInt64 { get }
    var file: MediaFile { get }
    var journal: AdapterJournal { get }
    func beginWindow(generation: UInt64) async throws -> LocalWindowByteSource
    func read(stamp: BridgeStamp, file: MediaFile, range: Range<UInt64>) async throws -> Data
    // VLC may fulfill its existing demand up to 512 KiB; parser callers retain 256 KiB.
    func readVLCInput(stamp: BridgeStamp, file: MediaFile, range: Range<UInt64>) async throws -> Data
    func validate(stamp: BridgeStamp) async throws
    func verifyEOF(stamp: BridgeStamp) async throws
    func retireAndDrain(stamp: BridgeStamp) async throws -> BridgeSourceQuiescenceWitness
    func closeAfterDrain() async throws
    func performanceSnapshot() -> LocalSourcePerformance
}

extension SourceOperationOwner {
    // Other owners opt out by retaining their existing read contract.
    func readVLCInput(stamp: BridgeStamp, file: MediaFile, range: Range<UInt64>) async throws -> Data {
        try await read(stamp: stamp, file: file, range: range)
    }
}
