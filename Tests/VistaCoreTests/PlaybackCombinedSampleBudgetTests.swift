import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

/// Complete Native/controller sample key union, including the retained timing/read-count/byte seek stages,
/// source/cache metrics, current memory/video fields, and controller UI snapshot.
/// Uses numeric synthetic values only: no AVPlayer, NAS or user media is opened.
@Suite(.serialized) @MainActor struct PlaybackCombinedSampleBudgetTests {
 private let directFields:[PlaybackLogField]=[.autoSpeedAwaitingRateStart,.autoSpeedBaselineReady,.autoSpeedLastResetReason,.autoSpeedResetCount,.bufferAheadMS,.bufferEmpty,.buffering,.bytes,.cacheHistoryBytes,.cacheHistoryHitBytes,.cacheInFlightReservedBytes,.cacheMaxTotalBytes,.cacheMetadataAllocatedBytes,.cacheMetadataEntries,.cacheMetadataPeakAllocatedBytes,.cacheMetadataPeakEntries,.cacheQuarantineCleared,.cacheQuarantineEntered,.cacheQuarantineValidated,.cacheQuarantined,.cacheStorageAllocatedBytes,.cacheStoragePeakAllocatedBytes,.cacheTotalBytes,.cacheValidBytes,.clockDeltaMS,.coalesced,.currentDemandChunkBytes,.decoder,.deliveredBytes,.effectiveRate,.epoch,.firstBytes,.firstFrameMS,.firstReads,.frames,.height,.interrupted,.ioCancelled,.ioFailed,.ioFinished,.ioInFlight,.ioMaxMS,.ioOld,.ioOldMS,.ioOldRemaining,.ioPeak,.ioStarted,.largeDemandBytes,.largeDemandReads,.layout,.logDropped,.logFailures,.maximumDemandReads,.maximumSpeed,.paused,.playerClock,.playing,.position,.prefetchDemandWaitMS,.prefetchDiscardedBytes,.prefetchHitBytes,.prefetchJoinedBytes,.prefetchMissBytes,.prefetchPeakBytes,.prefetchReadBytes,.prefetchReadMS,.prefetchResidentBytes,.prefetchRetiredBytes,.prefetchWaitCount,.prefetchWaitMS,.preparing,.presentBytes,.presentMS,.presentReads,.projection,.rawDataRequests,.rawMaximumBytes,.rawRequestsAtLeast512,.rawRequestsToEnd,.readMS,.reads,.resumeContext,.route,.seekBytes,.seekMS,.seekReads,.selectedSpeed,.smallDemandReads,.stallActiveMS,.stallAttempts,.stallBlockedBy,.stallNotifications,.stallPending,.stallResumes,.stallTimeout,.target,.targetBuffered,.textureCount,.textureMS,.transportStatus,.uploaded,.waitCompleted,.waitEpisodes,.waitIncomplete,.waitMS,.waitSuppressed,.waits,.width]
 private let booleanFields:Set<PlaybackLogField>=[.playing,.paused,.preparing,.buffering,.targetBuffered,.stallPending,.bufferEmpty,.autoSpeedBaselineReady,.autoSpeedAwaitingRateStart,.cacheQuarantined]
 private let memoryFields:[PlaybackLogField]=[.memoryFootprintBytes,.memoryObservedPeakBytes,.memoryProcessPeakBytes,.memoryAvailableBytes,.memoryWarningEvents,.memoryCriticalEvents]
 private let videoFields:[PlaybackLogField]=[.videoLoopTicks,.videoLoopSessionMaxGapMS,.videoOutputPolls,.videoOutputHasNew,.videoOutputCopyNil,.videoFrameAgeMS]
 private func sample(level:Int)->[PlaybackLogField:Double] {
  var values=NativePlaybackSession().anonymousLogValues()
  for field in directFields+memoryFields+videoFields {values[field]=0}
  values.merge(PrefetchDiagnosticsSnapshot().playbackLogValues){_,new in new}
  var ui=PlaybackControllerUIDiagnostics()
  let state=PlaybackControllerUIState(stopping:true,scrubbing:true,preparing:false,advancing:false,requiresFormatConfirmation:false,canResetSpeed:true,canIncreaseSpeed:true,canGoBack:true,canAdvance:true,hasDuration:true)
  _=ui.update(state:state,action:.stopBegan,now:1_234_567.123456789)
  values.merge(ui.snapshot(now:1_234_568.987654321)){_,new in new}
  for field in Array(values.keys) {
   let name=field.rawValue.lowercased()
   if booleanFields.contains(field) {values[field]=1;continue}
   if name.contains("mask") {values[field]=3;continue}
   if name.contains("uptime") {values[field]=1_234_567.123456789;continue}
   if name.hasSuffix("ms") {values[field]=level == 0 ? 0 : level == 1 ? 1234.567890123456 : level == 2 ? 86_400_123.456789 : Double.greatestFiniteMagnitude;continue}
   if name.contains("bytes") || name == "bytes" {values[field]=level == 0 ? 0 : level == 1 ? 167_772_160 : level == 2 ? 1_099_511_627_776 : Double(UInt64.max);continue}
   values[field]=level == 0 ? 0 : level == 1 ? 12_345 : level == 2 ? 1_234_567 : Double(UInt64.max)
  }
  values[.selectedSpeed]=2.5;values[.effectiveRate]=2.5;values[.maximumSpeed]=5
  values[.position]=7_200.123456789;values[.playerClock]=7_200.123456789
  values[.width]=7680;values[.height]=3840;values[.decoder] = -1
  values[.projection]=2;values[.layout]=1;values[.route]=0
  values[.currentDemandChunkBytes]=2_097_152;values[.cacheTotalBytes]=167_772_160
  values[.cacheStorageAllocatedBytes]=167_772_160;values[.cacheStoragePeakAllocatedBytes]=167_772_160
  values[.cacheInFlightReservedBytes]=2_097_152;values[.cacheMetadataEntries]=1024
  values[.cacheMetadataPeakEntries]=1024;values[.cacheValidBytes]=167_772_160
  return values
 }
 @Test(arguments:[0,1,2,3]) func combinedNativePrefetchAndControllerSampleFitsExistingRecordBudget(level:Int)throws {
  let values=sample(level:level)
  #expect(values[.pfDemandFullCacheCount] != nil && values[.uiStateMask] != nil)
  #expect(values[.cacheTotalBytes] != nil && values[.seekMS] != nil && values[.memoryAvailableBytes] != nil)
  #expect(PlaybackLogStore.ordinaryRecordLimit == 8192)
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:dir)}
  let store=PlaybackLogStore(directory:dir)
  for event in [PlaybackLogEvent.sample,.controllerUI,.stopped,.failed] {
   let record=PlaybackLogRecord(event:event,values:values,build:"96")
   let measured=event.isCritical ? record.withWaitLosses(dropped:UInt64.max,rejected:UInt64.max,failures:UInt64.max,missingPayload:UInt64.max,oversize:UInt64.max,encoding:UInt64.max,rotatedFiles:UInt64.max,expiredFiles:UInt64.max):record
   let data=try JSONEncoder().encode(measured)
   let report:[String:Any]=["level":level,"event":event.rawValue,"fields":measured.values.count,"encodedBytes":data.count,"strictLimitBytes":PlaybackLogStore.ordinaryRecordLimit]
   print("COMBINED_LOG_BUDGET",String(decoding:try JSONSerialization.data(withJSONObject:report,options:.sortedKeys),as:UTF8.self))
   #expect(data.count < PlaybackLogStore.ordinaryRecordLimit)
   store.enqueue(measured);store.drainForTesting()
  }
  #expect(store.status.dropped == 0 && store.status.failures == 0)
  let persisted=try String(contentsOf:dir.appendingPathComponent("current.jsonl"),encoding:.utf8)
  let rows=try persisted.split(separator:"\n").map{try JSONDecoder().decode(PlaybackLogRecord.self,from:Data($0.utf8))}
  #expect(rows.count == 4)
  for row in rows {
   #expect(values.allSatisfy{row.values[$0.key.rawValue] == $0.value})
  }
 }
 @Test func oversizedFiniteRecordIsRejectedWithoutCreatingFile()throws {
  let values=Dictionary(uniqueKeysWithValues:PlaybackLogField.allCases.map{($0, -Double.greatestFiniteMagnitude)})
  let record=PlaybackLogRecord(event:.sample,values:values,build:"96")
  let encoded=try JSONEncoder().encode(record)
  #expect(encoded.count >= PlaybackLogStore.ordinaryRecordLimit)
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:dir)}
  let store=PlaybackLogStore(directory:dir);store.enqueue(record);store.drainForTesting()
  #expect(store.status.dropped == 1 && store.status.failures == 0)
  #expect(!FileManager.default.fileExists(atPath:dir.path))
  print("OVERSIZE_LOG_BUDGET",encoded.count,"fields",values.count,"dropped",store.status.dropped)
 }
 @Test func completeFieldUnionRejectsUnconstrainedDoubleWidthWhenNecessary()throws {
  // This deliberately ignores mask/count/time semantics. It proves rejection
  // remains bounded, not that all these values can coexist in real playback.
  let values=Dictionary(uniqueKeysWithValues:sample(level:0).keys.map{($0,-Double.greatestFiniteMagnitude)})
  let record=PlaybackLogRecord(event:.controllerUI,values:values,build:"96").withWaitLosses(dropped:UInt64.max,rejected:UInt64.max,failures:UInt64.max,missingPayload:UInt64.max,oversize:UInt64.max,encoding:UInt64.max,rotatedFiles:UInt64.max,expiredFiles:UInt64.max)
  let encoded=try JSONEncoder().encode(record)
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:dir)}
  let store=PlaybackLogStore(directory:dir);store.enqueue(record);store.drainForTesting()
  #expect(store.status.failures == 0)
  #expect(store.status.dropped == (encoded.count >= PlaybackLogStore.ordinaryRecordLimit ? 1:0))
  print("UNCONSTRAINED_FULL_UNION",encoded.count,"fields",record.values.count,"dropped",store.status.dropped)
 }
 @Test func explicitNativeAndControllerKeyUnionMatchesProductionSource()throws {
  let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let native=try String(contentsOf:root.appendingPathComponent("Sources/VistaMedia/NativePlaybackSession.swift"),encoding:.utf8).components(separatedBy:"public func anonymousLogValues()")[1].components(separatedBy:"public private(set) var selectedSpeed")[0]
  let controller=try String(contentsOf:root.appendingPathComponent("Sources/VistaMedia/PlaybackController.swift"),encoding:.utf8).components(separatedBy:"public func persistDiagnostics(")[1].components(separatedBy:"public func play(file:")[0]
  let text=native+controller
  let regex=try NSRegularExpression(pattern:#"\.([A-Za-z][A-Za-z0-9]*)"#)
  let strings=Set(regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap{Range($0.range(at:1),in:text).map{String(text[$0])}})
  let expected=Set(PlaybackLogField.allCases.map(\.rawValue)).intersection(strings)
  #expect(Set(directFields.map(\.rawValue)) == expected)
 }
 @Test func smallerJournalRejectsCombinedRecordBeforeWriting()throws {
  let record=PlaybackLogRecord(event:.sample,values:sample(level:1),build:"96")
  let encoded=try JSONEncoder().encode(record)
  #expect(encoded.count >= 4096 && encoded.count < PlaybackLogStore.ordinaryRecordLimit)
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:dir)}
  let store=PlaybackLogStore(directory:dir,limit:4096)
  store.enqueue(record);store.drainForTesting()
  #expect(store.status.dropped == 1 && store.status.failures == 0)
  #expect(!FileManager.default.fileExists(atPath:dir.path))
 }
 @Test func loggerQueueFileAndWaitLimitsRemainUnchanged()throws {
  let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let source=try String(contentsOf:root.appendingPathComponent("Sources/VistaMedia/PlaybackMetrics.swift"),encoding:.utf8)
  #expect(source.contains("if pending.count>=8"))
  #expect(source.contains("limit:Int=262144"))
  #expect(source.contains("self.limit=max(4096,limit)"))
  #expect(PlaybackLogStore.waitJournalLimit == 1_048_576)
  #expect(source.components(separatedBy:"encoded.count<min(Self.ordinaryRecordLimit,limit)").count == 3)
  #expect(source.contains("guard encoded.count+1<Self.waitJournalLimit"))
 }
}
