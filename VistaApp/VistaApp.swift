import SwiftUI

@main struct VistaApp: App {
    var body: some Scene {
        WindowGroup { ConnectionView() }
            .defaultSize(width: 1000, height: 680)
            .windowResizability(.contentMinSize)
    }
}

struct ConnectionView: View {
    @State private var server = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    @State private var message: String?
    @State private var browser: BrowserModel?
    @State private var session: SMBDirectoryProvider?
    @State private var connecting = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var isDemo = false
    @State private var connectedServer = ""
    @State private var connectedShare = ""
    var input: ConnectionInput { ConnectionInput(server: server, share: share, username: username) }
    var body: some View {
        Group {
            if let browser {
                BrowserView(model: browser, isDemo: isDemo, serverName: connectedServer, shareName: connectedShare, mediaSource: isDemo ? DemoMediaSource() : session) {
                    browser.stop()
                    self.browser = nil
                    let closing = session
                    session = nil
                    Task { await closing?.disconnect() }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Label("Vista", systemImage: "vision.pro").font(.largeTitle.bold())
                        Text("連接你的影片資料夾").font(.title2)
                        Text("透過 SMB 瀏覽網路分享中的 VR 影片。").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 16) {
                            field("伺服器", hint: "例如 nas.example.test", value: $server).accessibilityIdentifier("serverField")
                            field("分享名稱", hint: "例如 Videos", value: $share).accessibilityIdentifier("shareField")
                            TextField("使用者名稱", text: $username).textContentType(.username).accessibilityIdentifier("usernameField")
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("密碼", text: $password).textContentType(.password)
                                .accessibilityIdentifier("passwordField")
                                .submitLabel(.go).onSubmit(connect)
                        }.textFieldStyle(.roundedBorder)
                        Text("帳密僅用於這次 SMB 連線，不會儲存。系統密碼建議是否可用，仍需裝置驗證。")
                            .font(.callout).foregroundStyle(.secondary)
                        if connecting {
                            ProgressView("正在連接伺服器…").accessibilityIdentifier("connectionProgress")
                        }
                        if let message { Text(message).foregroundStyle(.orange).accessibilityIdentifier("connectionMessage") }
                        HStack {
                            Button(connecting ? "連線中…" : "連線", action: connect)
                                .buttonStyle(.borderedProminent).tint(.blue)
                                .keyboardShortcut(.defaultAction)
                                .accessibilityIdentifier("connectButton")
                                .disabled(connecting)
                            if connecting {
                                Button("取消") { connectionTask?.cancel(); message = "正在取消連線…" }
                            }
                            Button("使用示範資料") {
                                password = ""; message = nil; isDemo = true
                                connectedServer = "示範伺服器"; connectedShare = "示範分享"
                                browser = BrowserModel(provider: DemoDirectoryProvider())
                            }.disabled(connecting).accessibilityIdentifier("openDemo")
                        }
                    }.padding(40).frame(maxWidth: 600)
                }
            }
        }.frame(minWidth: 800, minHeight: 560)
    }
    private func connect() {
        guard !connecting else { return }
        guard input.isValid else {
            message = "請填寫伺服器、分享名稱及使用者名稱。伺服器只填主機名稱或 IPv4 位址，不含 smb:// 或資料夾路徑。"
            return
        }
        let submitted = input
        let secret = password
        password = ""; message = nil; connecting = true
        connectionTask = Task {
            do {
                let connected = try await SMBDirectoryProvider.connect(input: submitted, password: secret)
                guard !Task.isCancelled else { await connected.disconnect(); connecting = false; return }
                session = connected; isDemo = false
                connectedServer = submitted.server.trimmingCharacters(in: .whitespacesAndNewlines)
                connectedShare = submitted.share.trimmingCharacters(in: .whitespacesAndNewlines)
                browser = BrowserModel(provider: connected)
            } catch {
                if !Task.isCancelled { message = "無法連線。請確認伺服器、分享名稱、帳密與網路後重試。" }
            }
            connecting = false
        }
    }
    private func field(_ title: String, hint: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(hint, text: value).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }
}

