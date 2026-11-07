import Foundation
import OSLog

/// A local anonymous timeline. No file names, paths, accounts, URLs, or arbitrary text enter records.
public enum LifecycleEvent:String,Codable,Sendable {
    case processStart,applicationNotification,scenePhase,viewAppear,viewDisappear
    case browseIntent,cancelRequested,requestStart,resultApplied,resultDiscarded,requestError
    case taskCreated,taskEntered,taskExited,providerWillCall,providerEntered,providerExited
    case sessionLookup,sessionReused,sessionCreateRequested,cacheMiss,recoveryStage
    case apiStart,apiReturned,apiError,directoryMappingDone,cacheHit,readerClosed,disconnectRequested
}
public enum LifecycleField:String,Codable,Sendable {
    case scope,phase,previousPhase,notification,navigation,request,parentRequest,session,operation,outcome
    case errorDomain,errorCode,errorOrigin,timeout,durationMS,sampledStart,sourceKind,generation,active,cancelled
}
public enum LifecycleOperation:Int,Codable,Sendable {
    case connect=1,listShares,listDirectory,attributes,rangeRead,tagRead,finderInfo,disconnect
}
/// These are Swift call boundaries, not evidence that library work or RPCs have drained.
public enum LifecycleProviderStage:Sendable {
    case willCall,entered,exited
    fileprivate var event:LifecycleEvent {
        switch self {case .willCall:.providerWillCall;case .entered:.providerEntered;case .exited:.providerExited}
    }
}
public struct LifecycleFailure:Sendable {
    public let domain:Int,code:Int,origin:Int,isTimeout:Bool,isCancellation:Bool
    public init(domain:Int,code:Int,origin:Int=0,isTimeout:Bool=false,isCancellation:Bool=false) {
        self.domain=domain;self.code=code;self.origin=origin;self.isTimeout=isTimeout;self.isCancellation=isCancellation
    }
    public init(_ error:any Error) {
        origin=0
        let e=error as NSError
        isCancellation=error is CancellationError || (e.domain==NSURLErrorDomain && e.code==NSURLErrorCancelled)
        switch e.domain {
        case NSPOSIXErrorDomain:domain=1
        case NSURLErrorDomain:domain=2
        case NSCocoaErrorDomain:domain=3
        default:domain=0
        }
        code=domain != 0 && e.code>=Int(Int32.min) && e.code<=Int(Int32.max) ? e.code:0
        isTimeout=(domain==1 && code==Int(ETIMEDOUT)) || (domain==2 && code==NSURLErrorTimedOut)
    }
}
public extension LifecycleFailure {
    var fields:[LifecycleField:Double] {[.errorDomain:Double(domain),.errorCode:Double(code),.errorOrigin:Double(origin),.timeout:isTimeout ? 1:0,.outcome:isCancellation ? 1:2]}
}
public struct LifecycleRecord:Codable,Sendable {
    public let schema:Int,build:String,run:UInt64,pid:Int32,sequence:UInt64
    public let wallTime:Double,uptime:Double,event:LifecycleEvent,fields:[String:Double]
    public let dropped:UInt64,omitted:UInt64,writerFailures:UInt64
    // Known before this record was captured, not proof that this record itself persisted.
    public let syncWrites:UInt64?,syncFailures:UInt64?,syncSlowWrites:UInt64?,syncMaxDurationMS:Double?
}
public struct LifecycleOperationToken:Sendable {
    public let request:UInt64,session:UInt64,operation:LifecycleOperation,navigation:UInt64,parentRequest:UInt64
    fileprivate let started:Double,recorded:Bool
}
public struct LifecycleRequestContext:Sendable {
    public let navigation:UInt64,request:UInt64
    public init(navigation:UInt64=0,request:UInt64=0){self.navigation=navigation;self.request=request}
}
public enum LifecycleContext {
    @TaskLocal public static var request=LifecycleRequestContext()
    public static var navigation:UInt64 {request.navigation}
}

