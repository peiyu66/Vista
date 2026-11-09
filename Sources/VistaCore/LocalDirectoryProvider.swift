import Foundation

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
    private func access<T>(_ components: [String], _ read: (URL) throws -> T) throws -> T {
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
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &failure) { coordinated in
            outcome = Result { try read(coordinated) }
        }
        if let failure { throw failure }
        guard let outcome else { throw LocalFolderFailure.unavailable }
        return try outcome.get()
    }
    public func invalidate() { cachedPath = nil; cachedEntries = [] }
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
                for case let url as URL in iterator {
                    try Task.checkCancellation()
                    guard entries.count < 100_000 else { throw LocalFolderFailure.tooManyItems }
                    let value = try url.resourceValues(forKeys: keys)
                    guard value.isSymbolicLink != true, value.isHidden != true, !url.lastPathComponent.hasPrefix("."),
                          SavedLocations.validComponent(url.lastPathComponent), value.isDirectory == true || value.isRegularFile == true else { continue }
                    let kind: FileEntry.Kind = value.isDirectory == true ? .directory : ["mp4","m4v","mov","mkv"].contains(url.pathExtension.lowercased()) ? .video : .other
                    entries.append(FileEntry(url.lastPathComponent,kind,hiddenAttribute:value.isHidden,modifiedAt:value.contentModificationDate,byteSize:kind == .directory ? nil:value.fileSize.map(Int64.init),createdAt:value.creationDate))
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

/// Display-only resolution. Never changes bookmark identity or path components.
public enum LocalDirectoryName {
    public static func select(localized:String?,resourceName:String?,pathComponent:String)->String {
        for value in [localized,resourceName,pathComponent].compactMap({$0}) {
            if SavedLocations.validName(value) {return value.trimmingCharacters(in:.whitespacesAndNewlines)}
        }
        return "資料夾"
    }
}
