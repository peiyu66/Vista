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
            if ProcessInfo.processInfo.arguments.contains("--credential-self-test-write") || ProcessInfo.processInfo.arguments.contains("--credential-self-test-read") {
                CredentialSelfTestView()
            } else { ShortcutBrowserView().glassBackgroundEffect() }
            #else
            ShortcutBrowserView().glassBackgroundEffect()
            #endif
        }.windowStyle(.plain).defaultSize(initialSize).windowResizability(.contentMinSize)
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
