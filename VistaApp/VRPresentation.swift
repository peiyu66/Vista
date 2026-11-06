import ImageIO
import SwiftUI
import RealityKit
import Observation
import AVFoundation
import CoreImage

private struct ControllerBackgroundTarget:Component {}

@MainActor @Observable final class VRPresentation {
    var settings = VRSettings()
    var player: PlaybackController?
    var testPattern = false
    var active = false
    var opening = false
    var message: String?
    let calibration = VRViewCalibration()
    var calibrationRequest = 0
    var scrubbing = false
    var movingControls = false
    var controlsOffset = SIMD3<Float>.zero
    var preservePlacementAcrossFiles = false
    var navigationVisibility:Bool?
    var controlsVisible = true
    var settingsVisible = false
    var diagnosticsVisible = false
    var advancing = false
    var canAdvance = false
    var canGoBack = false
    var stopping = false
    var requiresFormatConfirmation = false
    var fileTitle = ""
    var onStop: (() -> Void)?
    var onCancelNavigation: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onReplay: (() -> Void)?
    var onFormatChanged: (() -> Void)?
    var onClearFormat: (() -> Void)?
    var canClearFormat=false
    var openRequest: UUID?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    func revealControls() {
        if let saved=navigationVisibility {controlsVisible=saved;return}
        controlsVisible = true
        scheduleHide()
    }
    func scheduleHide() {
        hideTask?.cancel()
        guard active, !movingControls, !scrubbing, message == nil, !testPattern, !settingsVisible, !diagnosticsVisible, !requiresFormatConfirmation, !advancing,
              let player, player.isPlaying, !player.isPaused, !player.isPreparing else { return }
        hideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, !Task.isCancelled, self.active, !self.settingsVisible, !self.diagnosticsVisible,
                  !self.requiresFormatConfirmation, !self.advancing, !self.scrubbing,
                  self.player?.isPlaying == true, self.player?.isPaused == false else { return }
            self.controlsVisible = false
        }
    }
    func toggleControlsFromBackground() {
        guard active, !testPattern, !movingControls, !scrubbing else { return }
        hideTask?.cancel(); hideTask = nil
        if navigationVisibility != nil {
            controlsVisible.toggle();navigationVisibility=controlsVisible;return
        }
        if controlsVisible { controlsVisible = false }
        else { revealControls() }
    }
    func holdControls() { hideTask?.cancel(); controlsVisible = navigationVisibility ?? true }
    func beginControllerNavigation() {
        navigationVisibility=controlsVisible;preservePlacementAcrossFiles=true;hideTask?.cancel()
    }
    func endControllerNavigation(showError:Bool=false) {
        if let saved=navigationVisibility {controlsVisible=showError ? true:saved}
        navigationVisibility=nil
        if controlsVisible {scheduleHide()}
    }
    func finishSession() {
        let callback = onStop
        onStop = nil; onCancelNavigation = nil; onNext = nil; onPrevious = nil; onReplay = nil; onFormatChanged = nil; onClearFormat = nil; canClearFormat=false
        openRequest = nil; hideTask?.cancel(); hideTask = nil
        player?.stop(); player = nil; active = false; opening = false; testPattern = false
        controlsVisible = true; settingsVisible = false; diagnosticsVisible = false; advancing = false; stopping = false
        scrubbing = false; movingControls = false; controlsOffset = .zero
        preservePlacementAcrossFiles=false;navigationVisibility=nil
        callback?()
    }
    var image: CGImage? {
        testPattern ? (settings.projection == .equidistantFisheye180 ? Self.fisheyePatterns[settings.layout] : Self.pattern) : player?.frame?.image
    }
    private static let fisheyePatterns: [VRLayout: CGImage] = VRLayout.allCases.reduce(into: [:]) { result, layout in
        result[layout] = VRFisheyeCalibration.image(layout: layout)
    }
    static let pattern: CGImage? = {
        guard let context = CGContext(data: nil, width: 1024, height: 512, bitsPerComponent: 8, bytesPerRow: 4096,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for y in 0..<8 { for x in 0..<16 {
            context.setFillColor(CGColor(red: CGFloat(x) / 15, green: CGFloat(y) / 7, blue: x.isMultiple(of: 2) ? 0.15 : 0.65, alpha: 1))
            context.fill(CGRect(x: x * 64, y: y * 64, width: 64, height: 64))
        } }
        context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(3)
        for x in stride(from: 0, through: 1024, by: 64) { context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: 512)) }
        for y in stride(from: 0, through: 512, by: 64) { context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: 1024, y: y)) }
        context.strokePath()
        return context.makeImage()
    }()
}

struct VRSettingsView: View {
    @Bindable var presentation: VRPresentation
    var edited: () -> Void = {}
    var body: some View {
        Text("影片格式").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).accessibilityAddTraits(.isHeader).accessibilityIdentifier("videoFormatHeading")
        HStack(spacing:8) {
            projectionChoice("180°",.equirectangular180)
            projectionChoice("360°",.equirectangular360)
            projectionChoice("魚眼",.equidistantFisheye180)
        }.accessibilityElement(children:.contain).accessibilityLabel("投影")
        HStack(spacing:8) {
            layoutChoice("上下",.overUnder)
            layoutChoice("左右",.sideBySide)
            layoutChoice("單眼",.mono)
        }.accessibilityElement(children:.contain).accessibilityLabel("畫面排列")
        if presentation.settings.projection == .equidistantFisheye180 {
            explanation.accessibilityIdentifier("fisheyeScope")
        } else {
            explanation.hidden().accessibilityHidden(true)
        }
    }
    private var explanation:some View {
        Text("每眼須為置中的 180° 等距圓形影像，圓徑等於短邊；不適用前後雙魚眼 360° 或需鏡頭校正的素材。")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal:false,vertical:true).allowsHitTesting(false)
    }
    private func projectionChoice(_ title:LocalizedStringKey,_ value:VRProjection)->some View {
        choice(title,description:value.title,selected:presentation.settings.projection == value,identifier:"projection-"+value.rawValue) {
            guard presentation.settings.projection != value else{return}
            presentation.settings.projection=value;edited()
        }
    }
    private func layoutChoice(_ title:LocalizedStringKey,_ value:VRLayout)->some View {
        choice(title,description:value.title,selected:presentation.settings.layout == value,identifier:"layout-"+value.rawValue) {
            guard presentation.settings.layout != value else{return}
            presentation.settings.layout=value;edited()
        }
    }
    private func choice(_ title:LocalizedStringKey,description:String,selected:Bool,identifier:String,action:@escaping ()->Void)->some View {
        Button(action:action) {
            Text(title).lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth:.infinity,minHeight:44).padding(.horizontal,6)
                .foregroundStyle(selected ? BrowserBluePalette.emphasis:Color.primary)
                .background(selected ? BrowserBluePalette.selection.opacity(0.35):Color.white.opacity(0.05),in:Capsule())
                .overlay(Capsule().strokeBorder(selected ? BrowserBluePalette.emphasis.opacity(0.7):.clear,lineWidth:1))
                .contentShape(.interaction,Capsule()).contentShape(.hoverEffect,Capsule())
        }.buttonStyle(.plain).hoverEffect(.highlight)
            .accessibilityLabel(description).accessibilityValue(selected ? "已選取":"未選取")
            .accessibilityAddTraits(selected ? .isSelected:[]).accessibilityIdentifier(identifier)
    }
}

