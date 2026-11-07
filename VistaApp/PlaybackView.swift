import SwiftUI
import CoreImage

struct PlaybackView: View {
    @Environment(VRPresentation.self) private var vr
    @Environment(\.openImmersiveSpace) private var openVR
    @Environment(\.dismissImmersiveSpace) private var dismissVR
    let selection: PlaybackSelection
    let source: (any MediaByteSource)?
    let isDemo: Bool
    let preferenceSource: VRPreferenceSource
    var directImmersive=false
    var nextFile: @MainActor (PlaybackSelection) async throws -> PlaybackSelection? = {_ in nil}
    var hasNext: @MainActor (PlaybackSelection) -> Bool = {_ in false}
    var previousFile: @MainActor (PlaybackSelection) async throws -> PlaybackSelection? = {_ in nil}
    var hasPrevious: @MainActor (PlaybackSelection) -> Bool = {_ in false}
    var close: () -> Void
    @State private var replacement: PlaybackSelection?
    @State private var advanceTask: Task<Void, Never>?
    @State private var autoplayReplacement = false
    private var playingSelection: PlaybackSelection { replacement ?? selection }
    @State private var inspection: MediaInspection?
    @State private var inspectionFailed = false
    @State private var preferenceMessage: String?
    @State private var rememberedFormat: VRFormatDimensions?
    @State private var appliedSettings=VRSettings()
    @State private var preferencesReady = false
    @State private var formatChoice = VRFormatChoice()
    @State private var attempt = 0
    @State private var player = PlaybackController()
    @State private var scrubTime = 0.0
    @State private var isScrubbing = false
    @State private var pixelPreview:CGImage?
    @State private var previewContext=CIContext()
    private var previewImage:CGImage? {player.frame?.image ?? pixelPreview}
    private struct PreviewKey:Hashable {let pixel:ObjectIdentifier?;let immersive:Bool}
    var body: some View {
        Group {
        if directImmersive {
            VStack(spacing:16) {
                Button("返回檔案",systemImage:"chevron.left") {Task {await stopAndReturn()}}.accessibilityIdentifier("returnToBrowser")
                if inspectionFailed {
                    Text("無法讀取影片，請確認連線與檔案後重試。")
                    Button("重試") {attempt += 1}
                } else {ProgressView("準備影片…")}
                if let message=vr.message {Text(message)}
                if let preferenceMessage {Text(preferenceMessage)}
            }.padding(24).accessibilityIdentifier("directPlaybackPreparation")
        } else {
        VStack(spacing: 16) {
            HStack {
                Button("返回檔案", systemImage: "chevron.left", action: {Task {await stopAndReturn()}})
                    .accessibilityLabel("返回檔案").accessibilityIdentifier("returnToBrowser")
                Spacer()
                Text("視訊播放器").font(.headline)
                if PlaybackDecodingPolicy.simulatorSoftwareTest {Text("模擬器解碼測試・非實機效能").font(.caption).accessibilityIdentifier("simulatorDecodeNotice")}
            }
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    if let image = previewImage {
                        Image(image, scale: 1, label: Text("影片畫面")).resizable().scaledToFit()
                            .frame(maxHeight: 220).accessibilityIdentifier("decodedVideoFrame")
                    } else { Image(systemName: "play.rectangle").font(.system(size: 60)).foregroundStyle(.secondary) }
                    Text(playingSelection.file.name).font(.title2).multilineTextAlignment(.center)
                    if isDemo { Text("示範資料").font(.caption) }
                    if PlaybackDecodingPolicy.simulatorSoftwareTest {
                        #if VISTA_NATIVE_PLAYER_EXPERIMENT
                        Text("AVPlayer 候選・解碼方式未知").accessibilityIdentifier("nativeDecodeMode")
                        #else
                        Text("模擬器軟體解碼測試版・非實機效能").foregroundStyle(.orange).accessibilityIdentifier("simulatorDecodeMode")
                        #endif
                    }
                    if let inspection {
                        Text("檔案大小：\(ByteCountFormatter.string(fromByteCount: Int64(clamping: inspection.fileSize), countStyle: .file))")
                        Text("檔頭：\(inspection.headerKind.rawValue)").accessibilityIdentifier("mediaHeader")
                    } else if inspectionFailed {
                        Text("無法讀取檔案資訊。請確認連線與檔案後重試。")
                        Button("重試") { attempt += 1 }
                    } else { ProgressView("讀取檔案資訊…") }
                    if let trackInfo = player.trackInfo {
                        Text("\(trackInfo.codec) · \(trackInfo.width) × \(trackInfo.height)").accessibilityIdentifier("videoTrackInfo")
                        Slider(value: $scrubTime, in: 0...trackInfo.duration,
                               onEditingChanged: { editing in
                                   isScrubbing = editing
                                   if !editing { player.seek(to: scrubTime) }
                               })
                            .accessibilityLabel("播放位置").accessibilityIdentifier("playbackPosition")
                        Text("\(timeLabel(isScrubbing ? scrubTime : player.position)) / \(timeLabel(trackInfo.duration))")
                            .monospacedDigit().accessibilityIdentifier("playbackTime")
                    }
                    VRSettingsView(presentation: vr, edited: chooseManualFormat).disabled(!preferencesReady)
                    if !formatChoice.hasManual {
                        if let metadata = formatChoice.metadata {
                            Text(metadata.message).font(.callout).accessibilityIdentifier("vrMetadataStatus")
                        } else if preferencesReady {
                            ProgressView("讀取格式標記…")
                        }
                        if preferencesReady && !formatChoice.confirmed {
                            Button("使用目前格式", action: chooseManualFormat).accessibilityIdentifier("confirmVRFormat")
                        }
                    }
                    if rememberedFormat != nil {
                        Button("清除此片格式") {
                            clearSavedFormat()
                        }
                            .accessibilityIdentifier("clearVRFormat")
                    }
                    if let preferenceMessage { Text(preferenceMessage).accessibilityIdentifier("vrPreferenceError") }
                    HStack {
                        Button("進入 VR") { Task { await enterVR(testPattern: false) } }
                            .disabled((player.frame == nil && player.pixelFrame == nil) || !formatChoice.confirmed || vr.active || vr.opening).accessibilityIdentifier("openVR")
                        if isDemo {
                            Button("投影測試圖") { Task { await enterVR(testPattern: true) } }
                                .disabled(vr.active || vr.opening).accessibilityIdentifier("openVRTest")
                        }
                    }
                    if let message = vr.message { Text(message) }
                    if let trackInfo = player.trackInfo, !trackInfo.hasAudio { Text("影片無音軌").font(.caption) }
                    Text(player.speedStatus.text).font(.caption.monospacedDigit()).accessibilityIdentifier("flatPlaybackSpeed")
                    if player.speedStatus.ready,!player.speedStatus.supportsFastForward {Text("此影片最高 2×").font(.caption2)}
                    if let message=player.speedMessage {Text(message).font(.caption)}
                    if let playbackMessage = player.message { Text(playbackMessage).accessibilityIdentifier("playbackStatus") }
                    HStack {
                        if player.trackInfo != nil {
                            Button("恢復 1 倍速") { player.resetSpeed() }
                                .disabled(!player.canResetSpeed).accessibilityIdentifier("skipBackward")
                            Button("加速 1 倍", systemImage: "forward.fill") { player.increaseSpeed() }
                                .disabled(!player.canIncreaseSpeed).labelStyle(.iconOnly).accessibilityIdentifier("skipForward")
                        }
                        if player.isPlaying {
                            Button(player.isPaused ? "繼續" : "暫停", action: player.togglePause)
                                .disabled(player.isPreparing).accessibilityIdentifier("pauseResumeVideo")
                            Button("停止") { Task { await stopAndReturn() } }.accessibilityIdentifier("stopVideo")
                        } else {
                            Button("播放", action: startPlayback).accessibilityIdentifier("playVideo")
                                .disabled(!preferencesReady || !formatChoice.confirmed || vr.opening)
                        }
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 16)
            }
        }.padding(24).frame(maxWidth: 680, maxHeight: .infinity)
        }
        }
        .task(id:PreviewKey(pixel:player.pixelFrame.map(ObjectIdentifier.init),immersive:vr.active)) {
            // Flat preview retains the original packed 2D image; immersive rendering never pays this conversion.
            guard !vr.active,let frame=player.pixelFrame else {pixelPreview=nil;return}
            let image=frame.makeImage(context:previewContext)
            guard !Task.isCancelled else{return}
            pixelPreview=image
        }
        .onAppear { vr.settings = VRSettings(); vr.message = nil; vr.calibration.resetForNewFile() }
        .onDisappear {
            advanceTask?.cancel(); vr.openRequest = nil
            player.stop()
            if vr.active { Task { await dismissVR() } }
        }
        .onChange(of: player.position) { _, position in
            if !isScrubbing { scrubTime = position }
        }
        .task(id: playingSelection.id + "#" + String(attempt)) {
            preferencesReady = false;vr.canClearFormat=false
            formatChoice = VRFormatChoice();formatChoice.filename=playingSelection.file.name; rememberedFormat = nil
            inspection = nil
            inspectionFailed = false
            if directImmersive && !vr.active {
                await enterVR(testPattern: false, preparing: true)
                guard vr.active, !Task.isCancelled else { return }
            }
            if directImmersive { vr.advancing = true; vr.holdControls() }
            do {
                #if DEBUG
                if isDemo && ProcessInfo.processInfo.arguments.contains("--slow-media-preparation") {
                    try await Task.sleep(for: .seconds(30))
                }
                if isDemo && ProcessInfo.processInfo.arguments.contains("--failed-media-preparation") {
                    throw MediaInspectionError.unavailable
                }
                #endif
                guard let source else { throw MediaInspectionError.unavailable }
                let file = try MediaFile(components: playingSelection.directory.components + [playingSelection.file.name])
                let result = try await MediaInspector.inspect(file, source: source)
                try Task.checkCancellation()
                inspection = result
                do {
                    let saved = try VRPreferenceStore.local.get().loadDimensions(source: preferenceSource, file: file, revision: result.revision)
                    rememberedFormat = saved
                    formatChoice.manualDimensions = saved
                    vr.settings = formatChoice.format.settings
                    preferenceMessage = nil
                } catch { preferenceMessage = "無法讀取已存格式；仍可手動設定。" }
                preferencesReady = true;vr.canClearFormat=rememberedFormat != nil
                let metadata = try await VRMetadataInspector.inspect(file, source: source)
                try Task.checkCancellation()
                formatChoice.metadata = metadata
                vr.settings = formatChoice.format.settings;appliedSettings=vr.settings
                if autoplayReplacement {finishReplacementPreparation()}
                else if directImmersive {
                    vr.advancing = false
                    vr.requiresFormatConfirmation = !formatChoice.confirmed
                    vr.settingsVisible = !formatChoice.confirmed
                    if formatChoice.confirmed { startPlayback() }
                    else { vr.holdControls() }
                }
            } catch {
                if !Task.isCancelled {
                    player.persistDiagnostics(event:.failed,rendererValues:[.failureKind:1])
                    inspectionFailed = true; preferencesReady = true; formatChoice.metadata = .unavailable
                    preferenceMessage = "無法確認檔案；本次格式不會保存。"
                    autoplayReplacement = false
                    vr.advancing = false
                    vr.message = "無法讀取影片，請停止返回檔案列表，確認連線與檔案後再試。"
                    vr.holdControls()
                }
            }
        }
    }
    private func chooseManualFormat() {
        guard preferencesReady else { return }
        var changed=formatChoice.manualDimensions ?? .init()
        if vr.settings.projection != appliedSettings.projection {changed.projection=vr.settings.projection}
        if vr.settings.layout != appliedSettings.layout {changed.layout=vr.settings.layout}
        if changed.isEmpty {changed = .init(VRFormat(vr.settings))}
        formatChoice.manualDimensions=changed;appliedSettings=vr.settings
        _ = saveFormat(changed)
        vr.requiresFormatConfirmation = !formatChoice.confirmed
    }
    private func clearSavedFormat() {
        guard saveFormat(nil) else {vr.message=preferenceMessage;return}
        formatChoice.manualDimensions=nil;formatChoice.manual=nil
        let fallback=formatChoice.format.settings
        vr.settings.projection=fallback.projection;vr.settings.layout=fallback.layout
        appliedSettings=vr.settings;vr.requiresFormatConfirmation = !formatChoice.confirmed
    }
    @discardableResult private func saveFormat(_ format: VRFormatDimensions?) -> Bool {
        guard let inspection,
              let file = try? MediaFile(components: playingSelection.directory.components + [playingSelection.file.name]) else { return false }
        do {
            try VRPreferenceStore.local.get().saveDimensions(format, source: preferenceSource, file: file, revision: inspection.revision)
            rememberedFormat = format; preferenceMessage = nil; vr.canClearFormat = format != nil
            return true
        } catch { preferenceMessage = "無法保存格式；本次設定仍可使用。"; return false }
    }
    private func timeLabel(_ value: Double) -> String {
        let seconds = Int(max(0, min(value, Double(Int.max / 2))))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    private func configureImmersiveCallbacks() {
        vr.fileTitle = playingSelection.file.name
        vr.canAdvance = hasNext(playingSelection)
        vr.canGoBack = hasPrevious(playingSelection)
        vr.onStop = { advanceTask?.cancel(); player.stop(); close() }
        vr.onCancelNavigation = { advanceTask?.cancel() }
        vr.onNext = { advanceToAdjacent(backward:false) }
        vr.onPrevious = { advanceToAdjacent(backward:true) }
        vr.onReplay = startPlayback
        vr.onFormatChanged = chooseManualFormat
        vr.onClearFormat = clearSavedFormat
        vr.canClearFormat = rememberedFormat != nil
    }
    private func finishReplacementPreparation() {
        guard autoplayReplacement else { return }
        autoplayReplacement = false
        guard vr.active else { return }
        configureImmersiveCallbacks()
        vr.advancing = false
        vr.requiresFormatConfirmation = !formatChoice.confirmed
        // Preserve expansion during this immersive session; confirmation is shown independently.
        if !formatChoice.confirmed {vr.endControllerNavigation(showError:true)}
        vr.holdControls()
        if formatChoice.confirmed { startPlayback() }
    }
    private func advanceToAdjacent(backward:Bool) {
        guard vr.active, !vr.stopping, !vr.advancing else { return }
        vr.beginControllerNavigation()
        vr.advancing = true; vr.message = nil; vr.holdControls()
        let previous = playingSelection
        advanceTask = Task {
            do {
                let next = try await (backward ? previousFile(previous) : nextFile(previous))
                guard !Task.isCancelled, vr.active, !vr.stopping else { return }
                guard let next else {
                    vr.advancing = false
                    if backward { vr.canGoBack = false } else { vr.canAdvance = false }
                    vr.endControllerNavigation()
                    return
                }
                player.stop()
                autoplayReplacement = true
                vr.calibration.resetForNewFile();vr.calibrationRequest += 1
                replacement = next
            } catch {
                guard !Task.isCancelled, vr.active, !vr.stopping else { return }
                vr.advancing = false; vr.endControllerNavigation(showError:true);vr.message = "無法切換影片，請稍後重試。"
            }
        }
    }
    private func stopAndReturn() async {
        advanceTask?.cancel(); vr.openRequest = nil; player.stop()
        if vr.active { await dismissVR() }
        vr.finishSession()
        close()
    }
    private func enterVR(testPattern: Bool, preparing: Bool = false) async {
        guard !vr.active, !vr.opening, preparing || testPattern || formatChoice.confirmed else { return }
        let request = UUID(); vr.openRequest = request
        vr.opening = true; vr.message = nil
        if testPattern { player.stop(); vr.onStop = nil }
        else { configureImmersiveCallbacks() }
        vr.player = player; vr.testPattern = testPattern
        vr.advancing = preparing
        vr.controlsVisible = true; vr.settingsVisible = false
        let result = await openVR(id: "VistaVR")
        guard vr.openRequest == request else {
            if case .opened = result { await dismissVR() }
            return
        }
        switch result {
        case .opened: vr.active = true; vr.revealControls()
        case .userCancelled: vr.player = nil; vr.testPattern = false; vr.advancing = false; player.stop(); vr.message = "已取消進入沉浸空間。"
        default: vr.player = nil; vr.testPattern = false; vr.advancing = false; player.stop(); vr.message = "無法開啟 VR 空間。"
        }
        vr.opening = false
    }
    private func startPlayback() {
        guard preferencesReady, !inspectionFailed, formatChoice.confirmed, !vr.opening, !vr.advancing,
              let source,
              let file = try? MediaFile(components: playingSelection.directory.components + [playingSelection.file.name]) else { return }
        configureImmersiveCallbacks()
        vr.requiresFormatConfirmation = false
        if vr.active || !directImmersive {
            player.play(file: file, source: source, sourceKind:isDemo ? .synthetic : source is LocalDirectoryProvider ? .local : .smb); vr.revealControls()
        } else {
            Task {
                await enterVR(testPattern: false)
                guard vr.active, !Task.isCancelled else { return }
                player.play(file: file, source: source, sourceKind:isDemo ? .synthetic : source is LocalDirectoryProvider ? .local : .smb); vr.revealControls()
            }
        }
    }
}
