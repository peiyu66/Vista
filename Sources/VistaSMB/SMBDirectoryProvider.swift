import Foundation
import AMSMB2
#if SWIFT_PACKAGE
import VistaCore
#endif

/// Fixed, non-sensitive categories for one read-only directory recovery decision.
/// Eligibility does not claim a physical disconnection or authorize a second attempt.
public enum SMBDirectoryReadFailure: Int, Error, Sendable, Equatable {
    case cancelled=1, retired=2, permissionDenied=3, authenticationRequired=4, notFound=5, serverRejected=6
    case serviceInvalidated=7, contextUnavailable=8, transportFailure=9, unclassifiedSessionFailure=10
    case retiredByPlaybackRecovery=11

    public var allowsFreshRecovery: Bool {
        switch self {
        case .serviceInvalidated,.contextUnavailable,.transportFailure,.unclassifiedSessionFailure,.retiredByPlaybackRecovery:true
        default:false
        }
    }

    /// A live player may still borrow the registry's provider. Only the playback-specific
    /// retirement marker proves that provider has already drained and closed; the player's
    /// replacement stays private. Registry/current-owner checks remain the runner's job.
    public func permitsDirectoryRecovery(playbackActive: Bool) -> Bool {
        allowsFreshRecovery && (!playbackActive || self == .retiredByPlaybackRecovery)
    }

    static func classify(_ error:any Error)->Self {
        if error is CancellationError {return .cancelled}
        if let failure=error as? Self {return failure}
        if let failure=error as? SMB2OperationFailure {
            // The provenance is captured before context destruction, not inferred from messages.
            switch failure.origin {
            case .serviceInvalidated:return .serviceInvalidated
            case .contextUnavailable:return .contextUnavailable
            case .response:
                if let status=failure.ntStatus,let kind=serverStatus(status) {return kind}
                if let code=failure.posixCode,let kind=posix(code,confirmedResponse:true) {return kind}
                return .unclassifiedSessionFailure
            case .submission,.wait:
                if let code=failure.posixCode,let kind=posix(code,confirmedResponse:false) {return kind}
                return .unclassifiedSessionFailure
            }
        }
        let error=error as NSError
        if error.domain==NSPOSIXErrorDomain,let code=Int32(exactly:error.code) {
            return posix(code,confirmedResponse:false) ?? .unclassifiedSessionFailure
        }
        if error.domain==NSURLErrorDomain {
            switch error.code {
            case NSURLErrorCancelled:return .cancelled
            case NSURLErrorUserAuthenticationRequired,NSURLErrorUserCancelledAuthentication:return .authenticationRequired
            case NSURLErrorNoPermissionsToReadFile:return .permissionDenied
            case NSURLErrorFileDoesNotExist:return .notFound
            case NSURLErrorNetworkConnectionLost,NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotConnectToHost,NSURLErrorCannotFindHost,NSURLErrorDNSLookupFailed:return .transportFailure
            case NSURLErrorBadURL,NSURLErrorUnsupportedURL:return .serverRejected
            default:return .unclassifiedSessionFailure
            }
        }
        if error.domain==NSCocoaErrorDomain {
            switch error.code {
            case NSUserCancelledError:return .cancelled
            case NSFileReadNoPermissionError:return .permissionDenied
            case NSFileNoSuchFileError,NSFileReadNoSuchFileError:return .notFound
            default:break
            }
        }
        return .unclassifiedSessionFailure
    }