/// Full timeline is asynchronous. Selected low-frequency boundaries also wait for a separate durable journal.
public final class LifecycleDiagnostics:@unchecked Sendable {
    public static let shared=LifecycleDiagnostics(directory:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VistaLifecycleDiagnostics",isDirectory:true))
    public let run:UInt64
    private let build:String,directory:URL,fileLimit:Int,pendingLimit:Int
    private let queue=DispatchQueue(label:"Vista.lifecycle.diagnostics",qos:.utility)
    private let lock=NSLock()
    private let mirror:Bool
    private let criticalJournal:LifecycleCriticalJournal?
    private let systemLog=Logger(subsystem:"org.peiyu66.Vista",category:"lifecycle")
    private var sequence:UInt64=0,identifier:UInt64=0,dropped:UInt64=0,omitted:UInt64=0,writerFailures:UInt64=0
    private var syncWrites:UInt64=0,syncFailures:UInt64=0,syncSlowWrites:UInt64=0,syncMaxDurationMS:Double=0
    private var pending:[(LifecycleRecord,Bool)]=[],draining=false,lastSample:[LifecycleOperation:Double]=[:]
    // The following state is owned exclusively by queue.
    private var handle:FileHandle?,size=0,prepared=false,lastSync = -Double.infinity
    public init(directory:URL,build:String=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0",fileLimit:Int=262144,pendingLimit:Int=128,mirror:Bool=true,criticalDurability:Bool=true,criticalFileLimit:Int=65536) {
        self.directory=directory;self.fileLimit=max(4096,fileLimit);self.pendingLimit=max(2,pendingLimit);self.mirror=mirror
        self.criticalJournal=criticalDurability ? LifecycleCriticalJournal(directory:directory,fileLimit:criticalFileLimit):nil
        self.build=build.count<=12 && !build.isEmpty && build.allSatisfy{$0.isASCII && ($0.isNumber || $0==".")} ? build:"0"
        run=UInt64.random(in:1...9_007_199_254_740_991)
        record(.processStart)
    }
    public var status:(dropped:UInt64,omitted:UInt64,writerFailures:UInt64,pending:Int,syncWrites:UInt64,syncFailures:UInt64,syncSlowWrites:UInt64,syncMaxDurationMS:Double) {
        lock.lock();defer{lock.unlock()};return(dropped,omitted,writerFailures,pending.count,syncWrites,syncFailures,syncSlowWrites,syncMaxDurationMS)
    }
    public func nextID()->UInt64 {
        lock.lock();defer{lock.unlock()}
        identifier += 1
        return identifier
    }
    public func record(_ event:LifecycleEvent,_ values:[LifecycleField:Double]=[:],priority:Bool=true) {
        let wall=Date().timeIntervalSince1970,up=ProcessInfo.processInfo.systemUptime
        let fields=Dictionary(uniqueKeysWithValues:values.filter{$0.value.isFinite && abs($0.value)<=9_007_199_254_740_991}.map{($0.key.rawValue,$0.value)})
        let durable=criticalJournal != nil && Self.requiresDurableCopy(event,fields:fields)
        lock.lock();sequence += 1
        if pending.count>=pendingLimit {
            if let i=pending.firstIndex(where:{!$0.1}) {pending.remove(at:i);dropped += 1}
            else if !priority && !durable {dropped += 1;lock.unlock();return}
            else {pending.removeFirst();dropped += 1}
        }
        let record=LifecycleRecord(schema:4,build:build,run:run,pid:ProcessInfo.processInfo.processIdentifier,sequence:sequence,wallTime:wall,uptime:up,event:event,fields:fields,dropped:dropped,omitted:omitted,writerFailures:writerFailures,syncWrites:syncWrites,syncFailures:syncFailures,syncSlowWrites:syncSlowWrites,syncMaxDurationMS:syncMaxDurationMS)
        pending.append((record,priority));let start = !draining;draining=true;lock.unlock()
        // Only low-frequency boundary/error events are mirrored. This contains typed data only.
        if mirror,priority,let data=try? JSONEncoder().encode(record),let text=String(data:data,encoding:.utf8) {systemLog.notice("\(text,privacy:.public)")}
        if start {queue.async{self.drain()}}
        // Never hold the admission lock or wait for the asynchronous timeline to drain.
        if let criticalJournal,durable {
            let result=criticalJournal.append(record)
            lock.lock()
            if result.succeeded {syncWrites += 1}else{syncFailures += 1}
            if result.durationMS>=50 {syncSlowWrites += 1}
            syncMaxDurationMS=max(syncMaxDurationMS,result.durationMS)
            lock.unlock()
        }
    }
    private static func requiresDurableCopy(_ event:LifecycleEvent,fields:[String:Double])->Bool {
        switch event {
        case .processStart,.scenePhase,.browseIntent,.cancelRequested,.requestStart,
             .taskCreated,.taskEntered,.taskExited,.sessionLookup,.sessionReused,.sessionCreateRequested,
             .cacheHit,.cacheMiss,.directoryMappingDone,.resultApplied,.resultDiscarded,.requestError,.recoveryStage:
            return true
        case .providerWillCall,.providerEntered,.providerExited,.apiStart,.apiReturned,.apiError:
            return [1.0,2.0,3.0].contains(fields[LifecycleField.operation.rawValue] ?? 0)
        default:return false
        }
    }
    /// `request` is the calling UI request here. API events use their own request ID and parentRequest.
    /// Reading cancellation only observes state; it does not check, throw, cancel, or wait for work.
    public func providerBoundary(_ stage:LifecycleProviderStage,operation:LifecycleOperation,session:UInt64=0) {
        record(stage.event,[.operation:Double(operation.rawValue),.session:Double(session),
            .request:Double(LifecycleContext.request.request),.navigation:Double(LifecycleContext.navigation),
            .cancelled:Task.isCancelled ? 1:0])
    }
    /// Records the observed cache branch only; it never reads a path, changes the cache, or starts network I/O.
    public func directoryCache(hit:Bool,session:UInt64) {
        record(hit ? .cacheHit:.cacheMiss,[.operation:Double(LifecycleOperation.listDirectory.rawValue),
            .session:Double(session),.request:Double(LifecycleContext.request.request),
            .navigation:Double(LifecycleContext.navigation)])
    }
    public func begin(_ operation:LifecycleOperation,session:UInt64=0,navigation:UInt64=LifecycleContext.navigation)->LifecycleOperationToken {
        let now=ProcessInfo.processInfo.systemUptime
        lock.lock();identifier += 1;let id=identifier
        let sampled=operation == .rangeRead || operation == .tagRead || operation == .finderInfo
        let emit = !sampled || now-(lastSample[operation] ?? -Double.infinity)>=1
        if sampled,emit {lastSample[operation]=now}
        if !emit {omitted += 1};lock.unlock()
        let token=LifecycleOperationToken(request:id,session:session,operation:operation,navigation:navigation,parentRequest:LifecycleContext.request.request,started:now,recorded:emit)
        if emit {record(.apiStart,fields(token),priority:operation != .rangeRead && operation != .tagRead && operation != .finderInfo)}
        return token
    }
    public func finish(_ token:LifecycleOperationToken,failure:LifecycleFailure?=nil) {
        let expectedMetadataFailure=(token.operation == .tagRead || token.operation == .finderInfo) && failure?.domain==1 && [ENOENT,ENODATA,ENOTSUP,EACCES,EPERM].contains(Int32(failure?.code ?? 0))
        if !token.recorded,(failure==nil || expectedMetadataFailure) {lock.lock();omitted += 1;lock.unlock();return}
        var values=fields(token);values[.durationMS]=max(0,(ProcessInfo.processInfo.systemUptime-token.started)*1000)
        values[.sampledStart]=token.recorded ? 1:0
        if let failure {
            values[.errorDomain]=Double(failure.domain);values[.errorCode]=Double(failure.code);values[.errorOrigin]=Double(failure.origin)
            values[.timeout]=failure.isTimeout ? 1:0;values[.outcome]=failure.isCancellation ? 1:2
        } else {values[.outcome]=0}
        record(failure==nil ? .apiReturned:.apiError,values,priority:(failure != nil && !expectedMetadataFailure) || (token.operation != .rangeRead && token.operation != .tagRead && token.operation != .finderInfo))
    }
    public func fields(_ token:LifecycleOperationToken)->[LifecycleField:Double] {
        [.request:Double(token.request),.session:Double(token.session),.operation:Double(token.operation.rawValue),.navigation:Double(token.navigation),.parentRequest:Double(token.parentRequest)]
    }
    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else{draining=false;lock.unlock();return}
            let record=pending.removeFirst().0;lock.unlock()
            do {var data=try JSONEncoder().encode(record);data.append(10);guard data.count<2048 else{throw CocoaError(.fileWriteInapplicableStringEncoding)};try write(data)}
            catch {lock.lock();writerFailures += 1;lock.unlock()}
        }
    }
    private func file(_ index:Int)->URL {directory.appendingPathComponent(index==0 ? "current.jsonl":"previous-\(index).jsonl")}
    private func prepare()throws {
        let fm=FileManager.default
        try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var url=directory;var values=URLResourceValues();values.isExcludedFromBackup=true;try url.setResourceValues(values)
        for i in 0...3 {
            let url=file(i)
            if let date=try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,Date().timeIntervalSince(date)>7*86400 {try fm.removeItem(at:url)}
        }
        size=(try? fm.attributesOfItem(atPath:file(0).path)[.size] as? NSNumber)?.intValue ?? 0
        prepared=true
    }
    private func write(_ data:Data)throws {
        let fm=FileManager.default
        if !prepared {try prepare()}
        if size+data.count>fileLimit {
            try handle?.close();handle=nil
            if fm.fileExists(atPath:file(3).path) {try fm.removeItem(at:file(3))}
            for i in stride(from:2,through:0,by:-1) where fm.fileExists(atPath:file(i).path) {try fm.moveItem(at:file(i),to:file(i+1))}
            size=0
        }
        if handle==nil {
            if !fm.fileExists(atPath:file(0).path) {
                guard fm.createFile(atPath:file(0).path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw CocoaError(.fileWriteUnknown)}
                #if os(visionOS) || os(iOS)
                try fm.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:file(0).path)
                #endif
            }
            handle=try FileHandle(forWritingTo:file(0));try handle?.seekToEnd()
        }
        try handle?.write(contentsOf:data);size += data.count
        let now=ProcessInfo.processInfo.systemUptime
        // Priority controls admission, not fsync. Bound synchronization to at most 4 Hz.
        if now-lastSync>=0.25 {lastSync=now;try handle?.synchronize()}
    }
    #if DEBUG
    public func setCriticalSynchronizerForTesting(_ sync:(@Sendable (FileHandle)throws->Void)?) {
        criticalJournal?.setSynchronizerForTesting(sync)
    }
    public func setCriticalWriterForTesting(_ writer:(@Sendable (FileHandle,Data)throws->Void)?) {
        criticalJournal?.setWriterForTesting(writer)
    }
    public func drainForTesting(){queue.sync{try? handle?.synchronize()}}
    public func withPausedWriterForTesting(_ body:()->Void){queue.sync{};queue.suspend();defer{queue.resume()};body()}
    #endif
}


