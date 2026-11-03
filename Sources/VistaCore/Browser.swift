import Foundation
import Observation

public struct DirectoryPath: Hashable, Sendable {
    public let components: [String]
    public init(_ components: [String] = []) { self.components = components }
    public var parent: DirectoryPath? { components.isEmpty ? nil : DirectoryPath(Array(components.dropLast())) }
    public var name: String { components.last ?? "分享根目錄" }
    public var display: String { "/" + components.joined(separator: "/") }
    public func appending(_ name: String) -> DirectoryPath { DirectoryPath(components + [name]) }
}

public struct FileEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case directory, video, other }
    public let name: String
    public let kind: Kind
    /// nil means the provider did not expose a hidden attribute.
    public let hiddenAttribute: Bool?
    public var isHidden: Bool { name.hasPrefix(".") || hiddenAttribute == true }
    public var id: String { name }
    public init(_ name: String, _ kind: Kind, hiddenAttribute: Bool? = nil) {
        self.name = name; self.kind = kind; self.hiddenAttribute = hiddenAttribute
    }
}

public struct DirectoryPage: Sendable {
    public let entries: [FileEntry]
    public let nextOffset: Int?
    public init(entries: [FileEntry], nextOffset: Int? = nil) { self.entries = entries; self.nextOffset = nextOffset }
}

/// A session-scoped, read-only listing boundary. Production SMB must preserve server security.
public protocol DirectoryProvider: Sendable {
    func page(at path: DirectoryPath, offset: Int) async throws -> DirectoryPage
}

public struct DirectoryState {
    public var entries: [FileEntry] = []
    public var nextOffset: Int? = 0
    public var isLoading = false
    public var error: String?
    public var scrollID: String?
    public var selectedID: String?
    public init() {}
}

public struct PlaybackSelection: Identifiable, Equatable {
    public let directory: DirectoryPath
    public let file: FileEntry
    public var id: String { directory.appending(file.name).display }
}

@MainActor @Observable public final class BrowserModel {
    public private(set) var current = DirectoryPath()
    public private(set) var directories: [DirectoryPath: DirectoryState] = [:]
    public var playback: PlaybackSelection?
    @ObservationIgnored private let provider: any DirectoryProvider
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    public init(provider: any DirectoryProvider) { self.provider = provider }
    public func state(at path: DirectoryPath) -> DirectoryState { directories[path] ?? DirectoryState() }
    public func start() { loadMore() }
    public func select(_ entry: FileEntry, in path: DirectoryPath) {
        guard path == current || path == current.parent,
              state(at: path).entries.contains(entry) else { return }
        directories[path, default: DirectoryState()].selectedID = entry.id
        switch entry.kind {
        case .directory: navigate(to: path.appending(entry.name))
        case .video: playback = PlaybackSelection(directory: path, file: entry)
        case .other: break
        }
    }
    public func back() { if let parent = current.parent { navigate(to: parent) } }
    public func setScroll(_ id: String?, at path: DirectoryPath) {
        directories[path, default: DirectoryState()].scrollID = id
    }
    public func stop() {
        generation += 1; request?.cancel(); request = nil
        for path in Array(directories.keys) { directories[path]?.isLoading = false }
    }
    private func navigate(to path: DirectoryPath) {
        guard path != current else { return }
        stop(); current = path
        if state(at: path).entries.isEmpty { loadMore() }
    }
    public func loadMore() {
        let path = current
        let state = state(at: path)
        guard !state.isLoading, let offset = state.nextOffset else { return }
        generation += 1
        let token = generation
        directories[path, default: DirectoryState()].isLoading = true
        directories[path]?.error = nil
        request = Task { [weak self, provider] in
            do {
                let page = try await provider.page(at: path, offset: offset)
                guard let self, !Task.isCancelled, token == self.generation, path == self.current else { return }
                // Reject malformed names, traversal and duplicate IDs at the provider boundary.
                let existing = Set(self.state(at: path).entries.map(\.id))
                var seen = existing
                let safe = page.entries.filter {
                    !$0.isHidden && !$0.name.isEmpty && $0.name != "." && $0.name != ".." &&
                    !$0.name.contains("/") && !$0.name.contains("\\") &&
                    !$0.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
                    seen.insert($0.id).inserted
                }
                self.directories[path]?.entries.append(contentsOf: safe)
                self.directories[path]?.nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
                self.directories[path]?.isLoading = false
            } catch {
                guard let self, token == self.generation, path == self.current else { return }
                self.directories[path]?.isLoading = false
                // Never expose a backend error: it may contain credentials or private URLs.
                self.directories[path]?.error = "無法讀取資料夾。請檢查連線或存取權限後重試。"
            }
        }
    }
}

public struct ConnectionInput: Sendable {
    public var server: String
    public var share: String
    public var username: String
    public init(server: String, share: String, username: String) {
        self.server = server; self.share = share; self.username = username
    }
    public var isValid: Bool {
        let host = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = share.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept host/IP only. Credentials, ports, paths and URL syntax belong in separate fields.
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "/\\@?#:"))
        return !host.isEmpty && host.rangeOfCharacter(from: forbidden) == nil &&
            !name.isEmpty && name != "." && name != ".." &&
            name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\").union(.controlCharacters)) == nil &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Entirely synthetic fixtures; no network requests or private media.
public struct DemoDirectoryProvider: DirectoryProvider {
    public init() {}
    public func page(at path: DirectoryPath, offset: Int) async throws -> DirectoryPage {
        try await Task.sleep(for: .milliseconds(120))
        if path.components.last == "讀取失敗範例" { throw URLError(.notConnectedToInternet) }
        if path.components.last == "大量影片" {
            let end = min(offset + 100, 5_000)
            return DirectoryPage(entries: (offset..<end).map { FileEntry(String(format: "影片 %04d.mp4", $0 + 1), .video) }, nextOffset: end < 5_000 ? end : nil)
        }
        let entries: [FileEntry]
        switch path.components {
        case []: entries = [FileEntry("影片", .directory), FileEntry("大量影片", .directory), FileEntry("空資料夾", .directory), FileEntry("讀取失敗範例", .directory)]
        case ["影片"]: entries = [FileEntry("電影", .directory), FileEntry("旅行", .directory)]
        case ["影片", "電影"]: entries = [FileEntry("科幻", .directory), FileEntry("紀錄片", .directory), FileEntry("預告片.mp4", .video)]
        case ["影片", "電影", "科幻"]: entries = [FileEntry("星際漫遊_SBS_180.mp4", .video), FileEntry("月球之旅.mkv", .video), FileEntry("影片說明.txt", .other)]
        case ["空資料夾"]: entries = []
        default: entries = [FileEntry("示範影片.mp4", .video)]
        }
        return DirectoryPage(entries: offset == 0 ? entries : [])
    }
}
