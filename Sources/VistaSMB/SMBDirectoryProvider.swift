import Foundation
import AMSMB2
#if SWIFT_PACKAGE
import VistaCore
#endif

/// Owns one authenticated session. Never encode, log or persist the manager or credentials.
public actor SMBDirectoryProvider: DirectoryProvider {
    private let manager: SMB2Manager
    private var cache: [DirectoryPath: [FileEntry]] = [:]
    private var closed = false
    private init(manager: SMB2Manager) { self.manager = manager }

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
        guard !closed else { throw URLError(.networkConnectionLost) }
        if cache[path] == nil {
            let entries: [FileEntry] = try await withCheckedThrowingContinuation { continuation in
                manager.contentsOfDirectory(atPath: path.components.joined(separator: "/")) { result in
                    switch result {
                    case .failure: continuation.resume(throwing: URLError(.cannotLoadFromNetwork))
                    case .success(let items):
                        let mapped = items.compactMap { item -> FileEntry? in
                            guard let name = item[.nameKey] as? String,
                                  let type = item[.fileResourceTypeKey] as? URLFileResourceType else { return nil }
                            if type == .directory { return FileEntry(name, .directory) }
                            let ext = (name as NSString).pathExtension.lowercased()
                            return FileEntry(name, ["mp4", "mkv", "mov", "m4v"].contains(ext) ? .video : .other)
                        }.sorted {
                            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
                            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        }
                        continuation.resume(returning: mapped)
                    }
                }
            }
            try Task.checkCancellation()
            guard !closed else { throw URLError(.networkConnectionLost) }
            // Bound transport cache; the UI owns its visited-directory snapshots.
            if cache.count >= 8 { cache.removeAll() }
            cache[path] = entries
        }
        let entries = cache[path] ?? []
        guard offset >= 0, offset <= entries.count else { throw URLError(.badServerResponse) }
        let end = min(offset + 100, entries.count)
        return DirectoryPage(entries: Array(entries[offset..<end]), nextOffset: end < entries.count ? end : nil)
    }

    public func disconnect() async {
        closed = true; cache.removeAll()
        try? await manager.disconnectShare()
    }
}
