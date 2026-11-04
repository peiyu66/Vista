import SwiftUI
import UIKit
import Observation

@MainActor @Observable final class ShortcutBrowserModel {
    private var displayDefaults:UserDefaults?
    private func saveDisplayPreferences() {
        displayDefaults?.set(["modified":showModified,"created":showCreated,"size":showSize,"tags":showTags,
                              "field":sort.field.rawValue,"ascending":sort.ascending],forKey:"browserDisplay.v1")
    }
    private func restoreDisplayPreferences(testing:Bool,reset:Bool) {
        let defaults=testing ? UserDefaults(suiteName:"org.peiyu66.Vista.BrowserPrototype.display-tests")! : .standard
        if reset {defaults.removeObject(forKey:"browserDisplay.v1")}
        if let value=defaults.dictionary(forKey:"browserDisplay.v1"),
           let modified=value["modified"] as? Bool,let created=value["created"] as? Bool,
           let size=value["size"] as? Bool,let tags=value["tags"] as? Bool,
           let field=value["field"] as? String,let parsed=DirectorySort.Field(rawValue:field),
           let ascending=value["ascending"] as? Bool {
            showModified=modified;showCreated=created;showSize=size;showTags=tags
            sort=DirectorySort(field:parsed,ascending:ascending)
        }
        displayDefaults=defaults
    }
    private var capabilityTask:Task<Void,Never>?
    private var sampledFolders:Set<String>=[]
    private var bonjourAttempted:Set<UUID>=[]
    var tagsAvailable:Bool {source?.providesFinderTags == true && !isHostRoot}
    var tagsVisible:Bool {showTags && tagsAvailable}
    private var refreshTagSort=false
    private var tagsNeeded:Bool {tagsAvailable && (showTags || (refreshTagSort && sort.field == .tags))}
    private var refreshFixtureRevision=0
    func refreshDirectory() {
        guard let source else{return}
        let path=components,session=sessions[sessionKey(source.id,path)]
        cancelListing();refreshTagSort=sort.field == .tags
        entries=[];nextOffset=0;error=nil;notice=nil;selection=nil
        parentEntries=[];parentOffset=belowShortcutRoot ? 0:nil;parentError=nil
        sampledFolders.removeAll();bonjourAttempted.remove(source.id)
        let token=generation
        loading=true
        request=Task {
            if let session {await session.invalidateDirectory(DirectoryPath(mediaPath(path,source:source)))}
            guard !Task.isCancelled,token==generation else{return}
            #if DEBUG
            if testing {refreshFixtureRevision += 1}
            #endif
            loading=false;loadMore()
        }
    }
    var visibleSort:DirectorySort {sort.field == .tags && !tagsAvailable ? DirectorySort():sort}
    private func recordTagEvidence(id:UUID,endpoint:String) {
        guard let index=saved.sources.firstIndex(where:{$0.id==id}),
              TagSupportEvidence.endpoint(saved.sources[index].server)==TagSupportEvidence.endpoint(endpoint) else{return}
        saved.sources[index].tagEvidenceEndpoint=TagSupportEvidence.endpoint(endpoint)
        persist()
        if sourceID==id {tagsVisibilityChanged()}
    }
    private func detectTagSupport() {
        guard let source,!source.isDemo,!source.providesFinderTags,
              capabilityTask==nil else{return}
        let token=generation,path=components,key=sessionKey(source.id,path)+"/"+path.dropFirst().joined(separator:"/")
        let samples=Array(entries.prefix(TagSupportEvidence.sampleLimit)).map {
            (mediaPath(path,source:source)+[$0.name]).joined(separator:"/")
        }
        let session=sessions[sessionKey(source.id,path)]
        let checkBonjour = !bonjourAttempted.contains(source.id)
        let checkSamples = !path.isEmpty && !samples.isEmpty && !sampledFolders.contains(key) && session != nil
        guard checkBonjour || checkSamples else{return}
        capabilityTask=Task {
            #if DEBUG
            if testing {
                try? await Task.sleep(for:.milliseconds(100))
                guard !Task.isCancelled,token==generation else{return}
                bonjourAttempted.insert(source.id);sampledFolders.insert(key);capabilityTask=nil
                if ProcessInfo.processInfo.arguments.contains("--tag-capability-positive") {
                    recordTagEvidence(id:source.id,endpoint:source.server)
                }
                return
            }
            #endif
            var positive=false
            if checkBonjour {
                positive=await BonjourTagProbe().check(server:source.server)
                guard !Task.isCancelled,token==generation else{return}
                bonjourAttempted.insert(source.id)
            }
            if !positive,checkSamples,let session {
                positive=(try? await session.hasFinderEvidence(paths:samples)) == true
                guard !Task.isCancelled,token==generation else{return}
                if sampledFolders.count>=64 {sampledFolders.removeAll()}
                sampledFolders.insert(key)
            }
            capabilityTask=nil
            if positive {recordTagEvidence(id:source.id,endpoint:source.server)}
        }
    }
    var saved: SavedLocations
    var editing=false
    var sourceID: UUID?
    var components: [String]=[]
    var shortcutID: UUID?
    var sort=DirectorySort() {didSet {saveDisplayPreferences()}}
    var showModified=true {didSet {saveDisplayPreferences()}}
    var showCreated=false {didSet {saveDisplayPreferences()}}
    var showTags=false {didSet {saveDisplayPreferences()}}
    var tagsLoading=false
    private var tagTask:Task<Void,Never>?
    private var tagRevision=0
    var tagsPaused=false
    var tagProgress=0
    var tagSortMessage:String?
    var tagUnresolved=0
    var tagReportVisible:Bool {tagsNeeded && !editing && (loading || tagsLoading || tagsPaused || tagUnresolved>0)}
    var tagTestValue:String {
        #if DEBUG
        if testing,tagsVisible,!loading,!tagsLoading,nextOffset==nil,entries.allSatisfy({$0.finderTags.isResolvedForSorting}) {return "tags-complete:\(entries.count)"}
        #endif
        return ""
    }
    var fullTagSortRunning:Bool {tagsNeeded && !editing && !tagsPaused && (loading || tagsLoading)}
    func cancelTagSort() {
        tagRevision += 1;tagTask?.cancel();request?.cancel();parentRequest?.cancel();generation += 1
        parentLoading=false;loading=false;tagsLoading=false;tagsPaused=true
        tagSortMessage="已暫停標籤讀取";tagUnresolved=0
    }
    func resumeTags() {tagsPaused=false;loadTags()}
    func sortAvailableTags() {
        entries=sort.sorted(entries)
        tagSortMessage="已排序已取得的標籤；\(tagUnresolved) 項未確認"
    }

