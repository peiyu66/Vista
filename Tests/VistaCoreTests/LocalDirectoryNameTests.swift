import Foundation
import Testing
@testable import VistaCore
struct LocalDirectoryNameTests {
    @Test func providerAliasUsesDisplayNameWithoutChangingPath() {
        #expect(LocalDirectoryName.select(localized:"我的影片",resourceName:"document",pathComponent:"document")=="我的影片")
        #expect(LocalDirectoryName.select(localized:" ",resourceName:"子資料夾",pathComponent:"opaque")=="子資料夾")
        #expect(LocalDirectoryName.select(localized:nil,resourceName:nil,pathComponent:"原名稱")=="原名稱")
    }
    @Test func savedManualNamesSurviveRoundTrip() throws {
        var source=SavedSource(kind:.local,name:"我的影片");source.localBookmark=Data([1,2,3])
        var saved=SavedLocations(sources:[source])
        saved.shortcuts=[FolderShortcut(sourceID:source.id,components:[],name:"手動名稱"),FolderShortcut(sourceID:source.id,components:["document"],name:"保留舊名")]
        let restored=try JSONDecoder().decode(SavedLocations.self,from:JSONEncoder().encode(saved))
        #expect(restored==saved && restored.sources[0].localBookmark==source.localBookmark)
        #expect(restored.shortcuts[1].components==["document"])
    }
    @Test func rootAndChildNameLookupAndMissingFolder() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Child"),withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let provider=LocalDirectoryProvider(testRoot:root)
        #expect(try await provider.displayName(at:.init())==root.lastPathComponent)
        #expect(try await provider.displayName(at:.init(["Child"]))=="Child")
        await #expect(throws:(any Error).self) {try await provider.displayName(at:.init(["Missing"]))}
    }
}