struct BrowserView: View {
    @Bindable var model: BrowserModel
    let isDemo: Bool
    let serverName: String
    let shareName: String
    let mediaSource: (any MediaByteSource)?
    var disconnect: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button(action: model.back) { Image(systemName: "chevron.left") }
                    .disabled(model.current.parent == nil).accessibilityLabel("回上層")
                    .accessibilityIdentifier("back")
                VStack(alignment: .leading) {
                    Text("伺服器：\(serverName)").font(.headline)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("serverTitle")
                    Text("分享：\(shareName)").font(.subheadline)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("shareTitle")
                    Text(model.current.display).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("directoryPath")
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(isDemo ? "示範資料" : "SMB").font(.caption).padding(8).background(.orange.opacity(0.15), in: Capsule())
                Button("離開分享", action: disconnect)
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                if let parent = model.current.parent {
                    DirectoryColumn(model: model, path: parent, isCurrent: false, rootName: shareName).id(parent)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "externaldrive.connected.to.line.below").font(.largeTitle)
                        Text(shareName).font(.headline)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                DirectoryColumn(model: model, path: model.current, isCurrent: true, rootName: shareName).id(model.current)
            }
        }
        .task { model.start() }
        .sheet(item: $model.playback) { selection in
            PlaybackView(selection: selection, source: mediaSource, isDemo: isDemo) { model.playback = nil }
        }
    }
}

struct DirectoryColumn: View {
    @Bindable var model: BrowserModel
    let path: DirectoryPath
    let isCurrent: Bool
    let rootName: String
    private var state: DirectoryState { model.state(at: path) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isCurrent ? "本層" : "上層").font(.caption).foregroundStyle(.secondary)
                    Text(path.components.isEmpty ? rootName : path.name).font(.title3.bold()).lineLimit(1)
                        .accessibilityIdentifier(isCurrent ? "currentDirectoryTitle" : "parentDirectoryTitle")
                }
                Spacer()
                Text("\(state.entries.count) 項\(state.nextOffset == nil ? "" : "＋")").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(state.entries) { entry in
                        let selected = !isCurrent && path.appending(entry.name) == model.current || state.selectedID == entry.id
                        Button { model.select(entry, in: path) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: icon(entry)).font(.title3).frame(width: 28)
                                    .foregroundStyle(entry.kind == .directory ? .blue : .secondary)
                                Text(entry.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                if entry.kind == .directory { Image(systemName: "chevron.right").font(.caption) }
                            }.padding(14).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(selected ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                        .disabled(entry.kind == .other)
                        .accessibilityLabel(entry.name + (entry.kind == .directory ? "，資料夾" : "，檔案"))
                        .id(entry.id)
                    }
                }.scrollTargetLayout().padding(.horizontal, 12)
                if state.isLoading { ProgressView("載入中…").padding() }
                if let error = state.error {
                    VStack(spacing: 12) {
                        Text(error).multilineTextAlignment(.center)
                        if isCurrent { Button("重試", action: model.loadMore) }
                    }.padding()
                } else if state.entries.isEmpty && !state.isLoading && state.nextOffset == nil {
                    ContentUnavailableView("空資料夾", systemImage: "folder", description: Text("這裡目前沒有檔案。"))
                } else if isCurrent && state.nextOffset != nil && !state.isLoading {
                    Button("載入更多", action: model.loadMore).padding()
                        .onAppear { model.loadMore() }
                }
            }
            .scrollPosition(id: Binding(get: { state.scrollID }, set: { model.setScroll($0, at: path) }))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func icon(_ entry: FileEntry) -> String {
        switch entry.kind { case .directory: "folder.fill"; case .video: "film"; case .other: "doc" }
    }
}

