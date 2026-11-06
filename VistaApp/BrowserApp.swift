import SwiftUI

enum BrowserWindowPreferences {
    static var defaults:UserDefaults {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--shortcut-ui-tests") {
            return UserDefaults(suiteName:"org.peiyu66.Vista.BrowserPrototype.display-tests")!
        }
        #endif
        return .standard
    }
    static func load()->CGSize {
        let w=defaults.double(forKey:"windowWidth.v1"),h=defaults.double(forKey:"windowHeight.v1")
        guard w.isFinite,h.isFinite,w>=880,h>=620,w<=10000,h<=10000 else{return CGSize(width:1080,height:720)}
        return CGSize(width:w,height:h)
    }
    static func save(_ size:CGSize) {
        guard size.width.isFinite,size.height.isFinite,size.width>=880,size.height>=620,
              size.width<=10000,size.height<=10000 else{return}
        defaults.set(size.width,forKey:"windowWidth.v1");defaults.set(size.height,forKey:"windowHeight.v1")
    }
}
@main struct VistaApp: App {
    @State private var vr=VRPresentation()
    private let initialSize:CGSize
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--shortcut-ui-tests"),
           ProcessInfo.processInfo.arguments.contains("--reset-shortcut-fixture") {
            BrowserWindowPreferences.defaults.removeObject(forKey:"windowWidth.v1")
            BrowserWindowPreferences.defaults.removeObject(forKey:"windowHeight.v1")
        }
        #endif
        initialSize=BrowserWindowPreferences.load()
    }
    var body:some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--packing-renderer-review") {
                PackingRendererReview().frame(width:700,height:700)
            } else if ProcessInfo.processInfo.arguments.contains("--controller-layout-review") {
                VRImmersiveView().frame(width:600,height:1000)
                    .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--review-large-text") ? .xxxLarge:.large).onAppear {
                    vr.canClearFormat=true;vr.onClearFormat={vr.settings.projection = .equirectangular180;vr.settings.layout = .sideBySide};vr.settingsVisible=true;vr.fileTitle="合成控制器版面檢視";vr.player=PlaybackController()
                    if ProcessInfo.processInfo.arguments.contains("--review-fisheye") {vr.settings.projection = .equidistantFisheye180}
                }
            } else if ProcessInfo.processInfo.arguments.contains("--device-media-self-test") {
                DeviceMediaSelfTestView()
            } else if ProcessInfo.processInfo.arguments.contains("--credential-self-test-write") || ProcessInfo.processInfo.arguments.contains("--credential-self-test-read") {
                CredentialSelfTestView()
            } else { ShortcutBrowserView().glassBackgroundEffect().opacity(vr.active ? 0:1).allowsHitTesting(!vr.active).accessibilityHidden(vr.active).persistentSystemOverlays(vr.active ? .hidden : .automatic) }
            #else
            ShortcutBrowserView().glassBackgroundEffect().opacity(vr.active ? 0:1).allowsHitTesting(!vr.active).accessibilityHidden(vr.active).persistentSystemOverlays(vr.active ? .hidden : .automatic)
            #endif
        }.environment(vr).windowStyle(.plain).defaultSize(initialSize).windowResizability(.contentMinSize)
        ImmersiveSpace(id:"VistaVR") {VRImmersiveView().environment(vr)}
            .immersionStyle(selection:.constant(.full),in:.full)
    }
}
#if DEBUG
private struct CredentialSelfTestView:View {
    @State private var result="測試中"
    var body:some View {
        Text(result).accessibilityIdentifier("credentialTestResult").padding(40).task {
            let store=SMBCredentialStore(service:"org.peiyu66.Vista.BrowserPrototype.synthetic-test-only")
            let id=UUID(uuidString:"4AD3F322-A439-4E4E-9244-0A91F4523715")!
            do {
                if ProcessInfo.processInfo.arguments.contains("--credential-self-test-write") {
                    try store.save("synthetic-not-a-real-password",for:id)
                    result="測試憑證已保存"
                } else {
                    let matches=try store.load(for:id)=="synthetic-not-a-real-password"
                    try store.remove(for:id)
                    let cleared = try store.load(for:id) == nil
                    result=matches && cleared ? "測試憑證恢復與清理成功":"測試失敗"
                }
            } catch SMBCredentialStore.Failure.status(let status) {result="Keychain 測試失敗：\(status)"}
            catch {result="Keychain 測試失敗"}
        }
    }
}
#endif

#if DEBUG
/// Explicit synthetic-only device probe; never loads saved locations or credentials.
private struct DeviceMediaSelfTestView: View {
    @State private var status = "合成影片硬體解碼測試中…"
    @State private var detectedCodec = ""
    var body: some View {
        Text(status).padding(40).task {
            let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VistaSyntheticPlaybackReport.json")
            var results: [[String: Any]] = []
            func save(_ complete: Bool) {
                let report: [String: Any] = ["complete": complete, "softwareTest": PlaybackDecodingPolicy.simulatorSoftwareTest, "results": results]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: destination, options: .atomic)
                }
            }
            save(false)
            for (codec, name) in [("H.264", "H264 播放測試.mp4"), ("HEVC", "HEVC 播放測試.mp4")] {
                do {
                    detectedCodec = ""
                    let report = try await HardwarePlayback().play(file: MediaFile(components: [name]), source: DemoMediaSource(), onInfo: { info in detectedCodec = info.codec }, onFrame: { _ in })
                    results.append(["codec": codec, "frames": report.decodedFrames, "hardwareVerified": report.hardwareVerified, "audioSamples": report.audioSamples, "detectedCodec": detectedCodec, "success": detectedCodec == codec])
                } catch {
                    results.append(["codec": codec, "success": false, "failure": (error as? PlaybackFailure)?.message ?? "合成素材測試失敗"])
                }
                save(false)
            }
            save(true)
            status = "合成影片測試完成；此測試不代表沉浸或雙眼立體驗收。"
        }
    }
}
#endif