struct VRImmersiveView: View {
    @Environment(VRPresentation.self) private var presentation
    @Environment(\.dismissImmersiveSpace) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var renderer = VRRenderer()
    @State private var systemRenderer = SystemVideoPresenter()
    @State private var placement = Entity()
    @State private var controllerEntryPose:VRInitialPose?
    @State private var controllerReference:Entity = {let entity=Entity();entity.position=[0,1.5,0];return entity}()
    @State private var controlsAnchor: AnchorEntity = {
        let anchor = AnchorEntity(.head)
        anchor.anchoring.trackingMode = .once
        return anchor
    }()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controlVisual=ControllerVisualState()
    @State private var scrubPosition=0.0
    @State private var draggingControls = false
    private var controlEntity:Entity? {controlVisual.entity}
    @State private var moveHandle: ModelEntity = {
        var mesh=MeshDescriptor(name:"Controller capsule")
        let outline=VRControllerHandle.outline
        mesh.positions=MeshBuffers.Positions([.zero]+outline)
        mesh.normals=MeshBuffers.Normals(Array(repeating:[0,0,1],count:outline.count+1))
        mesh.primitives = .triangles((0..<outline.count).flatMap { [UInt32(0),UInt32($0+1),UInt32(($0+1)%outline.count+1)] })
        var material=UnlitMaterial(color:UIColor(white:0.60,alpha:1))
        material.faceCulling = .none
        let entity=ModelEntity()
        if let resource=try? MeshResource.generate(from:[mesh]) {entity.model=ModelComponent(mesh:resource,materials:[material])}
        entity.name="vista-controls-move-handle"
        entity.components.set(CollisionComponent(shapes:[.generateBox(size:[0.22,0.022,0.04])]))
        entity.components.set(InputTargetComponent(allowedInputTypes:.indirect))
        entity.components.set(HoverEffectComponent())
        return entity
    }()
    private struct UpdateKey: Hashable { let image: ObjectIdentifier?; let settings: VRSettings; let pixel:ObjectIdentifier? }
    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--controller-layout-review") { playerControls }
        else { immersiveBody }
        #else
        immersiveBody
        #endif
    }
    private var immersiveBody:some View {
        RealityView { content, attachments in
            content.add(placement)
            content.add(controlsAnchor)
            content.add(controllerReference)
            placement.addChild(renderer.entity)
            placement.addChild(systemRenderer.entity)
            addTapTargets()
            applyPlacement()
            placeControls(attachments.entity(for: "controls"))
        } update: { _, attachments in
            applyPlacement()
            placeControls(attachments.entity(for: "controls"))
        } attachments: {
            Attachment(id: "controls") {
                if !presentation.testPattern {
                    playerControls
                } else {
                VStack {
                    if presentation.testPattern {
                        Text("投影測試圖，非影片播放").accessibilityIdentifier("vrTestPattern")
                        if presentation.settings.projection == .equidistantFisheye180 {
                            Text("魚眼校準圖：環線 30°／60°／90°，上綠、右紅、下藍、左黃")
                                .font(.caption).accessibilityIdentifier("fisheyeCalibration")
                        }
                    }
                    if presentation.calibration.status == .capturing {
                        ProgressView("設定初始方向…")
                    } else if presentation.calibration.status == .unavailable {
                        Text("無法取得初始方向；可手動調整或重新置中。")
                            .font(.caption).accessibilityIdentifier("initialPoseUnavailable")
                    }
                    if let error = renderer.error { Text(error).accessibilityIdentifier("vrError") }
                    else if renderer.ready { Text(presentation.settings.projection.title).accessibilityIdentifier("vrReady") }
                    else { ProgressView("準備投影…") }
                    Text(presentation.settings.layout.title).accessibilityIdentifier("vrLayoutReady")
                    HStack {
                        Button("向左轉") { presentation.settings.yawDegrees -= 15 }
                        Button("方向歸零") { resetManualDirection() }
                        Button("向右轉") { presentation.settings.yawDegrees += 15 }
                    }
                    .accessibilityIdentifier("recenterVideo").accessibilityHint("以目前觀看方向重新置中影片")
                    .disabled(presentation.calibration.status == .capturing)
                    HStack {
                        Button("向上轉") { presentation.settings.pitchDegrees += 15 }
                        Button("向下轉") { presentation.settings.pitchDegrees -= 15 }
                        Button("左傾") { presentation.settings.rollDegrees += 15 }
                        Button("右傾") { presentation.settings.rollDegrees -= 15 }
                    }.accessibilityIdentifier("recenterVideo").accessibilityHint("以目前觀看方向重新置中影片")
                    .disabled(presentation.calibration.status == .capturing)
                    Button("重新置中") {
                        presentation.calibration.requestRecenter(); presentation.calibrationRequest += 1
                    }.accessibilityIdentifier("recenterVideo").accessibilityHint("以目前觀看方向重新置中影片")
                    .disabled(presentation.calibration.status == .capturing)
                        .accessibilityIdentifier("recenterVR")
                        .accessibilityValue(presentation.calibration.status == .ready ? "已取得初始方向" : "尚未取得初始方向")
                    if !presentation.testPattern, let player = presentation.player {
                        Button(player.isPaused ? "繼續" : "暫停", action: player.togglePause).disabled(player.isPreparing || !player.isPlaying)
                    }
                    Button("返回視窗") { Task { await dismiss(); presentation.active = false } }.accessibilityIdentifier("closeVR")
                }.padding().glassBackgroundEffect()
                }
            }
        }
        .gesture(SpatialTapGesture(count:3).targetedToEntity(where:.has(ControllerBackgroundTarget.self))
            .exclusively(before:SpatialTapGesture(count:2).targetedToEntity(where:.has(ControllerBackgroundTarget.self))
                .exclusively(before:SpatialTapGesture(count:1).targetedToEntity(where:.has(ControllerBackgroundTarget.self))))
            .onEnded { result in
                let count:Int;let entity:Entity
                switch result {
                case .first(let event):count=3;entity=event.entity
                case .second(.first(let event)):count=2;entity=event.entity
                case .second(.second(let event)):count=1;entity=event.entity
                }
                switch VRBackgroundInteraction.action(taps:count,isBackground:entity.name.hasPrefix("show-controls-"),active:presentation.active,
                    testPattern:presentation.testPattern,moving:presentation.movingControls,scrubbing:presentation.scrubbing) {
                case .none:break
                case .toggle:presentation.toggleControlsFromBackground()
                case .reset:resetControllerPosition()
                case .recenterVideo:resetVideoDirection()
                }

            })
        .simultaneousGesture(DragGesture(minimumDistance: 3).targetedToEntity(moveHandle)
            .onChanged { value in
                guard presentation.controlsVisible,!presentation.scrubbing,let parent=controlEntity?.parent else{return}
                guard let controls=controlEntity else{return}
                let pointer=value.convert(value.location3D,from:.local,to:parent)
                if !draggingControls {
                    draggingControls=true
                    controlVisual.localGrab=controls.convert(position:pointer,from:parent)
                    controlVisual.dragPointer=pointer
                    presentation.movingControls=true
                    faceViewerDuringDrag()
                }
                presentation.movingControls=true;presentation.holdControls()
                controlVisual.dragPointer=pointer
                updateDraggedPosition(controls)
                placeControls(controls)
            }.onEnded { _ in
                draggingControls=false;presentation.movingControls=false
                controlVisual.poseTask?.cancel();controlVisual.poseTask=nil
                controlVisual.dragPointer=nil
                faceViewerAfterDrag()
                presentation.scheduleHide()
            })
        .onChange(of: presentation.player?.isPaused) { _, _ in presentation.revealControls() }
        .onChange(of: presentation.player?.isPreparing) { _, preparing in
            if preparing == false,presentation.navigationVisibility != nil {presentation.endControllerNavigation()}
            else {presentation.revealControls()}
        }
        .onChange(of: presentation.player?.isPlaying) { _, _ in presentation.revealControls() }
        .onChange(of: renderer.error) { _, error in
            if let error {presentation.player?.persistDiagnostics(event:.rendererFailed);presentation.message=error;presentation.holdControls()}
        }
        .onChange(of: systemRenderer.lastSubmittedSession) {_,session in
            if let session {presentation.player?.markRendererSubmitted(session:session,enqueuedAt:systemRenderer.lastSubmittedAt)}
        }
        .onChange(of: systemRenderer.error) {_,error in
            guard let error else{return}
            presentation.message=error
            presentation.player?.persistDiagnostics(event:.rendererFailed)
            presentation.player?.stop()
            presentation.holdControls()
        }
        .onChange(of: presentation.message) {_,message in if message != nil {presentation.endControllerNavigation(showError:true);presentation.holdControls()}}
        .onChange(of: presentation.settings) { _, _ in updateControllerReference() }
        .onChange(of: presentation.settingsVisible) { _, _ in presentation.revealControls() }
        .onAppear { presentation.revealControls() }
        .task {
            while !Task.isCancelled {
                if let player=presentation.player,player.isPlaying || player.isPreparing {
                    player.persistDiagnostics(projection:VRProjection.allCases.firstIndex(of:presentation.settings.projection) ?? 0,layout:VRLayout.allCases.firstIndex(of:presentation.settings.layout) ?? 0,route:presentation.settings.projection == .equidistantFisheye180 ? 1:0,rendererValues:renderer.logValues)
                }
                do {try await Task.sleep(for:.seconds(1))}catch{return}
            }
        }
        .task(id: UpdateKey(image: presentation.image.map(ObjectIdentifier.init), settings: presentation.settings,pixel:presentation.player?.pixelFrame.map(ObjectIdentifier.init))) {
            #if VISTA_SYSTEM_VIDEO_EXPERIMENT
            if !presentation.testPattern,let frame=presentation.player?.pixelFrame {
                if #available(visionOS 26.0,*),SystemVideoSamples.supports(frame,settings:presentation.settings) {
                    renderer.stop()
                    systemRenderer.submit(frame,settings:presentation.settings)
                } else {
                    systemRenderer.stop()
                    renderer.submit(frame:frame,settings:presentation.settings,metrics:presentation.player?.metrics)
                }
            } else {
                systemRenderer.stop()
                renderer.submit(image:presentation.image,settings:presentation.settings,metrics:presentation.player?.metrics)
            }
            #else
            renderer.submit(image: presentation.image, settings: presentation.settings,metrics:presentation.player?.metrics)
            #endif
        }
        .task {
            // Copy the one-shot entry head pose into an ordinary, stationary world entity.
            // Keep attachments in stable scene coordinates after the initial head transform capture.
            for _ in 0..<180 {
                guard !Task.isCancelled else{return}
                if controlsAnchor.isAnchored {
                    controllerEntryPose=VRInitialPose(matrix:controlsAnchor.transformMatrix(relativeTo:nil))
                    updateControllerReference()
                    placeControls(controlEntity)
                    return
                }
                do {try await Task.sleep(for:.milliseconds(16))} catch{return}
            }
        }
        .task(id: presentation.calibrationRequest) {
            if await presentation.calibration.capture(using: DeviceInitialPose()) { resetManualDirection();updateControllerReference() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                presentation.player?.pauseForBackground()
                presentation.holdControls()
            }
        }
        .onDisappear {
            presentation.calibration.cancel()
            controlVisual.fadeTask?.cancel();controlVisual.fadeTask=nil
            controlVisual.facingTask?.cancel();controlVisual.facingTask=nil
            controlVisual.poseTask?.cancel();controlVisual.poseTask=nil
            controlVisual.dragPointer=nil;draggingControls=false
            renderer.stop();systemRenderer.stop(); presentation.finishSession()
        }
    }
    private var submittedAccessibilityValue:String {
        #if VISTA_SYSTEM_VIDEO_EXPERIMENT
        return (renderer.ready || systemRenderer.ready) ? "影格已提交":"準備影像"
        #else
        return renderer.ready ? "影像已呈現":"準備影像"
        #endif
    }
    private var candidateRouteText:String {
        #if VISTA_NATIVE_PLAYER_EXPERIMENT
        let label="AVPlayer 候選"
        #else
        let label="B 系統呈現候選"
        #endif
        if let error=systemRenderer.error {return label+"："+error}
        if presentation.settings.projection == .equidistantFisheye180,renderer.ready { return label+"：魚眼投影，"+renderer.route }
        if let frame=presentation.player?.pixelFrame {
            if #available(visionOS 26.0,*) {
                if let reason=SystemVideoSamples.fallbackReason(frame,settings:presentation.settings) {return label+"相容回退："+reason+"（原雙貼圖）"}
            } else {return label+"相容回退：系統版本（原雙貼圖）"}
        }
        return systemRenderer.ready ? label+"：送入 renderer，尚非雙眼驗收":label+"：準備中"
    }
    @ViewBuilder private var playerControls: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    guard !presentation.stopping else { return }
                    presentation.stopping = true
                    presentation.onCancelNavigation?()
                    presentation.player?.stop()
                    Task { await dismiss(); presentation.finishSession() }
                } label: { Image(systemName:"chevron.backward") }
                .accessibilityLabel("停止並返回瀏覽").accessibilityIdentifier("immersiveStop")
                .disabled(presentation.stopping)
                Text(presentation.fileTitle).font(.caption).lineLimit(1)
                .frame(maxWidth:.infinity).padding(.vertical,6).contentShape(Rectangle())
                .accessibilityIdentifier("immersiveFileTitle").accessibilityValue(submittedAccessibilityValue)
            }
            #if DEBUG && VISTA_DIAGNOSTIC_UI
            #if VISTA_SYSTEM_VIDEO_EXPERIMENT
            Text(candidateRouteText)
                .font(.caption2).accessibilityIdentifier("systemVideoCandidate")
                .accessibilityValue("materialInstances=\(systemRenderer.materialCreationCount)")
            if !systemRenderer.probe.isEmpty {Text(systemRenderer.probe).font(.caption2).accessibilityIdentifier("systemVideoProbe")}
            #elseif VISTA_PRESENTATION_BASELINE
            Text("A 雙貼圖基準").font(.caption2).accessibilityIdentifier("baselineVideoPath")
            #endif
            #if VISTA_NATIVE_PLAYER_EXPERIMENT
            Text("AVPlayer 候選・解碼方式未知").font(.caption2)
            #else
            if PlaybackDecodingPolicy.simulatorSoftwareTest {
                Text("模擬器軟體解碼測試").font(.caption2).foregroundStyle(.orange)
            }
            #endif
            #endif
            if let player = presentation.player {
                playbackProgress(player)
                HStack(spacing: 16) {
                    Button { presentation.onPrevious?(); presentation.holdControls() } label: { Image(systemName: "backward.end.fill") }
                        .accessibilityLabel("上一個影片").accessibilityIdentifier("immersivePrevious")
                        .disabled(!presentation.canGoBack || presentation.advancing)
                    Button { presentation.revealControls(); player.skip(by: -PlaybackProgress.skipInterval) } label: { Image(systemName: "gobackward.30") }
                        .accessibilityLabel("後退 30 秒").accessibilityIdentifier("immersiveBack")
                        .disabled(player.isPreparing || presentation.advancing || player.trackInfo == nil)
                    Button {
                        if player.isPlaying { player.togglePause() } else { presentation.onReplay?() }
                        presentation.revealControls()
                    } label: { Image(systemName: player.isPlaying && !player.isPaused ? "pause.fill" : "play.fill") }
                        .accessibilityLabel(player.isPlaying && !player.isPaused ? "暫停" : "播放")
                        .accessibilityIdentifier("immersivePause")
                        .disabled(player.isPreparing || presentation.advancing || presentation.requiresFormatConfirmation)
                    Button { presentation.revealControls(); player.skip(by: PlaybackProgress.skipInterval) } label: { Image(systemName: "goforward.30") }
                        .accessibilityLabel("前進 30 秒").accessibilityIdentifier("immersiveForward")
                        .disabled(player.isPreparing || presentation.advancing || player.trackInfo == nil)
                    Button { presentation.onNext?(); presentation.holdControls() } label: { Image(systemName: "forward.end.fill") }
                        .accessibilityLabel("下一個影片").accessibilityIdentifier("immersiveNext")
                        .disabled(!presentation.canAdvance || presentation.advancing)
                    Button { presentation.settingsVisible.toggle(); presentation.revealControls() } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("影片格式設定").accessibilityIdentifier("immersiveSettings")
                }.buttonStyle(.borderless).font(.title3).disabled(presentation.stopping || presentation.scrubbing)
                #if DEBUG && VISTA_DIAGNOSTIC_UI
                Button("效能診斷") {presentation.diagnosticsVisible.toggle();presentation.holdControls();if !presentation.diagnosticsVisible {presentation.scheduleHide()}}
                    .accessibilityIdentifier("playbackDiagnostics")
                if presentation.diagnosticsVisible {
                    Text("Vista \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "?"))\n" + player.diagnosticsText + "\n" + player.preparationText)
                        .font(.caption.monospacedDigit()).textSelection(.enabled)
                        .accessibilityIdentifier("playbackDiagnosticsResult")
                    Text("各階段可能重疊；貼圖完成不代表螢幕已顯示。跳轉或重播會重新量測。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                #endif
                if player.isPreparing || presentation.advancing {
                    ProgressView(player.isSeeking ? "正在跳轉…（保留上一張畫面）":"準備影片…")
                        .accessibilityIdentifier("playbackPreparing")
                }
                if let error = renderer.error { Text(error).font(.caption).accessibilityIdentifier("vrError") }
                if let message = presentation.message { Text(message).font(.caption).accessibilityIdentifier("immersiveMessage") }
                if !player.isPlaying || player.isBuffering, let message = player.message { Text(message).font(.caption).accessibilityIdentifier("immersivePlaybackStatus") }
            }
            if presentation.settingsVisible || presentation.requiresFormatConfirmation {
                Divider()
                VRSettingsView(presentation: presentation) { presentation.onFormatChanged?(); presentation.holdControls() }
                if presentation.requiresFormatConfirmation {
                    Button("使用目前格式並播放") { presentation.onFormatChanged?(); presentation.onReplay?() }
                        .accessibilityIdentifier("immersiveConfirmFormat")
                }
                VStack(spacing:4) {
                    Text("水平手動調整 \(VRManualAngleDisplay.text(presentation.settings.yawDegrees))")
                        .accessibilityIdentifier("manualHorizontalAngle")
                    Text("← −15°　│　0°　│　+15° →").foregroundStyle(.secondary)
                }.font(.caption).padding(.leading,56)
                HStack(spacing:8) {
                    VStack(spacing:8) {
                        Text("垂直")
                        Text(VRManualAngleDisplay.text(presentation.settings.pitchDegrees))
                            .accessibilityIdentifier("manualVerticalAngle")
                        Text("上\n+15°\n│\n0°\n│\n−15°\n下").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }.font(.caption).multilineTextAlignment(.center).frame(width:48).fixedSize(horizontal:false,vertical:true)
                    ZStack {
                    ringControl("重設影片方向", angle: -90, outer: true, identifier: "recenterVideo", hint: "以目前觀看方向重新置中影片，成功後清除手動轉向；也可三擊影片背景", action:resetVideoDirection).disabled(presentation.calibration.status == .capturing)
                    ringControl("重設\n影片格式", angle: -165, outer: true, identifier: "clearVRFormat", hint: "清除此片保存格式，不重設方向或控制器位置") {
                        presentation.onClearFormat?(); presentation.holdControls()
                    }.disabled(!presentation.canClearFormat || presentation.advancing)
                    ringControl("重設\n控制器\n位置", angle: -15, outer: true, identifier: "resetControllerPosition", hint: "也可雙擊影片背景", action: resetControllerPosition)
                    ringControl("arrowtriangle.up.fill", angle: -90, outer: false, identifier: "directionUp", hint: "向上轉，每次15度") { presentation.settings.pitchDegrees += 15 }
                    ringControl("arrowtriangle.left.fill", angle: -180, outer: false, identifier: "directionLeft", hint: "向左轉，每次15度") { presentation.settings.yawDegrees -= 15 }
                    ringControl("arrowtriangle.right.fill", angle: 0, outer: false, identifier: "directionRight", hint: "向右轉，每次15度") { presentation.settings.yawDegrees += 15 }
                    ringControl("arrowtriangle.down.fill", angle: 90, outer: false, identifier: "directionDown", hint: "向下轉，每次15度") { presentation.settings.pitchDegrees -= 15 }
                    Button(action:resetManualDirection) {
                        Text("歸零").font(.caption).frame(width:54,height:54)
                    }.buttonStyle(CenterRingFeedbackStyle())
                        .accessibilityLabel("方向歸零").accessibilityIdentifier("directionZero")
                        .accessibilityValue("yaw=\(Int(presentation.settings.yawDegrees)),pitch=\(Int(presentation.settings.pitchDegrees)),roll=\(Int(presentation.settings.rollDegrees))")
                        .accessibilityHint("清除手動轉向，不重新採樣觀看方向").position(x:190,y:180)
                    }.frame(width:380,height:286)
                }
                Text("角度相對本次取樣基準；0° 為未調整，每格 15°")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Text("看向影片背景：單擊顯示／隱藏；雙擊重設控制器位置；三擊重設影片方向")
                    .fixedSize(horizontal:false,vertical:true)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("resetControllerGestureHint")
                if let info=presentation.player?.trackInfo {
                    Text("\(info.codec) · \(info.width) × \(info.height)").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("controllerVideoInfo")
                    if !info.hasAudio {Text("影片無音軌").font(.caption).foregroundStyle(.secondary)}
                }

            }
        }.padding(16).frame(width: 480)
            .glassBackgroundEffect()
            .allowsHitTesting(presentation.controlsVisible)
            .accessibilityHidden(!presentation.controlsVisible)
            .onHover { hovering in if hovering { presentation.holdControls() } else { presentation.scheduleHide() } }
    }
    private func ringControl(_ title:String,angle:Double,outer:Bool,identifier:String,hint:String,action:@escaping ()->Void)->some View {
        let segment=RemoteRingSegment(inner:outer ? 104:43,outer:outer ? 160:94,angle:angle,span:outer ? (angle == -90 ? 80:70):90,gap:10)
        let bounds=segment.globalPath.boundingRect
        let anchor=segment.labelPoint
        return Button {action();presentation.holdControls()} label: {
            Group {
                if outer {Text(title).font(.caption).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)}
                else {Image(systemName:title).font(.body)}
            }
            .frame(width:outer ? (angle == -90 ? 170:92):40)
            .position(x:anchor.x-bounds.minX,y:anchor.y-bounds.minY)
            .frame(width:bounds.width,height:bounds.height)
            .contentShape(.interaction,segment)
        }.buttonStyle(LocalRingFeedbackStyle(segment:segment,center:CGPoint(x:anchor.x-bounds.minX,y:anchor.y-bounds.minY),diameter:outer ? 52:42))
            .accessibilityLabel(outer ? title.replacingOccurrences(of:"\n",with:""):hint)
            .accessibilityIdentifier(identifier).accessibilityHint(hint)
            .position(x:190+bounds.midX,y:180+bounds.midY)
    }
    private func directionButton(_ symbol:String,label:String,identifier:String,action:@escaping ()->Void)->some View {
        Button {action();presentation.holdControls()} label: {
            Image(systemName:symbol).frame(width:52,height:44)
        }.buttonStyle(.plain)
            .background(.white.opacity(0.08),in:Capsule()).contentShape(.interaction,Capsule())
            .contentShape(.hoverEffect,Capsule()).hoverEffect(.highlight)
            .accessibilityLabel(label).accessibilityIdentifier(identifier)
            .accessibilityHint("每次調整15度")
    }
    @ViewBuilder private func playbackProgress(_ player:PlaybackController)->some View {
        let duration=PlaybackProgress.duration(player.trackInfo?.duration)
        let enabled=duration != nil && !player.isPreparing && !presentation.advancing && !presentation.stopping && !presentation.requiresFormatConfirmation
        HStack(spacing:10) {
            Text(PlaybackProgress.time(presentation.scrubbing ? scrubPosition:player.position))
                .accessibilityIdentifier("playbackElapsed")
            Slider(value:Binding(get:{presentation.scrubbing ? scrubPosition:PlaybackProgress.clamp(player.position,duration:duration)},set:{value in
                if !presentation.scrubbing {presentation.scrubbing=true;presentation.holdControls()}
                scrubPosition=value
            }),in:0...(duration ?? 1),onEditingChanged:{ editing in
                if editing {
                    if !presentation.scrubbing {scrubPosition=PlaybackProgress.clamp(player.position,duration:duration)}
                    presentation.scrubbing=true;presentation.holdControls()
                }
                else {
                    let target=scrubPosition;presentation.scrubbing=false
                    if enabled,presentation.active,!presentation.stopping,presentation.player === player {player.seek(to:target)}
                    presentation.revealControls()
                }
            }).disabled(!enabled)
                .accessibilityLabel("播放進度")
                .accessibilityIdentifier("playbackSeek")
                .accessibilityHint("放開以跳轉，也可使用前後30秒按鈕。")
            Text(PlaybackProgress.time(duration)).accessibilityIdentifier("playbackDuration")
        }.font(.caption.monospacedDigit())
    }
    private func updateFade(_ controls:Entity,visible:Bool) {
        guard controlVisual.fadeTarget != visible else{return}
        controlVisual.fadeTarget=visible;controlVisual.fadeTask?.cancel()
        let start=controls.components[OpacityComponent.self]?.opacity ?? (visible ? 0:1)
        controls.isEnabled=true
        controls.components.set(OpacityComponent(opacity:start))
        if reduceMotion {controls.components.set(OpacityComponent(opacity:visible ? 1:0));controls.isEnabled=visible;return}
        controlVisual.fadeTask=Task { @MainActor in
            for step in 1...12 {
                do {try await Task.sleep(for:.milliseconds(16))} catch{return}
                guard !Task.isCancelled else{return}
                let t=Float(step)/12;let eased=t*t*(3-2*t)
                controls.components.set(OpacityComponent(opacity:start+((visible ? 1:0)-start)*eased))
            }
            controls.isEnabled=visible
        }
    }
    private func resetVideoDirection() {
        guard !presentation.movingControls,!presentation.scrubbing,presentation.calibration.status != .capturing else{return}
        presentation.calibration.requestRecenter();presentation.calibrationRequest += 1
    }
    private func resetControllerPosition() {
        guard !presentation.movingControls,!presentation.scrubbing else{return}
        controlVisual.facingTask?.cancel()
        controlVisual.orientation=VRControllerPlacement.facing(position:VRControllerPlacement.origin)
        presentation.controlsOffset = .zero
        if presentation.navigationVisibility != nil {presentation.navigationVisibility=true}
        presentation.controlsVisible=true
        presentation.scheduleHide()
    }
    private func addTapTargets() {
        // Six thin collision surfaces surround the frozen viewing origin. They have no visible material,
        // sit behind the controller, and do not use head-following or continuous pose sampling.
        for axis in 0..<3 { for sign: Float in [-1, 1] {
            let target = Entity(); target.name = "show-controls-\(axis)-\(sign)"
            target.components.set(ControllerBackgroundTarget())
            var size = SIMD3<Float>(repeating: 8); size[axis] = 0.01
            target.components.set(CollisionComponent(shapes: [.generateBox(size: size)]))
            target.components.set(InputTargetComponent(allowedInputTypes: .indirect))
            var position = SIMD3<Float>.zero; position[axis] = sign * 4; target.position = position
            placement.addChild(target)
        } }
    }
    private func resetManualDirection() {
        presentation.settings.yawDegrees = 0; presentation.settings.pitchDegrees = 0; presentation.settings.rollDegrees = 0
    }
    private func updateControllerReference() {
        guard let entry=controllerEntryPose else{return}
        // Use the same world orientation as the video surface, not a separate entry gaze.
        let videoBase=presentation.calibration.pose?.orientation ?? simd_quatf()
        let videoHeading=videoBase * VRInitialPose.manualRotation(yaw:presentation.settings.yawDegrees,pitch:presentation.settings.pitchDegrees,roll:presentation.settings.rollDegrees)
        guard let pose=VRControllerReference.pose(entry:entry,vertical:presentation.calibration.pose,horizontal:videoHeading) else{return}
        let oldY=controllerReference.position.y
        let oldReference=controllerReference.transformMatrix(relativeTo:nil)
        let oldLocal=Transform(scale:.one,rotation:controlVisual.orientation,translation:VRControllerPlacement.origin+presentation.controlsOffset).matrix
        controllerReference.position=pose.position;controllerReference.orientation=pose.orientation
        if presentation.preservePlacementAcrossFiles {
            let local=Transform(matrix:VRControllerContinuity.rebased(local:oldLocal,oldReference:oldReference,newReference:controllerReference.transformMatrix(relativeTo:nil)))
            presentation.controlsOffset=local.translation-VRControllerPlacement.origin
            controlVisual.orientation=local.rotation
        } else if presentation.controlsOffset != .zero {
            // A later calibration must not lower a controller the user has already moved.
            presentation.controlsOffset.y += oldY-pose.position.y
            presentation.controlsOffset=VRControllerPlacement.constrained(presentation.controlsOffset)
        }
        let viewer=controllerReference.convert(position:(presentation.calibration.pose ?? entry).position,from:nil)
        controlVisual.viewer=viewer
        controlVisual.viewerFrame=VRControllerViewFrame.localFrame(viewerWorld:(presentation.calibration.pose ?? entry).orientation,parentWorld:controllerReference.orientation(relativeTo:nil))
        if !draggingControls && !presentation.preservePlacementAcrossFiles {controlVisual.orientation=VRControllerViewFrame.facing(position:VRControllerPlacement.origin+presentation.controlsOffset,viewer:viewer,frame:controlVisual.viewerFrame,previous:controlVisual.orientation)}
    }
    private func placeControls(_ controls: Entity?) {
        guard let controls else { return }
        if controlEntity !== controls {controlVisual.entity=controls}
        // Controller range is centered on the video front, independently of restored vertical placement.
        // The right-front default is only a position within this coordinate frame, never its yaw origin.
        let parent: Entity = controllerReference
        if controls.parent != parent { parent.addChild(controls) }
        controls.position = presentation.testPattern ? [0, -0.25, -1.5] : VRControllerPlacement.origin + presentation.controlsOffset
        controls.orientation = presentation.testPattern ? simd_quatf() : controlVisual.orientation
        updateFade(controls,visible:presentation.testPattern || presentation.controlsVisible)
        if moveHandle.parent != controls {controls.addChild(moveHandle)}
        moveHandle.isEnabled=false
        let bounds=controls.visualBounds(relativeTo:controls,excludeInactive:true)
        moveHandle.position=[0,bounds.min.y-VRControllerHandle.gap,0]
        moveHandle.isEnabled = !presentation.testPattern
        if presentation.controlsVisible {moveHandle.components.set(InputTargetComponent(allowedInputTypes:.indirect))}
        else {moveHandle.components.remove(InputTargetComponent.self)}
    }
    private func updateDraggedPosition(_ controls:Entity) {
        guard let pointer=controlVisual.dragPointer else{return}
        let position=VRControllerPlacement.grabbedPosition(pointer:pointer,localGrab:controlVisual.localGrab,orientation:controlVisual.orientation,previous:controls.position)
        presentation.controlsOffset=position-VRControllerPlacement.origin
        controls.position=position
    }
    private func faceViewerDuringDrag() {
        controlVisual.facingTask?.cancel();controlVisual.poseTask?.cancel()
        guard let controls=controlEntity,let parent=controls.parent else{return}
        // Update viewing frame only while dragging; keep the last valid frame on tracking loss.
        controlVisual.poseTask=Task { @MainActor in
            guard presentation.calibration.status != .capturing else{return}
            try? await DeviceInitialPose().duringDrag { pose in
                guard !Task.isCancelled,presentation.movingControls,controls.parent === parent else{return}
                controlVisual.viewer=parent.convert(position:pose.position,from:nil)
                controlVisual.viewerFrame=VRControllerViewFrame.localFrame(viewerWorld:pose.orientation,parentWorld:parent.orientation(relativeTo:nil))
            }
        }
        controlVisual.facingTask=Task { @MainActor in
            var last=ContinuousClock.now
            while !Task.isCancelled,presentation.movingControls,!presentation.stopping,controls.parent === parent {
                let now=ContinuousClock.now
                let duration=last.duration(to:now).components
                let elapsed=Float(duration.seconds)+Float(duration.attoseconds)/1e18
                last=now
                let target=VRControllerViewFrame.facing(position:controls.position,viewer:controlVisual.viewer,frame:controlVisual.viewerFrame,previous:controlVisual.orientation)
                controlVisual.orientation=VRControllerViewFrame.approaching(controlVisual.orientation,target:target,frame:controlVisual.viewerFrame,elapsed:elapsed)
                controls.orientation=controlVisual.orientation
                updateDraggedPosition(controls)
                do {try await Task.sleep(for:.milliseconds(16))} catch{return}
            }
        }
    }
    private func faceViewerAfterDrag() {
        controlVisual.facingTask?.cancel()
        guard let controls=controlEntity, let parent=controls.parent else{return}
        let position=controls.position, start=controls.orientation
        controlVisual.facingTask=Task { @MainActor in
            // Release uses the same last viewing frame as the drag, without a late resample.
            guard !Task.isCancelled,!presentation.stopping,controls.parent === parent else{return}
            let viewer=controlVisual.viewer
            let target=VRControllerViewFrame.facing(position:position,viewer:viewer,frame:controlVisual.viewerFrame,previous:start)
            for step in 1...(reduceMotion ? 1:12) {
                guard !Task.isCancelled else{return}
                let t=reduceMotion ? Float(1):Float(step)/12
                controlVisual.orientation=VRControllerViewFrame.interpolating(start,target:target,frame:controlVisual.viewerFrame,fraction:t*t*(3-2*t))
                controls.orientation=controlVisual.orientation
                if !reduceMotion {do {try await Task.sleep(for:.milliseconds(16))} catch{return}}
            }
        }
    }
    private func applyPlacement() {
        if let pose = presentation.calibration.pose {
            placement.position = pose.position; placement.orientation = pose.orientation
        } else {
            placement.position = [0, 1.5, 0]; placement.orientation = simd_quatf()
        }
    }
}