struct PlaybackView: View {
    let selection: PlaybackSelection
    let source: (any MediaByteSource)?
    let isDemo: Bool
    var close: () -> Void
    @State private var inspection: MediaInspection?
    @State private var inspectionFailed = false
    @State private var attempt = 0
    @State private var playbackTask: Task<Void, Never>?
    @State private var playbackID = UUID()
    @State private var isPlaying = false
    @State private var trackInfo: VideoTrackInfo?
    @State private var frame: VideoFrame?
    @State private var playbackMessage: String?
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button("返回檔案", systemImage: "chevron.left", action: close)
                Spacer()
                Text("視訊播放器").font(.headline)
            }
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    if let frame {
                        Image(decorative: frame.image, scale: 1).resizable().scaledToFit()
                            .frame(maxHeight: 220).accessibilityIdentifier("decodedVideoFrame")
                    } else { Image(systemName: "play.rectangle").font(.system(size: 60)).foregroundStyle(.secondary) }
                    Text(selection.file.name).font(.title2).multilineTextAlignment(.center)
                    if isDemo { Text("示範資料").font(.caption) }
                    if let inspection {
                        Text("檔案大小：\(ByteCountFormatter.string(fromByteCount: Int64(clamping: inspection.fileSize), countStyle: .file))")
                        Text("檔頭：\(inspection.headerKind.rawValue)").accessibilityIdentifier("mediaHeader")
                    } else if inspectionFailed {
                        Text("無法讀取檔案資訊。請確認連線與檔案後重試。")
                        Button("重試") { attempt += 1 }
                    } else { ProgressView("讀取檔案資訊…") }
                    if let trackInfo {
                        Text("\(trackInfo.codec) · \(trackInfo.width) × \(trackInfo.height)").accessibilityIdentifier("videoTrackInfo")
                    }
                    Text("視訊播放，暫無音訊").font(.caption)
                    if let playbackMessage { Text(playbackMessage).accessibilityIdentifier("playbackStatus") }
                    HStack {
                        Button(isPlaying ? "播放中…" : "播放視訊", action: startPlayback)
                            .disabled(isPlaying).accessibilityIdentifier("playVideo")
                        if isPlaying { Button("停止", action: stopPlayback).accessibilityIdentifier("stopVideo") }
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 16)
            }
        }.padding(32).frame(width: 680, height: 620)
        .onDisappear(perform: stopPlayback)
        .task(id: attempt) {
            inspection = nil
            inspectionFailed = false
            do {
                guard let source else { throw MediaInspectionError.unavailable }
                let file = try MediaFile(components: selection.directory.components + [selection.file.name])
                let result = try await MediaInspector.inspect(file, source: source)
                try Task.checkCancellation()
                inspection = result
            } catch {
                if !Task.isCancelled { inspectionFailed = true }
            }
        }
    }
    private func stopPlayback() {
        playbackID = UUID()
        playbackTask?.cancel(); playbackTask = nil
        isPlaying = false; frame = nil
        playbackMessage = "已停止"
    }
    private func startPlayback() {
        guard !isPlaying, let source else { return }
        let id = UUID(); playbackID = id
        isPlaying = true; frame = nil; trackInfo = nil; playbackMessage = "正在準備影片…"
        playbackTask = Task {
            do {
                let file = try MediaFile(components: selection.directory.components + [selection.file.name])
                _ = try await HardwarePlayback().play(file: file, source: source, onInfo: { info in
                    guard playbackID == id else { return }; trackInfo = info
                }, onFrame: { next in
                    guard playbackID == id else { return }; frame = next; playbackMessage = "硬體解碼播放中"
                })
                guard playbackID == id else { return }; playbackMessage = "播放結束"
            } catch {
                guard playbackID == id else { return }
                playbackMessage = (error as? PlaybackFailure)?.message ?? "無法讀取影片。請確認連線及檔案後重試。"
            }
            if playbackID == id { isPlaying = false; playbackTask = nil }
        }
    }

}
