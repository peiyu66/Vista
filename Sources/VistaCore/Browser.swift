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
    public let modifiedAt: Date?
    public let createdAt: Date?
    public let byteSize: Int64?
    public var finderTags:FinderTagState = .notLoaded
    public var isHidden: Bool { name.hasPrefix(".") || hiddenAttribute == true }
    public var id: String { name }
    public init(_ name: String, _ kind: Kind, hiddenAttribute: Bool? = nil, modifiedAt: Date? = nil, byteSize: Int64? = nil, createdAt: Date? = nil) {
        self.name = name; self.kind = kind; self.hiddenAttribute = hiddenAttribute
        self.modifiedAt = modifiedAt.flatMap { $0.timeIntervalSince1970.isFinite ? $0:nil }
        self.createdAt = createdAt.flatMap { $0.timeIntervalSince1970.isFinite ? $0:nil }
        self.byteSize = byteSize.flatMap { $0 >= 0 ? $0:nil }
    }
}

/// File-system creation time, not a video's recording or production metadata.
/// Decimal file units, with exactly one fractional digit in the user's locale.
public enum BrowserSizeText {
    public static func string(_ bytes:Int64?,locale:Locale = .current)->String {
        guard let bytes,bytes>=0 else{return "—"}
        let units=["B","KB","MB","GB","TB","PB","EB"]
        var value=Double(bytes),unit=0
        while value>=1000,unit<units.count-1 {value/=1000;unit+=1}
        // Avoid presenting a rounded 1000.0 in a smaller unit.
        if (value*10).rounded()/10>=1000,unit<units.count-1 {value/=1000;unit+=1}
        let rounded=(value*10).rounded()/10
        let number=rounded.formatted(.number.locale(locale).precision(.fractionLength(1)).grouping(.never))
        return number+" "+units[unit]
    }
}

public enum BrowserDateText {
    private static let formatter = makeFormatter(timeZone:.autoupdatingCurrent)
    private static func makeFormatter(timeZone:TimeZone) -> DateFormatter {
        let value=DateFormatter()
        value.locale=Locale(identifier:"en_US_POSIX")
        value.calendar=Calendar(identifier:.gregorian)
        value.timeZone=timeZone
        value.dateFormat="yyyy/M/d h:mm a"
        return value
    }
    public static func string(_ date:Date?,timeZone:TimeZone?=nil) -> String {
        guard let date else{return "—"}
        return (timeZone.map(makeFormatter) ?? formatter).string(from:date)
    }
}

