import Foundation

public struct SavedSource: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case smb, demoLocal, demoSMB }
    public var id: UUID
    public var kind: Kind
    public var name: String
    public var server: String
    public var share: String
    public var hostRoot: Bool?
    public var credentialID: UUID?
    public var tagPolicy:TagSupportPolicy?
    public var tagEvidenceEndpoint:String?
    public var providesFinderTags:Bool {
        isDemo || tagEvidenceEndpoint == TagSupportEvidence.endpoint(server)
    }
    public var username: String
    public init(id: UUID = UUID(), kind: Kind, name: String, server: String = "", share: String = "", username: String = "") {
        self.id=id; self.kind=kind; self.name=name; self.server=server; self.share=share; self.username=username; self.hostRoot=(kind != .demoLocal && share.isEmpty)
    }
    public var isDemo: Bool { kind != .smb }
}
public struct FolderShortcut: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var sourceID: UUID
    public var components: [String]
    public var name: String
    public init(id: UUID = UUID(), sourceID: UUID, components: [String], name: String) {
        self.id=id; self.sourceID=sourceID; self.components=components; self.name=name
    }
}
public struct SavedLocations: Codable, Equatable, Sendable {
    public var version = 1
    public var sources: [SavedSource]
    public var shortcuts: [FolderShortcut] = []
    public var lastShortcutID: UUID?
    public init(sources: [SavedSource]) { self.sources=sources }
    public static var emptyPrototype: Self {
        Self(sources: [SavedSource(kind: .demoLocal, name: "本機（示範）"), SavedSource(kind: .demoSMB, name: "範例 NAS（示範）", server: "nas.example.test", share: "")])
    }
    public func migratedHosts()->Self {
        var result=self
        for index in result.sources.indices {result.sources[index].tagPolicy=nil}
        for index in result.sources.indices where result.sources[index].kind != .demoLocal && result.sources[index].hostRoot != true {
            let id=result.sources[index].id,share=result.sources[index].share
            if !share.isEmpty {
                for shortcutIndex in result.shortcuts.indices where result.shortcuts[shortcutIndex].sourceID==id {
                    result.shortcuts[shortcutIndex].components.insert(share,at:0)
                }
            }
            result.sources[index].share="";result.sources[index].hostRoot=true
        }
        return result
    }
    public func validated() throws -> Self {
        guard version == 1, sources.count <= 100, shortcuts.count <= 1000,
              Set(sources.map(\.id)).count == sources.count,
              Set(shortcuts.map(\.id)).count == shortcuts.count else { throw SavedLocationError.invalid }
        let ids=Set(sources.map(\.id))
        for source in sources {
            guard (source.tagEvidenceEndpoint?.count ?? 0)<=253, Self.validName(source.name), source.username.count <= 256 else { throw SavedLocationError.invalid }
            if source.kind == .smb {
                guard ConnectionInput(server:source.server, share:source.hostRoot == true ? "placeholder":source.share, username:source.username).isValid else { throw SavedLocationError.invalid }
            }
        }
        for shortcut in shortcuts {
            guard ids.contains(shortcut.sourceID), Self.validName(shortcut.name), shortcut.components.count <= 129,
                  shortcut.components.allSatisfy(Self.validComponent) else { throw SavedLocationError.invalid }
        }
        return self
    }
    public static func validName(_ value: String) -> Bool {
        !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && value.count <= 128 &&
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    public static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.count <= 255 &&
        !value.contains("/") && !value.contains("\\") &&
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    public func removingSource(_ id:UUID,includingShortcutIDs:Set<UUID>) throws ->Self {
        guard sources.contains(where:{$0.id==id && $0.kind == .smb}),Set(shortcuts.filter{$0.sourceID==id}.map(\.id))==includingShortcutIDs else {throw SavedLocationError.invalid}
        var candidate=self
        candidate.sources.removeAll{$0.id==id}
        candidate.shortcuts.removeAll{$0.sourceID==id}
        if let last=candidate.lastShortcutID,includingShortcutIDs.contains(last) {candidate.lastShortcutID=nil}
        return try candidate.validated()
    }
    public mutating func reorderShortcut(_ id:UUID,to target:UUID) {
        guard id != target,let from=shortcuts.firstIndex(where:{$0.id==id}),let to=shortcuts.firstIndex(where:{$0.id==target}) else{return}
        let item=shortcuts.remove(at:from);shortcuts.insert(item,at:to)
    }
    public mutating func moveShortcut(_ id: UUID, by delta: Int) {
        guard abs(delta) == 1, let index=shortcuts.firstIndex(where: {$0.id==id}), shortcuts.indices.contains(index+delta) else { return }
        shortcuts.swapAt(index,index+delta)
    }
}
public enum SavedLocationError: Error { case invalid, storage }
public struct SavedLocationStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url=url }
    public func load() throws -> SavedLocations {
        guard FileManager.default.fileExists(atPath:url.path) else { return .emptyPrototype }
        guard let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize, size <= 1_048_576 else { throw SavedLocationError.invalid }
        return try JSONDecoder().decode(SavedLocations.self,from:Data(contentsOf:url)).validated().migratedHosts().validated()
    }
    public func save(_ value: SavedLocations) throws {
        let data=try JSONEncoder().encode(value.validated())
        guard data.count <= 1_048_576 else { throw SavedLocationError.invalid }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        #if os(visionOS) || os(iOS)
        try data.write(to:url,options:[.atomic,.completeFileProtection])
        #else
        try data.write(to:url,options:.atomic)
        #endif
    }
}

public enum TagSupportPolicy:String,Codable,Sendable,CaseIterable {case automatic,mac,disabled}
public enum TagSupportEvidence {
    public static let sampleLimit=3
    public static func endpoint(_ value:String)->String {
        value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))
    }
    public static func bonjour(server:String,resolvedHost:String,port:Int,txt:[String:Data])->Bool {
        guard !endpoint(server).isEmpty,endpoint(server)==endpoint(resolvedHost),port==445 else{return false}
        if let data=txt["model"],data.count<=128,let model=String(data:data,encoding:.utf8),
           model.range(of:"^(Mac|MacBook|MacBookAir|MacBookPro|Macmini|MacPro|MacStudio|iMac|iMacPro|PowerMac|PowerBook|Xserve)[0-9]+,[0-9]+$",options:.regularExpression) != nil {return true}
        if let data=txt["osxvers"],data.count<=8,let text=String(data:data,encoding:.utf8),
           let version=Int(text),version>0 {return true}
        return false
    }
    public static func tags(_ state:FinderTagState)->Bool {
        if case .loaded(let tags)=state {return !tags.isEmpty}
        return false
    }
    public static func finderInfo(_ data:Data)->Bool {
        guard data.count==60,Array(data.prefix(8))==[0x41,0x46,0x50,0,0,0,1,0] else{return false}
        return data.dropFirst(16).prefix(32).contains(where:{$0 != 0})
    }
}