    private static func posix(_ code:Int32,confirmedResponse:Bool)->Self? {
        switch code {
        case ECANCELED:return .cancelled
        case EACCES:return .permissionDenied
        // Legacy service -1 was previously manufactured into EPERM. Only a server response
        // establishes a permission refusal; an unproven EPERM is not labelled "disconnected".
        case EPERM:return confirmedResponse ? .permissionDenied:nil
        case EAUTH,ENEEDAUTH:return .authenticationRequired
        case ENOENT,ENOTDIR:return .notFound
        // libsmb2 maps LOGON_FAILURE to ECONNREFUSED in command callbacks.
        case ECONNREFUSED:return confirmedResponse ? .authenticationRequired:.transportFailure
        // In callbacks these include translated NTSTATUS, e.g. CANCELLED/FILE_CLOSED
        // -> ENETRESET and PIPE_DISCONNECTED -> EPIPE. Preserve uncertainty.
        case ECONNRESET,ECONNABORTED,ENETRESET,ENOTCONN,EPIPE,
             ENETDOWN,ENETUNREACH,EHOSTDOWN,EHOSTUNREACH,ESHUTDOWN:
            return confirmedResponse ? .unclassifiedSessionFailure:.transportFailure
        case EINVAL,ENAMETOOLONG,ENOTSUP,EISDIR,EROFS:return .serverRejected
        default:return nil
        }
    }

    private static func serverStatus(_ status:UInt32)->Self? {
        switch status {
        case 0xC0000120:return .cancelled // STATUS_CANCELLED
        case 0xC0000022,0xC0000061,0xC00000CA:return .permissionDenied
        case 0xC0000064,0xC000006A,0xC000006D,0xC000006E,0xC000006F,
             0xC0000070,0xC0000071,0xC0000072,0xC0000149,0xC0000193,0xC0000224,0xC0000234:return .authenticationRequired
        case 0xC000000F,0xC0000034,0xC0000039,0xC000003A,0xC000003B,
             0xC00000CC,0xC0000103,0xC0000225:return .notFound
        case 0xC00000C9,0xC0000203,0xC000020C,0xC000035C:return .contextUnavailable
        case 0xC0000002,0xC000000D,0xC0000010,0xC0000033,0xC00000BA,0xC00000BB:return .serverRejected
        default:return nil
        }
    }
}

/// Synchronous admission paired with asynchronous drain. Releasing happens only after the
/// awaited operation returns, never in a cancellation handler. The library still needs its
/// own queue barrier after this gate drains because callback completion is a separate event.
final class SMBOperationLeases: @unchecked Sendable {
    private let lock=NSLock()
    private var accepting=true
    private var active=0
    private var waiters:[CheckedContinuation<Void,Never>]=[]

    func acquire()->Bool {
        lock.lock();defer{lock.unlock()}
        guard accepting else{return false}
        active += 1
        return true
    }
    func release() {
        lock.lock()
        precondition(active>0,"Unbalanced SMB operation lease")
        active -= 1
        let ready=active==0 ? waiters:[]
        if active==0 {waiters.removeAll()}
        lock.unlock()
        for waiter in ready {waiter.resume()}
    }
    func close() {
        lock.lock();accepting=false;lock.unlock()
    }
    func waitForDrain() async {
        await withCheckedContinuation {continuation in
            lock.lock()
            if active==0 {lock.unlock();continuation.resume()}
            else {waiters.append(continuation);lock.unlock()}
        }
    }
    // Internal deterministic state observation for no-network lifecycle tests.
    var snapshot:(accepting:Bool,active:Int,waiting:Int) {
        lock.lock();defer{lock.unlock()}
        return(accepting,active,waiters.count)
    }
}

