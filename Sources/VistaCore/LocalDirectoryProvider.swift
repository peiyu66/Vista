import Foundation
import Darwin

public enum LocalFolderFailure: Error { case permission, staleBookmark, invalidPath, unavailable, tooManyItems }

/// Read-only, nonrecursive pages and bounded media reads inside a user-selected folder.
public actor LocalDirectoryProvider: DirectoryProvider, MediaByteSource {
    private let root: URL
    private let requiresScope: Bool
    private var cachedPath: DirectoryPath?
    private var cachedEntries: [FileEntry] = []
    public init(bookmark: Data) throws {
        var stale = false
        root = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, root.isFileURL else { throw LocalFolderFailure.staleBookmark }
        requiresScope = true
    }
    // Internal seam for synthetic filesystem tests; production uses bookmark init.
    init(testRoot: URL) { root = testRoot; requiresScope = false }
    private static func isAppContainer(_ url:URL)->Bool {
        #if os(visionOS) || os(iOS)
        return url.standardizedFileURL.path.hasPrefix(URL(fileURLWithPath:NSHomeDirectory()).standardizedFileURL.path + "/")
        #else
        return false
        #endif
    }
    public static func displayName(for url:URL)->String {
        let accessed=url.startAccessingSecurityScopedResource()
        defer {if accessed {url.stopAccessingSecurityScopedResource()}}
        let values=try? url.resourceValues(forKeys:[.localizedNameKey,.nameKey])
        return LocalDirectoryName.select(localized:values?.localizedName,resourceName:values?.name,pathComponent:url.lastPathComponent)
    }
    public func displayName(at path:DirectoryPath)throws->String {
        try access(path.components) {Self.displayName(for:$0)}
    }
    public static func bookmark(for url: URL) throws -> Data {
        let accessed=url.startAccessingSecurityScopedResource()
        guard url.isFileURL,accessed || isAppContainer(url) else { throw LocalFolderFailure.permission }
        defer { if accessed {url.stopAccessingSecurityScopedResource()} }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw LocalFolderFailure.invalidPath }
        return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    private func access<T>(_ components: [String], options: NSFileCoordinator.ReadingOptions = [], _ read: (URL) throws -> T) throws -> T {
        guard components.allSatisfy(SavedLocations.validComponent) else { throw LocalFolderFailure.invalidPath }
        let accessed = root.startAccessingSecurityScopedResource()
        guard accessed || !requiresScope || Self.isAppContainer(root) else { throw LocalFolderFailure.permission }
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }
        var url = root
        for component in components {
            url.appendPathComponent(component)
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LocalFolderFailure.invalidPath }
        }
        var failure: NSError?
        var outcome: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: options, error: &failure) { coordinated in
            outcome = Result { try read(coordinated) }
        }
        if let failure { throw failure }
        guard let outcome else { throw LocalFolderFailure.unavailable }
        return try outcome.get()
    }
    #if VISTA_LOCAL_MKV_CANDIDATE
    // MKV operation owner; original URL/scope/path/coordinator policy remains.
    func openMKVOperationSource(for file: MediaFile, playbackID: UUID = UUID(), journal: AdapterJournal = AdapterJournal()) throws -> LocalOperationSource {
        let retainedScope = root.startAccessingSecurityScopedResource()
        guard retainedScope || !requiresScope || Self.isAppContainer(root) else { throw LocalFolderFailure.permission }
        let scopeLease = LocalSecurityScopeLease(root: root, acquired: retainedScope)
        do {
            return try access(file.components) { url in
                try LocalOperationSource.adoptCoordinatedURL(url, file: file, playbackID: playbackID, scopeLease: scopeLease, journal: journal)
            }
        } catch { scopeLease.release(); throw error }
    }
    #endif
    public func invalidate() { cachedPath = nil; cachedEntries = [] }
    /// Best-effort Finder-compatible metadata. Missing xattrs do not prove Files has no tags.
    /// Metadata-only coordination must not download movie contents just to discover tags.
    public func tags(at path: DirectoryPath) async throws -> FinderTagState {
        try Task.checkCancellation()
        let state: FinderTagState
        do {
            state = try access(path.components, options: .immediatelyAvailableMetadataOnly) {
                LocalFinderTagReader.read($0)
            }
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            if case LocalFolderFailure.permission = error { return .denied }
            let failure = error as NSError
            if failure.domain == NSPOSIXErrorDomain { return LocalFinderTagReader.failure(Int32(failure.code)) }
            if failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoPermissionError { return .denied }
            return .failed
        }
        try Task.checkCancellation()
        return state
    }
    /// Inspect one displayed page, never recurse or infer support merely from platform identity.
    public func hasFinderTagEvidence(at path: DirectoryPath, names: [String], includeDirectory: Bool) async throws -> Bool {
        if includeDirectory, try await tags(at: path).isConfirmed { return true }
        for name in names.prefix(250) {
            try Task.checkCancellation()
            guard SavedLocations.validComponent(name) else { continue }
            if try await tags(at: DirectoryPath(path.components + [name])).isConfirmed { return true }
        }
        return false
    }
    public func page(at path:DirectoryPath,offset:Int) async throws -> DirectoryPage {try await page(at:path,offset:offset,sort:.init())}
    public func page(at path: DirectoryPath, offset: Int, sort: DirectorySort) async throws -> DirectoryPage {
        try Task.checkCancellation()
        if cachedPath != path {
            let items = try access(path.components) { directory in
                guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw LocalFolderFailure.invalidPath }
                let keys: Set<URLResourceKey> = [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.isHiddenKey,.contentModificationDateKey,.creationDateKey,.fileSizeKey]
                var enumerationError:Error?
                guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsSubdirectoryDescendants,.skipsHiddenFiles,.skipsPackageDescendants], errorHandler:{_,error in enumerationError=error;return false}) else { throw LocalFolderFailure.unavailable }
                var entries: [FileEntry] = []
                var scannedCount = 0
                for case let url as URL in iterator {
                    try Task.checkCancellation()
                    guard scannedCount < 100_000 else { throw LocalFolderFailure.tooManyItems }
                    scannedCount += 1
                    let value = try url.resourceValues(forKeys: keys)
                    guard value.isSymbolicLink != true, value.isHidden != true, !url.lastPathComponent.hasPrefix("."),
                          SavedLocations.validComponent(url.lastPathComponent), value.isDirectory == true || value.isRegularFile == true else { continue }
                    let kind: FileEntry.Kind = value.isDirectory == true ? .directory : ["mp4","m4v","mov","mkv"].contains(url.pathExtension.lowercased()) ? .video : .other
                    let entry = FileEntry(url.lastPathComponent,kind,hiddenAttribute:value.isHidden,modifiedAt:value.contentModificationDate,byteSize:kind == .directory ? nil:value.fileSize.map(Int64.init),createdAt:value.creationDate)
                    if entry.isBrowserVisible { entries.append(entry) }
                }
                if let enumerationError {throw enumerationError}
                return entries
            }
            try Task.checkCancellation()
            cachedPath = path; cachedEntries = items
        }
        let sorted = sort.sorted(cachedEntries)
        guard offset >= 0, offset <= sorted.count else { throw LocalFolderFailure.invalidPath }
        let end = min(offset + 250, sorted.count)
        return DirectoryPage(entries:Array(sorted[offset..<end]),nextOffset:end < sorted.count ? end:nil)
    }
    public func fileSize(for file: MediaFile) async throws -> UInt64 {
        try Task.checkCancellation()
        return try access(file.components) { url in
            let value = try url.resourceValues(forKeys: [.isRegularFileKey,.fileSizeKey])
            guard value.isRegularFile == true, let size=value.fileSize, size >= 0 else { throw LocalFolderFailure.unavailable }
            return UInt64(size)
        }
    }
    public func read(_ file: MediaFile, range: Range<UInt64>) async throws -> Data {
        try Task.checkCancellation()
        guard range.count <= Int(MediaReadPlan.maximumChunkBytes), range.upperBound <= Int64.max else { throw LocalFolderFailure.invalidPath }
        return try access(file.components) { url in
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw LocalFolderFailure.invalidPath }
            let handle=try FileHandle(forReadingFrom:url);defer {try? handle.close()}
            try handle.seek(toOffset:range.lowerBound)
            let data=try handle.read(upToCount:Int(range.count)) ?? Data()
            guard data.count == range.count else { throw LocalFolderFailure.unavailable }
            try Task.checkCancellation()
            return data
        }
    }
}

