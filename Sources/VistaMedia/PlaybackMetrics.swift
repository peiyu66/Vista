import Foundation
import simd
#if canImport(Darwin)
import Darwin
#endif
#if os(visionOS)
import os
#endif
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
public enum PlaybackLogEvent:String,Codable,Sendable {case sample,stopped,failed,rendererFailed,controllerReset,prefetchTrace,prefetchSummary,waitEpisode,automaticSpeed,automaticRecovery,automaticRecoverySummary,controllerUI,stallProbe,stallProbeSummary,intentRecovery,playbackHypothesis
 var isCritical:Bool {self != .sample && self != .prefetchTrace && self != .waitEpisode}
}
public enum PlaybackLogField:String,Codable,CaseIterable,Sendable {
 // Controller UI observations: fixed numeric masks, monotonic timestamps and bounded event counters.
 case uiStateMask,uiRowDisabledMask,uiPreviousDisabledMask,uiNextDisabledMask,uiPauseDisabledMask,uiIncreaseDisabledMask,uiResetSpeedDisabledMask,uiSeekDisabledMask
 case uiObservationStartedUptime,uiStateSinceUptime,uiScrubbingSinceUptime,uiStoppingSinceUptime,uiStateSequence,uiEventSequence,uiEventSuppressed,uiEventAction,uiLastAction,uiLastActionUptime,uiStateAgeMS,uiScrubbingAgeMS,uiStoppingAgeMS
 case waitEpisodes,waitSuppressed,waitCompleted,waitIncomplete,waitLogDropped,waitLogRejected,waitLogFailures
 case waitLogRejectedMissingPayload,waitLogRejectedOversize,waitLogRejectedEncoding,waitJournalRotatedFiles,waitJournalExpiredFiles
 case videoLoopTicks,videoLoopSessionMaxGapMS,videoOutputPolls,videoOutputHasNew,videoOutputCopyNil,videoFrameAgeMS
 case autoSpeedGapWindowSeconds,autoSpeedGapMinimumPolls
 case selectedSpeed,effectiveRate,maximumSpeed
 case autoSpeedSession,autoSpeedSequence,autoSpeedReason,autoSpeedFrom,autoSpeedTo,autoSpeedObservedSeconds,autoSpeedAdvancingFrames,autoSpeedOutputPolls,autoSpeedClockAdvance,autoSpeedMaximumFrameGap,autoSpeedCooldownSeconds,autoSpeedWaitingCooldownSeconds,autoSpeedSparseRearmOnRateStart,autoSpeedSparseWindowSeconds
 // Build97: decision-specific fields stay off the ordinary Native sample.
 case autoSpeedCurrentFrameGap,autoSpeedFrameCountLimit,autoSpeedOutputPollCountLimit
 case autoSpeedSparseTrigger,autoSpeedLowCadenceFPS,autoSpeedLowCadenceFrameCount,autoSpeedLowCadenceCheckInterval,autoSpeedLowCadenceChecks,autoSpeedRequiredLowCadenceChecks,autoSpeedHealthyReferenceFPS,autoSpeedRecentAdvancingFrames,autoSpeedMaximumObservationGap,autoSpeedMinimumSparseSpeed
 // One terminal observation per automatic step (max16), plus one session summary.
 case autoRecoveryOutcome,autoRecoveryCadenceApplicable,autoRecoveryMilestones,autoRecoveryBaselineMask,autoRecoveryDecisionUptime,autoRecoveryRateConfirmedMS,autoRecoveryFirstFrameMS,autoRecoverySustainedMS,autoRecoveryEndedMS,autoRecoveryResets,autoRecoveryInvalidObservations
 case autoRecoveryWindowSeconds,autoRecoveryMinimumFPS,autoRecoveryCheckSeconds,autoRecoverySeen,autoRecoveryEmitted,autoRecoverySuppressed,autoRecoveryRecovered,autoRecoveryFirstFrameOnly,autoRecoveryIncomplete,autoRecoveryLimit
 case autoSpeedBaselineReady,autoSpeedAwaitingRateStart,autoSpeedLastResetReason,autoSpeedResetCount
 case stallNotifications,stallPending,stallAttempts,stallResumes,stallBlockedBy,stallActiveMS,stallTimeout,resumeContext,playerClock,transportStatus,bufferEmpty,bufferAheadMS,deliveredBytes
 case rawDataRequests,rawRequestsAtLeast512,rawRequestsToEnd,rawMaximumBytes,smallDemandReads,largeDemandReads,largeDemandBytes,readSizePromotions,readSizeResets,slowDemandReads,maximumDemandReads,readSizeWaitingReductions,currentDemandChunkBytes
 case prefetchHitBytes,prefetchJoinedBytes,prefetchMissBytes,prefetchReadBytes,prefetchDiscardedBytes,prefetchResidentBytes,prefetchPeakBytes,prefetchReadMS,prefetchDemandWaitMS
 // Build80 prefetch trace: fixed numeric relative ranges and reason codes only.
 case pfTraceSession,pfTraceSequence,pfTracePrefetch,pfTraceRequest,pfTraceGeneration,pfTraceEpoch,pfTraceReadGeneration,pfTraceReadEpoch,pfTraceEvent,pfTraceReason,pfTraceInvalidation
 case pfTracePrefetchBytes,pfTracePrefetchPrefix,pfTracePrefetchOverlap,pfTracePrefetchDelta,pfTraceDemandBytes,pfTraceDemandDelta,pfTraceReadyBytes,pfTraceReadyPrefix,pfTraceReadyOverlap
 case pfTraceInFlightBytes,pfTraceInFlightPrefix,pfTraceInFlightOverlap,pfTraceQueue,pfTraceUsedReady,pfTraceUsedJoined,pfTraceDiscarded,pfTraceState
 case pfTraceGenerated,pfTraceSuppressed,pfTraceHistoryGenerated,pfTraceHistorySuppressed,pfTracePrefetchGenerated,pfTracePrefetchSuppressed,pfDropFlushBytes,pfDropEpochBytes,pfDropMismatchBytes,pfDropCancelledBytes,pfDropSourceBytes,pfDropOtherBytes,pfDropTotalBytes
 // Build81: recent history is distinct from first use of speculative bytes.
 case cacheHistoryHitBytes,cacheHistoryBytes,cacheTotalBytes,cacheInFlightReservedBytes,cacheMaxTotalBytes,prefetchWaitCount,prefetchWaitMS
 // Build84: process memory and cache payload allocation are separate quantities.
 case memoryFootprintBytes,memoryObservedPeakBytes,memoryProcessPeakBytes,memoryAvailableBytes,memoryWarningEvents,memoryCriticalEvents
 case cacheStorageAllocatedBytes,cacheStoragePeakAllocatedBytes
 case prefetchRetiredBytes
 case cacheQuarantineEntered,cacheQuarantineValidated,cacheQuarantineCleared
 case cacheQuarantined
 case cacheValidBytes,cacheMetadataEntries,cacheMetadataPeakEntries,cacheMetadataAllocatedBytes,cacheMetadataPeakAllocatedBytes
 case pfWaitingDemands,pfJoinedDemands,pfHistoryEvictedBytes
 // Build96: whole-session successful wrapper demand and forward-state aggregates.
 case pfDemandFullCacheCount,pfDemandPartialCacheCount,pfDemandZeroCacheCount,pfDemandCancelledCount,pfDemandFailedCount,pfDemandSourceWaitCount,pfDemandSourceCallCount,pfForwardCreateCount,pfForwardAdvanceCount,pfForwardBackreadPreservedCount,pfForwardSuspendCount,pfForwardCancelPreservedCount,pfForwardRebaseCount,pfForwardDistantPendingCount,pfForwardLifecycleRetiredCount,pfForwardEpochRetiredCount,pfForwardEvidenceRetiredCount,pfForwardDemandFailureRetiredCount,pfForwardPrefetchFailureRetiredCount,pfForwardUnretainedEvidenceCount,pfForwardTransitionID,pfDemandSourceWaitMS,pfForwardTransition
 case pfNoAdmissionWindow,pfNoAdmissionDemandOrGrace,pfNoAdmissionDisabledOrEpoch,pfNoAdmissionFilledOrBudget
 case pfTraceHistoryBytes,pfTraceHistoryOverlap,pfTraceHistoryDelta,pfTraceCacheBytes,pfTraceReservedBytes,pfTraceDemandOwnedBytes,pfTraceUsedHistory,pfTraceWaited,pfTraceWaitMS,pfTraceHistoryEvictedBytes
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

/// One process-wide reading, not the cache size or device RAM. Unknown values stay absent.
struct PlaybackProcessMemorySnapshot:Sendable {
 var footprintBytes:UInt64?
 /// Kernel ledger peak for this process lifetime, which may precede this playback.
 var processPeakBytes:UInt64?
 /// Instantaneous remaining dirty-memory allowance; neither a fixed cap nor a promise.
 var availableBytes:UInt64?