/// Owns one authenticated session. Never encode, log or persist the manager or credentials.
public actor SMBDirectoryProvider: DirectoryProvider, MediaByteSource {
    private let manager: SMB2Manager
    private let diagnosticSession:UInt64
    private let diagnostics:LifecycleDiagnostics
    private let mediaReader: SMBMediaReader
    private let operationLeases: SMBOperationLeases
    private var retirement: Task<Void, any Error>?
    private var retirementStartedForPlayback = false
    private var retiredByPlaybackRecovery = false
    private var cache: [DirectoryPath: [FileEntry]] = [:]
    private var orderedCache: [DirectoryPath: (DirectorySort,[FileEntry])] = [:]
    private var tagCache:[String:(Date,FinderTagState)]=[:]
    private var cacheRevision=0
    private var closed = false
    // Internal injection seam supports no-network manager substitutes in focused lifecycle tests.
    init(manager: SMB2Manager,diagnostics:LifecycleDiagnostics,session:UInt64,leases:SMBOperationLeases=SMBOperationLeases()) {
        self.diagnostics=diagnostics;self.diagnosticSession=session
        self.manager = manager
        self.operationLeases = leases
        self.mediaReader = SMBMediaReader(transport: AMSMBRangeTransport(manager: manager),diagnostics:diagnostics,session:session,leases:leases)
    }

    /// Immutable Sendable dependencies let a playback session own a separate file transport.
    /// The shared admission gate still prevents all new work once this provider retires.
    nonisolated func makePlaybackReader() -> (reader: SMBMediaReader, transport: SMBPlaybackHandleTransport) {
        let transport = SMBPlaybackHandleTransport(manager: manager)
        return (SMBMediaReader(transport: transport, diagnostics: diagnostics,
                              session: diagnosticSession, leases: operationLeases), transport)
    }

    func finishPlaybackTransport(_ transport: SMBPlaybackHandleTransport) async throws {
        if operationLeases.acquire() {
            defer { operationLeases.release() }
            try await transport.close()
        } else {
            // A retirement that closed admission owns the context. Join it before the
            // file wrapper performs its now-local cleanup; do not race a fresh close RPC.
            if let retirement {
                try await retirement.value
                try await transport.closeAfterProviderRetirement()
            } else {
                try await transport.close()
            }
        }
    }

    func playbackFailure(_ error: any Error) -> SMBPlaybackReadFailure {
        let failure = SMBPlaybackSession.recoveryDisposition(for: error)
        return failure == .retired ? playbackRetirementFailure : failure
    }

    public static func connect(input: ConnectionInput, password: String) async throws -> SMBDirectoryProvider {
        try await connect(input:input,password:password,freshRecovery:false)
    }

    /// Exactly one library connect on a new manager, with no echo-triggered reconnect.
    public static func connectFreshForRecovery(input: ConnectionInput, password: String) async throws -> SMBDirectoryProvider {
        try await connect(input:input,password:password,freshRecovery:true)
    }

    private static func connect(input: ConnectionInput, password: String, freshRecovery: Bool) async throws -> SMBDirectoryProvider {
        LifecycleDiagnostics.shared.providerBoundary(.entered,operation:.connect)
        defer {LifecycleDiagnostics.shared.providerBoundary(.exited,operation:.connect)}
        try Task.checkCancellation()
        guard input.isValid else { throw URLError(.badURL) }
        var url = URLComponents()
        url.scheme = "smb"
        url.host = input.server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = url.url,
              let manager = SMB2Manager(url: endpoint, credential: URLCredential(user: input.username, password: password, persistence: .none)) else {
            throw URLError(.badURL)
        }
        manager.timeout = 15
        let diagnostics=LifecycleDiagnostics.shared,session=LifecycleDiagnostics.shared.nextID()
        let operation=diagnostics.begin(.connect,session:session)
        var returned=false
        do {
            // Preserve library negotiation/signing and server-required encryption.
            let share = input.share.trimmingCharacters(in: .whitespacesAndNewlines)
            if freshRecovery { try await manager.connectShareOnce(name:share) }
            else { try await manager.connectShare(name:share) }
            returned=true;diagnostics.finish(operation)
            try Task.checkCancellation()
            return SMBDirectoryProvider(manager:manager,diagnostics:diagnostics,session:session)
        } catch {
            if !returned {diagnostics.finish(operation,failure:SMBDirectoryProvider.diagnosticFailure(for:error))}
            let cleanup=diagnostics.begin(.disconnect,session:session)
            // Awaiting the connect continuation alone does not prove its callback has returned.
            // Failed connections are retired locally, never serviced again by a disconnect RPC.
            await manager.retireLocallyAfterDraining()
            diagnostics.finish(cleanup)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    public func page(at path: DirectoryPath, offset: Int) async throws -> DirectoryPage {
        try await page(at:path,offset:offset,sort:DirectorySort())
    }
    public func page(at path: DirectoryPath, offset: Int, sort: DirectorySort) async throws -> DirectoryPage {
        diagnostics.providerBoundary(.entered,operation:.listDirectory,session:diagnosticSession)
        defer {diagnostics.providerBoundary(.exited,operation:.listDirectory,session:diagnosticSession)}
        try Task.checkCancellation()
        guard !closed, operationLeases.acquire() else {
            throw retiredByPlaybackRecovery ? SMBDirectoryReadFailure.retiredByPlaybackRecovery : .retired
        }
        defer { operationLeases.release() }
        if cache[path] == nil {
            diagnostics.directoryCache(hit:false,session:diagnosticSession)
            let revision=cacheRevision
            let operation=diagnostics.begin(.listDirectory,session:diagnosticSession)
            let diagnostics=self.diagnostics
            let entries: [FileEntry]
            do {
                entries = try await withCheckedThrowingContinuation { continuation in
                    manager.contentsOfDirectory(atPath: path.components.joined(separator: "/")) { result in
                        switch result {
                        case .failure(let error):
                            diagnostics.finish(operation,failure:SMBDirectoryProvider.diagnosticFailure(for:error))
                            continuation.resume(throwing: error)
                        case .success(let items):
                            diagnostics.finish(operation)
                            let mapped = items.compactMap(Self.visibleEntry).sorted {
                                if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
                                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                            }
                            diagnostics.record(.directoryMappingDone,diagnostics.fields(operation))
                            continuation.resume(returning: mapped)
                        }
                    }
                }
            } catch {
                try Task.checkCancellation()
                throw error
            }
            try Task.checkCancellation()
            guard !closed,revision==cacheRevision else { throw CancellationError() }
            // Bound transport cache; the UI owns its visited-directory snapshots.
            if cache.count >= 8 { cache.removeAll();orderedCache.removeAll() }
            cache[path] = entries
        } else {diagnostics.directoryCache(hit:true,session:diagnosticSession)}
        if orderedCache[path]?.0 != sort { orderedCache[path]=(sort,sort.sorted(cache[path] ?? [])) }
        let entries = orderedCache[path]?.1 ?? []
        guard offset >= 0, offset <= entries.count else { throw URLError(.badServerResponse) }
        let end = min(offset + 100, entries.count)
        return DirectoryPage(entries: Array(entries[offset..<end]), nextOffset: end < entries.count ? end : nil)
    }

    /// Filter before pagination so hidden-only network results do not create empty UI pages.
    nonisolated static func visibleEntry(_ item: [URLResourceKey: any Sendable]) -> FileEntry? {
        guard let name = item[.nameKey] as? String,
              let type = item[.fileResourceTypeKey] as? URLFileResourceType else { return nil }
        let kind: FileEntry.Kind
        if type == .directory { kind = .directory }
        else {
            let ext = (name as NSString).pathExtension.lowercased()
            kind = ["mp4", "mkv", "mov", "m4v"].contains(ext) ? .video : .other
        }
        let entry = FileEntry(name, kind, hiddenAttribute: item[.isHiddenKey] as? Bool, modifiedAt:item[.contentModificationDateKey] as? Date,byteSize:(item[.fileSizeKey] as? NSNumber)?.int64Value,createdAt:item[.creationDateKey] as? Date)
        return entry.isHidden ? nil : entry
    }

    public func tags(at path:DirectoryPath) async throws ->FinderTagState {
        try Task.checkCancellation()
        guard !closed, operationLeases.acquire() else { throw SMBDirectoryReadFailure.retired }
        defer { operationLeases.release() }
        guard path.components.allSatisfy(SavedLocations.validComponent) else {throw URLError(.badURL)}
        let key=path.components.joined(separator:"/")
        if let cached=tagCache[key],Date().timeIntervalSince(cached.0)<60 {return cached.1}
        let revision=cacheRevision
        let state=try await SMBTagAdmission.shared.read {await self.readTags(path:key)}
        try Task.checkCancellation()
        guard !closed,revision==cacheRevision else {throw CancellationError()}
        if tagCache.count>=512 {tagCache.removeAll()}
        tagCache[key]=(Date(),state)
        return state
    }
    private func readTags(path:String) async ->FinderTagState {
        guard !closed else{return .failed}
        let manager=self.manager,diagnostics=self.diagnostics
        let operation=diagnostics.begin(.tagRead,session:diagnosticSession)
        return await Self.readTagMetadata {
            do {
            // One bounded named-stream operation; no base-file existence query.
            let stream:AsyncThrowingStream<Data,any Error>=manager.contents(atPath:path+":com.apple.metadata\u{F022}_kMDItemUserTags",range:0..<(FinderTagParser.limit+1))
            var data=Data()
            for try await part in stream {
                guard data.count+part.count<=FinderTagParser.limit+1 else {diagnostics.finish(operation);return Data(repeating:0,count:FinderTagParser.limit+1)}
                data.append(part)
            }
            diagnostics.finish(operation);return data
            } catch {diagnostics.finish(operation,failure:SMBDirectoryProvider.diagnosticFailure(for:error));throw error}
        }
    }
    nonisolated static func readTagMetadata(_ read:@Sendable () async throws ->Data) async ->FinderTagState {
        do {return FinderTagParser.parse(try await read())}
        catch {return tagFailure(error)}
    }
    /// At most three already-listed entries; no directory enumeration or recursion.
    public func hasFinderEvidence(paths:[String]) async throws ->Bool {
        try Task.checkCancellation()
        guard !closed, operationLeases.acquire() else { throw SMBDirectoryReadFailure.retired }
        defer { operationLeases.release() }
        let revision=cacheRevision
        let evidence = try await Self.probeFinderEvidence(paths:paths,readTags:{path in
            try await SMBTagAdmission.shared.read {await self.readTags(path:path)}
        },readInfo:{path in
            let result=try await SMBTagAdmission.shared.read {
                let valid=await self.readFinderInfo(path:path)
                return valid ? .loaded([FinderTag(name:"evidence",color:0)]):.unavailable
            }
            return TagSupportEvidence.tags(result)
        })
        try Task.checkCancellation()
        guard !closed,revision==cacheRevision else { throw CancellationError() }
        return evidence
    }
    nonisolated static func probeFinderEvidence(
        paths:[String],budget:TimeInterval=3,
        readTags:@Sendable (String) async throws ->FinderTagState,
        readInfo:@Sendable (String) async throws ->Bool
    ) async throws ->Bool {
        let deadline=Date().addingTimeInterval(budget)
        for path in paths.prefix(TagSupportEvidence.sampleLimit) {
            try Task.checkCancellation()
            guard Date()<deadline else{return false}
            let tags=try await readTags(path)
            try Task.checkCancellation()
            if TagSupportEvidence.tags(tags) {return true}
            guard Date()<deadline else{return false}
            let valid=try await readInfo(path)
            try Task.checkCancellation()
            if valid {return true}
        }
        return false
    }
    private func readFinderInfo(path:String) async ->Bool {
        guard !closed else{return false}
        let operation=diagnostics.begin(.finderInfo,session:diagnosticSession)
        do {
            let stream:AsyncThrowingStream<Data,any Error>=manager.contents(atPath:path+":AFP_AfpInfo",range:0..<61)
            var data=Data()
            for try await part in stream {
                guard data.count+part.count<=61 else{diagnostics.finish(operation);return false}
                data.append(part)
            }
            diagnostics.finish(operation);return TagSupportEvidence.finderInfo(data)
        } catch {diagnostics.finish(operation,failure:SMBDirectoryProvider.diagnosticFailure(for:error));return false}
    }
    public func clearTagCache() {cacheRevision += 1;tagCache.removeAll()}
    public func invalidateDirectory(_ path:DirectoryPath) {
        cacheRevision += 1
        cache[path]=nil;orderedCache[path]=nil
        let directory=path.components.joined(separator:"/")
        tagCache=tagCache.filter { !Self.isImmediateChild($0.key,of:directory) }
    }
    nonisolated static func isImmediateChild(_ path:String,of directory:String)->Bool {
        let parts=path.split(separator:"/",omittingEmptySubsequences:false)
        return parts.dropLast().joined(separator:"/")==directory
    }
    nonisolated static func tagFailure(_ error:Error)->FinderTagState {
        let code: Int
        if let failure=error as? SMB2OperationFailure {
            guard failure.origin == .response,let posixCode=failure.posixCode else{return .failed}
            code=Int(posixCode)
        } else {
            let e=error as NSError
            guard e.domain==NSPOSIXErrorDomain else{return .failed}
            code=e.code
        }
        switch code {
        case Int(EACCES),Int(EPERM):return .denied
        case Int(ENOTSUP):return .unsupported
        case Int(ENOENT),Int(ENODATA):return .unavailable
        default:return .failed
        }
    }

    /// Eligibility only. The caller owns request identity, one-attempt admission and publication.
    public nonisolated static func recoveryDisposition(for error:any Error)->SMBDirectoryReadFailure {
        SMBDirectoryReadFailure.classify(error)
    }

    /// Numeric provenance only. No server-provided text or mutable context state is inspected.
    public nonisolated static func diagnosticFailure(for error:any Error)->LifecycleFailure {
        guard let failure=error as? SMB2OperationFailure else {return LifecycleFailure(error)}
        let origin:Int
        switch failure.origin {
        case .serviceInvalidated:origin=1
        case .submission:origin=2
        case .response:origin=3
        case .wait:origin=4
        case .contextUnavailable:origin=5
        }
        // A generic service return is not errno. Other typed boundaries carry errno only
        // when the dependency had a defined POSIX result at that exact boundary.
        let code=failure.origin == .serviceInvalidated || failure.origin == .contextUnavailable ? nil:failure.posixCode
        return LifecycleFailure(domain:code == nil ? 0:1,code:Int(code ?? 0),origin:origin,
            isTimeout:code==ETIMEDOUT,isCancellation:recoveryDisposition(for:error) == .cancelled)
    }

    public func fileSize(for file: MediaFile) async throws -> UInt64 {
        guard !closed else {throw MediaInspectionError.unavailable}
        return try await mediaReader.fileSize(for:file)
    }
    public func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        guard !closed else {throw MediaInspectionError.unavailable}
        return try await mediaReader.read(file,range:range)
    }

    func playbackMetadata(for file: MediaFile) async throws -> PlaybackSourceIdentity {
        try Task.checkCancellation()
        guard !closed else { throw playbackRetirementFailure }
        do { return try await mediaReader.playbackMetadata(for: file) }
        catch SMBPlaybackReadFailure.retired { throw playbackRetirementFailure }
    }

    func playbackRead(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw playbackRetirementFailure }
        do { return try await mediaReader.playbackRead(file, range: range) }
        catch SMBPlaybackReadFailure.retired { throw playbackRetirementFailure }
    }

    private var playbackRetirementFailure: SMBPlaybackReadFailure {
        retiredByPlaybackRecovery ? .retiredByPlaybackRecovery : .retired
    }

    /// Stops admission, waits for real asynchronous work, then destroys only local session state.
    /// This call adds no RPC. If ordinary disconnect already began, it joins that same task
    /// (which may include its existing disconnect RPC) and propagates any cleanup failure.
    /// Cancellation never releases the gate early; the caller checks cancellation before reconnecting.
    public func retireForDirectoryRecovery() async throws {
        try await retire(localOnly:true)
    }

    /// A directory owner can replace this provider only after its actual retirement finished.
    /// Joining an earlier ordinary retirement never upgrades that retirement's reason.
    public func retireForPlaybackRecovery() async throws {
        try await retire(localOnly: true, forPlaybackRecovery: true)
    }

    public func disconnect() async {
        do {try await retire(localOnly:false)}
        catch { /* The shared retirement task has already recorded this failure. */ }
    }

    private func retire(localOnly:Bool,forPlaybackRecovery:Bool=false) async throws {
        if let retirement {
            try await retirement.value
            if retirementStartedForPlayback { retiredByPlaybackRecovery = true }
            return
        }
        retirementStartedForPlayback = forPlaybackRecovery
        diagnostics.record(.disconnectRequested,[.session:Double(diagnosticSession),.navigation:Double(LifecycleContext.navigation)])
        closed=true;cacheRevision += 1
        cache.removeAll();orderedCache.removeAll();tagCache.removeAll()
        operationLeases.close()
        let reader=mediaReader,leases=operationLeases,manager=manager,diagnostics=diagnostics,session=diagnosticSession
        // Unstructured cleanup deliberately survives cancellation of the navigation task.
        let task=Task<Void,any Error> {
            await reader.close()
            await leases.waitForDrain()
            let operation=diagnostics.begin(.disconnect,session:session)
            do {
                if localOnly {
                    // Library queue drain is a second barrier: a resumed Swift continuation can
                    // finish before its underlying completionHandler/operationCount has finished.
                    await manager.retireLocallyAfterDraining()
                } else {
                    try await manager.disconnectShare(gracefully:true)
                }
                diagnostics.finish(operation)
            } catch {
                diagnostics.finish(operation,failure:SMBDirectoryProvider.diagnosticFailure(for:error))
                throw error
            }
        }
        retirement=task
        try await task.value
        if retirementStartedForPlayback { retiredByPlaybackRecovery = true }
    }
}

