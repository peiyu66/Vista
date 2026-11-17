#if VISTA_LOCAL_MKV_CANDIDATE
import Foundation
@MainActor final class MKVLocalEngineSource: MKVEngineSource {
    let owner: any SourceOperationOwner
    init(owner: any SourceOperationOwner) { self.owner=owner }
    func create(staging:URL,receipt:URL,generation:UInt64,target:Double) async throws -> any MKVEngineWindow {
        try mkvRequire(target.isFinite && target>=0 && target<Double(Int64.max)/1e9,VistaL10n.text("跳轉時間超出範圍"))
        return MKVBoundEngineWindow(try await SourceAdapterSession.create(owner:owner,output:staging,receipt:receipt,generation:generation,requestedGlobalNS:Int64(target*1e9),maxUnackedSegments:1))
    }
    func close() async throws { try await owner.closeAfterDrain() }
}
@MainActor private final class MKVBoundEngineWindow: MKVEngineWindow {
    let engine: SourceAdapterSession
    init(_ engine: SourceAdapterSession) { self.engine=engine }
    var stamp:BridgeStamp {engine.stamp}
    func start() throws { try mkvRequire(engine.start(),VistaL10n.text("來源工作無法啟動")) }
    func info() throws -> MKVEngineInfo {
        let s=try engine.snapshot()
        if s.state==3 {throw MKVPlaybackError.engine(try engine.diagnosticSnapshot().reasonCode)}
        if s.state==5 {throw CancellationError()}
        return MKVEngineInfo(width:Int32(clamping:s.width),height:Int32(clamping:s.height),duration:Double(s.wholePresentationEndNS)/1e9,origin:Double(s.itemOriginGlobalNS)/1e9,targetDuration:Int(s.targetDurationSeconds),startupSegments:s.startupSegments,published:Int(s.publishedSegments),terminal:s.terminalSegmentPublished==1)
    }
    func diagnosticSnapshot() throws -> SAPDiagnostics {try engine.diagnosticSnapshot()}
    func performanceSnapshot() -> LocalSourcePerformance {engine.performanceSnapshot()}
    func segment(_ index:Int) throws -> MKVEngineSegment {
        let s=try engine.segmentInfo(index:UInt32(index))
        return MKVEngineSegment(index:Int(s.index),duration:Double(s.durationNS)/1e9,globalStart:Double(s.globalStartNS)/1e9,globalEnd:Double(s.globalEndNS)/1e9,durationNS:s.durationNS)
    }
    func acknowledgeImported(_ index:Int) async throws { try await engine.acknowledgeImported(index:UInt32(index)) }
    func validate() async throws { try await engine.validateRevision() }
    func cancel() {engine.cancel()}
    func drain() async throws -> BridgeDrainAck { try await engine.drain() }
    func destroy() throws { try engine.destroy() }
}
#endif
