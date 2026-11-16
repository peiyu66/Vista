#if VISTA_LOCAL_MKV_CANDIDATE
import Foundation

// Fixed numeric schema. Never stores a file name, path, URL, bookmark, hash, or arbitrary error text.
enum MKVAppStage: UInt32 {
    case admission=1, sourceOpen, workspace, engineCreate, enginePlan, initImport, segmentImport, manifest, server, player, playback, cleanup
    var label:String {
        switch self {
        case .admission:return "來源檢查";case .sourceOpen:return "開啟影片來源";case .workspace:return "建立暫存"
        case .engineCreate:return "建立 MKV 讀取工作";case .enginePlan:return "檢查 MKV 結構"
        case .initImport:return "匯入視訊初始化資料";case .segmentImport:return "匯入播放片段"
        case .manifest:return "發佈播放清單";case .server:return "建立本機播放服務";case .player:return "建立系統播放器"
        case .playback:return "系統播放";case .cleanup:return "結束播放資源"
        }
    }
}
struct MKVFatalAlertState: Equatable {
    private(set) var message:String?
    mutating func finish(message:String?, cancelled:Bool) { if !cancelled { self.message=message } }
    mutating func reset() {message=nil}
}
enum MKVImportCost: CaseIterable {case validation,dataRead,storeStageWriteFsyncHash,storeCommit}
// Numeric-only, generation-local observations. These clocks describe API and
// byte delivery stages, never physical audio output. No URL/path/error text.
enum MKVStartupMark:Int {
    case requested=1,playerCreated,ready,seekBegin,seekEnd,play,firstVideo,aborted
    var field:String {
        switch self {
        case .requested:return "mkvStartRequestedMS";case .playerCreated:return "mkvStartPlayerCreatedMS"
        case .ready:return "mkvStartReadyMS";case .seekBegin:return "mkvStartSeekBeginMS"
        case .seekEnd:return "mkvStartSeekEndMS";case .play:return "mkvStartPlayMS"
        case .firstVideo:return "mkvStartFirstVideoMS";case .aborted:return "mkvStartAbortedMS"
        }
    }
}
struct MKVObservationBudget {
    private(set) var count=0
    mutating func admit()->Bool {guard count<64 else{return false};count+=1;return true}
}
struct MKVHTTPObservation {
    let sequence:Int,accepted:Double
    var kind=0,segment=0,low = -1,high = -1,bytes=0
    var serving:Double?,firstPayload:Double?,completed:Double?
    var timedOut=false,outcome=0
    func values(relativeTo start:Double)->[String:Double] {
        var v:[String:Double] = ["mkvHTTPRequest":Double(sequence),"mkvHTTPKind":Double(kind),"mkvHTTPSegment":Double(segment),"mkvHTTPRangeLow":Double(low),"mkvHTTPRangeHigh":Double(high),"mkvHTTPBytes":Double(bytes),"mkvHTTPAcceptedMS":max(0,accepted-start)*1000,"mkvHTTPOutcome":Double(outcome)]
        if let serving {v["mkvHTTPQueueMS"]=max(0,serving-accepted)*1000}
        if let firstPayload {v["mkvHTTPFirstPayloadMS"]=max(0,firstPayload-start)*1000}
        if let completed {v["mkvHTTPCompletedMS"]=max(0,completed-start)*1000}
        return v
    }
}
struct MKVDiagnostics {
    private(set) var stage:MKVAppStage = .admission
    mutating func enter(_ value:MKVAppStage) {if reason==0 {stage=value}}
    private(set) var reason:UInt32=0,systemDomain:UInt32=0,systemCode:Int32=0
    private(set) var engine:SAPDiagnostics?
    private(set) var frames:UInt32=0,polls:UInt32=0
    private var appWindowBytes:Int?,appIncomingBytes:Int?
    private var generation:UInt64?
    private var sourcePerformance:LocalSourcePerformance?
    private var importNS:[MKVImportCost:UInt64]=[:]
    private var startupTargetSeconds:UInt64?,startupRequiredSegments:UInt64?
    private var startupImportedSegments:UInt64=0,startupImportedMediaNS:UInt64=0
    private(set) var observationOrigin=0.0
    private var startValues:[String:Double]=[:]
    private var httpCompleted:UInt64=0,httpTimeouts:UInt64=0,observationSuppressed:UInt64=0
    mutating func startupMark(_ mark:MKVStartupMark,now:Double=ProcessInfo.processInfo.systemUptime,requested:Double?=nil,origin:Double?=nil,current:Double?=nil,outcome:Double?=nil)->[String:Double] {
        guard reason==0 else{return [:]}
        let key=mark.field
        guard startValues[key]==nil else{return [:]}
        startValues[key]=max(0,now-observationOrigin)*1000
        if let requested,requested.isFinite {startValues["mkvStartRequestedSeconds"]=requested}
        if let origin,origin.isFinite {startValues["mkvStartOriginSeconds"]=origin}
        if let requested=startValues["mkvStartRequestedSeconds"],let origin=startValues["mkvStartOriginSeconds"] {startValues["mkvStartLocalSeconds"]=max(0,requested-origin)}
        if let current,current.isFinite {
            if mark == .ready {startValues["mkvStartReadyItemSeconds"]=current}
            if mark == .seekEnd {startValues["mkvStartSeekItemSeconds"]=current}
            if mark == .firstVideo {startValues["mkvStartFirstVideoSeconds"]=current}
        }
        if let outcome,outcome.isFinite {startValues["mkvStartSeekOutcome"]=outcome}
        var event=startValues;event["mkvObservationKind"]=Double(mark.rawValue);return event
    }
    mutating func observedHTTP(_ value:MKVHTTPObservation) {
        guard reason==0 else{return};httpCompleted=Self.sum(httpCompleted,1)
        if value.timedOut {httpTimeouts=Self.sum(httpTimeouts,1)}
    }
    mutating func suppressObservation() {if reason==0 {observationSuppressed=Self.sum(observationSuppressed,1)}}
    private static func sum(_ value:UInt64,_ addition:UInt64)->UInt64 {
        let result=value.addingReportingOverflow(addition)
        return result.overflow ? UInt64.max:result.partialValue
    }
    // Exact unsigned scalar range for JSON/Double. Never round an overflow into
    // a plausible duration or count. -2 is the explicit present/invalid sentinel.
    private static func unsigned(_ value:UInt64)->Double {value<=9_007_199_254_740_991 ? Double(value):-2}
    mutating func beginGeneration(_ value:UInt64) {
        guard reason==0 else{return}
        generation=value;engine=nil;sourcePerformance=nil;appWindowBytes=nil;appIncomingBytes=nil
        importNS=Dictionary(uniqueKeysWithValues:MKVImportCost.allCases.map{($0,0)})
        startupTargetSeconds=nil;startupRequiredSegments=nil;startupImportedSegments=0;startupImportedMediaNS=0
        observationOrigin=ProcessInfo.processInfo.systemUptime;startValues=[:];httpCompleted=0;httpTimeouts=0;observationSuppressed=0
    }
    mutating func observeSourcePerformance(_ value:LocalSourcePerformance) {if reason==0 {sourcePerformance=value}}
    mutating func startupContract(targetSeconds:UInt64,requiredSegments:UInt64) {
        guard reason==0 else{return}
        startupTargetSeconds=targetSeconds;startupRequiredSegments=requiredSegments
    }
    // Counts media already committed to the store during startup, excluding init.
    // Exact engine nanoseconds are copied; no Double round trip or playback gate.
    mutating func startupImported(durationNS:Int64) {
        guard reason==0 else{return}
        startupImportedSegments=Self.sum(startupImportedSegments,1)
        startupImportedMediaNS=durationNS>=0 ? Self.sum(startupImportedMediaNS,UInt64(durationNS)):UInt64.max
    }
    // Completed/error scopes accumulated for this generation. Validation includes
    // source revision observations and segment metadata/size/capacity preflight.
    // Read/stage/commit are separate elapsed API scopes, including scheduling waits;
    // stage bundles write+fsync+close+SHA256. Source coordination/engine scopes nest
    // inside these totals and must not be added together as disjoint work.
    mutating func importCost(_ cost:MKVImportCost,since start:UInt64,now:UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard reason==0 else{return}
        let elapsed=now>=start ? now-start:UInt64.max
        importNS[cost]=Self.sum(importNS[cost,default:0],elapsed)
    }
    mutating func capacity(windowBytes:Int,incomingBytes:Int) {
        if reason==0 {appWindowBytes=windowBytes;appIncomingBytes=incomingBytes}
    }
    // Immutable entries in this candidate version. Numeric IDs are 1000 + table index.
    static let knownMessages:[String] = [
        "跳轉時間超出範圍",
        "來源工作無法啟動",
        "片段資料夾無法讀取",
        "尚未完整產生的片段",
        "片段超過有界容量",
        "片段讀取不完整",
        "no port",
        "listener cancelled",
        "listener deadline",
        "server stopped",
        "request syntax",
        "path whitelist",
        "range count",
        "range syntax",
        "range start",
        "range end",
        "response lifetime byte cap",
        "stopped response",
        "先前來源尚未安全結束，請重新開啟候選 App。",
        "影片在完整片尾之前結束",
        "來源準備逾時",
        "GOP 結構超過此候選的有界播放窗口",
        "不支援的 MKV 視訊或時間資料",
        "初始窗口無法在有限儲存內成立",
        "MKV 起始跳轉失敗",
        "HTTP 讀取尚未結束",
        "來源讀取尚未結束",
        "片段仍有讀取租約",
        "來源暫存仍有未收尾檔案",
        "此 MKV 路徑需要 visionOS 26.2 或更新版本。",
        "此候選只接本機資料夾的 VP9 P0＋AAC-LC；SMB MKV 尚未支援。",
        "MKV 播放窗口超過 128 MiB 或有界片段數",
        "MKV 系統播放器準備逾時",
        "MKV 起始跳轉逾時", "此 MKV 來源尚未支援。"]
    static let adapterReasons:[String] = ["local file URL required", "open", "positive regular file with Int64 offsets required", "closed or revoked source revision", "fd metadata changed", "window admission closed or wrong full stamp", "previous window not drained", "read range or file", "short pread inside known source", "known end is not physical EOF", "drain wrong full stamp", "source operation still active", "close before window drain", "close", "wrong file", "producer create", "producer destroyed", "producer diagnostics", "producer snapshot", "import acknowledgement order", "destroyed", "segment unavailable", "callback invocation not drained", "destroy before actual drain", "complete positive SMB identity required", "SMB generation retired", "SMB source revision changed", "SMB previous generation not drained", "SMB read range or file", "short SMB source read", "SMB drain wrong generation", "SMB source invocation still active", "SMB source drain changed", "SMB close before generation drain"]
    static let storeReasons:[String] = ["stamp/cleaned", "retiring", "directory name", "parent open", "mkdir owned", "owned open", "name/overwrite/pending/file cap", "size cap", "pending open", "write", "fsync", "fstat", "closed payload size/type", "immutable mode", "close payload", "no stage", "hash/overwrite", "stage identity", "publish no-replace", "remove stage name", "playlist references", "unpublished", "rolling manifest contract", "unpublished rolling references", "manifest version cap", "retired stat", "retention-safe unlink", "lease cap", "lease open", "lease stat", "lease absent", "owned inode changed", "response bounds", "short response", "reply absent", "reply still borrowed", "lease close", "discard unpublished stage", "incomplete source/owner drain", "cleanup stat", "owned unlink", "owned rmdir"]
    mutating func poll() {if polls<UInt32.max {polls += 1}}
    mutating func frame() {if frames<UInt32.max {frames += 1}}
    mutating func observe(_ snapshot:SAPDiagnostics) {if reason==0 {engine=snapshot}}
    mutating func fail(_ error:any Error) {
        guard reason==0,!(error is CancellationError),!((error as NSError).domain==NSURLErrorDomain && (error as NSError).code==NSURLErrorCancelled) else{return}
        if let e=error as? MKVPlaybackError {
            switch e {
            case .engine:reason=2
            case .failure(let text):reason=Self.knownMessages.firstIndex(of:text).map{1000+UInt32($0)} ?? 1
            }
        } else if let e=error as? LocalFolderFailure {
            switch e {case .permission:reason=10;case .staleBookmark:reason=11;case .invalidPath:reason=12;case .unavailable:reason=13;case .tooManyItems:reason=14}
        } else if let e=error as? AdapterFailure {
            switch e {case .rejected(let text):reason=Self.adapterReasons.firstIndex(of:text).map{2000+UInt32($0)} ?? 20;case .system(let text,let code):reason=Self.adapterReasons.firstIndex(of:text).map{2000+UInt32($0)} ?? 21;systemDomain=1;systemCode=code}
        } else if let e=error as? MKVStoreError {
            switch e {case .rejected(let text):reason=Self.storeReasons.firstIndex(of:text).map{3000+UInt32($0)} ?? 30;case .system(let text,let code):reason=Self.storeReasons.firstIndex(of:text).map{3000+UInt32($0)} ?? 31;systemDomain=1;systemCode=code}
        } else if let e=error as? NativePlaybackSession.Failure {
            switch e {case .source:reason=40;case .stalled:reason=41;case .player:reason=42;case .unsupported:reason=43}
        } else {
            reason=1
            let e=error as NSError
            switch e.domain {case NSPOSIXErrorDomain:systemDomain=1;case NSCocoaErrorDomain:systemDomain=2;case NSURLErrorDomain:systemDomain=3;case "AVFoundationErrorDomain":systemDomain=4;default:break}
            if systemDomain != 0 {systemCode=Int32(clamping:e.code)}
        }
    }
    static func engineReason(_ code:UInt32)->String {
        switch code {
        case 211:return "此測試版的 MKV 目前只支援單一 VP9 視訊軌；這支影片的視訊編碼尚未支援。"
        case 212:return "此測試版的 MKV 目前只支援單一 AAC 音軌。"
        default:return SourceAdapterSession.diagnosticReason(code)
        }
    }
    var safeReason:String {
        if reason==2,let engine {return Self.engineReason(engine.reasonCode)}
        if reason>=1000,Int(reason-1000)<Self.knownMessages.count {return Self.knownMessages[Int(reason-1000)]}
        if reason>=2000,Int(reason-2000)<Self.adapterReasons.count {return "來源檢查："+Self.adapterReasons[Int(reason-2000)]}
        if reason>=3000,Int(reason-3000)<Self.storeReasons.count {return "片段儲存："+Self.storeReasons[Int(reason-3000)]}
        switch reason {
        case 10:return "無法取得所選資料夾的讀取權限。";case 11:return "資料夾授權已失效，請重新選取。"
        case 12:return "來源路徑未通過安全檢查。";case 13:return "本機來源暫時無法存取。";case 14:return "資料夾項目超過候選上限。"
        case 20:return "來源或讀取工作未通過生命週期檢查。";case 21:return "本機來源的系統讀取操作失敗。"
        case 30:return "片段儲存未通過安全或容量檢查。";case 31:return "片段儲存的系統操作失敗。"
        case 40:return "來源讀取失敗。";case 41:return "系統播放器超過 30 秒沒有交付新畫面。"
        case 42:return "系統播放器無法播放這個檔案。";case 43:return "這個操作不在候選支援範圍。"
        default:return "候選在此階段失敗，已保存匿名診斷代碼。"
        }
    }
    var fatalMessage:String? {
        guard reason != 0 else{return nil}
        let code=engine.map{"／引擎 \($0.stage):\($0.reasonCode)"} ?? ""
        return "\(stage.label)失敗：\(safeReason)\n診斷 \(stage.rawValue):\(reason)\(code)"
    }
    var values:[String:Double] {
        var v:[String:Double] = ["mkvSchema":7,"mkvAppStage":Double(stage.rawValue),"mkvAppReason":Double(reason),"mkvSystemDomain":Double(systemDomain),"mkvSystemCode":Double(systemCode),"mkvFrames":Double(frames),"mkvPolls":Double(polls)]
        if let appWindowBytes {v["mkvAppWindowBytes"]=Double(appWindowBytes)}
        if let appIncomingBytes {v["mkvAppIncomingBytes"]=Double(appIncomingBytes)}
        if let generation {
            v["mkvGeneration"]=Self.unsigned(generation)
            v["mkvStartupImportedSegments"]=Self.unsigned(startupImportedSegments)
            v["mkvStartupImportedMediaNS"]=Self.unsigned(startupImportedMediaNS)
            v.merge(startValues,uniquingKeysWith:{$1});v["mkvObservationOriginUptime"]=observationOrigin
            v["mkvHTTPCompletedCount"]=Self.unsigned(httpCompleted);v["mkvHTTPTimeoutCount"]=Self.unsigned(httpTimeouts);v["mkvObservationSuppressed"]=Self.unsigned(observationSuppressed)
            let costs:[(MKVImportCost,String)]=[(.validation,"mkvAppImportValidationNS"),(.dataRead,"mkvAppImportDataReadNS"),(.storeStageWriteFsyncHash,"mkvAppStoreStageWriteFsyncHashNS"),(.storeCommit,"mkvAppStoreCommitNS")]
            for (cost,key) in costs {v[key]=Self.unsigned(importNS[cost,default:0])}
        }
        if let startupTargetSeconds {v["mkvStartupTargetSeconds"]=Self.unsigned(startupTargetSeconds)}
        if let startupRequiredSegments {v["mkvStartupRequiredSegments"]=Self.unsigned(startupRequiredSegments)}
        if let p=sourcePerformance {
            let costs:[(String,UInt64)]=[
                ("mkvLocalCoordinationCalls",p.coordinationCalls),("mkvLocalCoordinationNS",p.coordinationNS),
                ("mkvLocalCoordinationWaitNS",p.coordinationWaitNS),("mkvLocalIdentityCalls",p.identityCalls),
                ("mkvLocalIdentityNS",p.identityNS),("mkvLocalPreadCalls",p.preadCalls),("mkvLocalPreadNS",p.preadNS)]
            for (key,value) in costs {v[key]=Self.unsigned(value)}
        }
        if let d=engine {
            v["mkvEngineStage"]=Double(d.stage);v["mkvEngineReason"]=Double(d.reasonCode);v["mkvEngineNativeCode"]=Double(d.nativeCode);v["mkvObservedMask"]=Double(d.observedMask);v["mkvPublished"]=Double(d.publishedSegments)
            let optional:[(UInt64,String,UInt32)] = [(1,"mkvTrackCount",d.trackCount),(2,"mkvVideoCodec",d.videoCodec),(4,"mkvAudioCodec",d.audioCodec),(8,"mkvWidth",d.width),(8,"mkvHeight",d.height),(16,"mkvVP9Profile",d.vp9Profile),(32,"mkvVP9Colour",d.vp9ColourSpace),(64,"mkvAudioRate",d.audioSampleRate),(128,"mkvAudioChannels",d.audioChannels),(256,"mkvCueCount",d.cueCount)]
            for (mask,key,value) in optional where d.observedMask & mask != 0 {v[key]=Double(value)}
            v["mkvEngineSchema"]=Double(d.schema)
            let additional:[(UInt64,String,UInt32)] = [
                (512,"mkvContainerColourPresent",d.containerColourPresent),
                (32768,"mkvChromaPresence",d.containerChromaPresence),
                (65536,"mkvHDRMask",d.containerHdrMask),
                (131072,"mkvVP9FullRange",d.vp9FullRange),
                (262144,"mkvVP9KeyWidth",d.vp9KeyWidth),(262144,"mkvVP9KeyHeight",d.vp9KeyHeight),
                (524288,"mkvAudioObjectType",d.audioObjectType)]
            for (mask,key,value) in additional where d.observedMask & mask != 0 {v[key]=Double(value)}
            // Preserve ordinary raw values exactly in the numeric JSON schema. Out-of-range
            // metadata is explicitly -2, never rounded into a plausible supported CICP value.
            func scalar(_ value:Int64)->Double {value>=0 && value<=Int64(UInt32.max) ? Double(value):-2}
            let colour:[(UInt64,String,Int64)] = [
                (1024,"mkvContainerMatrix",d.containerMatrix),(2048,"mkvContainerTransfer",d.containerTransfer),
                (4096,"mkvContainerPrimaries",d.containerPrimaries),(8192,"mkvContainerRange",d.containerRange),
                (16384,"mkvContainerBits",d.containerBitsPerChannel)]
            for (mask,key,value) in colour where d.observedMask & mask != 0 {v[key]=scalar(value)}
            let capacityFields:[(UInt64,String,UInt64)] = [
                (134217728,"mkvMuxPacketCount",d.muxPacketCount),(134217728,"mkvMuxPayloadBytes",d.muxPayloadBytes),
                (268435456,"mkvMuxPacketBytes",d.muxPacketBytes),(268435456,"mkvMuxPacketTrack",UInt64(d.muxPacketTrack)),
                (536870912,"mkvMuxFragmentBytes",d.muxFragmentBytes),(1073741824,"mkvMuxStagingBytes",d.muxStagingBytes)]
            for (mask,key,value) in capacityFields where d.observedMask & mask != 0 {v[key]=value<=9_007_199_254_740_991 ? Double(value):-2}
            if d.observedMask & 2147483648 != 0 {
                let costs:[(String,UInt64)]=[
                    ("mkvEngineSourceReadCalls",d.sourceReadCalls),("mkvEngineSourceReadBytes",d.sourceReadBytes),
                    ("mkvEngineSourceReadNS",d.sourceReadNS),("mkvEngineSourceValidateCalls",d.sourceValidateCalls),
                    ("mkvEngineSourceValidateNS",d.sourceValidateNS),("mkvEngineGPACWriteNS",d.gpacWriteNS),
                    ("mkvEngineGPACCloseNS",d.gpacCloseNS),("mkvEngineOutputInspectNS",d.outputInspectNS),("mkvEnginePlanNS",d.planNS)]
                for (key,value) in costs {v[key]=Self.unsigned(value)}
            }
            if d.observedMask & 4294967296 != 0 {
                v["mkvStartupTargetSeconds"]=Self.unsigned(UInt64(d.startupTargetSeconds))
                v["mkvStartupRequiredSegments"]=Self.unsigned(UInt64(d.startupRequiredSegments))
            }
            if d.observedMask & 8589934592 != 0 {
                v["mkvMetadataClusters"]=Double(d.metadataClusters)
                v["mkvMetadataEmptyClusters"]=Double(d.metadataEmptyClusters)
                v["mkvMetadataBlocks"]=Double(d.metadataBlocks)
            }
            if d.observedMask & 17179869184 != 0 {
                v["mkvAudioRetimedPacketCount"]=Self.unsigned(d.audioRetimedPacketCount)
                v["mkvAudioRetimingMaxAbsResidual"]=Self.unsigned(d.audioRetimingMaxAbsResidual)
                v["mkvAudioRetimingLimitExceeded"]=Double(d.audioRetimingLimitExceeded)
            }
            if d.observedMask & 1048576 != 0 {v["mkvPlanKind"]=Double(d.planKind)}
            // Nanoseconds/sample positions fit exactly in JSON Double within this bounded
            // engine. A present out-of-range value is -2^53, never silently rounded.
            func timing(_ value:Int64)->Double {
                let exactLimit:Int64=9_007_199_254_740_991
                return value >= -exactLimit && value <= exactLimit ? Double(value):-9_007_199_254_740_992
            }
            let times:[(UInt64,String,Int64)] = [
                (2097152,"mkvTimestampTickNS",d.containerTimestampTickNS),
                (2097152,"mkvCodecDelaySamples",d.audioCodecDelaySamples),
                (2097152,"mkvSeekPrerollSamples",d.audioSeekPrerollSamples),
                (4194304,"mkvVideoOriginNS",d.selectedVideoOriginNS),
                (8388608,"mkvAudioAnchorNS",d.sourceAudioAnchorNS),
                (16777216,"mkvAudioPacketPTSNS",d.audioPacketPTSNS),
                (16777216,"mkvAudioPacketIndex",d.audioPacketSourceIndex),
                (16777216,"mkvAudioResidual",d.audioPacketResidual),
                (16777216,"mkvAudioPreviousIndex",d.audioPreviousSourceIndex),
                (33554432,"mkvAudioOriginDeltaNS",d.audioOriginDeltaNS),
                (33554432,"mkvAudioCutSample",d.audioCutSample),
                (33554432,"mkvAudioOriginResidual",d.audioOriginResidual),
                (67108864,"mkvAudioEmptyEditNS",d.audioLeadingEmptyEditNS)]
            for (mask,key,value) in times where d.observedMask & mask != 0 {v[key]=timing(value)}
            if d.observedMask & 32768 != 0 {
                let chroma:[(UInt32,String,Int64)] = [
                    (1,"mkvChromaSubsamplingHorz",d.containerChromaSubsamplingHorz),
                    (2,"mkvChromaSubsamplingVert",d.containerChromaSubsamplingVert),
                    (4,"mkvCbSubsamplingHorz",d.containerCbSubsamplingHorz),
                    (8,"mkvCbSubsamplingVert",d.containerCbSubsamplingVert),
                    (16,"mkvChromaSitingHorz",d.containerChromaSitingHorz),
                    (32,"mkvChromaSitingVert",d.containerChromaSitingVert)]
                for (mask,key,value) in chroma where d.containerChromaPresence & mask != 0 {v[key]=scalar(value)}
            }
        }
        return v
    }
}
#endif