/// Process-wide admission avoids accumulating non-interruptible library RPCs after UI cancellation.
public actor SMBShareEnumerator {
    public static let shared=SMBShareEnumerator()
    private var busy=false
    public func shares(server:String,username:String,password:String) async throws -> [String] {
        LifecycleDiagnostics.shared.providerBoundary(.entered,operation:.listShares)
        defer {LifecycleDiagnostics.shared.providerBoundary(.exited,operation:.listShares)}
        guard !busy else {throw URLError(.resourceUnavailable)}
        try Task.checkCancellation()
        guard ConnectionInput(server:server,share:"placeholder",username:username).isValid else {throw URLError(.badURL)}
        busy=true;defer{busy=false}
        var url=URLComponents();url.scheme="smb";url.host=server.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let endpoint=url.url,let manager=SMB2Manager(url:endpoint,credential:URLCredential(user:username,password:password,persistence:.none)) else {throw URLError(.badURL)}
        manager.timeout=15
        let diagnostics=LifecycleDiagnostics.shared,session=LifecycleDiagnostics.shared.nextID()
        let operation=diagnostics.begin(.listShares,session:session)
        var returned=false
        do {
            let shares=try await manager.listShares(enumerateHidden:false)
            returned=true;diagnostics.finish(operation)
            let cleanup=diagnostics.begin(.disconnect,session:session)
            do {try await manager.disconnectShare();diagnostics.finish(cleanup)}
            catch {diagnostics.finish(cleanup,failure:SMBDirectoryProvider.diagnosticFailure(for:error))}
            try Task.checkCancellation()
            return Array(Set(shares.map(\.name).filter {SavedLocations.validComponent($0) && !$0.hasPrefix(".") && !$0.hasSuffix("$")})).sorted {$0.localizedStandardCompare($1) == .orderedAscending}.prefix(200).map{$0}
        } catch {
            if !returned {diagnostics.finish(operation,failure:SMBDirectoryProvider.diagnosticFailure(for:error))}
            let cleanup=diagnostics.begin(.disconnect,session:session)
            do {try await manager.disconnectShare();diagnostics.finish(cleanup)}
            catch {diagnostics.finish(cleanup,failure:SMBDirectoryProvider.diagnosticFailure(for:error))}
            throw error is CancellationError ? CancellationError():URLError(.cannotLoadFromNetwork)
        }
    }
}

/// One process-wide tag RPC, including cancelled callers whose library work is still draining.
actor SMBTagAdmission {
    static let shared=SMBTagAdmission()
    private var busy=false
    func read(_ operation:@escaping @Sendable () async ->FinderTagState) async throws ->FinderTagState {
        while busy {try await Task.sleep(for:.milliseconds(50))}
        try Task.checkCancellation();busy=true
        // Unstructured worker deliberately outlives caller cancellation; do not free admission early.
        let worker=Task {await operation()}
        let value=await worker.value
        busy=false
        try Task.checkCancellation()
        return value
    }
}