 static func current()->Self {
  var snapshot=Self()
  #if canImport(Darwin)
  var info=task_vm_info_data_t()
  var count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
  let capacity=Int(count)
  let result=withUnsafeMutablePointer(to:&info) {pointer in
   pointer.withMemoryRebound(to:integer_t.self,capacity:capacity) {
    task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
   }
  }
  if result==KERN_SUCCESS {
   // Older kernels can return a shorter revision. Test field bounds, not zero-filled data.
   let returnedBytes=Int(count)*MemoryLayout<integer_t>.size
   if let offset=MemoryLayout<task_vm_info_data_t>.offset(of:\.phys_footprint),returnedBytes>=offset+MemoryLayout<UInt64>.size {
    snapshot.footprintBytes=info.phys_footprint
   }
   if let offset=MemoryLayout<task_vm_info_data_t>.offset(of:\.ledger_phys_footprint_peak),returnedBytes>=offset+MemoryLayout<Int64>.size,info.ledger_phys_footprint_peak>=0 {
    snapshot.processPeakBytes=UInt64(info.ledger_phys_footprint_peak)
   }
  }
  #if os(visionOS) && !targetEnvironment(simulator)
  if #available(visionOS 1.0, *) {
   // The API returns zero for an over-limit process or a caller that is not an app.
   // Do not substitute physicalMemory, and do not present host/simulator budget as device budget.
   snapshot.availableBytes=UInt64(os_proc_available_memory())
  }
  #endif
  #endif
  return snapshot
 }
}

