import Foundation
import simd
#if SWIFT_PACKAGE
import VistaCore
#endif

public enum PlaybackSourceKind: String, Sendable { case smb = "SMB", local = "本機", synthetic = "合成", unknown = "未分類" }
public enum PlaybackMetricStage: String, CaseIterable, Sendable { case buffering = "補緩衝等待", read = "來源讀取", decode = "解碼等待", image = "影像轉換", texture = "雙眼貼圖" }
public enum PlaybackMetricEvent: String, CaseIterable, Sendable { case decoded, delivered, dropped, submitted, coalesced, uploaded, stale, readFailure, readCancelled }
public struct PlaybackMetricAggregate: Sendable {
    public var count = 0
    public var seconds = 0.0
    public var maximum = 0.0
}
public struct PlaybackMetricSnapshot: Sendable {
    public let elapsed: Double
    public let complete: Bool
    public let source: PlaybackSourceKind
    public let hardware: String
    public let format: String
    public let stages: [PlaybackMetricStage: PlaybackMetricAggregate]
    public let events: [PlaybackMetricEvent: Int]
    public let readBytes: Int
    public var text: String {
        let heading = String(format:"%@ %.1f 秒（含準備／暫停）",complete ? "已結束":"收集中",elapsed)
        var lines = [heading, "來源：\(source.rawValue)　\(hardware)", format]
        for stage in PlaybackMetricStage.allCases {
            let s=stages[stage] ?? PlaybackMetricAggregate()
            lines.append(String(format:"%@：%d 次／共 %.1f ms／最大 %.1f ms",stage.rawValue,s.count,s.seconds*1000,s.maximum*1000))
        }
        lines.append("解碼 \(events[.decoded,default:0])／送出 \(events[.delivered,default:0])／同步丟幀 \(events[.dropped,default:0])")
        lines.append("呈現請求 \(events[.submitted,default:0])／合併 \(events[.coalesced,default:0])／貼圖完成 \(events[.uploaded,default:0])／過期 \(events[.stale,default:0])")
        lines.append("讀取 \(readBytes) bytes／失敗 \(events[.readFailure,default:0])（取消 \(events[.readCancelled,default:0])／其他 \(max(0,events[.readFailure,default:0]-events[.readCancelled,default:0]))）")
        return lines.joined(separator:"\n")
    }
}
/// Fixed-size aggregate counters only. No URLs, file names, samples or per-frame history.
public final class PlaybackMetrics: @unchecked Sendable {
    private let lock=NSLock()
    public let cancellationTrace=ReadCancellationTrace()
    private let start: Double
    private let source: PlaybackSourceKind
    private var ended: Double?
    private var stages:[PlaybackMetricStage:PlaybackMetricAggregate]=[:]
    private var events:[PlaybackMetricEvent:Int]=[:]
    private var bytes=0
    private var hardware="硬解尚未確認"
    private var format="軌道尚未取得"
    public init(source:PlaybackSourceKind = .unknown, now:Double = ProcessInfo.processInfo.systemUptime) {self.source=source;start=now}
    private func accepts(_ now:Double)->Bool {ended == nil && now >= start && now < start+10}
    public func record(_ stage:PlaybackMetricStage, seconds:Double, bytes:Int=0, now:Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock();defer{lock.unlock()}
        guard accepts(now),seconds.isFinite,seconds>=0,bytes>=0 else{return}
        let duration=min(seconds,now-start)
        var value=stages[stage] ?? PlaybackMetricAggregate()
        value.count += 1;value.seconds += duration;value.maximum=max(value.maximum,duration)
        stages[stage]=value;self.bytes += bytes
    }
    public func recordReadFailure(seconds:Double,cancelled:Bool,now:Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock();defer{lock.unlock()}
        guard accepts(now),seconds.isFinite,seconds>=0 else{return}
        let duration=min(seconds,now-start)
        var value=stages[.read] ?? PlaybackMetricAggregate()
        value.count += 1;value.seconds += duration;value.maximum=max(value.maximum,duration)
        stages[.read]=value;events[.readFailure,default:0] += 1
        if cancelled {events[.readCancelled,default:0] += 1}
    }
    public func mark(_ event:PlaybackMetricEvent, now:Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock();defer{lock.unlock()};guard accepts(now) else{return};events[event,default:0] += 1
    }
    public func setHardware(verified:Bool, softwareTest:Bool, now:Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock();defer{lock.unlock()};guard accepts(now) else{return}
        hardware=softwareTest ? "模擬器軟解測試" : verified ? "已查核硬解":"硬解查核失敗"
    }
    public func setFormat(codec:String,width:Int,height:Int,now:Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock();defer{lock.unlock()};guard accepts(now) else{return}
        let safeCodec=["H.264","HEVC","VP9"].contains(codec) ? codec:"其他編碼"
        format="\(safeCodec)　\(width)×\(height)"
    }
    public func finish(now:Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock();defer{lock.unlock()};if ended == nil {ended=max(start,min(now,start+10))}
    }
    public func snapshot(now:Double = ProcessInfo.processInfo.systemUptime)->PlaybackMetricSnapshot {
        lock.lock();defer{lock.unlock()}
        return PlaybackMetricSnapshot(elapsed:max(0,min(ended ?? now,start+10)-start),complete:ended != nil || now>=start+10,
            source:source,hardware:hardware,format:format,stages:stages,events:events,readBytes:bytes)
    }
}
struct MeasuredMediaSource:MediaByteSource {
    let base:any MediaByteSource
    let metrics:PlaybackMetrics
    func fileSize(for file:MediaFile) async throws -> UInt64 {try await base.fileSize(for:file)}
    func read(_ file:MediaFile,range:Range<UInt64>) async throws -> Data {
        let start=ProcessInfo.processInfo.systemUptime
        do {
            let data=try await base.read(file,range:range)
            metrics.record(.read,seconds:ProcessInfo.processInfo.systemUptime-start,bytes:data.count)
            return data
        } catch {
            metrics.recordReadFailure(seconds:ProcessInfo.processInfo.systemUptime-start,cancelled:error is CancellationError)
            throw error
        }
    }
}