@MainActor private final class ControllerVisualState {
    var entity:Entity?
    var orientation=VRControllerPlacement.facing(position:VRControllerPlacement.origin)
    var facingTask:Task<Void,Never>?
    var poseTask:Task<Void,Never>?
    var viewer=SIMD3<Float>.zero
    var viewerFrame=simd_quatf(angle:0,axis:[0,1,0])
    var dragPointer:SIMD3<Float>?
    var localGrab=SIMD3<Float>.zero
    var fadeTarget:Bool?
    var fadeTask:Task<Void,Never>?
}


/// Candidate only: a single pending pixel buffer, one serial flush/enqueue worker, existing timeline upstream.
@MainActor @Observable private final class SystemVideoPresenter {
    let entity=ModelEntity()
    let context=CIContext()
    var ready=false
    var error:String?
    var probe=""
    private var inputProbe=""
    @ObservationIgnored private var probeTask:Task<Void,Never>?
    @ObservationIgnored private var statusTask:Task<Void,Never>?
    @ObservationIgnored private var failedSession:UUID?
    @ObservationIgnored private var video=AVSampleBufferVideoRenderer()
    @ObservationIgnored private var sharedVideoMaterial:VideoMaterial?
    @ObservationIgnored private var configuredSettings:VRSettings?
    #if DEBUG
    var packingImageSize:CGSize? {sharedVideoMaterial?.controller.currentImageSize}
    var packingState:String {
        let size=sharedVideoMaterial?.controller.currentImageSize
        return "layout=\(configuredSettings?.layout.rawValue ?? "nil") image=\(size?.width ?? -1)x\(size?.height ?? -1) mode=\(String(describing:sharedVideoMaterial?.controller.currentViewingMode)) ready=\(ready) error=\(error ?? "none")"
    }
    #endif
    private(set) var materialCreationCount=0
    private(set) var lastSubmittedSession:UUID?
    private(set) var lastSubmittedAt:Double?
    @available(visionOS 26.0,*)
    private func material()->VideoMaterial {
        if let sharedVideoMaterial {return sharedVideoMaterial}
        let created=VideoMaterial(videoRenderer:video)
        sharedVideoMaterial=created;materialCreationCount += 1
        return created
    }
    @ObservationIgnored private var pending:(DecodedVideoFrame,VRSettings)?
    @ObservationIgnored private var worker:Task<Void,Never>?
    @ObservationIgnored private var generation=0
    @ObservationIgnored private var current:(UUID,VRSettings)?
    @ObservationIgnored private var needsFlush=true
    @ObservationIgnored private var isStopped=true
    func stop() {
        guard !isStopped else{return}
        isStopped=true
        generation += 1;pending=nil;needsFlush=true;ready=false;entity.isEnabled=false
        probeTask?.cancel();probeTask=nil;probe="";inputProbe=""
        statusTask?.cancel();statusTask=nil
        // The existing serial worker finishes any flush before a later generation can enqueue.
        if worker == nil {video.flush()}
    }
    @available(visionOS 26.0,*)
    func submit(_ frame:DecodedVideoFrame,settings:VRSettings) {
        guard failedSession != frame.session else{return}
        isStopped=false
        if current?.0 != frame.session || current?.1 != settings {
            generation += 1;needsFlush=true;current=(frame.session,settings)
            probeTask?.cancel();probeTask=nil;probe="";inputProbe=""
        statusTask?.cancel();statusTask=nil
        }
        pending=(frame,settings)
        guard worker == nil else{return}
        worker=Task { @MainActor in
            let samples=SystemVideoSamples()
            while let next=pending {
                pending=nil
                let ticket=generation
                var stage="prepare"
                do {
                    if needsFlush {
                        needsFlush=false;samples.reset()
                        // RealityKit retains the initial packing for a renderer/material pair.
                        // Retire both together only when packing changes; ordinary frames reuse them.
                        let changesPacking = configuredSettings.map { $0.layout != next.1.layout } ?? false
                        await video.flush(removingDisplayedImage:changesPacking)
                        guard ticket==generation else{continue}
                        if changesPacking {
                            entity.model=nil;sharedVideoMaterial=nil
                            video=AVSampleBufferVideoRenderer();configuredSettings=nil
                        }
                        if configuredSettings != next.1 || entity.model == nil {
                        let crop=next.1.crop(width:CVPixelBufferGetWidth(next.0.pixel),height:CVPixelBufferGetHeight(next.0.pixel),rightEye:false)!
                        guard let mesh=VRMesh(projection:next.1.projection,eyeWidth:Int(crop.width),eyeHeight:Int(crop.height)) else{throw PlaybackFailure.unsupportedTrack}
                        var descriptor=MeshDescriptor(name:"System video candidate")
                        descriptor.positions=MeshBuffers.Positions(mesh.positions)
                        descriptor.normals=MeshBuffers.Normals(mesh.normals)
                        descriptor.textureCoordinates=MeshBuffers.TextureCoordinates(mesh.uv)
                        descriptor.primitives = .triangles(mesh.indices)
                        let material=material()
                        material.controller.preferredViewingMode = next.1.layout == .mono ? .mono:.stereo
                        entity.model=ModelComponent(mesh:try MeshResource.generate(from:[descriptor]),materials:[material])
                        entity.orientation=VRInitialPose.manualRotation(yaw:next.1.yawDegrees,pitch:next.1.pitchDegrees,roll:next.1.rollDegrees)
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--system-renderer-flat") {
                        entity.model=ModelComponent(mesh:.generatePlane(width:2,height:1),materials:[material])
                        entity.position=[0,0,-2];entity.orientation=simd_quatf()
                    }
                    #endif
                        configuredSettings=next.1
                        }
                    }
                    stage="queue"
                    let deadline=ContinuousClock.now.advanced(by:.milliseconds(250))
                    while !video.isReadyForMoreMediaData,ContinuousClock.now<deadline,ticket==generation,pending==nil {
                        try await Task.sleep(for:.milliseconds(5))
                    }
                    guard ticket==generation,pending==nil else{continue}
                    guard video.isReadyForMoreMediaData,video.status != .failed else{throw PlaybackFailure.decodeFailed}
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--system-renderer-failure") {stage="injected";throw PlaybackFailure.decodeFailed}
                    #endif
                    stage="sample"
                    let sample=try samples.sample(next.0,settings:next.1)
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--system-renderer-probe"),inputProbe.isEmpty {
                        let image=CIImage(cvPixelBuffer:next.0.pixel)
                        let thumb=image.transformed(by:CGAffineTransform(scaleX:16/image.extent.width,y:16/image.extent.height))
                        var bytes=[UInt8](repeating:0,count:16*16*4)
                        context.render(thumb,toBitmap:&bytes,rowBytes:64,bounds:CGRect(x:0,y:0,width:16,height:16),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
                        let rgb=bytes.enumerated().filter{$0.offset%4 != 3}.map{Int($0.element)}
                        let sum=rgb.reduce(0,+),bright=rgb.filter{$0>20}.count
                        inputProbe="inputRGBsum=\(sum) bright=\(bright) surface=\(CVPixelBufferGetIOSurface(next.0.pixel) != nil) format=\(CVPixelBufferGetPixelFormatType(next.0.pixel)) PTS=\(next.0.time)"
                        if ProcessInfo.processInfo.arguments.contains("--shortcut-ui-tests"),let cg=context.createCGImage(image,from:image.extent),let destination=CGImageDestinationCreateWithURL(FileManager.default.temporaryDirectory.appendingPathComponent("vista-input-calibration.png") as CFURL,"public.png" as CFString,1,nil) {
                            CGImageDestinationAddImage(destination,cg,nil);_ = CGImageDestinationFinalize(destination)
                        }
                    }
                    #endif
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--system-renderer-raw") {
                        let rawFormat=try CMVideoFormatDescription(imageBuffer:next.0.pixel)
                        let raw=try CMSampleBuffer(imageBuffer:next.0.pixel,formatDescription:rawFormat,sampleTiming:CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:.zero,decodeTimeStamp:.invalid))
                        raw.sampleAttachments[0][.displayImmediately]=true
                        video.enqueue(raw)
                    } else {video.enqueue(sample)}
                    #else
                    video.enqueue(sample)
                    #endif
                    ready=true;entity.isEnabled=true;error=nil
                    if lastSubmittedSession != next.0.session {
                        lastSubmittedAt=ProcessInfo.processInfo.systemUptime
                        lastSubmittedSession=next.0.session
                    }
                    startProbe(ticket:ticket)
                    startStatusMonitor(ticket:ticket)
                } catch { if ticket==generation {
                    failedSession=next.0.session;pending=nil;needsFlush=true
                    self.error=failureMessage(stage:stage)
                    ready=false;entity.isEnabled=false
                } }
            }
            if needsFlush {await video.flush(removingDisplayedImage:true)}
            worker=nil
            if let next=pending {submit(next.0,settings:next.1)}
        }
    }
    private func failureMessage(stage:String)->String {
        let status=(video.error as NSError?).map {" code=\($0.code)"} ?? ""
        return "系統影片呈現失敗，已停止 [videoRenderer/\(stage)\(status)]"
    }
    private func startStatusMonitor(ticket:Int) {
        guard statusTask==nil else{return}
        statusTask=Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(for:.milliseconds(100))} catch{return}
                guard let self,ticket==self.generation else{return}
                if self.video.status == .failed || self.video.requiresFlushToResumeDecoding {
                    self.failedSession=self.current?.0;self.pending=nil;self.needsFlush=true
                    self.error=self.failureMessage(stage:"async")
                    self.ready=false;self.entity.isEnabled=false
                    return
                }
            }
        }
    }
    private func startProbe(ticket:Int) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--system-renderer-probe"),probeTask==nil else{return}
        probeTask=Task { @MainActor in
            for _ in 0..<20 {
                do {try await Task.sleep(for:.milliseconds(100))} catch{return}
                guard ticket==generation else{return}
                // Apple's copyDisplayedPixelBuffer contract returns nil at nonzero rate.
                // Freeze only the renderer for this synthetic Debug observation, then restore.
                let synthetic=ProcessInfo.processInfo.arguments.contains("--shortcut-ui-tests")
                let savedRate=CMTimebaseGetRate(video.timebase)
                if synthetic {CMTimebaseSetRate(video.timebase,rate:0)}
                let displayed=video.displayedPixelBuffer()
                if synthetic {CMTimebaseSetRate(video.timebase,rate:savedRate)}
                if let pixel=displayed {
                    if ProcessInfo.processInfo.arguments.contains("--shortcut-ui-tests"),let image=context.createCGImage(CIImage(cvPixelBuffer:pixel),from:CIImage(cvPixelBuffer:pixel).extent) {
                        let url=FileManager.default.temporaryDirectory.appendingPathComponent("vista-renderer-calibration.png")
                        if let destination=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil) {
                            CGImageDestinationAddImage(destination,image,nil);_ = CGImageDestinationFinalize(destination)
                        }
                    }
                    probe=inputProbe+" renderer 可讀回影格 \(CVPixelBufferGetWidth(pixel))×\(CVPixelBufferGetHeight(pixel))；非雙眼輸出驗收"
                    return
                }
            }
            probe=inputProbe+" renderer 讀回不可用（不代表黑畫面） status=\(video.status.rawValue) ready=\(video.isReadyForMoreMediaData) flush=\(video.requiresFlushToResumeDecoding) rate=\(CMTimebaseGetRate(video.timebase)) error=\((video.error as NSError?)?.code ?? 0)"
            print("SYSTEM_RENDERER_PROBE status=\(video.status.rawValue) ready=\(video.isReadyForMoreMediaData) requiresFlush=\(video.requiresFlushToResumeDecoding) time=\(CMTimebaseGetTime(video.timebase).seconds) rate=\(CMTimebaseGetRate(video.timebase)) error=\((video.error as NSError?)?.code ?? 0)")
        }
        #endif
    }

}

