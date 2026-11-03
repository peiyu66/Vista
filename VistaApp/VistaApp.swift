import SwiftUI

@main struct VistaApp: App {
    var body: some Scene {
        WindowGroup { ConnectionView() }
            .defaultSize(width: 1000, height: 680)
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
    var input: ConnectionInput { ConnectionInput(server: server, share: share, username: username) }
    var body: some View {
        Group {
            if let browser {
                BrowserView(model: browser, isDemo: isDemo) {
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
                            field("伺服器", hint: "例如 nas.example.test", value: $server)
                            field("分享名稱", hint: "例如 Videos", value: $share)
                            TextField("使用者名稱", text: $username).textContentType(.username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("密碼", text: $password).textContentType(.password)
                        }.textFieldStyle(.roundedBorder)
                        Text("帳密僅用於這次 SMB 連線，不會儲存。系統密碼建議是否可用，仍需裝置驗證。")
                            .font(.callout).foregroundStyle(.secondary)
                        if let message { Text(message).foregroundStyle(.orange).accessibilityIdentifier("connectionMessage") }
                        HStack {
                            Button(connecting ? "連線中…" : "連線") {
                                let submitted = input
                                let secret = password
                                password = ""; message = nil; connecting = true
                                connectionTask = Task {
                                    do {
                                        let connected = try await SMBDirectoryProvider.connect(input: submitted, password: secret)
                                        guard !Task.isCancelled else { await connected.disconnect(); connecting = false; return }
                                        session = connected; isDemo = false
                                        browser = BrowserModel(provider: connected)
                                    } catch {
                                        if !Task.isCancelled { message = "無法連線。請確認伺服器、分享名稱、帳密與網路後重試。" }
                                    }
                                    connecting = false
                                }
                            }.buttonStyle(.borderedProminent).disabled(!input.isValid || connecting)
                            if connecting {
                                Button("取消") { connectionTask?.cancel(); message = "正在取消連線…" }
                            }
                            Button("使用示範資料") {
                                password = ""; message = nil; isDemo = true
                                browser = BrowserModel(provider: DemoDirectoryProvider())
                            }.disabled(connecting).accessibilityIdentifier("openDemo")
                        }
                    }.padding(40).frame(maxWidth: 600)
                }
            }
        }.frame(minWidth: 800, minHeight: 560)
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
    var disconnect: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button(action: model.back) { Image(systemName: "chevron.left") }
                    .disabled(model.current.parent == nil).accessibilityLabel("回上層")
                    .accessibilityIdentifier("back")
                VStack(alignment: .leading) {
                    Text(isDemo ? "Vista · 示範分享" : "Vista · SMB 分享").font(.headline)
                    Text(model.current.display).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(isDemo ? "示範資料" : "SMB").font(.caption).padding(8).background(.orange.opacity(0.15), in: Capsule())
                Button("離開分享", action: disconnect)
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                if let parent = model.current.parent {
                    DirectoryColumn(model: model, path: parent, isCurrent: false).id(parent)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "externaldrive.connected.to.line.below").font(.largeTitle)
                        Text("分享根目錄").font(.headline)
                        Text("已在最上層").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                DirectoryColumn(model: model, path: model.current, isCurrent: true).id(model.current)
            }
            Divider()
            HStack {
                Text("點選資料夾進入下一層；左欄可切換同層資料夾。")
                Spacer()
                Text("僅瀏覽")
            }.font(.caption).foregroundStyle(.secondary).padding(16)
        }
        .task { model.start() }
        .sheet(item: $model.playback) { selection in
            PlaybackView(selection: selection) { model.playback = nil }
        }
    }
}

struct DirectoryColumn: View {
    @Bindable var model: BrowserModel
    let path: DirectoryPath
    let isCurrent: Bool
    private var state: DirectoryState { model.state(at: path) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isCurrent ? "本層" : "上層").font(.caption).foregroundStyle(.secondary)
                    Text(path.name).font(.title3.bold()).lineLimit(1)
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
    var close: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Button("返回檔案", systemImage: "chevron.left", action: close)
                Spacer()
                Text("播放預覽").font(.headline)
            }
            Spacer()
            Image(systemName: "play.rectangle").font(.system(size: 80)).foregroundStyle(.secondary)
            Text(selection.file.name).font(.title2).multilineTextAlignment(.center)
            Text("尚未啟用播放").font(.headline)
            Text("這是播放介面與返回流程預覽。影片需要經過 SMB 讀取、格式辨識與硬體解碼驗證後才能播放。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 500)
            HStack(spacing: 24) {
                Image(systemName: "gobackward.10")
                Image(systemName: "play.fill")
                Image(systemName: "goforward.10")
            }.font(.title).foregroundStyle(.tertiary).accessibilityLabel("播放控制尚未啟用")
            Spacer()
            Text("返回後保留瀏覽位置與選取檔案。").font(.caption).foregroundStyle(.secondary)
        }.padding(32).frame(width: 680, height: 520)
    }
}