/// Bounded, metadata-free request cancellation evidence, separate from the 10-second counters.
public struct ReadCancellationRecord:Sendable {
    public let request:Int
    public let origin:String
    public let cancelAtMS:Double?
    public let finishedAtMS:Double
    public let readingAtCancel:Bool
    public let readThrewCancellation:Bool
    public let bytesDelivered:Int
    public var releaseMS:Double? {cancelAtMS.map {max(0,finishedAtMS-$0)}}
}
public final class ReadCancellationTrace:@unchecked Sendable {
    private struct Active {var cause:String?;var at:Double?;var reading=false;var atRead=false;var threw=false;var bytes=0}
    private let lock=NSLock()
    private let start:Double
    private var serial=0
    private var active:[Int:Active]=[:]
    private var records:[ReadCancellationRecord]=[]
    public private(set) var capacity=64
    public init(now:Double = ProcessInfo.processInfo.systemUptime) {start=now}
    public func begin()->Int {lock.lock();defer{lock.unlock()};serial += 1;active[serial]=Active();return serial}
    public func reading(_ id:Int,_ value:Bool) {lock.lock();defer{lock.unlock()};active[id]?.reading=value}
    public func delivered(_ id:Int,_ bytes:Int) {lock.lock();defer{lock.unlock()};active[id]?.bytes += max(0,bytes)}
    public func cancel(_ id:Int,cleanup:Bool,now:Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock();defer{lock.unlock()}
        guard var item=active[id],item.cause==nil else{return}
        item.cause=cleanup ? "cleanup":"loader";item.at=max(0,(now-start)*1000);item.atRead=item.reading;active[id]=item
    }
    public func readCancelled(_ id:Int) {lock.lock();defer{lock.unlock()};active[id]?.threw=true}
    public func finish(_ id:Int,now:Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock();defer{lock.unlock()}
        guard let item=active.removeValue(forKey:id),item.cause != nil || item.threw else{return}
        if records.count==capacity {records.removeFirst()}
        records.append(ReadCancellationRecord(request:id,origin:item.cause ?? "source",cancelAtMS:item.at,
          finishedAtMS:max(0,(now-start)*1000),readingAtCancel:item.atRead,readThrewCancellation:item.threw,bytesDelivered:item.bytes))
    }
    public func snapshot()->[ReadCancellationRecord] {lock.lock();defer{lock.unlock()};return records}
    public var text:String {
        let rows=snapshot(),failures=rows.filter(\.readThrewCancellation)
        let counts=["loader","cleanup","source"].map {origin in failures.filter {$0.origin==origin}.count}
        let lag=rows.compactMap(\.releaseMS).max() ?? 0
        return "取消追蹤（最近64請求，非10秒計數）：讀取拋取消 loader \(counts[0])／cleanup \(counts[1])／source \(counts[2])；釋放最久 \(Int(lag)) ms"
    }
}