#if DEBUG
struct PackingRendererReview:View {
    @State private var presenter=SystemVideoPresenter()
    @State private var status="loading"
    var body:some View {
        VStack {
            Text(status).font(.caption).accessibilityIdentifier("packingReviewState")
            RealityView { content in content.add(presenter.entity) } update: { _ in
                presenter.entity.position = .zero;presenter.entity.scale = .init(repeating:0.25)
            }.frame(width:600,height:400)
        }.task {
            guard #available(visionOS 26.0,*) else {status="requires visionOS 26";return}
            do {
                let name=ProcessInfo.processInfo.arguments.contains("--packing-ou-source") ? "CalibrationOU180":"CalibrationSBS180"
                let asset=AVURLAsset(url:Bundle.main.url(forResource:name,withExtension:"mp4")!)
                let tracks=try await asset.loadTracks(withMediaType:.video)
                let reader=try AVAssetReader(asset:asset)
                let output=AVAssetReaderTrackOutput(track:tracks[0],outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferIOSurfacePropertiesKey as String:[:],kCVPixelBufferMetalCompatibilityKey as String:true])
                reader.add(output);guard reader.startReading(),let sample=output.copyNextSampleBuffer(),let pixel=CMSampleBufferGetImageBuffer(sample) else {status="read failed";return}
                reader.cancelReading()
                let frame=DecodedVideoFrame(pixel:pixel,time:0,session:UUID())
                var records=[String]()
                for layout in [VRLayout.sideBySide,.overUnder,.mono,.sideBySide] {
                    var settings=VRSettings();settings.layout=layout
                    presenter.submit(frame,settings:settings)
                    try await Task.sleep(for:.seconds(2))
                    status=name+" "+presenter.packingState
                    let expected=settings.crop(width:CVPixelBufferGetWidth(pixel),height:CVPixelBufferGetHeight(pixel),rightEye:false)!.size
                    guard presenter.ready,presenter.error == nil,presenter.packingImageSize == expected else {throw NSError(domain:"PackingReview",code:1,userInfo:[NSLocalizedDescriptionKey:status])}
                    records.append(status+" verified")
                    try JSONEncoder().encode(records).write(to:FileManager.default.temporaryDirectory.appendingPathComponent("packing-review.json"))
                    try await Task.sleep(for:.seconds(1))
                }
                // Rapid updates interleave with flush; only the newest generation may win.
                for i in 0..<60 {
                    var settings=VRSettings();settings.layout=[VRLayout.sideBySide,.overUnder,.mono][i%3]
                    presenter.submit(frame,settings:settings)
                    if i%7 == 0 {presenter.stop()}
                    try await Task.sleep(for:.milliseconds(2))
                }
                presenter.stop()
                try await Task.sleep(for:.milliseconds(300))
                guard !presenter.ready,!presenter.entity.isEnabled else {throw NSError(domain:"PackingReview",code:2)}
                var final=VRSettings();final.layout = .overUnder
                let restarted=DecodedVideoFrame(pixel:pixel,time:0,session:UUID())
                presenter.submit(restarted,settings:final)
                try await Task.sleep(for:.seconds(2))
                let expected=final.crop(width:CVPixelBufferGetWidth(pixel),height:CVPixelBufferGetHeight(pixel),rightEye:false)!.size
                guard presenter.ready,presenter.error == nil,presenter.packingImageSize == expected else {throw NSError(domain:"PackingReview",code:3)}
                let before=presenter.materialCreationCount
                for _ in 0..<30 {presenter.submit(restarted,settings:final);try await Task.sleep(for:.milliseconds(5))}
                try await Task.sleep(for:.milliseconds(500))
                guard presenter.materialCreationCount == before else {throw NSError(domain:"PackingReview",code:4)}
                records.append("rapid60 stop restart ordinary30 materialReuse PASS "+presenter.packingState)
                status="PASS "+name
                try JSONEncoder().encode(records).write(to:FileManager.default.temporaryDirectory.appendingPathComponent("packing-review.json"))
            } catch {
                status=String(describing:error)
                try? Data(status.utf8).write(to:FileManager.default.temporaryDirectory.appendingPathComponent("packing-review-error.txt"))
            }
        }
    }
}
#endif

