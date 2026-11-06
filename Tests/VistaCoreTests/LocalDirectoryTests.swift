import Foundation
import Testing
@testable import VistaCore

struct LocalDirectoryTests {
    @Test func realFilesPagingSortingRefreshAndBoundedRead() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Child"),withIntermediateDirectories:true)
        try Data([1,2,3,4]).write(to:root.appendingPathComponent("movie.mp4"))
        try Data().write(to:root.appendingPathComponent(".DS_Store"))
        for n in 0..<520 {try Data().write(to:root.appendingPathComponent(String(format:"file-%04d.txt",n)))}
        let provider=LocalDirectoryProvider(testRoot:root)
        var offset=0, names:[String]=[]
        repeat {
            let page=try await provider.page(at:.init(),offset:offset)
            #expect(page.entries.count<=250)
            names += page.entries.map(\.name)
            guard let next=page.nextOffset else {break};offset=next
        } while true
        #expect(names.count==522 && Set(names).count==522)
        #expect(!names.contains(".DS_Store"))
        let file=try MediaFile(components:["movie.mp4"])
        #expect(try await provider.fileSize(for:file)==4)
        #expect(try await provider.read(file,range:1..<3)==Data([2,3]))
        await #expect(throws:(any Error).self) {try await provider.read(file,range:0..<5)}
        await #expect(throws:(any Error).self) {try await provider.read(file,range:0..<1_048_577)}
        #expect(try await provider.page(at:.init(["Child"]),offset:0).entries.isEmpty)
        try FileManager.default.removeItem(at:root.appendingPathComponent("movie.mp4"))
        await provider.invalidate()
        let sorted=try await provider.page(at:.init(),offset:0,sort:.init(field:.size,ascending:false))
        #expect(!sorted.entries.contains{$0.name=="movie.mp4"})
    }
    @Test func traversalSymlinksAndDeletedFoldersFail() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:root.deletingLastPathComponent())
        let provider=LocalDirectoryProvider(testRoot:root)
        #expect(try await provider.page(at:.init(),offset:0).entries.isEmpty)
        await #expect(throws:(any Error).self) {try await provider.page(at:.init([".."]),offset:0)}
        await #expect(throws:(any Error).self) {try await provider.page(at:.init(["link"]),offset:0)}
        try FileManager.default.removeItem(at:root)
        await provider.invalidate()
        await #expect(throws:(any Error).self) {try await provider.page(at:.init(),offset:0)}
    }
    @Test func normalMigrationRemovesOnlyDemoSourcesAndShortcuts() throws {
        var value=SavedLocations.emptyPrototype
        let demo=value.sources[0].id
        var local=SavedSource(kind:.local,name:"Selected")
        local.localBookmark=Data([1,2,3])
        let smb=SavedSource(kind:.smb,name:"NAS",server:"nas.example.test",username:"test")
        value.sources += [local,smb]
        value.shortcuts=[.init(sourceID:demo,components:["影片"],name:"Demo"),.init(sourceID:local.id,components:[],name:"Root"),.init(sourceID:smb.id,components:["Videos"],name:"Remote")]
        value.lastShortcutID=value.shortcuts[0].id
        let clean=value.removingDemos()
        #expect(clean.sources == [local,smb]);#expect(clean.shortcuts.count==2);#expect(clean.lastShortcutID==nil)
        #expect(try clean.validated()==clean)
        #expect(clean.migratedHosts().shortcuts[0].components.isEmpty)
        let removed=try clean.removingSource(local.id,includingShortcutIDs:[clean.shortcuts[0].id])
        #expect(removed.sources==[smb]);#expect(removed.shortcuts.count==1)
        awaitInvalidBookmark()
    }
    private func awaitInvalidBookmark() {
        #expect(throws:(any Error).self) {try LocalDirectoryProvider(bookmark:Data([1,2,3]))}
    }
    @Test func newStoreIsEmptyAndLocalBookmarkRoundTrips() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=SavedLocationStore(url:root.appendingPathComponent("settings.json"))
        #expect(try store.load() == .empty)
        var source=SavedSource(kind:.local,name:"Selected")
        source.localBookmark=Data([1,2,3])
        let saved=SavedLocations(sources:[source]);try store.save(saved)
        #expect(try store.load()==saved)
    }
}