/// Anonymous bounded records: no arbitrary text, names, URLs, errors or credentials accepted.
public enum PlaybackLogEvent:String,Codable,Sendable {case sample,stopped,failed,rendererFailed,controllerReset}
public enum PlaybackLogField:String,Codable,CaseIterable,Sendable {
 case position,playing,paused,preparing,buffering,width,height,frames,waits,clockDeltaMS,epoch,target,targetBuffered
 case reads,bytes,readMS,interrupted,waitMS,seekMS,firstFrameMS,presentMS
 case seekReads,seekBytes,firstReads,firstBytes,presentReads,presentBytes
 case seekReadMS,seekWaitMS,seekInterrupted,firstReadMS,firstWaitMS,firstInterrupted,presentReadMS,presentWaitMS,presentInterrupted,failureKind
 case ioStarted,ioFinished,ioCancelled,ioFailed,ioInFlight,ioPeak,ioOld,ioOldRemaining,ioOldMS,ioMaxMS
 case logFailures,logDropped,decoder,projection,layout,route,textureCount,textureMS,uploaded,coalesced
 // Controller-reset diagnostics: fixed numeric fields, no absolute room positions.
 case crPoseSource,crPoseAgeMS,crPreservePlacement
 case crSequence,crPhase,crElapsedMS,crHasEntity,crHasParent,crExpectedParent,crHasScene,crHeadCached,crVideoAvailable,crCalibration
 case crVisible,crMoving,crScrubbing,crAutoPitch,crManualPitch,crManualYaw,crManualRoll,cw00,cw01,cw02
 case cw10,cw11,cw12,cw20,cw21,cw22,cp00,cp01,cp02,cp10
 case cp11,cp12,cp20,cp21,cp22,cl00,cl01,cl02,cl10,cl11
 case cl12,cl20,cl21,cl22,cqX,cqY,cqZ,cqW,cfX,cfY
 case cfZ,cfW,chX,chY,chZ,chW,cvX,cvY,cvZ,cvW
 case crLocalX,crLocalY,crLocalZ,crViewerX,crViewerY,crViewerZ,crOffsetX,crOffsetY,crOffsetZ
}
public struct PlaybackLogRecord:Codable,Sendable {
 public let event:PlaybackLogEvent
 public let uptime:Double
 public let values:[String:Double]
 public let build:String
 public init(event:PlaybackLogEvent,values:[PlaybackLogField:Double],build:String = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0") {
  self.event=event;uptime=ProcessInfo.processInfo.systemUptime
  self.values=Dictionary(uniqueKeysWithValues:values.filter{$0.value.isFinite}.map{($0.key.rawValue,$0.value)})
  self.build=build.count<=12 && build.allSatisfy({$0.isNumber || $0 == "."}) ? build:"0"
 }
}
public final class PlaybackLogStore:@unchecked Sendable {
 public static let shared=PlaybackLogStore(directory:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VistaDiagnostics",isDirectory:true))
 private let directory:URL,limit:Int,retention:TimeInterval
 private let queue=DispatchQueue(label:"Vista.anonymous.diagnostics",qos:.utility),lock=NSLock()
 private var pending:[(Data,Bool)]=[],draining=false,failures=0,dropped=0
 public init(directory:URL,limit:Int=262144,retention:TimeInterval=7*86400){self.directory=directory;self.limit=max(4096,limit);self.retention=max(0,retention)}
 public var status:(failures:Int,dropped:Int){lock.lock();defer{lock.unlock()};return(failures,dropped)}
 public func enqueue(_ record:PlaybackLogRecord){
  guard let encoded=try? JSONEncoder().encode(record),encoded.count<4096 else{return}
  var data=encoded;data.append(10)
  lock.lock()
  if pending.count>=8 {
   if let sample=pending.firstIndex(where:{!$0.1}) {pending.remove(at:sample)}
   else if record.event == .sample {dropped+=1;lock.unlock();return}
   else {pending.removeFirst()}
   dropped+=1
  }
  pending.append((data,record.event != .sample))
  if draining {lock.unlock();return}
  draining=true;lock.unlock()
  queue.async{self.drain()}
 }
 private func drain(){
  while true {
   lock.lock();guard !pending.isEmpty else{draining=false;lock.unlock();return}
   let next=pending.removeFirst();lock.unlock()
   do {try write(next.0,synchronize:next.1)}catch{lock.lock();failures+=1;lock.unlock()}
  }
 }
 private func file(_ index:Int)->URL {directory.appendingPathComponent(index == 0 ? "current.jsonl":"previous-\(index).jsonl")}
 private func write(_ data:Data,synchronize:Bool)throws {
  let fm=FileManager.default
  try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  var excluded=directory;var values=URLResourceValues();values.isExcludedFromBackup=true;try excluded.setResourceValues(values)
  for i in 0...3 {
   let url=file(i)
   if let date=try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,Date().timeIntervalSince(date)>retention {try fm.removeItem(at:url)}
  }
  let size=(try? fm.attributesOfItem(atPath:file(0).path)[.size] as? NSNumber)?.intValue ?? 0
  if size+data.count>limit {
   if fm.fileExists(atPath:file(3).path){try fm.removeItem(at:file(3))}
   for i in stride(from:2,through:0,by:-1) where fm.fileExists(atPath:file(i).path){try fm.moveItem(at:file(i),to:file(i+1))}
  }
  if !fm.fileExists(atPath:file(0).path) {
   guard fm.createFile(atPath:file(0).path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw CocoaError(.fileWriteUnknown)}
   #if os(visionOS) || os(iOS)
   try fm.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:file(0).path)
   #endif
  }
  let handle=try FileHandle(forWritingTo:file(0));defer{try? handle.close()}
  try handle.seekToEnd();try handle.write(contentsOf:data)
  if synchronize {try handle.synchronize()}
 }
 public func drainForTesting(){queue.sync{}}
}