/// All regions share one center. Rounded corners preserve the remote's concentric proportions.
private struct RemoteRingSegment:Shape {
    var inner:CGFloat,outer:CGFloat,angle:Double,span:Double,gap:CGFloat
    var labelPoint:CGPoint {point((inner+outer)/2,angle)}
    private func point(_ radius:CGFloat,_ degrees:Double)->CGPoint {
        let a=degrees * .pi / 180
        return CGPoint(x:radius*cos(a),y:radius*sin(a))
    }
    // Each edge is offset by half the gap from the shared bisector.
    // Adjacent straight edges therefore remain parallel at every radius.
    private func edgePoint(_ radius:CGFloat,_ boundary:Double,_ sign:Double)->CGPoint {
        point(radius,boundary + sign * asin(Double(gap/2/radius))*180 / .pi)
    }
    var globalPath:Path {
        let start=angle-span/2,end=angle+span/2,corner:CGFloat=4
        let outerTrim=Double(corner/outer)*180 / .pi,innerTrim=Double(corner/inner)*180 / .pi
        let os=start+asin(Double(gap/2/outer))*180 / .pi
        let oe=end-asin(Double(gap/2/outer))*180 / .pi
        let ins=start+asin(Double(gap/2/inner))*180 / .pi
        let ine=end-asin(Double(gap/2/inner))*180 / .pi
        var p=Path()
        p.move(to:point(outer,os+outerTrim))
        p.addArc(center:.zero,radius:outer,startAngle:.degrees(os+outerTrim),endAngle:.degrees(oe-outerTrim),clockwise:false)
        p.addQuadCurve(to:edgePoint(outer-corner,end,-1),control:edgePoint(outer,end,-1))
        p.addLine(to:edgePoint(inner+corner,end,-1))
        p.addQuadCurve(to:point(inner,ine-innerTrim),control:edgePoint(inner,end,-1))
        p.addArc(center:.zero,radius:inner,startAngle:.degrees(ine-innerTrim),endAngle:.degrees(ins+innerTrim),clockwise:true)
        p.addQuadCurve(to:edgePoint(inner+corner,start,1),control:edgePoint(inner,start,1))
        p.addLine(to:edgePoint(outer-corner,start,1))
        p.addQuadCurve(to:point(outer,os+outerTrim),control:edgePoint(outer,start,1));p.closeSubpath()
        return p
    }
    func path(in rect:CGRect)->Path {
        let p=globalPath,b=p.boundingRect
        return p.applying(CGAffineTransform(translationX:rect.minX-b.minX,y:rect.minY-b.minY))
    }
}
/// Custom styles own feedback explicitly; no built-in highlight on the outer Button or text.
/// The group activates the small visual overlay from the complete interaction path.
private struct LocalRingFeedbackStyle:ButtonStyle {
    let segment:RemoteRingSegment,center:CGPoint,diameter:CGFloat
    func makeBody(configuration:Configuration)->some View {
        configuration.label
            .background(.white.opacity(0.10),in:segment)
            .overlay {
                Circle().fill(.white.opacity(configuration.isPressed ? 0.28:0.20))
                    .frame(width:diameter,height:diameter)
                    .position(center)
                    .hoverEffect { effect,active,_ in effect.opacity(active ? 1:0) }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .contentShape(.interaction,segment)
            .hoverEffectGroup()
    }
}
private struct CenterRingFeedbackStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View {
        configuration.label
            .background(.white.opacity(0.10),in:Circle())
            .overlay {
                Circle().stroke(.white.opacity(configuration.isPressed ? 0.65:0.45),lineWidth:2)
                    .frame(width:60,height:60)
                    .hoverEffect { effect,active,_ in effect.opacity(active ? 1:0) }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .contentShape(.interaction,Circle())
            .hoverEffectGroup()
    }
}