/// Fixed-size per-playback state. Called only with existing diagnostic snapshots, not per read/frame.
struct PlaybackMemoryDiagnostics {
 var pressureMonitored=false
 var warningEvents:UInt32=0,criticalEvents:UInt32=0
 private(set) var observedPeakBytes:UInt64?

 mutating func recordPressure(warning:Bool,critical:Bool) {
  guard pressureMonitored else{return}
  // Dispatch can coalesce notifications: these count delivered flags, not pressure transitions.
  if warning,warningEvents<UInt32.max {warningEvents += 1}
  if critical,criticalEvents<UInt32.max {criticalEvents += 1}
 }
 mutating func values(sampling snapshot:PlaybackProcessMemorySnapshot)->[PlaybackLogField:Double] {
  var values:[PlaybackLogField:Double]=[:]
  if let footprint=snapshot.footprintBytes {
   observedPeakBytes=max(observedPeakBytes ?? footprint,footprint)
   values[.memoryFootprintBytes]=Double(footprint)
  }
  // Sampled high-water mark since this playback began. It can miss between-sample peaks.
  if let observedPeakBytes {values[.memoryObservedPeakBytes]=Double(observedPeakBytes)}
  if let peak=snapshot.processPeakBytes {values[.memoryProcessPeakBytes]=Double(peak)}
  if let available=snapshot.availableBytes {values[.memoryAvailableBytes]=Double(available)}
  if pressureMonitored {
   values[.memoryWarningEvents]=Double(warningEvents)
   values[.memoryCriticalEvents]=Double(criticalEvents)
  }
  return values
 }
}
public struct PlaybackLogRecord:Codable,Sendable {
 public let event:PlaybackLogEvent
 public let uptime:Double
 public private(set) var values:[String:Double]
 var waitEpisode:PlaybackWaitEpisodeDiagnostics.Record?
 var intentRecovery:PlaybackIntentRecoveryDiagnostics.Record?
 var hypothesis:PlaybackHypothesisDiagnostics.Record?
 var stallProbe:PlaybackStallProbeDiagnostics.Record?
 var rateChange:PlaybackStallProbeDiagnostics.CommandSnapshot?
 var stallProbeSummary:PlaybackStallProbeDiagnostics.Summary?
 public let build:String
 public init(event:PlaybackLogEvent,values:[PlaybackLogField:Double],build:String = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0") {
  self.event=event;uptime=ProcessInfo.processInfo.systemUptime;waitEpisode=nil
  self.values=Dictionary(uniqueKeysWithValues:values.filter{$0.value.isFinite}.map{($0.key.rawValue,$0.value)})
  self.build=build.count<=12 && build.allSatisfy({$0.isNumber || $0 == "."}) ? build:"0"
 }
 init(waitEpisode:PlaybackWaitEpisodeDiagnostics.Record,build:String = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0") {
  self.init(event:.waitEpisode,values:[:],build:build);self.waitEpisode=waitEpisode
 }
 func withWaitLosses(dropped:UInt64,rejected:UInt64,failures:UInt64,missingPayload:UInt64=0,oversize:UInt64=0,encoding:UInt64=0,rotatedFiles:UInt64=0,expiredFiles:UInt64=0)->Self {
  var result=self
  result.values[PlaybackLogField.waitLogDropped.rawValue]=Double(dropped)
  result.values[PlaybackLogField.waitLogRejected.rawValue]=Double(rejected)
  result.values[PlaybackLogField.waitLogFailures.rawValue]=Double(failures)
  result.values[PlaybackLogField.waitLogRejectedMissingPayload.rawValue]=Double(missingPayload)
  result.values[PlaybackLogField.waitLogRejectedOversize.rawValue]=Double(oversize)
  result.values[PlaybackLogField.waitLogRejectedEncoding.rawValue]=Double(encoding)
  result.values[PlaybackLogField.waitJournalRotatedFiles.rawValue]=Double(rotatedFiles)
  result.values[PlaybackLogField.waitJournalExpiredFiles.rawValue]=Double(expiredFiles)
  return result
 }
}
/// Detailed traces use a separate low-priority record, not an ever-growing sample payload.
public extension PlaybackLogRecord {
 init(prefetch record:PrefetchDiagnosticRecord,build:String = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0") {
  var v:[PlaybackLogField:Double] = [
   .pfTraceSession:Double(record.sessionID),.pfTraceSequence:Double(record.sequence),
   .pfTracePrefetch:Double(record.prefetchID),.pfTraceRequest:Double(record.requestID),
   .pfTraceGeneration:Double(record.generation),.pfTraceEvent:Double(record.event.rawValue),
   .pfTraceReason:Double(record.reason.rawValue),.pfTraceInvalidation:Double(record.invalidationReason.rawValue),
   .pfTracePrefetchBytes:Double(record.prefetchBytes),.pfTracePrefetchPrefix:Double(record.prefetchPrefixBytes),.pfTracePrefetchOverlap:Double(record.prefetchOverlapBytes),.pfTraceDemandBytes:Double(record.demandBytes),
   .pfTraceReadyBytes:Double(record.readyBytes),.pfTraceReadyPrefix:Double(record.readyPrefixBytes),.pfTraceReadyOverlap:Double(record.readyOverlapBytes),
   .pfTraceInFlightBytes:Double(record.inFlightBytes),.pfTraceInFlightPrefix:Double(record.inFlightPrefixBytes),.pfTraceInFlightOverlap:Double(record.inFlightOverlapBytes),
   .pfTraceQueue:Double(record.queueDepth),.pfTraceUsedReady:Double(record.usedReadyBytes),.pfTraceUsedJoined:Double(record.usedJoinedBytes),
   .pfTraceDiscarded:Double(record.discardedBytes),.pfTraceState:Double(record.stateBits),
   .pfTraceHistoryBytes:Double(record.historyBytes),.pfTraceHistoryOverlap:Double(record.historyOverlapBytes),
   .pfTraceCacheBytes:Double(record.totalCacheBytes),.pfTraceReservedBytes:Double(record.inFlightReservedBytes),
   .pfTraceDemandOwnedBytes:Double(record.demandOwnedBytes),.pfTraceUsedHistory:Double(record.usedHistoryBytes),
   .pfTraceWaited:record.waitedForPrefetch ? 1:0,.pfTraceWaitMS:Double(record.waitMilliseconds),
   .pfTraceHistoryEvictedBytes:Double(record.historyEvictedBytes)]
  if let epoch=record.epoch {v[.pfTraceEpoch]=Double(epoch)}
  if let generation=record.prefetchGeneration {v[.pfTraceReadGeneration]=Double(generation)}
  if let epoch=record.prefetchEpoch {v[.pfTraceReadEpoch]=Double(epoch)}
  if let delta=record.previousPrefetchDelta {v[.pfTracePrefetchDelta]=Double(delta)}
  if let delta=record.demandDelta {v[.pfTraceDemandDelta]=Double(delta)}
  if let delta=record.historyDelta {v[.pfTraceHistoryDelta]=Double(delta)}
  self.init(event:.prefetchTrace,values:v,build:build)
 }
}
public extension PrefetchDiagnosticsSnapshot {
 var playbackLogValues:[PlaybackLogField:Double] {[
  .pfDemandFullCacheCount:Double(demandFullCacheCount),
  .pfDemandPartialCacheCount:Double(demandPartialCacheCount),
  .pfDemandZeroCacheCount:Double(demandZeroCacheCount),
  .pfDemandCancelledCount:Double(demandCancelledCount),
  .pfDemandFailedCount:Double(demandFailedCount),
  .pfDemandSourceWaitCount:Double(demandSourceWaitCount),
  .pfDemandSourceCallCount:Double(demandSourceCallCount),
  .pfForwardCreateCount:Double(forwardCreateCount),
  .pfForwardAdvanceCount:Double(forwardAdvanceCount),
  .pfForwardBackreadPreservedCount:Double(forwardBackreadPreservedCount),
  .pfForwardSuspendCount:Double(forwardSuspendCount),
  .pfForwardCancelPreservedCount:Double(forwardCancelPreservedCount),
  .pfForwardRebaseCount:Double(forwardRebaseCount),
  .pfForwardDistantPendingCount:Double(forwardDistantPendingCount),
  .pfForwardLifecycleRetiredCount:Double(forwardLifecycleRetiredCount),
  .pfForwardEpochRetiredCount:Double(forwardEpochRetiredCount),
  .pfForwardEvidenceRetiredCount:Double(forwardEvidenceRetiredCount),
  .pfForwardDemandFailureRetiredCount:Double(forwardDemandFailureRetiredCount),
  .pfForwardPrefetchFailureRetiredCount:Double(forwardPrefetchFailureRetiredCount),
  .pfForwardUnretainedEvidenceCount:Double(forwardUnretainedEvidenceCount),
  .pfForwardTransitionID:Double(forwardTransitionID),
  .pfDemandSourceWaitMS:demandSourceWaitSeconds*1000,.pfForwardTransition:Double(forwardTransition.rawValue),
  .pfNoAdmissionWindow:Double(noAdmissionWindow),.pfNoAdmissionDemandOrGrace:Double(noAdmissionDemandOrGrace),
  .pfNoAdmissionDisabledOrEpoch:Double(noAdmissionDisabledOrEpoch),.pfNoAdmissionFilledOrBudget:Double(noAdmissionFilledOrBudget),
  .pfTraceSession:Double(sessionID),.pfTraceGenerated:Double(generatedRecords),.pfTraceSuppressed:Double(suppressedRecords),
  .pfTraceHistoryGenerated:Double(historyGeneratedRecords),.pfTraceHistorySuppressed:Double(historySuppressedRecords),
  .pfTracePrefetchGenerated:Double(prefetchGeneratedRecords),.pfTracePrefetchSuppressed:Double(prefetchSuppressedRecords),
  .pfDropFlushBytes:Double(discardedFlushBytes),.pfDropEpochBytes:Double(discardedEpochBytes),
  .pfDropMismatchBytes:Double(discardedNoPrefixOrFIFOBytes),.pfDropCancelledBytes:Double(discardedCancellationBytes),
  .pfDropSourceBytes:Double(discardedSourceBytes),.pfDropOtherBytes:Double(discardedOtherBytes),
  .pfDropTotalBytes:Double(discardedBytes),.pfWaitingDemands:Double(waitingDemandCount),
  .pfJoinedDemands:Double(joinedDemandCount),.pfHistoryEvictedBytes:Double(historyEvictedBytes)]}
}