/// Diagnostic-only sequence bookkeeping. Does not apply transforms or request tracking.
public struct ControllerResetTrace:Sendable {
 public private(set) var sequence=0
 public private(set) var awaitingApply:Int?
 public private(set) var awaitingFrame:Int?
 public init() {}
 @discardableResult public mutating func begin()->Int {sequence += 1;awaitingApply=sequence;awaitingFrame=nil;return sequence}
 public mutating func applied()->Int? {guard let ticket=awaitingApply else{return nil};awaitingApply=nil;awaitingFrame=ticket;return ticket}
 public mutating func nextFrame(ticket:Int)->Bool {guard awaitingFrame==ticket else{return false};awaitingFrame=nil;return true}
 public mutating func cancel(){awaitingApply=nil;awaitingFrame=nil}
}
public enum ControllerResetLogPhase:Int,Sendable {case before=0,applied=1,nextSceneUpdate=2}
/// Matrix linear blocks only (rotation and any scale): no absolute room/device positions or arbitrary text.
public enum ControllerResetLog {
 public static func values(sequence:Int,phase:ControllerResetLogPhase,world:simd_float4x4?,parent:simd_float4x4?,local:simd_float4x4?,
                           intended:simd_quatf,frame:simd_quatf,cachedHead:simd_quatf?,video:simd_quatf?,
                           localPosition:SIMD3<Float>?,cachedViewer:SIMD3<Float>,offset:SIMD3<Float>)->[PlaybackLogField:Double] {
  var v:[PlaybackLogField:Double]=[.crSequence:Double(sequence),.crPhase:Double(phase.rawValue),.crHasEntity:world == nil ? 0:1,
      .crHasParent:parent == nil ? 0:1,.crHeadCached:cachedHead == nil ? 0:1,.crVideoAvailable:video == nil ? 0:1]
  func matrix(_ m:simd_float4x4?,_ keys:[PlaybackLogField]) {
   guard let m else{return}
   for row in 0..<3 {for column in 0..<3 {v[keys[row*3+column]]=Double(m[column][row])}}
  }
  func quaternion(_ q:simd_quatf?,_ keys:[PlaybackLogField]) {
   guard let q else{return}
   for i in 0..<4 {v[keys[i]]=Double(q.vector[i])}
  }
  func vector(_ p:SIMD3<Float>?,_ keys:[PlaybackLogField]) {
   guard let p else{return}
   for i in 0..<3 {v[keys[i]]=Double(p[i])}
  }
  matrix(world,[.cw00,.cw01,.cw02,.cw10,.cw11,.cw12,.cw20,.cw21,.cw22])
  matrix(parent,[.cp00,.cp01,.cp02,.cp10,.cp11,.cp12,.cp20,.cp21,.cp22])
  matrix(local,[.cl00,.cl01,.cl02,.cl10,.cl11,.cl12,.cl20,.cl21,.cl22])
  quaternion(intended,[.cqX,.cqY,.cqZ,.cqW]);quaternion(frame,[.cfX,.cfY,.cfZ,.cfW])
  quaternion(cachedHead,[.chX,.chY,.chZ,.chW]);quaternion(video,[.cvX,.cvY,.cvZ,.cvW])
  vector(localPosition,[.crLocalX,.crLocalY,.crLocalZ]);vector(cachedViewer,[.crViewerX,.crViewerY,.crViewerZ]);vector(offset,[.crOffsetX,.crOffsetY,.crOffsetZ])
  return v
 }
}
