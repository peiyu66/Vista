import Testing
import Foundation
@testable import VistaCore

struct ImmediateProvider: DirectoryProvider {
    func page(at path: DirectoryPath, offset: Int) async throws -> DirectoryPage {
        if path.components.last == "失敗" { throw URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "password=DO_NOT_DISPLAY"]) }
        if path.components.last == "慢" { try? await Task.sleep(for: .milliseconds(150)) }
        if path.components.isEmpty {
            return DirectoryPage(entries: [FileEntry("影片", .directory), FileEntry("慢", .directory), FileEntry("失敗", .directory), FileEntry("大量", .directory)])
        }
        if path.components.last == "大量" {
            let end = min(offset + 100, 5000)
            return DirectoryPage(entries: (offset..<end).map { FileEntry("\($0).mp4", .video) }, nextOffset: end < 5000 ? end : nil)
        }
        return DirectoryPage(entries: [FileEntry("子層", .directory), FileEntry("movie.mp4", .video), FileEntry("../bad", .video), FileEntry("..", .directory), FileEntry("movie.mp4", .video)])
    }
}
@MainActor struct BrowserTests {
    func settled(_ model: BrowserModel) async throws {
        for _ in 0..<200 {
            if !model.state(at: model.current).isLoading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Listing did not settle")
    }
    @Test func rootDescendBackAndSibling() async throws {
        let m = BrowserModel(provider: ImmediateProvider()); m.start(); try await settled(m)
        m.back(); #expect(m.current == DirectoryPath())
        m.select(FileEntry("影片", .directory), in: m.current); try await settled(m)
        m.setScroll("movie.mp4", at: m.current)
        m.select(FileEntry("子層", .directory), in: m.current); try await settled(m)
        #expect(m.current == DirectoryPath(["影片", "子層"]))
        m.back(); #expect(m.current == DirectoryPath(["影片"]))
        #expect(m.state(at: m.current).scrollID == "movie.mp4")
        #expect(m.state(at: m.current).selectedID == "子層")
        m.select(FileEntry("大量", .directory), in: DirectoryPath()); try await settled(m)
        #expect(m.current == DirectoryPath(["大量"]))
        m.stop()
    }
    @Test func lateResponseDoesNotReplaceCurrent() async throws {
        let m = BrowserModel(provider: ImmediateProvider()); m.start(); try await settled(m)
        m.select(FileEntry("慢", .directory), in: m.current)
        m.back()
        m.select(FileEntry("影片", .directory), in: m.current); try await settled(m)
        try await Task.sleep(for: .milliseconds(200))
        #expect(m.current == DirectoryPath(["影片"]))
        #expect(m.state(at: DirectoryPath(["慢"])).entries.isEmpty)
        #expect(!m.state(at: DirectoryPath(["慢"])).isLoading)
    }
    @Test func sanitizedErrorRetryAndRecovery() async throws {
        let m = BrowserModel(provider: ImmediateProvider()); m.start(); try await settled(m)
        m.select(FileEntry("失敗", .directory), in: m.current); try await settled(m)
        #expect(m.state(at: m.current).error != nil)
        #expect(m.state(at: m.current).error?.contains("DO_NOT_DISPLAY") == false)
        m.loadMore(); try await settled(m)
        #expect(!m.state(at: m.current).isLoading)
        m.back(); #expect(m.state(at: m.current).error == nil)
    }
    @Test func fiveThousandEntriesArePagedAndUnique() async throws {
        let m = BrowserModel(provider: ImmediateProvider()); m.start(); try await settled(m)
        m.select(FileEntry("大量", .directory), in: m.current); try await settled(m)
        #expect(m.state(at: m.current).entries.count == 100)
        for _ in 1..<50 { m.loadMore(); m.loadMore(); try await settled(m) }
        #expect(m.state(at: m.current).entries.count == 5000)
        #expect(Set(m.state(at: m.current).entries.map(\.id)).count == 5000)
        #expect(m.state(at: m.current).nextOffset == nil)
    }
    @Test func playbackPreservesNavigationAndRejectsTraversal() async throws {
        let m = BrowserModel(provider: ImmediateProvider()); m.start(); try await settled(m)
        m.select(FileEntry("影片", .directory), in: m.current); try await settled(m)
        #expect(m.state(at: m.current).entries.count == 2)
        m.select(FileEntry("movie.mp4", .video), in: m.current)
        #expect(m.playback?.directory == m.current)
        m.playback = nil
        #expect(m.current == DirectoryPath(["影片"]))
        #expect(m.state(at: m.current).selectedID == "movie.mp4")
    }
    @Test func connectionRejectsEmbeddedSecrets() {
        #expect(ConnectionInput(server: "nas.example.test", share: "Videos", username: "viewer").isValid)
        for host in ["", "smb://example.test", "user:secret@example.test", "example.test/path", "example.test?secret"] {
            #expect(!ConnectionInput(server: host, share: "Videos", username: "viewer").isValid)
        }
        #expect(!ConnectionInput(server: "nas.example.test", share: "..", username: "viewer").isValid)
    }
    @Test func emptyDemoDirectory() async throws {
        let page = try await DemoDirectoryProvider().page(at: DirectoryPath(["空資料夾"]), offset: 0)
        #expect(page.entries.isEmpty); #expect(page.nextOffset == nil)
    }
}
