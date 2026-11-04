import Foundation
import AMSMB2
#if SWIFT_PACKAGE
import VistaCore
#endif

/// Owns one authenticated session. Never encode, log or persist the manager or credentials.
public actor SMBDirectoryProvider: DirectoryProvider, MediaByteSource {
    private let manager: SMB2Manager
    private let mediaReader: SMBMediaReader
    private var cache: [DirectoryPath: [FileEntry]] = [:]
    private var orderedCache: [DirectoryPath: (DirectorySort,[FileEntry])] = [:]
    private var tagCache:[String:(Date,FinderTagState)]=[:]
    private var cacheRevision=0
    private var closed = false
    private init(manager: SMB2Manager) {
        self.manager = manager
        self.mediaReader = SMBMediaReader(transport: AMSMBRangeTransport(manager: manager))
    }

    public static func connect(input: ConnectionInput, password: String) async throws -> SMBDirectoryProvider {
        guard input.isValid else { throw URLError(.badURL) }
        var url = URLComponents()
        url.scheme = "smb"
        url.host = input.server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = url.url,
              let manager = SMB2Manager(url: endpoint, credential: URLCredential(user: input.username, password: password, persistence: .none)) else {
            throw URLError(.badURL)
        }
        manager.timeout = 15
        do {
            // Preserve library negotiation/signing and server-required encryption.
            try await manager.connectShare(name: input.share.trimmingCharacters(in: .whitespacesAndNewlines))
            try Task.checkCancellation()
            return SMBDirectoryProvider(manager: manager)
        } catch {
            try? await manager.disconnectShare()
            throw URLError(.cannotConnectToHost)
        }
    }

    public func page(at path: DirectoryPath, offset: Int) async throws -> DirectoryPage {
        try await page(at:path,offset:offset,sort:DirectorySort())
    }
    public func page(at path: DirectoryPath, offset: Int, sort: DirectorySort) async throws -> DirectoryPage {
        guard !closed else { throw URLError(.networkConnectionLost) }
        if cache[path] == nil {
            let revision=cacheRevision
            let entries: [FileEntry] = try await withCheckedThrowingContinuation { continuation in
                manager.contentsOfDirectory(atPath: path.components.joined(separator: "/")) { result in
                    switch result {
                    case .failure: continuation.resume(throwing: URLError(.cannotLoadFromNetwork))
                    case .success(let items):
                        let mapped = items.compactMap(Self.visibleEntry).sorted {
                            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
                            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        }
                        continuation.resume(returning: mapped)
                    }
                }
            }
            try Task.checkCancellation()
            guard !closed,revision==cacheRevision else { throw CancellationError() }
            // Bound transport cache; the UI owns its visited-directory snapshots.
            if cache.count >= 8 { cache.removeAll();orderedCache.removeAll() }
            cache[path] = entries
        }
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
        guard !closed,path.components.allSatisfy(SavedLocations.validComponent) else {throw URLError(.networkConnectionLost)}
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
        let manager=self.manager
        return await Self.readTagMetadata {
            // One bounded named-stream operation; no base-file existence query.
            let stream:AsyncThrowingStream<Data,any Error>=manager.contents(atPath:path+":com.apple.metadata\u{F022}_kMDItemUserTags",range:0..<(FinderTagParser.limit+1))
            var data=Data()
            for try await part in stream {
                guard data.count+part.count<=FinderTagParser.limit+1 else {return Data(repeating:0,count:FinderTagParser.limit+1)}
                data.append(part)
            }
            return data
        }
    }
    nonisolated static func readTagMetadata(_ read:@Sendable () async throws ->Data) async ->FinderTagState {
        do {return FinderTagParser.parse(try await read())}
        catch {return tagFailure(error)}
    }
    /// At most three already-listed entries; no directory enumeration or recursion.
    public func hasFinderEvidence(paths:[String]) async throws ->Bool {
        try await Self.probeFinderEvidence(paths:paths,readTags:{path in
            try await SMBTagAdmission.shared.read {await self.readTags(path:path)}
        },readInfo:{path in
            let result=try await SMBTagAdmission.shared.read {
                let valid=await self.readFinderInfo(path:path)
                return valid ? .loaded([FinderTag(name:"evidence",color:0)]):.unavailable
            }
            return TagSupportEvidence.tags(result)
        })
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
        do {
            let stream:AsyncThrowingStream<Data,any Error>=manager.contents(atPath:path+":AFP_AfpInfo",range:0..<61)
            var data=Data()
            for try await part in stream {
                guard data.count+part.count<=61 else{return false}
                data.append(part)
            }
            return TagSupportEvidence.finderInfo(data)
        } catch {return false}
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
            let e=error as NSError
            guard e.domain==NSPOSIXErrorDomain else{return .failed}
            switch e.code {
            case Int(EACCES),Int(EPERM):return .denied
            case Int(ENOTSUP):return .unsupported
            case Int(ENOENT),Int(ENODATA):return .unavailable
            default:return .failed
            }
    }

    public func fileSize(for file: MediaFile) async throws -> UInt64 { try await mediaReader.fileSize(for: file) }
    public func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data { try await mediaReader.read(file, range: range) }

    public func disconnect() async {
        closed = true; cache.removeAll();orderedCache.removeAll();tagCache.removeAll()
        await mediaReader.close()
        try? await manager.disconnectShare()
    }
}

/// Process-wide admission avoids accumulating non-interruptible library RPCs after UI cancellation.
public actor SMBShareEnumerator {
    public static let shared=SMBShareEnumerator()
    private var busy=false
    public func shares(server:String,username:String,password:String) async throws -> [String] {
        guard !busy else {throw URLError(.resourceUnavailable)}
        try Task.checkCancellation()
        guard ConnectionInput(server:server,share:"placeholder",username:username).isValid else {throw URLError(.badURL)}
        busy=true;defer{busy=false}
        var url=URLComponents();url.scheme="smb";url.host=server.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let endpoint=url.url,let manager=SMB2Manager(url:endpoint,credential:URLCredential(user:username,password:password,persistence:.none)) else {throw URLError(.badURL)}
        manager.timeout=15
        do {
            let shares=try await manager.listShares(enumerateHidden:false)
            try? await manager.disconnectShare()
            try Task.checkCancellation()
            return Array(Set(shares.map(\.name).filter {SavedLocations.validComponent($0) && !$0.hasPrefix(".") && !$0.hasSuffix("$")})).sorted {$0.localizedStandardCompare($1) == .orderedAscending}.prefix(200).map{$0}
        } catch {
            try? await manager.disconnectShare()
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