/// A single bounded syscall avoids a size-query/read race and unbounded allocation.
/// XATTR_NOFOLLOW prevents following a final-component symlink; access() rejects path symlinks.
enum LocalFinderTagReader {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"
    static func read(_ url: URL) -> FinderTagState {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return .failed }
            var bytes = Data(count: FinderTagParser.limit + 1)
            let (count, code) = bytes.withUnsafeMutableBytes { buffer in
                let count = getxattr(path, attribute, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
                return (count, count < 0 ? errno : 0)
            }
            guard count >= 0 else { return failure(code) }
            bytes.count = count
            return FinderTagParser.parse(bytes)
        }
    }
    static func failure(_ code: Int32) -> FinderTagState {
        switch code {
        case ENOATTR: return .unavailable
        case ENOTSUP: return .unsupported
        case EACCES, EPERM: return .denied
        case ERANGE: return .invalid
        default: return .failed
        }
    }
}

/// Display-only resolution. Never changes bookmark identity or path components.
public enum LocalDirectoryName {
    public static func select(localized:String?,resourceName:String?,pathComponent:String)->String {
        for value in [localized,resourceName,pathComponent].compactMap({$0}) {
            if SavedLocations.validName(value) {return value.trimmingCharacters(in:.whitespacesAndNewlines)}
        }
        return "資料夾"
    }
}