    var showSize=true {didSet {saveDisplayPreferences()}}
    func sortBy(_ field:DirectorySort.Field) {
        if field == .tags,sort.field == .tags,!loading,!tagsLoading,tagUnresolved==0,nextOffset==nil,entries.allSatisfy({$0.finderTags.isResolvedForSorting}) {
            sort.ascending.toggle();entries=sort.sorted(entries);return
        }
        sort=DirectorySort(field:field,ascending:sort.field == field ? !sort.ascending:true)
        if let sourceID {browse(source:sourceID,path:components)}
    }
    var entries: [FileEntry]=[]
    var parentEntries: [FileEntry]=[]
    var parentOffset: Int?
    var parentLoading=false
    var parentError: String?
    private var parentRequest: Task<Void,Never>?
    var nextOffset: Int?
    var loading=false
    var error: String?
    var notice: String?
    var showingConnection=false
    var connectionSourceID: UUID?
    var reauthenticating=false
    private var returnAfterAuthentication=false
    var offerFallbackAuthentication=false
    var fallbackAuthentication=false
    var manualShare=""
    var connecting=false
    var server=""
    var username=""
    var password=""
    var connectionName=""
    var selection: String?
    var playback:BrowserPlayback?
    private var generation=0
    private var request: Task<Void,Never>?
    private var connectionTask: Task<Void,Never>?
    private var sessions: [String:SMBDirectoryProvider]=[:]
    private var normalContext: (UUID,[String],UUID?)?
    private let testing:Bool
    private var storageHealthy=true
    private let store: SavedLocationStore
    private let credentials:SMBCredentialStore
    private var syntheticAuthentication:Bool {
        #if DEBUG
        testing && ProcessInfo.processInfo.arguments.contains("--saved-login-fixture")
        #else
        false
        #endif
    }
    var source: SavedSource? { saved.sources.first {$0.id==sourceID} }
    var isHostRoot:Bool {source?.kind != .demoLocal && source != nil && components.isEmpty}
    func sessionKey(_ id:UUID,_ path:[String])->String {id.uuidString+"/"+(path.first ?? "")}
    func mediaPath(_ path:[String],source:SavedSource)->[String] {source.kind == .demoLocal ? path:Array(path.dropFirst())}
    func openManualShare() {
        let name=manualShare.trimmingCharacters(in:.whitespacesAndNewlines)
        guard isHostRoot,SavedLocations.validComponent(name),let sourceID else{error="請輸入有效分享名稱。";return}
        browse(source:sourceID,path:[name])
    }
    var currentTitle: String { components.last ?? source?.share.nonempty ?? source?.name ?? "資料夾" }
    var activeShortcut: FolderShortcut? { saved.shortcuts.first {$0.id==shortcutID && $0.sourceID==sourceID} }
    var belowShortcutRoot: Bool {
        guard !editing,let root=activeShortcut?.components else {return false}
        return components.count>root.count && components.starts(with:root)
    }
    var canGoBack: Bool { editing ? !components.isEmpty : belowShortcutRoot }
    var parentTitle: String { components.dropLast().last ?? source?.share.nonempty ?? source?.name ?? "資料夾" }
    func home() {guard let item=activeShortcut,!editing else{return};selectShortcut(item)}
    var alreadySaved: Bool { saved.shortcuts.contains {$0.sourceID==sourceID && $0.components==components} }
    init(testFixture: Bool=false, resetFixture: Bool=false) {
        testing=testFixture
        credentials=SMBCredentialStore(service:testFixture ? "org.peiyu66.Vista.BrowserPrototype.ui-test-only":"org.peiyu66.Vista.BrowserPrototype.smb.v1")
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        store=SavedLocationStore(url:root.appendingPathComponent(testFixture ? "shortcut-ui-fixture.json" : "saved-locations.json"))
        do {
            if testFixture && resetFixture { try store.save(.emptyPrototype) }
            saved=try store.load()
            #if DEBUG
            if testFixture,resetFixture,ProcessInfo.processInfo.arguments.contains("--source-settings-fixture") {
                var source=SavedSource(kind:.smb,name:"測試分享",server:"test-nas.example.test",share:"Videos",username:"original-user")
                if ProcessInfo.processInfo.arguments.contains("--legacy-tag-mac") {source.tagPolicy = .mac}
                saved.sources.append(source)
                if ProcessInfo.processInfo.arguments.contains("--source-shortcut-fixture") {saved.shortcuts.append(FolderShortcut(sourceID:source.id,components:["Movies"],name:"保留的捷徑"));saved.shortcuts.append(FolderShortcut(sourceID:source.id,components:[],name:"分享根捷徑"));saved.shortcuts.append(FolderShortcut(sourceID:saved.sources[0].id,components:["影片"],name:"其他主機外的捷徑"))}
                saved=saved.migratedHosts()
                if ProcessInfo.processInfo.arguments.contains("--saved-login-fixture"),let index=saved.sources.firstIndex(where:{$0.id==source.id}) {
                    let reference=UUID();saved.sources[index].credentialID=reference
                    try credentials.save("synthetic-old",for:reference)
                    saved.lastShortcutID=saved.shortcuts.first(where:{$0.sourceID==source.id})?.id
                }
                try store.save(saved)
            }
            #endif
        } catch {
            saved = .emptyPrototype; storageHealthy=false; notice="無法讀取已保存的設定；原資料保留，本次不會覆寫。"
        }
        restoreDisplayPreferences(testing:testFixture,reset:resetFixture || (testFixture && !ProcessInfo.processInfo.arguments.contains("--persist-display-test")))
    }
    func start() {
        guard sourceID==nil, !editing else { return }
        #if DEBUG
        if testing,!syntheticAuthentication,ProcessInfo.processInfo.arguments.contains("--source-settings-fixture") {return}
        #endif
        if let first=saved.shortcuts.first(where:{$0.id==saved.lastShortcutID}) ?? saved.shortcuts.first { selectShortcut(first) }
    }
    func toggleEditing() {
        error=nil; notice=nil; selection=nil
        if !editing {
            if let sourceID { normalContext=(sourceID,components,shortcutID) }
            parentRequest?.cancel(); parentLoading=false; editing=true
        } else {
            editing=false; showingConnection=false; password=""; connectionTask?.cancel(); connecting=false
            if let previous=normalContext, saved.shortcuts.contains(where:{$0.id==previous.2}) {
                shortcutID=previous.2; browse(source:previous.0,path:previous.1)
            } else if let first=saved.shortcuts.first { selectShortcut(first) }
            else { cancelListing(); sourceID=nil; entries=[]; components=[]; shortcutID=nil }
        }
    }
    func selectShortcut(_ item: FolderShortcut) {
        guard !editing else { return }
        shortcutID=item.id; saved.lastShortcutID=item.id; persist()
        browse(source:item.sourceID,path:item.components)
    }
    func selectSource(_ item: SavedSource) {
        guard editing else { return }
        connectionTask?.cancel(); connecting=false; shortcutID=nil; showingConnection=false; password="";manualShare=""
        browse(source:item.id,path:[])
    }
    func browse(source id: UUID,path: [String]) {
        guard path.allSatisfy(SavedLocations.validComponent) else { return }
        cancelListing(); sourceID=id;components=path;entries=[];nextOffset=0;error=nil;notice=nil;selection=nil
        parentEntries=[];parentOffset=belowShortcutRoot ? 0:nil;parentError=nil
        loadMore()
    }
    private func cancelListing() { refreshTagSort=false; capabilityTask?.cancel();capabilityTask=nil; tagRevision += 1;tagTask?.cancel();tagsLoading=false;tagSortMessage=nil;tagProgress=0;tagUnresolved=0;tagsPaused=false;generation += 1;request?.cancel();parentRequest?.cancel();loading=false;parentLoading=false }
    func back() { guard let sourceID,canGoBack else {return};browse(source:sourceID,path:Array(components.dropLast())) }
    func open(_ entry: FileEntry) {
        guard entries.contains(entry), let sourceID else {return}
        if entry.kind == .directory {browse(source:sourceID,path:components+[entry.name])}
        else {
            selection=entry.id
            guard entry.kind == .video,let source else {notice="此檔案不是可播放的影片。";return}
            let directory=DirectoryPath(mediaPath(components,source:source))
            let mediaSource:any MediaByteSource
            if source.isDemo {mediaSource=DemoMediaSource()}
            else if let session=sessions[sessionKey(source.id,components)] {mediaSource=session}
            else {notice="連線已失效，請重新開啟資料夾。";return}
            notice=nil
            playback=BrowserPlayback(selection:PlaybackSelection(directory:directory,file:entry),source:mediaSource,isDemo:source.isDemo,
                preferenceSource:source.isDemo ? .demo:.smb(server:source.server,share:components.first ?? source.share,account:source.username))
        }
    }
    func nextPlayback(after previous:PlaybackSelection) async throws ->PlaybackSelection? {
        let token=generation
        while nextOffset != nil || loading {
            try Task.checkCancellation()
            guard token==generation else {throw CancellationError()}
            if !loading {loadMore()}
            try await Task.sleep(for:.milliseconds(40))
            if error != nil {throw URLError(.cannotLoadFromNetwork)}
        }
        while tagsLoading {try await Task.sleep(for:.milliseconds(40));try Task.checkCancellation();guard token==generation else{throw CancellationError()}}
        guard token==generation,let index=entries.firstIndex(where:{$0.id==previous.file.id}) else{return nil}
        guard let entry=entries.dropFirst(index+1).first(where:{$0.kind == .video}) else{return nil}
        selection=entry.id
        return PlaybackSelection(directory:previous.directory,file:entry)
    }
    func hasNextPlayback(after previous:PlaybackSelection)->Bool {
        if nextOffset != nil || loading {return true}
        guard let index=entries.firstIndex(where:{$0.id==previous.file.id}) else{return false}
        return entries.dropFirst(index+1).contains{$0.kind == .video}
    }
    func loadMore() {
        guard !loading,let offset=nextOffset,let source else {return}
        loading=true;error=nil;let token=generation;let path=components
        request=Task {
            do {
                let page:DirectoryPage
                if testing,ProcessInfo.processInfo.arguments.contains("--refresh-directory-fixture") {
                    let revision=refreshFixtureRevision
                    if revision>0 {try? await Task.sleep(for:.milliseconds(500))}
                    if revision==1 && ProcessInfo.processInfo.arguments.contains("--refresh-failure-fixture") {throw URLError(.networkConnectionLost)}
                    let items=revision==0 ? [FileEntry("舊檔.mp4",.video,byteSize:100),FileEntry("保留.mp4",.video,byteSize:200)] :
                        [FileEntry("新檔.mp4",.video,byteSize:300),FileEntry("保留.mp4",.video,byteSize:50)]
                    page=DirectoryPage(entries:sort.sorted(items))
                } else if syntheticAuthentication && !source.isDemo {
                    guard let secret=try credentials.load(for:source.credentialID ?? source.id),
                          secret == "synthetic-new" || (secret == "synthetic-old" && !ProcessInfo.processInfo.arguments.contains("--auth-expired")) else {throw SMBCredentialStore.Failure.unavailable}
                    page=DirectoryPage(entries:[FileEntry("合成登入成功",.directory)])
                } else if source.kind != .demoLocal && path.isEmpty {
                    let names:[String]
                    if source.isDemo || testing {
                        if testing,ProcessInfo.processInfo.arguments.contains("--host-list-error") {throw URLError(.cannotLoadFromNetwork)}
                        names=["Videos","Movies"]
                    } else {
                        guard let secret=try credentials.load(for:source.credentialID ?? source.id) else{throw SMBCredentialStore.Failure.unavailable}
                        names=try await SMBShareEnumerator.shared.shares(server:source.server,username:source.username,password:secret)
                    }
                    page=DirectoryPage(entries:names.map{FileEntry($0,.directory)})
                } else if source.isDemo || (testing && ProcessInfo.processInfo.arguments.contains("--host-navigation-fixture")) {
                    page=try await DemoDirectoryProvider().page(at:DirectoryPath(mediaPath(path,source:source)),offset:offset,sort:sort.field == .tags ? DirectorySort():sort)
                } else {
                    if testing {throw SMBCredentialStore.Failure.unavailable}
                    let session:SMBDirectoryProvider
                    if let existing=sessions[sessionKey(source.id,path)] {session=existing}
                    else {
                        guard let secret=try credentials.load(for:source.credentialID ?? source.id) else {throw SMBCredentialStore.Failure.unavailable}
                        session=try await SMBDirectoryProvider.connect(input:ConnectionInput(server:source.server,share:path.first ?? "",username:source.username),password:secret)
                        guard !Task.isCancelled, token==generation else {await session.disconnect();return}
                        sessions[sessionKey(source.id,path)]=session
                        bonjourAttempted.remove(source.id);sampledFolders.removeAll()
                    }
                    page=try await session.page(at:DirectoryPath(mediaPath(path,source:source)),offset:offset,sort:sort.field == .tags ? DirectorySort():sort)
                }
                guard !Task.isCancelled,token==generation else {return}
                var seen=Set(entries.map(\.id))
                entries += page.entries.filter {!$0.isHidden && SavedLocations.validComponent($0.name) && seen.insert($0.id).inserted}
                nextOffset=page.nextOffset.flatMap {$0>offset ? $0:nil};loading=false
                detectTagSupport()
                if tagsNeeded,!editing,!tagsPaused {
                    tagSortMessage="正在列出資料夾：\(entries.count) 項"
                    if nextOffset != nil {
                        loadMore()
                    } else {loadTags()}
                } else if tagsNeeded {loadTags()}
                if belowShortcutRoot && parentEntries.isEmpty && parentOffset == 0 {loadParent()}
            } catch {
                guard !Task.isCancelled,token==generation else {return}
                if !source.isDemo,let failed=sessions.removeValue(forKey:sessionKey(source.id,path)) {Task {await failed.disconnect()}}
                loading=false;self.error=path.isEmpty && source.kind != .demoLocal ? "無法列出分享；可手動指定已知分享，或確認帳號權限。":source.isDemo ? "無法讀取此示範資料夾。" : "無法開啟資料夾。請確認伺服器、網路及登入資訊。"
                if belowShortcutRoot && parentOffset == 0 {loadParent()}
            }
        }
    }
    func loadTags() {
        tagRevision += 1;tagTask?.cancel();tagsLoading=false
        guard tagsNeeded,!editing,!tagsPaused,let source,!isHostRoot else{return}
        if nextOffset != nil {if !loading {loadMore()};return}
        let token=generation,path=components,revision=tagRevision
        let pending=entries.filter {if case .notLoaded=$0.finderTags{return true};if case .loading=$0.finderTags{return true};return false}
        guard !pending.isEmpty else {finishTagSort();return}
        tagProgress=entries.count-pending.count
        tagSortMessage="正在讀取標籤"
        tagsLoading=true
        tagTask=Task {
            var working=entries
            let indices=Dictionary(uniqueKeysWithValues:working.enumerated().map{($0.element.id,$0.offset)})
            for (position,entry) in pending.enumerated() {
                guard !Task.isCancelled,token==generation,revision==tagRevision,tagsNeeded else{return}
                guard let index=indices[entry.id] else{continue}
                let state:FinderTagState
                if source.isDemo || testing {
                    do {try await Task.sleep(for:.milliseconds(testing && ProcessInfo.processInfo.arguments.contains("--full-tags-fixture") ? 1:5))}catch{return}
                    let colors=[6,7,5,2,4,3,1,0]
                    let value=entry.name.utf8.reduce(0){($0+Int($1))%12}
                    if testing && ProcessInfo.processInfo.arguments.contains("--missing-tags-fixture") {state = .unavailable}
                    else if testing && ProcessInfo.processInfo.arguments.contains("--refresh-directory-fixture") {
                        let name=entry.name == "保留.mp4" ? (refreshFixtureRevision == 0 ? "Zulu":"Alpha") : "Middle"
                        state = .loaded([FinderTag(name:name,color:0)])
                    } else if path.last == "標籤示範" {
                        switch entry.name.first {
                        case "A":state = .loaded([FinderTag(name:"Yellow",color:4)])
                        case "B":state = .loaded([FinderTag(name:"Orange",color:6),FinderTag(name:"旅行",color:2),FinderTag(name:"Yellow",color:4)])
                        case "C":state = .loaded([FinderTag(name:"Orange",color:6)])
                        case "D":state = .loaded([FinderTag(name:"👩🏽‍💻工作",color:0)])
                        case "E":state = .loaded([])
                        case "F":state = .unavailable
                        case "G":state = .unsupported
                        case "H":state = .denied
                        case "I":state = .invalid
                        case "K":state = .loaded([FinderTag(name:"旅行",color:0),FinderTag(name:"旅遊",color:0)])
                        case "L":state = .loaded([FinderTag(name:"Orange",color:6),FinderTag(name:"Office",color:6)])
                        default:state = .failed
                        }
                    } else if testing && ProcessInfo.processInfo.arguments.contains("--full-tags-fixture") {
                        state = .loaded([FinderTag(name:String(format:"Tag %04d",5000-(Int(entry.name.split(separator:" ").last?.split(separator:".").first.map(String.init) ?? "") ?? 0)),color:0)])
                    } else {switch value {
                    case 8:state = .loaded([])
                    case 9:state = .unsupported
                    case 10:state = .denied
                    case 11:state = .invalid
                    default:state = .loaded([FinderTag(name:"合成標籤",color:colors[value]),FinderTag(name:"合成第二標籤",color:4)])
                    }}
                } else if let session=sessions[sessionKey(source.id,path)] {
                    do {state=try await session.tags(at:DirectoryPath(mediaPath(path,source:source)+[entry.name]))}
                    catch {if Task.isCancelled{return};state = .failed}
                } else {state = .failed}
                guard !Task.isCancelled,token==generation,revision==tagRevision,tagsNeeded else{return}
                working[index].finderTags=state
                if !source.isDemo,TagSupportEvidence.tags(state),
                   let savedIndex=saved.sources.firstIndex(where:{$0.id==source.id}),
                   saved.sources[savedIndex].tagEvidenceEndpoint != TagSupportEvidence.endpoint(source.server) {
                    saved.sources[savedIndex].tagEvidenceEndpoint=TagSupportEvidence.endpoint(source.server);persist()
                }
                if (position+1)%32==0 || position==pending.count-1 {
                    entries=working;tagProgress=entries.count-pending.count+position+1
                }
            }
            guard !Task.isCancelled,token==generation,revision==tagRevision else{return}
            tagsLoading=false
            finishTagSort()
        }
    }
    private func finishTagSort() {
        guard nextOffset==nil else{return}
        tagUnresolved=entries.filter{!$0.finderTags.isResolvedForSorting}.count
        let unavailable=entries.filter{$0.finderTags == .unavailable}.count
        let suffix=unavailable>0 ? "；\(unavailable) 項未提供標籤":""
        if tagUnresolved==0 {
            if sort.field == .tags {entries=sort.sorted(entries)}
            tagSortMessage=nil
        } else {
            let groups=Dictionary(grouping:entries.filter{!$0.finderTags.isResolvedForSorting},by:{$0.finderTags.label})
            let detail=groups.keys.sorted().map{"\($0) \(groups[$0]!.count)"}.joined(separator:"、")
            tagSortMessage="\(tagUnresolved) 項未完成（\(detail)）"+suffix
        }
    }
    func refreshTags() {refreshTags(retryOnly:false)}
    func retryTags() {refreshTags(retryOnly:true)}
    private func refreshTags(retryOnly:Bool) {
        guard tagsNeeded,let source else{return}
        tagsPaused=false
        tagRevision += 1;tagTask?.cancel();tagsLoading=false
        let revision=tagRevision
        let token=generation,session=sessions[sessionKey(source.id,components)]
        tagTask=Task {
            if let session {await session.clearTagCache()}
            guard !Task.isCancelled,token==generation,revision==tagRevision,tagsNeeded else{return}
            for i in entries.indices where !retryOnly || !entries[i].finderTags.isResolvedForSorting {entries[i].finderTags = .notLoaded}
            tagTask=nil;loadTags()
        }
    }
    func tagsVisibilityChanged() {
        refreshTagSort=false
        if tagsVisible {tagsPaused=false;loadTags()}else {tagRevision += 1;tagTask?.cancel();tagsLoading=false;tagSortMessage=nil}
    }
    func loadParent() {
        guard belowShortcutRoot,!parentLoading,let offset=parentOffset,let source else {return}
        let token=generation,path=Array(components.dropLast())
        parentLoading=true;parentError=nil
        parentRequest=Task {
            do {
                let page:DirectoryPage
                if source.isDemo || (testing && ProcessInfo.processInfo.arguments.contains("--host-navigation-fixture")) {page=try await DemoDirectoryProvider().page(at:DirectoryPath(mediaPath(path,source:source)),offset:offset,sort:sort.field == .tags ? DirectorySort():sort)}
                else if let session=sessions[sessionKey(source.id,path)] {page=try await session.page(at:DirectoryPath(mediaPath(path,source:source)),offset:offset,sort:sort.field == .tags ? DirectorySort():sort)}
                else {throw SMBCredentialStore.Failure.unavailable}
                guard !Task.isCancelled,token==generation,!editing else{return}
                var seen=Set(parentEntries.map(\.id))
                parentEntries += page.entries.filter {$0.kind == .directory && !$0.isHidden && SavedLocations.validComponent($0.name) && seen.insert($0.id).inserted}
                parentOffset=page.nextOffset.flatMap {$0>offset ? $0:nil};parentLoading=false
            } catch {
                guard !Task.isCancelled,token==generation,!editing else{return}
                parentLoading=false;parentError="無法讀取上層資料夾。"
            }
        }
    }
    func openParent(_ entry:FileEntry) {
        guard belowShortcutRoot,entry.kind == .directory,parentEntries.contains(entry),let sourceID else{return}
        browse(source:sourceID,path:Array(components.dropLast())+[entry.name])
    }
    func reorder(_ id:UUID,to target:UUID) {guard editing else{return};saved.reorderShortcut(id,to:target);persist()}
    func addShortcut() {
        guard editing,let source,!isHostRoot,!loading,error==nil,!alreadySaved else {return}
        let name=components.last ?? source.share.nonempty ?? source.name
        saved.shortcuts.append(FolderShortcut(sourceID:source.id,components:components,name:name));persist()
    }
    func rename(_ id:UUID,to name:String) {
        guard editing,SavedLocations.validName(name),let index=saved.shortcuts.firstIndex(where:{$0.id==id}) else {return}
        saved.shortcuts[index].name=name.trimmingCharacters(in:.whitespacesAndNewlines);persist()
    }
    func remove(_ id:UUID) {
        guard editing else {return}
        saved.shortcuts.removeAll {$0.id==id};if saved.lastShortcutID==id {saved.lastShortcutID=nil};persist()
    }
    func move(_ id:UUID,by delta:Int) {guard editing else{return};saved.moveShortcut(id,by:delta);persist()}
    func beginConnection(_ existing:SavedSource?=nil,reauthenticate:Bool=false) {
        reauthenticating=reauthenticate
        returnAfterAuthentication=reauthenticate && !editing
        offerFallbackAuthentication=false;fallbackAuthentication=false;manualShare=""
        cancelListing(); connectionTask?.cancel(); connecting=false
        if !editing {normalContext=sourceID.map{($0,components,shortcutID)};editing=true}
        showingConnection=true;connectionSourceID=existing?.id;server=existing?.server ?? ""
        username=existing?.username ?? "";connectionName=existing?.name ?? "";password="";error=nil;notice=nil
    }
    func connect() {
        let input=ConnectionInput(server:server,share:fallbackAuthentication ? manualShare:"IPC$",username:username)
        guard input.isValid,!connecting else {error="請填寫主機名稱或 IPv4 與使用者名稱；使用替代驗證時需填寫已知分享。";return}
        let id=connectionSourceID ?? UUID(),secret=password
        let name=connectionName.trimmingCharacters(in:.whitespacesAndNewlines).nonempty ?? input.server
        guard SavedLocations.validName(name) else {error="連線名稱太長或含無效字元。";return}
        guard storageHealthy else {error="無法保存設定；請先處理設定讀取問題。";return}
        if let existing=saved.sources.first(where:{$0.id==connectionSourceID}),input.username==existing.username,secret.isEmpty,!reauthenticating {
            var candidate=saved
            if let index=candidate.sources.firstIndex(where:{$0.id==id}) {candidate.sources[index].name=name;candidate.sources[index].tagPolicy=nil
            }
            do {
                try store.save(candidate);saved=candidate;showingConnection=false;error=nil
                sampledFolders.removeAll();bonjourAttempted.remove(id)
                if sourceID==id {tagsVisibilityChanged();detectTagSupport()}
            }
            catch {self.error="無法保存名稱，原設定保留。"}
            return
        }
        if testing && !syntheticAuthentication {error="測試連線未通過，原設定保留。";offerFallbackAuthentication=true;return}
        password="";connecting=true;error=nil
        connectionTask=Task {
            do {
                if syntheticAuthentication {
                    guard secret == "synthetic-new" else {throw SMBCredentialStore.Failure.unavailable}
                } else {
                    let session=try await SMBDirectoryProvider.connect(input:input,password:secret)
                    await session.disconnect()
                }
                guard !Task.isCancelled,editing,showingConnection else{return}
                let oldSource=saved.sources.first {$0.id==id}
                let credentialID=UUID()
                var source=SavedSource(id:id,kind:.smb,name:name,server:input.server.trimmingCharacters(in:.whitespacesAndNewlines),share:"",username:input.username)
                source.credentialID=credentialID
                if let oldSource,TagSupportEvidence.endpoint(oldSource.server)==TagSupportEvidence.endpoint(source.server) {
                    source.tagEvidenceEndpoint=oldSource.tagEvidenceEndpoint
                }
                sampledFolders.removeAll();bonjourAttempted.remove(id)
                var candidate=saved
                if let index=candidate.sources.firstIndex(where:{$0.id==id}) {candidate.sources[index]=source}else{candidate.sources.append(source)}
                do {
                    try credentials.save(secret,for:credentialID)
                    try store.save(candidate)
                } catch {
                    try? credentials.remove(for:credentialID)
                    connecting=false
                    self.error="無法安全保存連線設定與密碼；原設定保留，請重試。"
                    return
                }
                saved=candidate
                let keys=sessions.keys.filter{$0.hasPrefix(id.uuidString+"/")}
                for key in keys {if let old=sessions.removeValue(forKey:key) {Task {await old.disconnect()}}}
                var cleanupNotice:String?
                if let oldSource {
                    do {try credentials.remove(for:oldSource.credentialID ?? oldSource.id)}
                    catch {cleanupNotice="新登入已保存；舊登入資訊未能清理。"}
                }
                connecting=false;showingConnection=false
                if returnAfterAuthentication,let previous=normalContext,previous.0==id {
                    editing=false;shortcutID=previous.2;browse(source:id,path:previous.1)
                } else {browse(source:id,path:[])}
                reauthenticating=false;notice=cleanupNotice
            } catch {
                guard !Task.isCancelled else {return}
                connecting=false;offerFallbackAuthentication=true;self.error="無法驗證主機登入。請確認帳密與網路；若伺服器限制 IPC$，可改用已知分享驗證。"
            }
        }
    }
    func sourceShortcutCount(_ id:UUID)->Int {saved.shortcuts.filter{$0.sourceID==id}.count}
    func removeSource(_ requested:SavedSource,including shortcuts:Set<UUID>) {
        guard editing,let source=saved.sources.first(where:{$0.id==requested.id && $0.kind == .smb}),storageHealthy else{return}
        do {
            let candidate=try saved.removingSource(source.id,includingShortcutIDs:shortcuts)
            try store.save(candidate)
            do {try credentials.remove(for:source.credentialID ?? source.id)}
            catch {try store.save(saved);throw error}
            saved=candidate
            if normalContext?.0==source.id {normalContext=nil}
            connectionTask?.cancel();connecting=false;password="";showingConnection=false
            if sourceID==source.id {cancelListing();sourceID=nil;shortcutID=nil;components=[];entries=[];parentEntries=[];normalContext=nil}
            for key in sessions.keys.filter({$0.hasPrefix(source.id.uuidString+"/")}) {if let session=sessions.removeValue(forKey:key){Task {await session.disconnect()}}}
            notice=nil
            #if DEBUG
            if syntheticAuthentication {notice=(try credentials.load(for:source.credentialID ?? source.id)) == nil ? "合成憑證已清除":"合成憑證清除失敗"}
            #endif
        } catch {notice="無法完整移除連線與登入資訊，請重試。"}
    }
    func cancelConnection() {connectionTask?.cancel();connecting=false;password="";showingConnection=false;error=nil}
    private func persist() {
        guard storageHealthy else {notice="設定無法保存；原資料保留。";return}
        do {try store.save(saved)}catch{notice="無法保存變更；重新開啟可能恢復先前設定。"}
    }
}
private extension String {var nonempty:String? {isEmpty ? nil:self}}