public final class PlaybackLogStore:@unchecked Sendable {
 public static let shared=PlaybackLogStore(directory:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VistaDiagnostics",isDirectory:true))
 private let directory:URL,limit:Int,retention:TimeInterval
 private let queue=DispatchQueue(label:"Vista.anonymous.diagnostics",qos:.utility),lock=NSLock()
 private var pending:[(Data,Bool)]=[],draining=false,failures=0,dropped=0
 // A complete Native/cache/controller snapshot remains one bounded record.
 // Strict encoded-byte comparison reserves its JSONL delimiter; smaller journals keep their limit.
 static let ordinaryRecordLimit=8192
 static let waitJournalLimit=1_048_576
 private var waitPending=PlaybackWaitEpisodeLogBuffer(),waitRejected:UInt64=0,waitFailures:UInt64=0
 private var waitMissingPayload:UInt64=0,waitOversize:UInt64=0,waitEncoding:UInt64=0
 // These count files actually removed, not rename operations or assumed records.
 private var waitRotatedFiles:UInt64=0,waitExpiredFiles:UInt64=0
 public init(directory:URL,limit:Int=262144,retention:TimeInterval=7*86400){self.directory=directory;self.limit=max(4096,limit);self.retention=max(0,retention)}
 public var status:(failures:Int,dropped:Int){lock.lock();defer{lock.unlock()};return(failures,dropped)}
 public func enqueue(_ record:PlaybackLogRecord){
  lock.lock()
  if record.event == .waitEpisode {
   // Four fixed-shape records, separate from the original eight pending entries.
   // No fsync and no eviction of critical terminal records by episode traffic.
   let previous=waitPending.dropped;waitPending.append(record)
   if waitPending.dropped>previous {dropped+=1}
  } else {
   let enriched=record.event.isCritical ? enrichWaitLosses(record):record
   lock.unlock()
   guard let encoded=try? JSONEncoder().encode(enriched),encoded.count<min(Self.ordinaryRecordLimit,limit) else {lock.lock();dropped+=1;lock.unlock();return}
   var data=encoded;data.append(10)
   lock.lock()
   if pending.count>=8 {
    if let sample=pending.firstIndex(where:{!$0.1}) {pending.remove(at:sample)}
    else if !record.event.isCritical {dropped+=1;lock.unlock();return}
    else {pending.removeFirst()}
    dropped+=1
   }
   pending.append((data,record.event.isCritical))
  }
  if draining {lock.unlock();return}
  draining=true;lock.unlock()
  queue.async{self.drain()}
 }
 // Caller holds lock. Counters are process-local cumulative observations.
 private func enrichWaitLosses(_ record:PlaybackLogRecord)->PlaybackLogRecord {
  var result=record.withWaitLosses(dropped:waitPending.dropped,rejected:waitRejected,failures:waitFailures,
   missingPayload:waitMissingPayload,oversize:waitOversize,encoding:waitEncoding,
   rotatedFiles:waitRotatedFiles,expiredFiles:waitExpiredFiles)
  if record.event == .playbackHypothesis || record.event == .intentRecovery || record.event == .automaticRecovery || record.event == .automaticRecoverySummary || record.event == .stallProbe || record.event == .stallProbeSummary {
   // Process-local cumulative journal losses, refreshed at drain. Emitted is
   // observer output, not an assertion that every earlier record reached disk.
   result=result.withRecoveryLogLosses(dropped:dropped,failures:failures)
  }
  return result
 }
 private func rejectWait(_ reason:Int) {
  lock.lock();defer{lock.unlock()}
  PlaybackWaitEpisodeDiagnostics.increment(&waitRejected);dropped+=1
  switch reason {
  case 0:PlaybackWaitEpisodeDiagnostics.increment(&waitMissingPayload)
  case 1:PlaybackWaitEpisodeDiagnostics.increment(&waitOversize)
  default:PlaybackWaitEpisodeDiagnostics.increment(&waitEncoding)
  }
 }
 private func drain(){
  while true {
   lock.lock()
   var next:(Data,Bool)
   let episode:Bool
   if let critical=pending.firstIndex(where:{$0.1}) {
    next=pending.remove(at:critical);episode=false
    // Refresh counters on the utility queue, including failures after enqueue.
    if let record=try? JSONDecoder().decode(PlaybackLogRecord.self,from:next.0),
       let encoded=try? JSONEncoder().encode(enrichWaitLosses(record)),encoded.count<min(Self.ordinaryRecordLimit,limit) {
     var data=encoded;data.append(10);next=(data,true)
    }
   } else if let record=waitPending.take() {
    let enriched=enrichWaitLosses(record)
    lock.unlock()
    guard record.waitEpisode != nil else {rejectWait(0);continue}
    guard let encoded=try? JSONEncoder().encode(enriched) else {rejectWait(2);continue}
    // Include the JSONL delimiter in the strict per-record limit. Validate before
    // any file creation, expiration, rotation or write; never split a record.
    guard encoded.count+1<Self.waitJournalLimit else {rejectWait(1);continue}
    var data=encoded;data.append(10);next=(data,false);episode=true
    lock.lock()
   } else if !pending.isEmpty {next=pending.removeFirst();episode=false}
   else {draining=false;lock.unlock();return}
   lock.unlock()
   do {try write(next.0,synchronize:next.1,episode:episode)}catch{
    lock.lock();failures+=1
    if episode {PlaybackWaitEpisodeDiagnostics.increment(&waitFailures)}
    lock.unlock()
   }
  }
 }
 private func file(_ index:Int,episode:Bool)->URL {
  let prefix=episode ? "wait-":""
  return directory.appendingPathComponent(prefix+(index == 0 ? "current.jsonl":"previous-\(index).jsonl"))
 }
 private func write(_ data:Data,synchronize:Bool,episode:Bool)throws {
  let fm=FileManager.default
  let journalLimit=episode ? Self.waitJournalLimit:limit
  guard data.count<=journalLimit else{throw CocoaError(.fileWriteUnknown)}
  try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  var excluded=directory;var values=URLResourceValues();values.isExcludedFromBackup=true;try excluded.setResourceValues(values)
  // Sweep both lanes for age, but only the selected lane can rotate for size.
  for lane in [false,true] {for i in 0...3 {
   let url=file(i,episode:lane)
   if let date=try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,Date().timeIntervalSince(date)>retention {
    try fm.removeItem(at:url)
    if lane {lock.lock();PlaybackWaitEpisodeDiagnostics.increment(&waitExpiredFiles);lock.unlock()}
   }
  }}
  let current=file(0,episode:episode)
  let size=(try? fm.attributesOfItem(atPath:current.path)[.size] as? NSNumber)?.intValue ?? 0
  if size+data.count>journalLimit {
   let oldest=file(3,episode:episode)
   if fm.fileExists(atPath:oldest.path){
    try fm.removeItem(at:oldest)
    if episode {lock.lock();PlaybackWaitEpisodeDiagnostics.increment(&waitRotatedFiles);lock.unlock()}
   }
   for i in stride(from:2,through:0,by:-1) where fm.fileExists(atPath:file(i,episode:episode).path){
    try fm.moveItem(at:file(i,episode:episode),to:file(i+1,episode:episode))
   }
  }
  if !fm.fileExists(atPath:current.path) {
   guard fm.createFile(atPath:current.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw CocoaError(.fileWriteUnknown)}
   #if os(visionOS) || os(iOS)
   try fm.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:current.path)
   #endif
  }
  let handle=try FileHandle(forWritingTo:current);defer{try? handle.close()}
  let offset=try handle.seekToEnd()
  do {try handle.write(contentsOf:data)} catch {
   // A failed append must not leave a partial JSONL row when rollback is possible.
   try? handle.truncate(atOffset:offset)
   throw error
  }
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

/// Rare numeric decision event, kept separate from already-dense ordinary samples.
public extension PlaybackLogRecord {
 init(automaticSpeed decision:PlaybackAutomaticSpeedPolicy.Decision,session:UInt64,previous:Double) {
  self.init(event:.automaticSpeed,values:[.autoSpeedSession:Double(session),.autoSpeedSequence:Double(decision.sequence),
   .autoSpeedReason:Double(decision.reason.rawValue),.autoSpeedFrom:previous,.autoSpeedTo:decision.nextSpeed,
   .autoSpeedObservedSeconds:decision.observedSeconds,.autoSpeedAdvancingFrames:Double(decision.advancingFrames),
   .autoSpeedOutputPolls:Double(decision.outputPolls),.autoSpeedClockAdvance:decision.clockAdvance,
   .autoSpeedMaximumFrameGap:decision.maximumFrameGap,
   // Retain the legacy field for log readers; it now labels waiting-only recovery.
   .autoSpeedCooldownSeconds:PlaybackAutomaticSpeedPolicy.cooldown,
   .autoSpeedWaitingCooldownSeconds:PlaybackAutomaticSpeedPolicy.cooldown,
   .autoSpeedSparseRearmOnRateStart:1,.autoSpeedSparseWindowSeconds:PlaybackAutomaticSpeedPolicy.sparseInterval,
   .autoSpeedGapWindowSeconds:PlaybackAutomaticSpeedPolicy.minimumSparseFrameGap,
   .autoSpeedGapMinimumPolls:6,
   .autoSpeedSparseTrigger:Double(decision.sparseTrigger.rawValue),
   .autoSpeedCurrentFrameGap:decision.maximumFrameGap,
   .autoSpeedFrameCountLimit:Double(PlaybackAutomaticSpeedPolicy.lowCadenceFrameCount),
   .autoSpeedOutputPollCountLimit:9,
   .autoSpeedLowCadenceFPS:PlaybackAutomaticSpeedPolicy.lowCadenceFPS,
   .autoSpeedLowCadenceFrameCount:Double(PlaybackAutomaticSpeedPolicy.lowCadenceFrameCount),
   .autoSpeedLowCadenceCheckInterval:PlaybackAutomaticSpeedPolicy.lowCadenceCheckInterval,
   .autoSpeedLowCadenceChecks:Double(decision.lowCadenceChecks),
   .autoSpeedRequiredLowCadenceChecks:Double(PlaybackAutomaticSpeedPolicy.minimumLowCadenceChecks),
   .autoSpeedHealthyReferenceFPS:decision.healthyReferenceFPS,
   .autoSpeedRecentAdvancingFrames:Double(decision.recentAdvancingFrames),
   .autoSpeedMaximumObservationGap:PlaybackAutomaticSpeedPolicy.maximumShortObservationGap,
   .autoSpeedMinimumSparseSpeed:PlaybackAutomaticSpeedPolicy.minimumSparseSpeed])
 }
}

// Numeric-only independent records; no new ordinary sample payload or journal.
extension PlaybackLogRecord {
 init(automaticRecovery record:PlaybackAutomaticRecoveryDiagnostics.Record,session:UInt64,
      build:String = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0") {
  var values:[PlaybackLogField:Double]=[
   .autoSpeedSession:Double(session),.autoSpeedSequence:Double(record.sequence),
   .autoSpeedFrom:record.previousSpeed,.autoSpeedTo:record.targetSpeed,
   .autoSpeedHealthyReferenceFPS:record.healthyReferenceFPS,
   .autoRecoveryOutcome:Double(record.reason.rawValue),.autoRecoveryCadenceApplicable:record.cadenceApplicable ? 1:0,
   .autoRecoveryMilestones:Double(record.milestoneMask),.autoRecoveryBaselineMask:Double(record.baselineMask),
   .autoRecoveryResets:Double(record.resets),.autoRecoveryInvalidObservations:Double(record.invalidObservations),
   .autoRecoveryWindowSeconds:PlaybackAutomaticRecoveryDiagnostics.cadenceWindow,
   .autoRecoveryMinimumFPS:PlaybackAutomaticRecoveryDiagnostics.minimumCadenceFPS,
   .autoRecoveryCheckSeconds:PlaybackAutomaticRecoveryDiagnostics.checkInterval]
  if let decisionAt=record.decisionAt {
   values[.autoRecoveryDecisionUptime]=decisionAt
   func elapsed(_ time:Double?,_ field:PlaybackLogField) {
    if let time,time>=decisionAt {values[field]=(time-decisionAt)*1000}
   }
   elapsed(record.rateConfirmedAt,.autoRecoveryRateConfirmedMS)
   elapsed(record.firstFrameAt,.autoRecoveryFirstFrameMS)
   elapsed(record.sustainedAt,.autoRecoverySustainedMS)
   elapsed(record.endedAt,.autoRecoveryEndedMS)
  }
  self.init(event:.automaticRecovery,values:values,build:build)
 }
 init(automaticRecoverySummary summary:PlaybackAutomaticRecoveryDiagnostics.Summary,session:UInt64,
      build:String = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0") {
  self.init(event:.automaticRecoverySummary,values:[
   .autoSpeedSession:Double(session),.autoRecoverySeen:Double(summary.seen),
   .autoRecoveryEmitted:Double(summary.emitted),.autoRecoverySuppressed:Double(summary.suppressed),
   .autoRecoveryRecovered:Double(summary.recovered),.autoRecoveryFirstFrameOnly:Double(summary.firstFrameOnly),
   .autoRecoveryIncomplete:Double(summary.incomplete),.autoRecoveryLimit:Double(PlaybackAutomaticRecoveryDiagnostics.recordLimit)],build:build)
 }
 func withRecoveryLogLosses(dropped:Int,failures:Int)->Self {
  var result=self
  result.values[PlaybackLogField.logDropped.rawValue]=Double(dropped)
  result.values[PlaybackLogField.logFailures.rawValue]=Double(failures)
  return result
 }
}

// Build98 probe evidence has two scalar snapshots at most. Ordinary samples do
// not gain fields; these events use the existing bounded critical writer lane.
extension PlaybackLogRecord {
 init(stallProbe record:PlaybackStallProbeDiagnostics.Record,session:UInt64,
      build:String = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0") {
  self.init(event:.stallProbe,values:[:],build:build)
  var payload=record;payload.session=session;stallProbe=payload
 }
 init(stallProbeSummary summary:PlaybackStallProbeDiagnostics.Summary,session:UInt64,
      build:String = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0") {
  self.init(event:.stallProbeSummary,values:[:],build:build)
  var payload=summary;payload.session=session;stallProbeSummary=payload
 }
}

// Limited by the existing automatic-recovery observer's 16-step admission at
// the caller. The ordinary decision event remains useful without this detail.
extension PlaybackLogRecord {
 init(automaticSpeed decision:PlaybackAutomaticSpeedPolicy.Decision,session:UInt64,previous:Double,
      before:PlaybackStallProbeDiagnostics.Snapshot?,after:PlaybackStallProbeDiagnostics.Snapshot?,setterBranch:Int?) {
  self.init(automaticSpeed:decision,session:session,previous:previous)
  if let before,let after,let setterBranch {
   rateChange=PlaybackStallProbeDiagnostics.CommandSnapshot(before:before.sanitized(),after:after.sanitized(),setterBranch:setterBranch)
  }
 }
}