/// A separate bounded critical copy avoids waiting behind high-frequency timeline producers.
/// Each call waits for append + synchronize or a caught failure. Disk I/O has no hard time bound.
private final class LifecycleCriticalJournal:@unchecked Sendable {
    struct Result {let succeeded:Bool,durationMS:Double}
    private let directory:URL,fileLimit:Int
    private let queue=DispatchQueue(label:"Vista.lifecycle.critical",qos:.utility)
    private let queueKey=DispatchSpecificKey<Bool>()
    // Accessed only on queue.
    private var handle:FileHandle?,size=0,prepared=false
    #if DEBUG
    private var synchronizerForTesting:(@Sendable (FileHandle)throws->Void)?
    private var writerForTesting:(@Sendable (FileHandle,Data)throws->Void)?
    #endif
    init(directory:URL,fileLimit:Int) {
        self.directory=directory;self.fileLimit=max(4096,fileLimit)
        queue.setSpecific(key:queueKey,value:true)
    }
    func append(_ record:LifecycleRecord)->Result {
        let started=ProcessInfo.processInfo.systemUptime
        // No production caller runs here. Fail instead of deadlocking if a future caller re-enters.
        guard DispatchQueue.getSpecific(key:queueKey) != true else{return Result(succeeded:false,durationMS:0)}
        let success:Bool=queue.sync {
            do {
                var data=try JSONEncoder().encode(record);data.append(10)
                guard data.count<2048 else{throw CocoaError(.fileWriteInapplicableStringEncoding)}
                try writeAndSynchronize(data)
                return true
            } catch {return false}
        }
        return Result(succeeded:success,durationMS:max(0,(ProcessInfo.processInfo.systemUptime-started)*1000))
    }
    private func file(_ index:Int)->URL {
        directory.appendingPathComponent(index==0 ? "critical-current.jsonl":"critical-previous-\(index).jsonl")
    }
    private func prepare()throws {
        let fm=FileManager.default
        try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var url=directory;var values=URLResourceValues();values.isExcludedFromBackup=true;try url.setResourceValues(values)
        for index in 0...3 {
            let url=file(index)
            if let date=try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,Date().timeIntervalSince(date)>7*86400 {try fm.removeItem(at:url)}
        }
        size=(try? fm.attributesOfItem(atPath:file(0).path)[.size] as? NSNumber)?.intValue ?? 0
        prepared=true
    }
    private func synchronize(_ handle:FileHandle)throws {
        #if DEBUG
        if let synchronizerForTesting {try synchronizerForTesting(handle);return}
        #endif
        try handle.synchronize()
    }
    private func writeAndSynchronize(_ data:Data)throws {
        let fm=FileManager.default
        if !prepared {try prepare()}
        if size+data.count+1>fileLimit {
            // A failed prior sync must not silently become a successful rotation acknowledgment.
            if let handle {try synchronize(handle);try handle.close()}
            handle=nil
            if fm.fileExists(atPath:file(3).path) {try fm.removeItem(at:file(3))}
            for index in stride(from:2,through:0,by:-1) where fm.fileExists(atPath:file(index).path) {try fm.moveItem(at:file(index),to:file(index+1))}
            size=0
        }
        if handle==nil {
            if !fm.fileExists(atPath:file(0).path) {
                guard fm.createFile(atPath:file(0).path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw CocoaError(.fileWriteUnknown)}
            }
            #if os(visionOS) || os(iOS)
            // Retry this protection step after a prior open/setup failure before writing any bytes.
            try fm.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:file(0).path)
            #endif
            let opened=try FileHandle(forUpdating:file(0))
            do {
                let end=try opened.seekToEnd()
                if end>0 {
                    try opened.seek(toOffset:end-1)
                    let last=try opened.read(upToCount:1)
                    try opened.seekToEnd()
                    // Preserve a damaged prior line, but do not glue a new valid record onto it.
                    if last != Data([10]) {try opened.write(contentsOf:Data([10]));size += 1}
                }
                handle=opened
            } catch {try? opened.close();prepared=false;throw error}
        }
        guard let handle else{throw CocoaError(.fileWriteUnknown)}
        do {
            #if DEBUG
            if let writerForTesting {try writerForTesting(handle,data)}else{try handle.write(contentsOf:data)}
            #else
            try handle.write(contentsOf:data)
            #endif
            size += data.count
        } catch {
            // A partial write is counted once; reopen and remeasure on the next event, never retry here.
            try? handle.close();self.handle=nil;prepared=false
            throw error
        }
        try synchronize(handle)
    }
    #if DEBUG
    func setSynchronizerForTesting(_ sync:(@Sendable (FileHandle)throws->Void)?) {
        queue.sync{synchronizerForTesting=sync}
    }
    func setWriterForTesting(_ writer:(@Sendable (FileHandle,Data)throws->Void)?) {
        queue.sync{writerForTesting=writer}
    }
    #endif
}