struct BrowserPlayback:Identifiable {
    let id=UUID()
    let selection:PlaybackSelection
    let source:any MediaByteSource
    let isDemo:Bool
    let preferenceSource:VRPreferenceSource
}

struct ShortcutBrowserView: View {
    @ScaledMetric(relativeTo:.body) private var dateColumnWidth:CGFloat=220
    @ScaledMetric(relativeTo:.body) private var sizeColumnWidth:CGFloat=120
    @State private var customWidths:[DirectorySort.Field:CGFloat]=[:]
    @State private var discovery=SMBDiscovery()
    @State private var browsingNetwork=false
    @State private var removingSource:SavedSource?
    @FocusState private var connectionFocus:ConnectionField?
    private enum ConnectionField {case username}
    @State private var shortcutFrames:[UUID:CGRect]=[:]
    @State private var model:ShortcutBrowserModel
    init() {
        #if DEBUG
        let args=ProcessInfo.processInfo.arguments
        let initial=ShortcutBrowserModel(testFixture:args.contains("--shortcut-ui-tests"),resetFixture:args.contains("--reset-shortcut-fixture"))
        if args.contains("--shortcut-ui-tests") && args.contains("--columns-preview") {
            initial.saved = .emptyPrototype
            let shortcut=FolderShortcut(sourceID:initial.saved.sources[0].id,components:["影片","電影","科幻"],name:"科幻")
            initial.saved.shortcuts=[shortcut];initial.saved.lastShortcutID=shortcut.id;initial.showCreated=true
            if ProcessInfo.processInfo.arguments.contains("--tags-preview") {
                let tagShortcut=FolderShortcut(sourceID:initial.saved.sources[0].id,components:[args.contains("--auto-tags-navigation") ? "影片":args.contains("--full-tags-fixture") ? "大量影片":"標籤示範"],name:"標籤示範")
                initial.saved.shortcuts=[tagShortcut];initial.saved.lastShortcutID=tagShortcut.id
                initial.showCreated=false;initial.showModified=false;initial.showSize=false;initial.showTags=true
            }
        }
        if args.contains("--review-host-settings"),!args.contains("--shortcut-ui-tests"),
           let source=initial.saved.sources.first(where:{$0.id==initial.saved.shortcuts.first(where:{$0.id==initial.saved.lastShortcutID})?.sourceID && $0.kind == .smb}) ?? initial.saved.sources.first(where:{$0.kind == .smb}) {
            initial.beginConnection(source)
        }
        if args.contains("--shortcut-ui-tests"),args.contains("--legacy-tag-preferences") {
            initial.showTags=true;initial.sort=DirectorySort(field:.tags,ascending:false)
        }
        _model=State(initialValue:initial)
        #else
        _model=State(initialValue:ShortcutBrowserModel())
        #endif
    }
    var body:some View {
        HStack(spacing:0) {
            sidebar.frame(width:300).disabled(removingSource != nil)
            Divider()
            VStack(spacing:0) {
                if let source=removingSource { removalConfirmation(source) }
                else if model.showingConnection { connectionForm }
                else { directory }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.frame(minWidth:880,minHeight:620)
        .opacity(model.playback == nil ? 1:0)
        .allowsHitTesting(model.playback == nil).accessibilityHidden(model.playback != nil)
        .overlay {
            if let playback=model.playback {
                PlaybackView(selection:playback.selection,source:playback.source,isDemo:playback.isDemo,
                             preferenceSource:playback.preferenceSource,directImmersive:true,nextFile:model.nextPlayback,hasNext:model.hasNextPlayback) {model.playback=nil}
                    .id(playback.id)
            }
        }
        .onGeometryChange(for:CGSize.self) {$0.size} action:{BrowserWindowPreferences.save($0)}
        .task{
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--shortcut-ui-tests") && ProcessInfo.processInfo.arguments.contains("--narrow-tags") {customWidths[.tags]=100}
            #endif
            model.start()
        }
        .onChange(of:model.showingConnection){_,showing in if !showing {discovery.stop();browsingNetwork=false}}
        .onChange(of:model.connectionSourceID){_,_ in discovery.stop();browsingNetwork=false}
        .onChange(of:discovery.selected?.1){_,host in
            guard let host,let chosen=discovery.selected,model.showingConnection,model.connectionSourceID==nil else{return}
            model.server=host;model.connectionName=chosen.0
            discovery.stop();browsingNetwork=false;connectionFocus = .username
        }
        .onDisappear{discovery.stop()}
        #if DEBUG
        .onChange(of:model.entries.count) {
            if ProcessInfo.processInfo.arguments.contains("--shortcut-ui-tests") && ProcessInfo.processInfo.arguments.contains("--fit-columns-preview") {
                for field in visibleColumns {fit(field)}
            }
        }
        #endif
    }
    private func removalConfirmation(_ source:SavedSource)->some View {
        let affected=model.saved.shortcuts.filter{$0.sourceID==source.id}
        return VStack(alignment:.leading,spacing:18) {
            Text("移除 \(source.name)？").font(.title2.bold())
            Text("只移除 Vista 保存的連線、登入資訊及下列捷徑，不會刪除伺服器檔案。").foregroundStyle(.secondary)
            if affected.isEmpty {
                Text("沒有捷徑指向此主機。").foregroundStyle(.secondary)
                Spacer()
            } else {
                Text("受影響的捷徑（\(affected.count)）").font(.headline)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:14) {
                        ForEach(affected) {item in
                            VStack(alignment:.leading,spacing:4) {
                                Text(item.name).accessibilityIdentifier("affectedShortcut-\(item.name)")
                                Text("/"+item.components.joined(separator:"/")).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }
                    }
                }
            }
            HStack {
                Button("取消"){removingSource=nil}.accessibilityIdentifier("cancelSourceRemoval")
                Spacer()
                Button(affected.isEmpty ? "移除":"一併移除",role:.destructive) {
                    model.removeSource(source,including:Set(affected.map(\.id)));removingSource=nil
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("confirmSourceRemoval")
            }
        }.padding(32)
    }
    private var sidebar:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text("Vista").font(.title2.bold())
                }
                Spacer()
                if model.belowShortcutRoot {
                    Button("Home",systemImage:"house",action:model.home).labelStyle(.iconOnly).accessibilityIdentifier("shortcutHome")
                } else {
                    Button(model.editing ? "完成":"編輯",systemImage:model.editing ? "checkmark":"pencil") {model.toggleEditing()}
                        .labelStyle(.iconOnly).accessibilityIdentifier("editShortcuts")
                }
            }.padding(22)
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    if model.editing {
                        Text("來源").font(.caption).foregroundStyle(.secondary)
                        ForEach(model.saved.sources) {source in
                            HStack(spacing:4) {
                            Button {model.selectSource(source)} label:{
                                Label(source.name,systemImage:source.kind == .demoLocal ? "internaldrive":"externaldrive.connected.to.line.below")
                                    .frame(maxWidth:.infinity,alignment:.leading).padding(10)
                            }.buttonStyle(.plain)
                                .background(model.sourceID==source.id && !model.showingConnection ? Color.accentColor.opacity(0.16):.clear,in:RoundedRectangle(cornerRadius:12))
                                .accessibilityIdentifier(source.kind == .demoLocal ? "localDemoSource":source.kind == .demoSMB ? "smbDemoSource":"savedSMBSource")
                            if source.kind == .smb {
                                Button {model.beginConnection(source)} label:{Image(systemName:"slider.horizontal.3")}
                                    .buttonStyle(.plain).padding(8).accessibilityLabel("設定 \(source.name)").accessibilityIdentifier("sourceSettings-\(source.name)")

                            }
                            }
                        }
                        Button("連接 SMB",systemImage:"plus.circle") {model.beginConnection()}
                            .accessibilityIdentifier("connectSMB").padding(.vertical,6)
                        Divider().padding(.vertical,8)
                        Text("已保存的捷徑").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.belowShortcutRoot { parentListing }
                    else {
                    if model.saved.shortcuts.isEmpty {
                        Text(model.editing ? "尚未加入資料夾":"尚無捷徑").foregroundStyle(.secondary).padding(.vertical,12)
                    }
                    ForEach(Array(model.saved.shortcuts.enumerated()),id:\.element.id) {index,item in
                        if model.editing {
                            ShortcutEditRow(item:item,rename:{model.rename(item.id,to:$0)},remove:{model.remove(item.id)},move:{y in
                                guard let target=shortcutFrames.min(by:{abs($0.value.midY-y)<abs($1.value.midY-y)})?.key else{return}
                                model.reorder(item.id,to:target)
                            })
                            .background(GeometryReader {geometry in
                                Color.clear.preference(key:ShortcutFrameKey.self,value:[item.id:geometry.frame(in:.named("shortcutList"))])
                            })
                        } else {
                            Button {model.selectShortcut(item)} label:{
                                Label(item.name,systemImage:"folder").lineLimit(2)
                                    .frame(maxWidth:.infinity,alignment:.leading).padding(13)
                            }.buttonStyle(.plain)
                                .background(model.shortcutID==item.id ? Color.accentColor.opacity(0.2):.clear,in:RoundedRectangle(cornerRadius:12))
                                .accessibilityIdentifier("shortcut-\(item.name)")
                        }
                    }
                    }
                }.padding(.horizontal,18).padding(.bottom,18)
                    .coordinateSpace(name:"shortcutList")
                    .onPreferenceChange(ShortcutFrameKey.self){shortcutFrames=$0}
            }
            Spacer(minLength:0)
        }.background(.black.opacity(0.08))
    }
    private var parentListing:some View {
        LazyVStack(spacing:4) {
            ForEach(model.parentEntries) {entry in
                Button {model.openParent(entry)} label:{
                    Label(entry.name,systemImage:entry.kind == .directory ? "folder":"doc")
                        .lineLimit(2).frame(maxWidth:.infinity,alignment:.leading).padding(12)
                }.buttonStyle(.plain)
                    .background(entry.name==model.components.last ? Color.accentColor.opacity(0.2):.clear,in:RoundedRectangle(cornerRadius:12))
                    .accessibilityIdentifier("parent-\(entry.name)")
            }
            if model.parentLoading {ProgressView("載入中…")}
            if let error=model.parentError {Text(error);Button("重試上層",action:model.loadParent)}
            if model.parentOffset != nil && !model.parentLoading && model.parentError == nil {
                Button("載入更多上層項目",action:model.loadParent).onAppear{model.loadParent()}
            }
        }
    }
    private var listingMaxWidth:CGFloat {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--shortcut-ui-tests") && ProcessInfo.processInfo.arguments.contains("--narrow-list") {return 440}
        #endif
        return .infinity
    }
    private var visibleColumns:[DirectorySort.Field] {
        [.name]+(model.showModified ? [.modified]:[])+(model.showCreated ? [.created]:[])+(model.showSize ? [.size]:[])+(model.tagsVisible ? [.tags]:[])
    }
    private func bounds(_ field:DirectorySort.Field) -> ClosedRange<CGFloat> {
        switch field {case .name:return 160...600;case .modified,.created:return 140...360;case .size:return 100...240;case .tags:return 100...260}
    }
    private func width(_ field:DirectorySort.Field,available:CGFloat) -> CGFloat {
        if let custom=customWidths[field] {return custom}
        switch field {
        case .modified,.created:return dateColumnWidth
        case .size:return sizeColumnWidth
        case .tags:return 150
        case .name:
            let other=visibleColumns.filter{$0 != .name}.reduce(CGFloat(0)) {$0+width($1,available:available)+8}
            return max(200,available-40-other)
        }
    }
    private func resize(_ field:DirectorySort.Field,to value:CGFloat) {

        customWidths[field]=min(bounds(field).upperBound,max(bounds(field).lowerBound,value))
    }
    private func fit(_ field:DirectorySort.Field) {
        let font=UIFont.preferredFont(forTextStyle:.body)
        let texts=model.entries.map { entry -> String in
            switch field {
            case .tags:return entry.finderTags.label
            case .name:return entry.name
            case .modified:return BrowserDateText.string(entry.modifiedAt)
            case .created:return BrowserDateText.string(entry.createdAt)
            case .size:return entry.kind == .directory ? "—":BrowserSizeText.string(entry.byteSize)
            }
        }
        let measured=texts.reduce(CGFloat(0)) {max($0,($1 as NSString).size(withAttributes:[.font:font]).width)}
        let title:String
        switch field {case .name:title="名稱";case .modified:title="修改日期";case .created:title="製作日期";case .size:title="檔案大小";case .tags:title="標籤"}
        let header=(title as NSString).size(withAttributes:[.font:UIFont.preferredFont(forTextStyle:.subheadline)]).width+(field == .size ? 37:field == .tags ? 93:85)
        resize(field,to:max(ceil(measured)+(field == .name ? 38:12),ceil(header)))
    }
    private func columnHeader(_ title:String,_ field:DirectorySort.Field,available:CGFloat) -> some View {
        let currentWidth=width(field,available:available)
        return HStack(spacing:0) {
            Button {model.sortBy(field)} label:{
                HStack(spacing:5) {
                    Text(title).lineLimit(1)
                    if model.visibleSort.field == field {Image(systemName:model.visibleSort.ascending ? "arrow.up":"arrow.down")}
                }.font(.subheadline.bold()).padding(.trailing,field == .size ? 12:0).padding(.leading,field == .tags ? 8:0).frame(maxWidth:.infinity,minHeight:60,alignment:field == .size ? .trailing:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("sort-"+field.rawValue)
                .accessibilityValue(model.visibleSort.field == field ? (model.visibleSort.ascending ? "升冪":"降冪"):"未排序")
            if field != .size {
                ColumnResizeHandle(title:title,width:currentWidth,onResize:{resize(field,to:$0)},onFit:{fit(field)})
                    .accessibilityIdentifier("resize-"+field.rawValue)
            }
        }.frame(width:currentWidth)
        .overlay(alignment:.trailing) {
            if field == .size {
                ColumnResizeHandle(title:title,width:currentWidth,onResize:{resize(field,to:$0)},onFit:{fit(field)})
                    .frame(width:60,height:60).offset(x:30)
                    .accessibilityIdentifier("resize-"+field.rawValue)
            }
        }
    }
    #if DEBUG
    private func testWindowWidth(_ value:CGFloat) {
        guard let scene=UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}).first else{return}
        scene.requestGeometryUpdate(.Vision(size:CGSize(width:value,height:720)))
    }
    #endif
    private var directory:some View {
        VStack(alignment:.leading,spacing:0) {
            if let source=model.source {
                HStack(spacing:14) {
                    Button(action:model.back){Image(systemName:"chevron.left")}.disabled(!model.canGoBack)
                        .accessibilityLabel("回上層").accessibilityIdentifier("folderBack")
                    VStack(alignment:.leading,spacing:4) {
                        Text(model.currentTitle).font(.title2.bold()).lineLimit(1).accessibilityIdentifier("folderTitle")
                        Text(source.isDemo ? "\(source.name) · 示範來源" : source.name.trimmingCharacters(in:.whitespacesAndNewlines).nonempty ?? source.server)
                            .font(.body).foregroundStyle(.secondary).lineLimit(1).accessibilityIdentifier("browserSourceName")
                    }
                    Spacer()
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--window-resize-test") && ProcessInfo.processInfo.arguments.contains("--shortcut-ui-tests") {
                        Button("窄窗"){testWindowWidth(880)}.accessibilityIdentifier("testNarrowWindow")
                        Button("寬窗"){testWindowWidth(1400)}.accessibilityIdentifier("testWideWindow")
                    }
                    #endif
                    if !model.editing {
                        Menu {
                            Toggle("修改日期",isOn:$model.showModified).menuActionDismissBehavior(.enabled).accessibilityIdentifier("toggleModified")
                            Toggle("製作日期",isOn:$model.showCreated).menuActionDismissBehavior(.enabled).accessibilityIdentifier("toggleCreated")
                            Toggle("檔案大小",isOn:$model.showSize).menuActionDismissBehavior(.enabled).accessibilityIdentifier("toggleSize")
                            if model.tagsAvailable {Toggle("標籤",isOn:$model.showTags).menuActionDismissBehavior(.enabled).accessibilityIdentifier("toggleTags")}
                            Button("重新整理資料夾",action:model.refreshDirectory).accessibilityIdentifier("refreshDirectory")
                            Divider()
                            Button("符合內容"){for field in visibleColumns {fit(field)}}.accessibilityIdentifier("fitColumns")
                                .help("依目前已載入的項目調整欄寬")
                            Button("重設欄寬"){customWidths=[:]}.accessibilityIdentifier("resetColumns")
                        } label:{Image(systemName:"line.3.horizontal.decrease")}
                        .accessibilityLabel("顯示欄位").accessibilityIdentifier("columnOptions")
                        .onChange(of:model.showModified) {if !model.showModified && model.sort.field == .modified {model.sortBy(.name)}}
                        .onChange(of:model.showTags) {model.tagsVisibilityChanged()}
                        .onChange(of:model.editing) {model.tagsVisibilityChanged()}
                        .onChange(of:model.showCreated) {if !model.showCreated && model.sort.field == .created {model.sortBy(.name)}}
                        .onChange(of:model.showSize) {if !model.showSize && model.sort.field == .size {model.sortBy(.name)}}
                    }
                    if model.editing && !model.isHostRoot {
                        Button(model.alreadySaved ? "已加入":"加入捷徑",systemImage:model.alreadySaved ? "checkmark":"plus") {model.addShortcut()}
                            .disabled(model.alreadySaved || model.loading || model.error != nil).accessibilityIdentifier("addShortcut")
                    }
                }.padding(24)
                HStack(alignment:.bottom,spacing:16) {
                    Text("/"+model.components.joined(separator:"/")).font(.body).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth:.infinity,alignment:.leading)
                        .accessibilityIdentifier("prototypePath").accessibilityValue(model.tagTestValue)
                if model.tagReportVisible {
                    HStack(alignment:.bottom,spacing:8) {
                        if model.tagsLoading {ProgressView().controlSize(.small)}
                        Text(model.tagSortMessage ?? "準備讀取當層標籤").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("tagSortStatus")
                        if model.tagsLoading {Text("\(model.tagProgress) / \(model.entries.count)").font(.caption).accessibilityIdentifier("tagSortProgress")}
                        if model.fullTagSortRunning {Button("取消",action:model.cancelTagSort).accessibilityIdentifier("cancelTagSort")}
                        else if model.tagsPaused {Button("繼續讀取",action:model.resumeTags).accessibilityIdentifier("resumeTags")}
                        else if model.tagUnresolved>0 {
                            Button("重試未完成",action:model.retryTags).accessibilityIdentifier("retryTagSort")
                            if model.sort.field == .tags {Button("只排序已取得項目",action:model.sortAvailableTags).accessibilityIdentifier("partialTagSort")}
                        }
                    }.frame(maxWidth:480,alignment:.trailing)
                }
                }.padding(.horizontal,24).padding(.bottom,14)
                if model.isHostRoot {
                    HStack {
                        TextField("手動指定分享",text:$model.manualShare).textFieldStyle(.roundedBorder).accessibilityIdentifier("manualShare")
                        Button("開啟",action:model.openManualShare).accessibilityIdentifier("openManualShare")
                    }.padding(.horizontal,24).padding(.bottom,14)
                }
                Divider()
                GeometryReader { geometry in
                VStack(spacing:0) {
                        if !model.editing {
                            HStack(spacing:8) {
                                columnHeader("名稱",.name,available:geometry.size.width-16)
                                if model.showModified {columnHeader("修改日期",.modified,available:geometry.size.width-16)}
                                if model.showCreated {columnHeader("製作日期",.created,available:geometry.size.width-16)}
                                if model.showSize {columnHeader("檔案大小",.size,available:geometry.size.width-16)}
                                if model.tagsVisible {columnHeader("標籤",.tags,available:geometry.size.width-16)}
                                Color.clear.frame(width:12,height:1)
                            }.padding(.horizontal,10).padding(.vertical,8)
                            .frame(width:max(geometry.size.width-16,40+visibleColumns.reduce(CGFloat(0)){$0+width($1,available:geometry.size.width-16)}+CGFloat(visibleColumns.count-1)*8),alignment:.leading)
                            .frame(width:max(0,geometry.size.width-16),alignment:.leading).padding(.horizontal,8).clipped()
                        }

                ScrollView(.vertical) {
                    LazyVStack(spacing:4) {
                        ForEach(model.entries) {entry in
                            Button {model.open(entry)} label:{
                                HStack(spacing:8) {
                                    HStack(spacing:8) {
                                    Image(systemName:entry.kind == .directory ? "folder.fill":entry.kind == .video ? "film":"doc")
                                        .foregroundStyle(entry.kind == .directory ? .blue:.secondary).font(.body).frame(width:22)
                                    Text(entry.name).font(.body).lineLimit(2).truncationMode(.middle).frame(maxWidth:.infinity,alignment:.leading)
                                    }.frame(width:model.editing ? nil:width(.name,available:geometry.size.width-16),alignment:.leading)
                                    if !model.editing && model.showModified {
                                        Text(BrowserDateText.string(entry.modifiedAt)).font(.body).lineLimit(1).foregroundStyle(.secondary).frame(width:width(.modified,available:geometry.size.width-16),alignment:.leading).accessibilityIdentifier("modified-"+entry.name)
                                    }
                                    if !model.editing && model.showCreated {
                                        Text(BrowserDateText.string(entry.createdAt)).font(.body).lineLimit(1).foregroundStyle(.secondary).frame(width:width(.created,available:geometry.size.width-16),alignment:.leading)
                                    }
                                    if !model.editing && model.showSize {
                                        Text(entry.kind == .directory ? "—":BrowserSizeText.string(entry.byteSize)).font(.body).lineLimit(1).foregroundStyle(.secondary).padding(.trailing,12).frame(width:width(.size,available:geometry.size.width-16),alignment:.trailing).accessibilityIdentifier("size-"+entry.name)
                                    }
                                    if !model.editing && model.tagsVisible {
                                        FinderTagInitials(state:entry.finderTags,availableWidth:max(0,width(.tags,available:geometry.size.width-16)-8)).padding(.leading,8).frame(width:width(.tags,available:geometry.size.width-16),alignment:.leading).accessibilityIdentifier("tags-\(entry.id)")
                                    }
                                    Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary).opacity(entry.kind == .directory ? 1:0).frame(width:12)
                                }.padding(.horizontal,10).padding(.vertical,12).frame(maxWidth:.infinity,alignment:.leading)
                            }.buttonStyle(.plain)
                                .background(model.selection==entry.id ? Color.accentColor.opacity(0.15):.clear,in:RoundedRectangle(cornerRadius:12))
                                .accessibilityValue(model.selection==entry.id ? "已選取":"")
                                .accessibilityIdentifier("entry-\(entry.name)")
                        }
                        if model.loading {ProgressView("載入中…").padding()}
                        if let error=model.error {
                            VStack(spacing:12) {
                                Text(error).multilineTextAlignment(.center).accessibilityIdentifier("listingError")
                                HStack {
                                    Button("重試",action:model.loadMore)
                                    if !source.isDemo {Button("重新登入"){model.beginConnection(source,reauthenticate:true)}.accessibilityIdentifier("reconnectSMB")}
                                }
                            }.padding(24)
                        } else if model.entries.isEmpty && !model.loading {
                            VStack(spacing:12) {
                                Image(systemName:"folder").font(.largeTitle).foregroundStyle(.secondary)
                                Text(model.isHostRoot ? "沒有可列出的分享":"空資料夾").font(.headline).accessibilityIdentifier("emptyDirectoryLabel")
                            }.frame(maxWidth:.infinity,alignment:.top).padding(.top,24)
                        }
                        if model.nextOffset != nil && !model.loading && model.error == nil {
                            Button("載入更多",action:model.loadMore).padding().onAppear{model.loadMore()}
                        }
                    }.frame(width:max(geometry.size.width-16,model.editing ? 240:40+visibleColumns.reduce(CGFloat(0)){$0+width($1,available:geometry.size.width-16)}+CGFloat(visibleColumns.count-1)*8)).frame(minHeight:max(0,geometry.size.height-16-(model.editing ? 0:76)),alignment:.topLeading)
                        .frame(width:max(0,geometry.size.width-16),alignment:.leading).padding(8)
                }.clipped().accessibilityIdentifier("directoryScroll")
                }
                }.frame(maxWidth:listingMaxWidth,alignment:.topLeading)
            } else {
                Spacer()
                VStack(spacing:16) {
                    Image(systemName:model.editing ? "folder.badge.plus":"star.square.on.square").font(.system(size:42)).foregroundStyle(.secondary)
                    Text(model.editing ? "選擇要加入的資料夾":"把常用資料夾放在這裡").font(.title2.bold())
                    Text(model.editing ? "從左側來源開始瀏覽。":"建立捷徑，下次直接開啟。").foregroundStyle(.secondary)
                    if !model.editing {Button("編輯捷徑"){model.toggleEditing()}.buttonStyle(.borderedProminent).accessibilityIdentifier("emptyEdit")}
                }.frame(maxWidth:.infinity)
                Spacer()
            }
            if let notice=model.notice {Text(notice).font(.callout).foregroundStyle(.secondary).padding(20).accessibilityIdentifier("prototypeNotice")}
        }
    }
    private var formWidth:CGFloat {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--narrow-form") {return 360}
        #endif
        return 600
    }
    private var connectionForm:some View {
        ScrollView {
        VStack(alignment:.leading,spacing:18) {
            HStack {Text(model.connectionSourceID == nil ? "登入 SMB 主機":"主機設定").font(.title2.bold());Spacer();Button("取消",action:model.cancelConnection)}
            HStack {
            TextField("伺服器，例如 nas.example.test",text:$model.server).keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.connectionSourceID != nil).accessibilityIdentifier("prototypeServer")
            if model.connectionSourceID == nil {
                Button("瀏覽網路",systemImage:"network") {browsingNetwork.toggle();if browsingNetwork {discovery.start()}else{discovery.stop()}}
                    .labelStyle(.iconOnly).accessibilityIdentifier("browseNetwork")
            }
            }
            if browsingNetwork {
                if discovery.devices.isEmpty && (discovery.running || discovery.resolving) {
                    Text("正在尋找 SMB 主機…").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("discoveryStatus")
                }
                if discovery.hasStaleResults {Text("上次結果尚未確認。").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("staleDiscovery")}
                BubbleLayout {
                    ForEach(discovery.devices) {device in
                        Button(device.name){discovery.select(device)}.buttonStyle(.bordered).buttonBorderShape(.capsule)
                            .disabled(discovery.resolving || !discovery.isCurrent(device)).accessibilityIdentifier("discovered-\(device.name)")
                    }
                }
                if let message=discovery.message {Text(message).font(.caption).foregroundStyle(.secondary)}
            }
            TextField("顯示名稱（選填）",text:$model.connectionName).keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("connectionName")
            TextField("使用者名稱",text:$model.username).keyboardType(.asciiCapable).focused($connectionFocus,equals:.username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("prototypeUsername")
            SecureField("密碼",text:$model.password).keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.password).accessibilityIdentifier("prototypePassword")
            if model.fallbackAuthentication {
                TextField("已知分享（用來驗證登入）",text:$model.manualShare).keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("fallbackShare")
            }
            if model.offerFallbackAuthentication && !model.fallbackAuthentication {
                Button("改用已知分享驗證"){model.fallbackAuthentication=true}.accessibilityIdentifier("fallbackAuthentication")
            }
            Text(model.reauthenticating ? "重新輸入帳密，或使用系統提供的密碼自動填入。":"連線設定會保存，密碼存於 Vista 的 Keychain。")
                .font(.caption).foregroundStyle(.secondary)
            if model.connectionSourceID != nil && !model.reauthenticating {
                Text("只改顯示名稱不需輸入密碼；更換帳號需重新驗證。").font(.caption).foregroundStyle(.secondary)
            }
            if let error=model.error {Text(error).foregroundStyle(.orange).accessibilityIdentifier("connectionError")}
            if model.connecting {ProgressView("正在連線…")}
            HStack(spacing:16) {
            Button(model.connectionSourceID == nil ? "連線並保存":"儲存變更",action:model.connect).buttonStyle(.borderedProminent).disabled(model.connecting).accessibilityIdentifier("prototypeConnect")
                if let source=model.saved.sources.first(where:{$0.id==model.connectionSourceID}) {
                    Button("移除主機",role:.destructive){removingSource=source}
                        .buttonStyle(.bordered).disabled(model.connecting).accessibilityIdentifier("sourceRemove-\(source.name)")
                }
            }
            Spacer()
        }.textFieldStyle(.roundedBorder).padding(32).frame(maxWidth:formWidth).frame(maxWidth:.infinity,alignment:.center)
        }
    }
}
private struct ShortcutEditRow:View {
    let item:FolderShortcut
    var rename:(String)->Void
    var remove:()->Void
    var move:(CGFloat)->Void
    @GestureState private var dragging=false
    @State private var draft=""
    var body:some View {
        HStack(spacing:8) {
            Image(systemName:"line.3.horizontal").foregroundStyle(.secondary)
                .padding(10).contentShape(Rectangle())
                .foregroundStyle(dragging ? Color.accentColor:Color.secondary)
                .gesture(DragGesture(minimumDistance:8,coordinateSpace:.named("shortcutList"))
                    .updating($dragging){_,state,_ in state=true}
                    .onEnded{move($0.location.y)})
                .accessibilityLabel("拖拉排序 \(item.name)").accessibilityIdentifier("drag-\(item.name)")
            TextField("捷徑名稱",text:$draft).textFieldStyle(.plain)
                .padding(.vertical,9).padding(.horizontal,6)
                .background(.white.opacity(0.025),in:RoundedRectangle(cornerRadius:7))
                .onSubmit{rename(draft)}.onChange(of:draft){_,value in rename(value)}
                .accessibilityIdentifier("rename-\(item.name)")
            Button(action:remove){Image(systemName:"minus.circle").foregroundStyle(.secondary)}
                .buttonStyle(.plain).padding(8).accessibilityLabel("移除 \(item.name)")
                .accessibilityIdentifier("remove-\(item.name)")
        }.padding(.vertical,5).onAppear{draft=item.name}
    }
}
private struct ShortcutFrameKey:PreferenceKey {
    static let defaultValue:[UUID:CGRect]=[:]
    static func reduce(value:inout [UUID:CGRect],nextValue:()->[UUID:CGRect]) {value.merge(nextValue()){_,new in new}}
}

