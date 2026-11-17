import Foundation

/// Passive diagnostic IDs only; never retain a pixel, media object or source path.
public struct PlaybackFlowToken:Sendable,Equatable {
 public let id:UInt64
 public init(_ id:UInt64=0){self.id=id}
 public static let none=Self()
}
public enum PlaybackFlowStage:UInt32,Sendable,CaseIterable {
 case session=1
 case trigger=2
 case anchor=3
 case control=4
 case watch=5
 case inputRead=10
 case inputSeek=11
 case demux=12
 case decoderEnqueue=13
 case block=14
 case fifoEnqueue=15
 case fifoDequeue=16
 case processInput=17
 case packetizer=18
 case decoderCall=19
 case fifoLock=20
 case inputPace=21
 case loopControl=22
 case loopEmpty=23
 case loopPause=24
 case frame=30
 case pacer=31
 case submit=32
 case callback=33
 case callbackLock=34
 case picture=35
 case dpbInsert=36
 case dpbExit=37
 case queueVideo=38
 case prepare=39
 case drop=40
 case render=41
 case renderWait=42
 case voutPrepare=43
 case voutDisplay=44
 case mailboxPrepare=45
 case mailboxDisplay=46
 case mailboxTake=47
 case mailboxRelease=48
 case vtSession=49
 case vtDrain=50
 case clockConvert=51
 case asyncRead=100
 case condition=101
 case taskStart=102
 case previousJoin=103
 case windowRead=104
 case callbackCopy=105
 case sourceRequest=110
 case sourceQueued=111
 case sourceWork=112
 case sourceCall=113
 case sourceAccept=114
 case poll=120
 case pollActor=121
 case frameCopy=122
 case pixelPrepare=123
 case appGate=124
 case publish=125
 case controller=126
 case property=127
 case uiTask=128
 case route=129
 case presentSubmit=130
 case coalesce=131
 case worker=132
 case flush=133
 case readyWait=134
 case sample=135
 case enqueue=136
 case material=137
 case bind=138
 case entity=139
 case discard=140
 case failure=141
 case gpuEpoch=142
 case gpuEncode=143
 case gpuCommit=144
 case gpuComplete=145
 case gpuResume=146
 case gpuTimes=147
 case image=148
 case textureLeft=149
 case textureRight=150
 case preview=151
 case cleanup=152
 case controlIntent=160
 case controlActor=161
 case observerEnd=162
 case state=163
 case link=164
 case resyncDecision=165
 case resyncState=166
 case resyncSamples=167
 case resyncPTS=168
 case resyncLate=169
 case resyncMapping=170
 case resyncReferences=171
 case resyncReads=172
 case resyncWindow=173
 case resyncProof=174
 case resyncDispatch=175
 case resyncDispatchData=176
 case resyncDispatchEnd=177
 case resyncMilestones=178
 case nativeAudioRateChange=180
 case nativeAudioSegment=181
 case nativeAudioSegmentMeta=182
 case nativeAudioMapReport=183
 case nativeAudioMapSystem=184
 case nativeAudioMapReset=185
 case nativeAudioMapFailure=186
 case nativeAudioPlay=187
 case nativeAudioFilter=188
 case nativeAudioSync=189
 case audioSummary=200
 case audioIdentity=201
 case audioMetadata=202
 case audioSetter=203
 case audioChange=204
 case audioBoundary=205
 case audioEnqueue=206
 case audioCounters=207
 case audioNativeEnd=208
 case audioFirstReport=209
 case audioLastReport=210
 case audioReject=211
 case audioAccept=212
 case audioClock=213
 case audioWatch=214
 case audioWatchPTS=215
 case audioSummaryEnd=216
 case resyncBaseline=217
 case resyncBaselineData=218
 case audioQueue=220
 case audioQueueLock=221
 case audioWaitUnblock=222
 case audioWaitCondition=223
 case audioStreamPlay=224
 case audioCheckReady=225
 case audioClockLock=226
 case audioClockConvert=227
 case audioTimingLock=228
 case audioMapEnqueue=229
 case audioCodec=230
 case audioWaitState=231
 case audioMeter=232
 case audioStats=233
 case audioCommandIdentity=234
 case audioMapAnchor=235
 case queuePressureSample=240
 case queuePressureTiming=241
 case queuePressureProgress=242
 case queuePressureResult=243
 case queuePressureDecision=244
 case queuePressureRead=245
 case controlSourceValidation=246
 case controlPresentationDrain=247
 case vtPrerollDecision=250
 case vtPrerollSubmit=251
 case vtPrerollCallback=252
 case vtPrerollDpb=253
 case vtPrerollFallback=254
 case bufferEpisode=300
 case bufferState=301
 case bufferThreshold=302
 case bufferComponents=303
 case bufferDecoder=304
 case bufferClock=305
 case prerollTarget=306
 case decoderIdentity=307
 case decoderStartWait=308
 case decoderReady=309
 case decoderWait=310
 case decoderStopWait=311
 case decoderPreroll=312
 case decoderPrerollCounts=313
 case decoderForced=314
 case decoderOutputWait=315
 case decoderWaitFlags=316
 case bufferPrerollMark=317
 case inputSeekQueued=318
 case inputControlExec=319
 case inputControlReplaced=320
 case voutForcedHandoff=330
 case voutForcedHandoffState=331
 case voutRenderDeferred=332
 case automaticDecision=340
 case automaticDecisionWindow=341
 case automaticDecisionContext=342
 case healthyRecovery=343
 case healthyRecoveryProof=344
 case healthyRecoveryCounters=345
 case healthyRecoveryScope=346
 case healthyRecoveryRun=347
 case healthyRecoveryTarget=348
 case presentationHold=350
 case presentationHoldRelease=351
 case presentationHoldState=352
 case resyncProbe=353
 case resyncProbeTiming=354
 case resyncProbeCached=355
 case resyncProbeScope=356
 case holdByteEstimate=360
 case holdByteValues=361
 case holdByteDimensions=362
 case holdByteLayout=363
 case holdByteIdentity=364
 case healthProbe=365
 case healthProbeRun=366
 case healthProbeScope=367
 case healthProbeNative=368
 case healthProbeApply=369
 case pollSleep=370
 case presentationBinding=371
 case presentationSurface=372
 case presentationGeometry=373
 case presentationPose=374
 case presentationClock=375
 case presentationSample=376
 case queuePressureThreshold=401
 // 157: candidate otherwise ready but latest native sample exceeds freshness limit.
 case healthCertificateFreshness=402
 case healthProbeResume=403
 // 158: optional VLC source read-ahead, original demand and exact fallback remain distinct.
 case sourceReadAhead=410
 case resyncRetry=430
 case resyncRetryNative=431
 case resyncRetryQueue=432
 case resyncRetryScope=433
 case resyncRetryOutcome=434
 case audioCommandQueue=435
 case audioQueueBounds=436
 case audioRateMarker=437
 case audioRateRender=438
 case audioBoundaryReport=439
 case audioBoundaryState=440
 case audioLatency=441
 case audioBoundaryScope=442
 case audioProducerQueue=443
 case audioProducerLowWater=444
 case audioProducerFormat=445
 case audioProducerPosition=446
 case audioProducerWindow=447
 // 164: fresh identity substeps; numeric boundaries only, no source identity payload.
 case sourceIdentity=451
 case sourceIdentityBaseline=452
 case sourceIdentitySlot=453
 case sourceIdentityActive=454
 case sourceIdentityMetadata=455
 case sourceIdentityRecovery=456
 case sourceIdentityAccept=457
 case queueEvidenceContext=460
 case queueEvidenceScope=461
 case queueEvidenceResult=462
 case queueEvidenceClock=463
 // 165: exact native API/mutex endpoints, emitted after the measured interval.
 case vtAPIBoundary=480
 case vtCallerCPU=481
 case vtCallbackMutex=482
 case vtCallbackTail=483
 // 168: bounded actual sample timing and anonymous format/session context.
 case vtSampleContext=484
 case vtInputTiming=485
 case vtSampleDuration=486
 case vtSamplePTS=487
 case vtSampleDTS=488
 case vtSampleShape=489
 case vtSampleSummary=490
 case vtFormatIdentity=491
 case vtSampleEpochs=492
}
public enum PlaybackFlowTrace {
 public static func scalar(_ value:Double)->Int64 {guard value.isFinite else{return Int64.min};return Int64(max(Double(Int64.min+4096),min(Double(Int64.max-4096),value)))}
 @TaskLocal public static var parent:PlaybackFlowToken = .none
 public static func measure<T>(_ stage:PlaybackFlowStage,parent:PlaybackFlowToken?=nil,_ operation:() throws ->T) rethrows ->T {
  let token=begin(stage,parent:parent);defer{end(token,stage)}
  return try $parent.withValue(token){try operation()}
 }
 public static func start(session:UInt64)->Bool {
  #if VISTA_VLC_CANDIDATE && (DEBUG || VISTA_DIAGNOSTICS)
  guard VFStart(session) != 0 else{return false}
  Task.detached(priority:.utility){await PlaybackFlowWriter.shared.begin(session:session)}
  return true
  #else
  return false
  #endif
 }
 public static var session:UInt64 {
  #if VISTA_VLC_CANDIDATE && (DEBUG || VISTA_DIAGNOSTICS)
  return VFSession()
  #else
  return 0
  #endif
 }
 public static var nativeParent:PlaybackFlowToken {
  #if VISTA_VLC_CANDIDATE && (DEBUG || VISTA_DIAGNOSTICS)
  return .init(VFParent())
  #else
  return .none
  #endif
 }
 public static func begin(_ stage:PlaybackFlowStage,parent:PlaybackFlowToken?=nil,a:Int64=0,b:Int64=0,c:Int64=0)->PlaybackFlowToken {
  #if VISTA_VLC_CANDIDATE && (DEBUG || VISTA_DIAGNOSTICS)
  return .init(VFNew(stage.rawValue,1,parent?.id ?? self.parent.id,a,b,c))
  #else
  return .none
  #endif
 }
 @discardableResult public static func mark(_ stage:PlaybackFlowStage,parent:PlaybackFlowToken?=nil,a:Int64=0,b:Int64=0,c:Int64=0)->PlaybackFlowToken {
  #if VISTA_VLC_CANDIDATE && (DEBUG || VISTA_DIAGNOSTICS)
  return .init(VFNew(stage.rawValue,3,parent?.id ?? self.parent.id,a,b,c))
  #else
  return .none
  #endif
 }
 public static func point(_ token:PlaybackFlowToken,_ stage:PlaybackFlowStage,a:Int64=0,b:Int64=0,c:Int64=0) {
  #if VISTA_VLC_CANDIDATE && (DEBUG || VISTA_DIAGNOSTICS)
  VFEmit(token.id,stage.rawValue,3,0,a,b,c)
  #endif
 }
 public static func end(_ token:PlaybackFlowToken,_ stage:PlaybackFlowStage,a:Int64=0,b:Int64=0,c:Int64=0) {
  #if VISTA_VLC_CANDIDATE && (DEBUG || VISTA_DIAGNOSTICS)
  VFEmit(token.id,stage.rawValue,2,0,a,b,c)
  #endif
 }
 public static func trigger(_ reason:UInt32) {
  #if VISTA_VLC_CANDIDATE && (DEBUG || VISTA_DIAGNOSTICS)
  _=VFTrigger(reason)
  #endif
 }
 public static func anchor() {
  #if VISTA_VLC_CANDIDATE && (DEBUG || VISTA_DIAGNOSTICS)
  let before=VFClock(),uptime=ProcessInfo.processInfo.systemUptime
  mark(.anchor,a:Int64(uptime*1e6),b:before)
  #endif
 }
 /// Called after player/source/renderer drain. Finalizes the already streaming spool.
 public static func finish(session:UInt64) async ->[String:UInt64] {
  #if VISTA_VLC_CANDIDATE && (DEBUG || VISTA_DIAGNOSTICS)
  return await PlaybackFlowWriter.shared.finish(session:session)
  #else
  return ["status":2]
  #endif
 }
 #if VISTA_FLOW_TEST && VISTA_VLC_CANDIDATE && (DEBUG || VISTA_DIAGNOSTICS)
 public static func testDestination(_ url:URL,recordLimit:Int=4_194_304,secondsLimit:Double=600,diskLimit:UInt64=805_306_368,sessionLimit:Int=8,chunkLimit:Int=2048) async {await PlaybackFlowWriter.shared.destination(url,recordLimit:recordLimit,secondsLimit:secondsLimit,diskLimit:diskLimit,sessionLimit:sessionLimit,chunkLimit:chunkLimit)}
 public static func testFlush(session:UInt64) async {await PlaybackFlowWriter.shared.begin(session:session);await PlaybackFlowWriter.shared.drain(session:session)}
 #endif
}
#if VISTA_VLC_CANDIDATE && (DEBUG || VISTA_DIAGNOSTICS)
/// Utility-only, bounded spool. Playback/renderer threads only write scalar RAM
/// records. Continuous chunks retain later stalls and their recovery, independent
/// of triggers. File failures/limits stop diagnostics, never playback.
private actor PlaybackFlowWriter {
 static let shared=PlaybackFlowWriter()
 // Policy identity stays 166; this is the actual producing App build.
 private let producerBuild:String = {
  let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0"
  return build.count<=12 && !build.isEmpty && build.allSatisfy{$0.isASCII && ($0.isNumber || $0==".")} ? build:"0"
 }()
 private var requestedRecordLimit=4_194_304 // Maximum 256 MiB events/session.
 private var recordLimit=0 // Admission fixes this session's effective capacity.
 private var minimumRecordLimit:Int {min(requestedRecordLimit,2_097_152)} // 128 MiB production floor.
 private var admissionUsedBytes:UInt64=0
 private var admissionAvailableBytes:UInt64=0
 private var secondsLimit:Double=600
 private var sessionLimit=8
 private var totalDiskLimit:UInt64=805_306_368
 private var chunkLimit=2048
 private let manifestLimit=1_048_576
 private let statusLimit=4096
 private var diskBytes:UInt64=0
 private var diskKnown=false
 private var priorSessions=0
 private var statusWritable=false
 private var manifestCurrent=false
 private enum StorageFailure:Error {case quota,insufficientSessionCapacity,sessionCount,inventory,chunkCount,manifestSize,existing,sessionExists}
 // Two full manifests/status files cover atomic replacement; one maximum chunk
 // remains reserved in addition to the complete event budget. Never borrow this
 // metadata reserve to admit more records. Logical bytes, not physical free space.
 private var metadataReserve:UInt64 {UInt64(manifestLimit)*2+524_288+UInt64(statusLimit)*2}
 private var reservation:UInt64 {UInt64(recordLimit)*64+metadataReserve}
 private var current:UInt64=0
 private var task:Task<Void,Never>?
 private var directory:URL?
 private var chunks:[[String:Any]]=[]
 private var records:UInt64=0
 private var started:Double=0
 private var stopReason="recording"
 private var lastHeader=VFHeader()
 private var result:[String:UInt64]=[:]
 private var completed:UInt64=0
 private var diagnosticStopped=false
 private var writerMaximumMS:Double=0
 private var writerTotalMS:Double=0
 private var writerPasses:UInt64=0
 private var destinationOverride:URL?
 #if VISTA_FLOW_TEST
 func destination(_ root:URL,recordLimit:Int,secondsLimit:Double,diskLimit:UInt64,sessionLimit:Int,chunkLimit:Int){
  precondition(current==0 && recordLimit>0 && recordLimit<=4_194_304 && secondsLimit>=0 && secondsLimit.isFinite && sessionLimit>0 && chunkLimit>0)
  destinationOverride=root;self.requestedRecordLimit=recordLimit;self.secondsLimit=secondsLimit;totalDiskLimit=diskLimit;self.sessionLimit=sessionLimit;self.chunkLimit=min(2048,chunkLimit)
 }
 #endif
 private func rootURL()->URL {
  destinationOverride ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VistaDiagnostics/Flow166",isDirectory:true)
 }
 // Fixed policy root: future builds keep Flow166. No legacy directory is read,
 // migrated or pruned; every session (including incomplete ones) is preserved.
 func begin(session:UInt64) {
  guard current==0,completed != session,VFSession()==session else{return}
  current=session;records=0;chunks=[];result=[:];lastHeader=VFHeader();stopReason="recording";diagnosticStopped=false
  directory=nil;diskKnown=false;statusWritable=false;manifestCurrent=false;diskBytes=0;priorSessions=0
  recordLimit=0;admissionUsedBytes=0;admissionAvailableBytes=0
  writerMaximumMS=0;writerTotalMS=0;writerPasses=0;started=ProcessInfo.processInfo.systemUptime
  do {
   let root=rootURL();let fm=FileManager.default
   // Reject symlink roots, including dangling links, rather than following them.
   if let type=try? fm.attributesOfItem(atPath:root.path)[.type] as? FileAttributeType,type == .typeSymbolicLink {throw StorageFailure.inventory}
   try fm.createDirectory(at:root,withIntermediateDirectories:true)
   try inventory()
   admissionUsedBytes=diskBytes
   admissionAvailableBytes=diskBytes<=totalDiskLimit ? totalDiskLimit-diskBytes:0
   let status=root.appendingPathComponent("status.json")
   if fm.fileExists(atPath:status.path) {
    let attributes=try fm.attributesOfItem(atPath:status.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
          (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max <= UInt64(statusLimit),
          let saved=try JSONSerialization.jsonObject(with:Data(contentsOf:status)) as? [String:Any],
          saved["policy"] as? Int == 166 else{throw StorageFailure.inventory}
   }
   statusWritable=true
   let dir=root.appendingPathComponent(String(session),isDirectory:true)
   guard !fm.fileExists(atPath:dir.path) else{throw StorageFailure.sessionExists}
   guard priorSessions<sessionLimit else{throw StorageFailure.sessionCount}
   guard diskBytes<=totalDiskLimit,admissionAvailableBytes>=metadataReserve else{throw StorageFailure.quota}
   let capacity=(admissionAvailableBytes-metadataReserve)/64
   let candidateLimit=Int(min(UInt64(requestedRecordLimit),capacity))
   guard candidateLimit>=minimumRecordLimit else{throw StorageFailure.insufficientSessionCapacity}
   recordLimit=candidateLimit
   guard reservation<=admissionAvailableBytes else{throw StorageFailure.quota}
   try fm.createDirectory(at:dir,withIntermediateDirectories:false);directory=dir
   drain(session:session)
   guard !diagnosticStopped else{return}
   task=Task.detached(priority:.utility) {
    while !Task.isCancelled {
     do {try await Task.sleep(for:.milliseconds(500))}catch{break}
     guard !Task.isCancelled else{break}
     await Self.shared.drain(session:session)
    }
   }
  } catch {stop(error);directory=nil;writeStatus()}
 }
 // One admission scan; thereafter this single actor accounts every owned write.
 // Re-scan after an uncertain IO failure. Unknown files count, symlinks/special
 // files fail closed. No external mutation of this private policy root is assumed.
 private func inventory() throws {
  let fm=FileManager.default;var total:UInt64=0,count=0,visited=0
  func scan(_ dir:URL,depth:Int) throws {
   guard depth<32 else{throw StorageFailure.inventory}
   for url in try fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil) {
    visited+=1;guard visited<=100_000 else{throw StorageFailure.inventory}
    let a=try fm.attributesOfItem(atPath:url.path)
    switch a[.type] as? FileAttributeType {
    case .typeDirectory:
     if depth==0 {count+=1};try scan(url,depth:depth+1)
    case .typeRegular:
     guard let bytes=(a[.size] as? NSNumber)?.uint64Value,total<=UInt64.max-bytes else{throw StorageFailure.inventory};total+=bytes
    default:throw StorageFailure.inventory
    }
   }
  }
  diskKnown=false;try scan(rootURL(),depth:0);diskBytes=total;priorSessions=count;diskKnown=true
 }
 private func stop(_ error:Error) {
  if let policy=error as? StorageFailure {
   switch policy {
   case .quota:stopReason="rootDiskBudgetLimit"
   case .insufficientSessionCapacity:stopReason="insufficientSessionCapacity"
   case .sessionCount:stopReason="rootSessionLimit"
   case .inventory:stopReason="inventoryUnavailable"
   case .chunkCount:stopReason="chunkLimit"
   case .manifestSize:stopReason="manifestLimit"
   case .existing:stopReason="pathAlreadyExists"
   case .sessionExists:stopReason="sessionAlreadyExists"
   }
   result["status"]=6
  } else {stopReason="ioFailure";result["status"]=4;diskKnown=false}
  _=VFStop(current);diagnosticStopped=true;task?.cancel()
  // Admission can fail after VFStart already published records. Snapshot without
  // consuming RAM, so a refusal status cannot imply an empty native tail.
  var header=lastHeader;_=VFDrain(&header,nil,0);lastHeader=header
 }
 private func persist(_ data:Data,to url:URL,replace:Bool) throws {
  if !diskKnown {try inventory()}
  let fm=FileManager.default
  var old:UInt64=0
  if let attributes=try? fm.attributesOfItem(atPath:url.path) {
   guard replace,attributes[.type] as? FileAttributeType == .typeRegular else{throw StorageFailure.existing}
   old=(attributes[.size] as? NSNumber)?.uint64Value ?? 0
  }
  // Include the complete new atomic temporary file before the old file is replaced.
  guard diskBytes<=totalDiskLimit,UInt64(data.count)<=totalDiskLimit-diskBytes else{throw StorageFailure.quota}
  do {try data.write(to:url,options:.atomic)}catch{diskKnown=false;throw error}
  guard diskBytes>=old else{diskKnown=false;throw StorageFailure.inventory}
  diskBytes=diskBytes-old+UInt64(data.count)
 }
 private func writeStatus() {
  guard statusWritable else{return}
  do {
   if !diskKnown {try inventory()}
   let status:[String:Any]=["policy":166,"producerBuild":producerBuild,"session":current,"reason":stopReason,
    "diagnosticStopped":diagnosticStopped,"usedBytesBeforeStatusWrite":diskBytes,"diskLimit":totalDiskLimit,
    "sessionLimit":sessionLimit,"existingDirectoriesAtLastScan":priorSessions,
    "sessionCreated":directory != nil,"sessionReservationBytes":reservation,"records":records,
    "admissionUsedBytes":admissionUsedBytes,"admissionAvailableBytes":admissionAvailableBytes,
    "requestedRecordLimit":requestedRecordLimit,"effectiveRecordLimit":recordLimit,
    "minimumRecordLimit":minimumRecordLimit,"metadataAtomicReserveBytes":metadataReserve,
    "manifestCurrent":manifestCurrent,"pendingRAMRecords":lastHeader.written>=lastHeader.drained ? lastHeader.written-lastHeader.drained:0,
    "drainedNotPersistedRecords":lastHeader.drained>=records ? lastHeader.drained-records:0,
    "noSessionDeletion":true]
   let data=try JSONSerialization.data(withJSONObject:status,options:[.sortedKeys])
   guard data.count<=statusLimit else{throw StorageFailure.manifestSize}
   try persist(data,to:rootURL().appendingPathComponent("status.json"),replace:true)
  } catch {result["statusWriteFailed"]=1}
 }
 private func manifest(completed:Bool) throws {
  guard let dir=directory else{return}
  manifestCurrent=false
  let h=lastHeader
  var m:[String:Any]=[
   "schema":2,"recordBytes":64,"clockDomain":"vlc_monotonic_us","endianness":"little",
   "session":current,"generation":h.generation,"openedUS":h.opened_us,"exportedUS":h.exported_us,
   "cutoffUS":h.cutoff_us,"cutoffReason":stopReason,"completed":completed,"records":records,
   "capacity":VF_CAPACITY,"spoolRecordLimit":recordLimit,"spoolSecondsLimit":secondsLimit,
   "retentionPolicy":166,"producerBuild":producerBuild,"spoolChunkLimit":chunkLimit,"manifestByteLimit":manifestLimit,
   "rootDiskLimit":totalDiskLimit,"rootSessionLimit":sessionLimit,"sessionReservationBytes":reservation,
   "usedBytesBeforeManifestWrite":diskBytes,"noSessionDeletion":true,
   "admissionUsedBytes":admissionUsedBytes,"admissionAvailableBytes":admissionAvailableBytes,
   "requestedRecordLimit":requestedRecordLimit,"minimumRecordLimit":minimumRecordLimit,
   "metadataAtomicReserveBytes":metadataReserve,"admissionMode":"remainingRootCapacity",
   "attempts":h.attempts,"contentionLost":h.contention_lost,"capacityLost":h.capacity_lost,
   "staleLost":h.stale_lost,"mapLost":h.map_lost,"mapBusy":h.map_busy,"mapMiss":h.map_miss,
   "mapEvictions":h.map_evictions,"mapInvalidations":h.map_invalidations,"written":h.written,"drained":h.drained,
   "pendingRAMRecords":h.written>=h.drained ? h.written-h.drained:0,
   "drainedNotPersistedRecords":h.drained>=records ? h.drained-records:0,
   "totalUnpersistedRecords":h.written>=records ? h.written-records:0,
   "writerMetricScope":"complete prior drain passes including manifest IO; active manifest lags one pass; final manifest itself excluded",
   "triggerCount":h.trigger_count,"firstTriggerUS":h.trigger_us,"lastTriggerUS":h.last_trigger_us,
   "firstTriggerID":h.trigger_id,"firstTriggerReason":h.trigger_reason,"chunks":chunks,
   "writerMaximumMS":writerMaximumMS,"writerTotalMS":writerTotalMS,"writerPasses":writerPasses,
   "wireFields":"u64 sequence,id,parent; i64 tick_us,a,b; u32 stage,phase; i64 c",
   "ordering":"merge chunks by sequence; lanes can drain out of order; IDs survive event loss",
   "limits":"Up to 256 MiB events or 10 minutes/session; admission reduces event capacity to remaining fixed Flow166 root budget after complete metadata/atomic reserve, production minimum 128 MiB; 768 MiB logical-file budget, max 8 directories; insufficient capacity refuses recording, never deletes sessions; no duration guarantee; system scanout not observed"
  ]
  m["stageNames"]=Dictionary(uniqueKeysWithValues:PlaybackFlowStage.allCases.map{(String($0.rawValue),String(describing:$0))})
  let data=try JSONSerialization.data(withJSONObject:m,options:[.prettyPrinted,.sortedKeys])
  guard data.count<=manifestLimit else{throw StorageFailure.manifestSize}
  try persist(data,to:dir.appendingPathComponent("manifest.json"),replace:true);manifestCurrent=true
 }
 func drain(session:UInt64) {
  guard current==session,!diagnosticStopped,let dir=directory else{return}
  let begin=ProcessInfo.processInfo.systemUptime
  defer {writerPasses+=1;let elapsed=(ProcessInfo.processInfo.systemUptime-begin)*1000;writerTotalMS+=elapsed;writerMaximumMS=max(writerMaximumMS,elapsed)}
  let buffer=UnsafeMutablePointer<VFRecord>.allocate(capacity:8192);defer{buffer.deallocate()}
  do {
   if begin-started>=secondsLimit {stopReason="durationLimit";_=VFStop(session);diagnosticStopped=true}
   // No awaited work or file operations on the producer threads. The consumer
   // copies only published records; writers reuse a slot after its head moves.
   for _ in 0..<8 {
    let available=recordLimit-Int(records)
    if available<=0 {stopReason="diskBudgetLimit";_=VFStop(session);diagnosticStopped=true;break}
    guard chunks.count<chunkLimit else{throw StorageFailure.chunkCount}
    var h=VFHeader();let count=VFDrain(&h,buffer,min(8192,available));lastHeader=h
    guard count>0 else{break}
    let name=String(format:"events-%06d.bin",chunks.count)
    let data=Data(bytes:buffer,count:count*MemoryLayout<VFRecord>.stride)
    manifestCurrent=false
    try persist(data,to:dir.appendingPathComponent(name),replace:false)
    let view=UnsafeBufferPointer(start:buffer,count:count)
    chunks.append(["file":name,"records":count,"bytes":data.count,"minSequence":view.map(\.sequence).min() ?? 0,"maxSequence":view.map(\.sequence).max() ?? 0,"minTickUS":view.map(\.tick_us).min() ?? 0,"maxTickUS":view.map(\.tick_us).max() ?? 0])
    records+=UInt64(count)
   }
   try manifest(completed:false)
  }catch{stop(error);try? manifest(completed:false)}
  if diagnosticStopped {
   var finalHeader=lastHeader;_=VFDrain(&finalHeader,nil,0);lastHeader=finalHeader
   try? manifest(completed:false);writeStatus()
  } else if writerPasses==0 {writeStatus()}
 }
 func finish(session:UInt64) async ->[String:UInt64] {
  if completed==session{return result}
  if current==0 {begin(session:session)}
  guard current==session else{return ["status":2]}
  task?.cancel();task=nil
  // Player, source and presentation drain precede this call. A last diagnostic
  // writer can still be returning; bounded cooperative retries avoid blocking.
  var stopped=false
  for _ in 0..<100 {if VFStop(session) != 0 {stopped=true;break};await Task.yield()}
  if !stopped {result["status"]=5;stopReason="producerDrainBusy"}
  if !diagnosticStopped {
   stopReason=stopped ? "finished":"producerDrainBusy"
   drain(session:session)
  }
  // Limits and IO failures can stop after the last data drain. Refresh without
  // consuming unsaved RAM so cutoff and all final loss/tail counters are honest.
  var finalHeader=lastHeader;_=VFDrain(&finalHeader,nil,0);lastHeader=finalHeader
  do {try manifest(completed:stopped)}catch{stop(error);manifestCurrent=false}
  writeStatus()
  result.merge(["status":stopReason=="finished" ? 0:stopReason=="ioFailure" ? 4:6,"session":session,"records":records,"chunks":UInt64(chunks.count),"contentionLost":lastHeader.contention_lost,"capacityLost":lastHeader.capacity_lost,"mapLost":lastHeader.map_lost,"staleLost":lastHeader.stale_lost]){old,_ in old}
  completed=session;current=0;directory=nil;chunks=[];return result
 }
}
#endif
