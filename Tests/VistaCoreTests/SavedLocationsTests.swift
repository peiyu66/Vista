import Foundation
import Testing
@testable import VistaCore
struct SavedLocationsTests {
    @Test func sourceRemovalRequiresExactReviewedShortcutsAndPreservesOthers() throws {
        let host=SavedSource(kind:.smb,name:"Host",server:"host.example.test",username:"viewer")
        let other=SavedSource(kind:.smb,name:"Other",server:"other.example.test",username:"viewer")
        var value=SavedLocations(sources:[host,other])
        let a=FolderShortcut(sourceID:host.id,components:["Videos"],name:"Root")
        let b=FolderShortcut(sourceID:host.id,components:["Videos","Movies"],name:"Movies")
        let c=FolderShortcut(sourceID:other.id,components:["Movies"],name:"Movies")
        value.shortcuts=[a,b,c];value.lastShortcutID=b.id
        let original=value
        #expect(throws:SavedLocationError.self){try value.removingSource(host.id,includingShortcutIDs:[a.id])}
        #expect(throws:SavedLocationError.self){try value.removingSource(host.id,includingShortcutIDs:[a.id,b.id,c.id])}
        #expect(value==original)
        let removed=try value.removingSource(host.id,includingShortcutIDs:[a.id,b.id])
        #expect(removed.sources==[other]);#expect(removed.shortcuts==[c]);#expect(removed.lastShortcutID==nil)
        #expect(value==original)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=SavedLocationStore(url:root.appendingPathComponent("settings.json"))
        try store.save(removed);#expect(try store.load()==removed)
        let empty=SavedLocations(sources:[host,other])
        #expect(try empty.removingSource(host.id,includingShortcutIDs:[]).sources==[other])
    }
    @Test func legacySharesMigrateOnceWithoutMergingAccountsOrLosingRootShortcuts() throws {
        let a=SavedSource(kind:.smb,name:"Old",server:"nas.example.test",share:"Videos",username:"first")
        let b=SavedSource(kind:.smb,name:"Other",server:"nas.example.test",share:"Movies",username:"second")
        var value=SavedLocations(sources:[a,b])
        let root=FolderShortcut(sourceID:a.id,components:[],name:"Videos")
        let nested=FolderShortcut(sourceID:b.id,components:["A"],name:"A")
        value.shortcuts=[root,nested];value.lastShortcutID=root.id
        let migrated=value.migratedHosts()
        #expect(migrated.shortcuts[0].components==["Videos"])
        #expect(migrated.shortcuts[1].components==["Movies","A"])
        #expect(migrated.shortcuts.map(\.id)==[root.id,nested.id])
        #expect(migrated.sources.map(\.id)==[a.id,b.id])
        #expect(migrated.lastShortcutID==root.id)
        #expect(migrated.migratedHosts()==migrated)
        #expect(try migrated.validated()==migrated)
    }
    @Test func credentialReferenceMigratesWithoutChangingShortcutIdentity() throws {
        var value=SavedLocations.emptyPrototype
        let source=SavedSource(kind:.smb,name:"NAS",server:"nas.example.test",share:"Videos",username:"old-user")
        value.sources.append(source)
        let shortcut=FolderShortcut(sourceID:source.id,components:["Movies"],name:"Movies")
        value.shortcuts=[shortcut]
        let legacy=try JSONEncoder().encode(value)
        var loaded=try JSONDecoder().decode(SavedLocations.self,from:legacy)
        #expect(loaded.sources.last?.credentialID == nil)
        let reference=UUID()
        loaded.sources[2].credentialID=reference;loaded.sources[2].username="new-user"
        let updated=try JSONDecoder().decode(SavedLocations.self,from:JSONEncoder().encode(loaded))
        #expect(updated.sources.last?.credentialID == reference)
        #expect(updated.shortcuts == [shortcut])
        #expect(updated.sources.last?.id == source.id)
        #expect(try updated.validated()==updated)
    }
    @Test func dragReorderPreservesIdentityAndIgnoresUnknownTargets() throws {
        var value=SavedLocations.emptyPrototype
        let id=value.sources[0].id
        let a=FolderShortcut(sourceID:id,components:["A"],name:"A")
        let b=FolderShortcut(sourceID:id,components:["B"],name:"B")
        let c=FolderShortcut(sourceID:id,components:["C"],name:"C")
        value.shortcuts=[a,b,c];value.lastShortcutID=b.id
        value.reorderShortcut(c.id,to:a.id)
        #expect(value.shortcuts == [c,a,b])
        value.reorderShortcut(c.id,to:b.id)
        #expect(value.shortcuts == [a,b,c])
        value.reorderShortcut(a.id,to:UUID())
        #expect(value.shortcuts == [a,b,c])
        #expect(value.lastShortcutID == b.id)
    }
    @Test func savesSourceAndShortcutWithoutCredentialFields() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=SavedLocationStore(url:root.appendingPathComponent("settings.json"))
        var value=SavedLocations.emptyPrototype
        let source=SavedSource(kind:.smb,name:"Test NAS",server:"nas.example.test",share:"Videos",username:"synthetic-viewer")
        value.sources.append(source)
        value.shortcuts=[FolderShortcut(sourceID:source.id,components:["Movies"],name:"Cinema")]
        value.lastShortcutID=value.shortcuts[0].id
        try store.save(value)
        #expect(try store.load()==value.migratedHosts())
        let object=try JSONSerialization.jsonObject(with:Data(contentsOf:store.url)) as! [String:Any]
        let sources=object["sources"] as! [[String:Any]]
        #expect(sources.allSatisfy {!$0.keys.contains("password") && !$0.keys.contains("credential")})
    }
    @Test func moveRenameRemoveAffectsOnlyShortcutRecords() throws {
        var value=SavedLocations.emptyPrototype
        let id=value.sources[0].id
        value.shortcuts=[FolderShortcut(sourceID:id,components:["A"],name:"A"),FolderShortcut(sourceID:id,components:["B"],name:"B")]
        let originalSources=value.sources, first=value.shortcuts[0].id
        value.moveShortcut(first,by:-1);#expect(value.shortcuts[0].id==first)
        value.moveShortcut(first,by:1);#expect(value.shortcuts[1].id==first)
        value.shortcuts[1].name="Renamed";#expect(value.shortcuts[1].components==["A"])
        value.shortcuts.removeAll {$0.id==first};#expect(value.sources==originalSources)
        #expect(try value.validated()==value)
    }
    @Test func rejectsTraversalDuplicateIDsAndDanglingSources() throws {
        for path in [[".."],["x/y"],["x\\y"],["\u{0}"],[""]] {
            var value=SavedLocations.emptyPrototype
            value.shortcuts=[FolderShortcut(sourceID:value.sources[0].id,components:path,name:"Test")]
            #expect(throws:SavedLocationError.self){try value.validated()}
        }
        var value=SavedLocations.emptyPrototype
        value.sources.append(value.sources[0])
        #expect(throws:SavedLocationError.self){try value.validated()}
        value = .emptyPrototype
        value.shortcuts=[FolderShortcut(sourceID:UUID(),components:[],name:"Unknown")]
        #expect(throws:SavedLocationError.self){try value.validated()}
    }
    @Test func corruptDataIsNotSilentlyOverwritten() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=SavedLocationStore(url:root.appendingPathComponent("settings.json")), bytes=Data("invalid-json".utf8)
        try bytes.write(to:store.url)
        #expect(throws:(any Error).self){try store.load()}
        #expect(try Data(contentsOf:store.url)==bytes)
    }
}