private struct BubbleLayout:Layout {
    var spacing:CGFloat=8
    private func measured(_ subviews:Subviews,width:CGFloat)->[CGSize] {
        subviews.map{$0.sizeThatFits(ProposedViewSize(width:width,height:nil))}
    }
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ())->CGSize {
        let width=proposal.width ?? 400
        let flow=BubbleFlow.positions(sizes:measured(subviews,width:width),width:width,spacing:spacing)
        return CGSize(width:width,height:flow.height)
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        let sizes=measured(subviews,width:bounds.width)
        let flow=BubbleFlow.positions(sizes:sizes,width:bounds.width,spacing:spacing)
        for (index,view) in subviews.enumerated() {
            view.place(at:CGPoint(x:bounds.minX+flow.points[index].x,y:bounds.minY+flow.points[index].y),anchor:.topLeading,proposal:ProposedViewSize(width:min(bounds.width,sizes[index].width),height:sizes[index].height))
        }
    }
}

private struct ColumnResizeHandle:UIViewRepresentable {
    let title:String
    let width:CGFloat
    var onResize:(CGFloat)->Void
    var onFit:()->Void
    func makeUIView(context:Context) -> ResizeGripView {ResizeGripView()}
    func updateUIView(_ view:ResizeGripView,context:Context) {
        view.currentWidth=width;view.onResize=onResize;view.onFit=onFit
        view.accessibilityLabel="調整\(title)欄寬";view.accessibilityValue="\(Int(width))"
    }
    func sizeThatFits(_ proposal:ProposedViewSize,uiView:ResizeGripView,context:Context) -> CGSize? {CGSize(width:60,height:60)}
}
private final class ResizeGripView:UIView,UIGestureRecognizerDelegate {
    var currentWidth:CGFloat=200
    var onResize:((CGFloat)->Void)?
    var onFit:(()->Void)?
    private var initialWidth:CGFloat=200
    private let line=UIView()
    override init(frame:CGRect) {
        super.init(frame:frame)
        isAccessibilityElement=true;accessibilityTraits = .adjustable
        line.backgroundColor=UIColor.secondaryLabel.withAlphaComponent(0.35);line.layer.cornerRadius=1
        addSubview(line)
        let pan=UIPanGestureRecognizer(target:self,action:#selector(drag(_:)))
        pan.delegate=self;addGestureRecognizer(pan)
        let doubleTap=UITapGestureRecognizer(target:self,action:#selector(fitContent))
        doubleTap.numberOfTapsRequired=2;addGestureRecognizer(doubleTap)
        accessibilityCustomActions=[UIAccessibilityCustomAction(name:"符合內容",target:self,selector:#selector(accessibleFit))]
        hoverStyle=UIHoverStyle(effect:UIHoverHighlightEffect())
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    override func layoutSubviews() {super.layoutSubviews();line.frame=CGRect(x:bounds.midX-1,y:bounds.midY-14,width:2,height:28)}
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldBeRequiredToFailBy otherGestureRecognizer:UIGestureRecognizer)->Bool {
        gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
    }
    @objc private func drag(_ gesture:UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:initialWidth=currentWidth
        case .changed,.ended:onResize?(initialWidth+gesture.translation(in:superview).x)
        default:break
        }
    }
    @objc private func fitContent() {onFit?()}
    @objc private func accessibleFit()->Bool {onFit?();return true}
    override func accessibilityIncrement() {onResize?(currentWidth+20)}
    override func accessibilityDecrement() {onResize?(currentWidth-20)}
}

private struct FinderTagInitials:View {
    let state:FinderTagState
    let availableWidth:CGFloat
    @State private var showingNames=false
    private var capacity:Int {max(1,Int((availableWidth+4)/32))}
    private var overflow:Bool {state.displayTags.count>capacity}
    private var shown:[FinderTag] {Array(state.displayTags.prefix(overflow ? max(0,capacity-1):capacity))}
    var body:some View {
        Group {
            if !state.displayTags.isEmpty {
                HStack(spacing:4) {
                    ForEach(Array(shown.enumerated()),id:\.offset) {_,tag in
                        Text(tag.initial).font(.body).lineLimit(1).minimumScaleFactor(0.65)
                            .frame(width:28,height:28)
                            .overlay(Circle().stroke(Color.secondary,lineWidth:1))
                    }
                    if overflow {Text("…").frame(width:28,height:28)}
                }.foregroundStyle(.secondary)
            } else if state.isVisuallyEmpty {Color.clear.frame(height:28)}
            else if case .loading=state {ProgressView().controlSize(.small)}
            else {Text(state.label).font(.body).foregroundStyle(.secondary).lineLimit(1)}
        }.accessibilityElement(children:.ignore).accessibilityLabel(state.label)
            .help(state == .unavailable ? "本次未取得可顯示的標籤；未查詢項目是否仍存在。":state.label)
            .contentShape(Rectangle())
            .highPriorityGesture(LongPressGesture(minimumDuration:0.6).onEnded { _ in
                if !state.displayTags.isEmpty {showingNames=true}
            })
            .accessibilityAction(named:"顯示完整標籤") {if !state.displayTags.isEmpty {showingNames=true}}
            .popover(isPresented:$showingNames) {
                ScrollView {
                    VStack(alignment:.leading,spacing:10) {
                        ForEach(Array(state.displayTags.enumerated()),id:\.offset) {_,tag in Text(tag.name).font(.body)}
                    }.padding(20)
                }.frame(maxWidth:360,maxHeight:360)
            }
    }
}