public struct DirectorySort: Equatable, Sendable {
    public enum Field: String, Sendable { case name, modified, created, size, tags }
    public var field: Field
    public var ascending: Bool
    public init(field: Field = .name, ascending: Bool = true) { self.field=field;self.ascending=ascending }
    public func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        let tagKeys=field == .tags ? entries.map{$0.finderTags.sortNames}:[]
        return entries.enumerated().sorted { a,b in
            let x=a.element,y=b.element
            if (x.kind == .directory) != (y.kind == .directory) { return x.kind == .directory }
            if field == .tags {
                let l=x.finderTags,r=y.finderTags
                if l.sortGroup != r.sortGroup {return l.sortGroup<r.sortGroup}
                let left=tagKeys[a.offset],right=tagKeys[b.offset]
                if left != right {return ascending ? left.lexicographicallyPrecedes(right,by:FinderTag.tagNamePrecedes):right.lexicographicallyPrecedes(left,by:FinderTag.tagNamePrecedes)}
            }
            if field == .size {
                let l=x.kind == .directory ? nil:x.byteSize,r=y.kind == .directory ? nil:y.byteSize
                if (l == nil) != (r == nil) {return l != nil}
                if let l,let r,l != r {return ascending ? l < r:l > r}
            }
            let left:Double?,right:Double?
            switch field {
            case .name: left=nil;right=nil
            case .created: left=x.createdAt?.timeIntervalSince1970;right=y.createdAt?.timeIntervalSince1970
            case .modified: left=x.modifiedAt?.timeIntervalSince1970;right=y.modifiedAt?.timeIntervalSince1970
            case .size,.tags: left=nil;right=nil
            }
            if field != .name {
                if (left == nil) != (right == nil) { return left != nil }
                if let left,let right,left != right { return ascending ? left < right:left > right }
            }
            let comparison=x.name.localizedStandardCompare(y.name)
            if comparison != .orderedSame { return field == .name && !ascending ? comparison == .orderedDescending:comparison == .orderedAscending }
            if x.name != y.name { return field == .name && !ascending ? x.name > y.name:x.name < y.name }
            return a.offset < b.offset
        }.map(\.element)
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

public struct PlaybackSelection: Identifiable, Equatable, Sendable {
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
                    !$0.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value != 0x200D && $0.value != 0x200C }) &&
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
        try await page(at:path,offset:offset,sort:DirectorySort())
    }
    public func page(at path: DirectoryPath, offset: Int, sort: DirectorySort) async throws -> DirectoryPage {
        try await Task.sleep(for: .milliseconds(120))
        if path.components.last == "讀取失敗範例" { throw URLError(.notConnectedToInternet) }
        if path.components.last == "大量影片" {
            let end = min(offset + 100, 5_000)
            let fixture:[FileEntry]=(0..<5_000).map { index in
                let modified=Date(timeIntervalSince1970:1_700_000_000+Double(index))
                let created=Date(timeIntervalSince1970:1_600_000_000+Double(index))
                return FileEntry(String(format:"影片 %04d.mp4",index+1),.video,
                                 modifiedAt:modified,byteSize:Int64(index+1)*1024,createdAt:created)
            }
            let all=sort.sorted(fixture)
            return DirectoryPage(entries:Array(all[offset..<end]),nextOffset:end < 5_000 ? end:nil)
        }
        #if DEBUG && targetEnvironment(simulator) && VISTA_SIMULATOR_SOFTWARE_DECODE
        if path.components == ["播放測試"] {
            return DirectoryPage(entries:offset == 0 ? [FileEntry("H264 播放測試.mp4",.video),FileEntry("HEVC 播放測試.mp4",.video)]:[])
        }
        if path.components.isEmpty {
            return DirectoryPage(entries:offset == 0 ? [FileEntry("播放測試",.directory),FileEntry("影片",.directory),FileEntry("大量影片",.directory),FileEntry("空資料夾",.directory),FileEntry("標籤示範",.directory),FileEntry("讀取失敗範例",.directory)]:[])
        }
        #endif
        let entries: [FileEntry]
        switch path.components {
        case []: entries = [FileEntry("影片", .directory), FileEntry("大量影片", .directory), FileEntry("空資料夾", .directory), FileEntry("標籤示範", .directory), FileEntry("讀取失敗範例", .directory)]
        case ["影片"]: entries = [FileEntry("電影", .directory), FileEntry("旅行", .directory)]
        case ["影片", "電影"]: entries = [FileEntry("科幻", .directory), FileEntry("紀錄片", .directory), FileEntry("預告片.mp4", .video)]
        case ["影片", "電影", "科幻"]: entries = [FileEntry("星際漫遊_SBS_180.mp4", .video), FileEntry("月球之旅.mkv", .video), FileEntry("影片說明.txt", .other), FileEntry("格式標記示範.mp4", .video)]
        case ["標籤示範"]: entries = ["A-藍色","B-紅綠藍","C-紅色","D-無色","E-無標籤","F-未提供","G-不支援","H-無權限","I-格式錯誤","J-讀取失敗","K-雙無色","L-同色雙標籤"].map{FileEntry($0+".mp4",.video)}
        case ["空資料夾"]: entries = []
        default: entries = [FileEntry("示範影片.mp4", .video)]
        }
        let dated=entries.enumerated().map { index,entry in FileEntry(entry.name,entry.kind,modifiedAt:Date(timeIntervalSince1970:1_700_000_000+Double(index)*86_400),byteSize:entry.kind == .directory ? nil:Int64(index+1)*1_048_576,createdAt:index == 0 ? nil:Date(timeIntervalSince1970:1_600_000_000+Double(index)*86_400)) }
        return DirectoryPage(entries: offset == 0 ? sort.sorted(dated) : [])
    }
}

