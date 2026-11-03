import Foundation
import Testing
@testable import VistaCore
@testable import VistaSMB

struct HiddenEntriesTests {
    @Test func smbMetadataFiltersHiddenFilesAndDirectories() {
        for type in [URLFileResourceType.directory, .regular] {
            for name in [".DS_Store", ".DS_STORE", ".cache", "._movie.mp4"] {
                #expect(SMBDirectoryProvider.visibleEntry([.nameKey: name, .fileResourceTypeKey: type]) == nil)
            }
            #expect(SMBDirectoryProvider.visibleEntry([.nameKey: "ordinary", .fileResourceTypeKey: type, .isHiddenKey: true]) == nil)
            #expect(SMBDirectoryProvider.visibleEntry([.nameKey: "ordinary", .fileResourceTypeKey: type, .isHiddenKey: NSNumber(value: true)]) == nil)
        }
    }
    @Test func missingAttributesDoNotHideOrdinaryEntries() {
        for name in ["movie.v2.mp4", "DS_Store", "normal.folder", "影片.mkv"] {
            let missing = SMBDirectoryProvider.visibleEntry([.nameKey: name, .fileResourceTypeKey: URLFileResourceType.regular])
            #expect(missing?.name == name)
            #expect(missing?.hiddenAttribute == nil)
            let visible = SMBDirectoryProvider.visibleEntry([.nameKey: name, .fileResourceTypeKey: URLFileResourceType.regular, .isHiddenKey: false])
            #expect(visible?.name == name)
            #expect(visible?.hiddenAttribute == false)
        }
        #expect(SMBDirectoryProvider.visibleEntry([.nameKey: ".folder", .fileResourceTypeKey: URLFileResourceType.directory, .isHiddenKey: false]) == nil)
    }
    @MainActor @Test func browserFiltersAnyProviderWithoutLosingNextPage() async throws {
        let model = BrowserModel(provider: HiddenPageProvider())
        model.start()
        try await settle(model)
        #expect(model.state(at: model.current).entries.isEmpty)
        #expect(model.state(at: model.current).nextOffset == 2)
        model.select(FileEntry(".folder", .directory), in: model.current)
        #expect(model.current == DirectoryPath())
        model.loadMore()
        try await settle(model)
        #expect(model.state(at: model.current).entries.map(\.name) == ["visible.mp4", "visible.folder"])
        #expect(model.state(at: model.current).nextOffset == nil)
    }
    @MainActor private func settle(_ model: BrowserModel) async throws {
        for _ in 0..<100 {
            if !model.state(at: model.current).isLoading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Listing did not settle")
    }
}
private struct HiddenPageProvider: DirectoryProvider {
    func page(at path: DirectoryPath, offset: Int) async throws -> DirectoryPage {
        if offset == 0 {
            return DirectoryPage(entries: [FileEntry(".folder", .directory), FileEntry("hidden.mp4", .video, hiddenAttribute: true)], nextOffset: 2)
        }
        return DirectoryPage(entries: [FileEntry("visible.mp4", .video), FileEntry("visible.folder", .directory)])
    }
}