public struct FinderTag: Hashable, Sendable {
    public let name:String
    public let color:Int
    public init(name:String,color:Int) {self.name=name;self.color=color}
    public var initial:String {name.first.map(String.init) ?? ""}
    public static func namePrecedes(_ lhs:String,_ rhs:String)->Bool {
        let comparison=lhs.localizedStandardCompare(rhs)
        return comparison == .orderedSame ? lhs < rhs:comparison == .orderedAscending
    }
    public static func tagNamePrecedes(_ lhs:String,_ rhs:String)->Bool {
        let l=lhs.precomposedStringWithCanonicalMapping,r=rhs.precomposedStringWithCanonicalMapping
        let li=l.first.map(String.init) ?? "",ri=r.first.map(String.init) ?? ""
        if li != ri {return namePrecedes(li,ri)}
        return namePrecedes(l,r)
    }
    public static let colorOrder=[6,7,5,2,4,3,1,0]
    public var rank:Int {Self.colorOrder.firstIndex(of:color) ?? 7}
}
public enum FinderTagState: Hashable, Sendable {
    case notLoaded, loading, loaded([FinderTag]), unavailable, unsupported, denied, invalid, failed
    public var colors:[Int] {
        guard case .loaded(let tags)=self else{return []}
        return Array(Set(tags.map(\.color))).sorted{(FinderTag.colorOrder.firstIndex(of:$0) ?? 7)<(FinderTag.colorOrder.firstIndex(of:$1) ?? 7)}
    }
    /// Initial first, full canonical name next; never merge different names sharing an initial.
    public var displayTags:[FinderTag] {
        guard case .loaded(let tags)=self else{return []}
        return tags.enumerated().sorted {a,b in
            if a.element.name == b.element.name {return a.offset<b.offset}
            return FinderTag.tagNamePrecedes(a.element.name,b.element.name)
        }.map(\.element)
    }
    public var sortNames:[String] {Array(Set(displayTags.map{$0.name.precomposedStringWithCanonicalMapping})).sorted(by:FinderTag.tagNamePrecedes)}
    public var isVisuallyEmpty:Bool {
        if case .loaded(let tags)=self {return tags.isEmpty}
        return self == .unavailable || self == .notLoaded || self == .loading
    }
    public var label:String {
        switch self {
        case .notLoaded:return "尚未讀取"
        case .loading:return "讀取中"
        case .loaded(let tags):return tags.isEmpty ? "無標籤":displayTags.map(\.name).joined(separator:"、")
        case .unavailable:return "未提供"
        case .unsupported:return "不支援"
        case .denied:return "無權限"
        case .invalid:return "格式錯誤"
        case .failed:return "讀取失敗"
        }
    }
    public var isResolvedForSorting:Bool {isConfirmed || self == .unavailable}
    public var isConfirmed:Bool {if case .loaded=self{return true};return false}
    public var sortGroup:Int {
        switch self {case .loaded(let tags):return tags.isEmpty ? 1:0;case .notLoaded,.loading:return 2;case .unavailable:return 3;case .unsupported:return 4;case .denied:return 5;case .invalid:return 6;case .failed:return 7}
    }
}
public enum FinderTagParser {
    public static let limit=16_384
    public static func parse(_ data:Data)->FinderTagState {
        // Bound binary-plist object table before Foundation decoding. XML is not accepted here.
        guard data.count>=40,data.count<=limit,data.prefix(8)==Data("bplist00".utf8) else{return .invalid}
        let trailer=data.suffix(32)
        let objects=trailer.dropFirst(8).prefix(8).reduce(UInt64(0)){($0<<8)|UInt64($1)}
        guard objects>0,objects<=256 else{return .invalid}
        guard let values=try? PropertyListSerialization.propertyList(from:data,options:[],format:nil) as? [String],values.count<=32 else{return .invalid}
        var tags:[FinderTag]=[]
        for value in values {
            let parts=value.split(separator:"\n",omittingEmptySubsequences:false)
            guard parts.count<=2,let name=parts.first,!name.isEmpty,name.utf8.count<=512 else{return .invalid}
            let color:Int
            if parts.count==2 {guard parts[1].count==1,let code=Int(parts[1]),(0...7).contains(code) else{return .invalid};color=code}else{color=0}
            guard !name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0) && $0.value != 0x200D && $0.value != 0x200C}) else{return .invalid}
            let tag=FinderTag(name:String(name),color:color);if !tags.contains(tag){tags.append(tag)}
        }
        return .loaded(tags)
    }
}
