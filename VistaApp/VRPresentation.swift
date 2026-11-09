import ImageIO
import SwiftUI

extension ScenePhase {
    var diagnosticValue:Double {switch self {case .active:0;case .inactive:1;case .background:2;@unknown default:-1}}
}

import RealityKit
import Observation
import Combine
import AVFoundation
import CoreImage

private struct ControllerBackgroundTarget:Component {}

@MainActor @Observable final class VRPresentation {
    var settings = VRSettings()
    var videoSettings: VRSettings { calibration.videoSettings(for: settings) }
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
        guard active, navigationVisibility == nil, !movingControls, !scrubbing, message == nil, !testPattern, !settingsVisible, !diagnosticsVisible, !requiresFormatConfirmation, !advancing,
              let player, player.isPlaying, !player.isPaused, !player.isPreparing, player.speedStatus.selected <= 1 else { return }
        hideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, !Task.isCancelled, self.active, self.navigationVisibility == nil, !self.settingsVisible, !self.diagnosticsVisible,
                  !self.requiresFormatConfirmation, !self.advancing, !self.scrubbing,
                  self.player?.isPlaying == true, self.player?.isPaused == false,
                  let selectedRate = self.player?.speedStatus.selected, selectedRate <= 1 else { return }
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

// Anonymous low-frequency view boundaries only. No media names or frame contents.
@MainActor private final class ImmersivePlaybackBoundaryState {
    // Cause: 1 appear, 2 first/changed frame session, 3 scene change, 4 renderer error, 5 disappear.
    let trace=PlaybackBoundaryTrace(scope:1)
    private(set) var generation=0
    private var observedSession:UUID?
    private var observedFrame=false
    func begin(_ cause:Int) {generation += 1;trace.begin(reason:cause,generation:generation)}
    func observeFrame(_ player:PlaybackController?) {
        let session=player?.pixelFrame?.session
        if !observedFrame || observedSession != session {
            observedFrame=true;observedSession=session;begin(2)
        }
        record(.frameObserved,player:player)
    }
    func record(_ stage:PlaybackBoundaryStage,player:PlaybackController?,fields:[LifecycleField:Double]=[:],once:Bool=true,context:PlaybackBoundaryTrace.Context?=nil,capturedGeneration:Int?=nil) {
        guard trace.shouldRecord(stage,once:once,context:context) else{return}
        var values:[LifecycleField:Double]=[.playing:player?.isPlaying == true ? 1:0,
            .paused:player?.isPaused == true ? 1:0,.preparing:player?.isPreparing == true ? 1:0,
            .frameAvailable:player?.pixelFrame != nil ? 1:0]
        if let session=player?.pixelFrame?.session {values[.session]=Double(PlaybackBoundaryIdentity.session(session))}
        values.merge(fields){_,new in new}
        trace.record(stage,generation:capturedGeneration ?? generation,fields:values,once:once,context:context)
    }
}

// Observes SwiftUI control policy only. Uptime is observation/callback time,
// not the instant a disabled appearance reached the compositor or display.
@MainActor private final class ImmersiveControllerUIDiagnosticState {
    private var trace=PlaybackControllerUIDiagnostics()
    static func state(_ presentation:VRPresentation)->PlaybackControllerUIState {
        let player=presentation.player
        return PlaybackControllerUIState(stopping:presentation.stopping,scrubbing:presentation.scrubbing,
            preparing:player?.isPreparing ?? false,advancing:presentation.advancing,
            requiresFormatConfirmation:presentation.requiresFormatConfirmation,
            canResetSpeed:player?.canResetSpeed ?? false,canIncreaseSpeed:player?.canIncreaseSpeed ?? false,
            canGoBack:presentation.canGoBack,canAdvance:presentation.canAdvance,
            hasDuration:PlaybackProgress.duration(player?.trackInfo?.duration) != nil)
    }
    func record(_ action:PlaybackControllerUIDiagnostics.Action = .stateChanged,presentation:VRPresentation) {
        guard let values=trace.update(state:Self.state(presentation),action:action) else{return}
        if let player=presentation.player {
            let projection=VRProjection.allCases.firstIndex(of:presentation.settings.projection) ?? 0
            let layout=VRLayout.allCases.firstIndex(of:presentation.settings.layout) ?? 0
            let route=presentation.settings.projection == .equidistantFisheye180 ? 1:0
            player.persistDiagnostics(event:.controllerUI,projection:projection,layout:layout,route:route,rendererValues:values)
        } else {
            // finishSession may already have released the player; retain the terminal edge.
            PlaybackLogStore.shared.enqueue(PlaybackLogRecord(event:.controllerUI,values:values))
        }
    }
    func currentValues(presentation:VRPresentation)->[PlaybackLogField:Double] {
        record(presentation:presentation)
        return trace.snapshot()
    }
}

struct VRImmersiveView: View {
    #if DEBUG
    // Presentation-only overrides for the synthetic controller fixture.
    var reviewSpeedStatus:PlaybackSpeedStatus?=nil
    var reviewVideoInfo:VideoTrackInfo?=nil
    var reviewProgressDurationText:String?=nil
    #endif
    @Environment(VRPresentation.self) private var presentation
    @Environment(\.dismissImmersiveSpace) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo:.caption) private var speedStatusLineHeight:CGFloat=22
    @State private var renderer = VRRenderer()
    @State private var systemRenderer = SystemVideoPresenter()
    @State private var playbackBoundaries=ImmersivePlaybackBoundaryState()
    @State private var controllerUIDiagnostics=ImmersiveControllerUIDiagnosticState()
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
    @State private var scrubInteraction=PlaybackScrubInteraction()
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
        if ProcessInfo.processInfo.arguments.contains("--controller-layout-review") {
            playerControls.task(id: presentation.calibrationRequest) {
                // Synthetic-only fixture: exercises the same capture/reset flow without device tracking.
                let provider = ControllerReviewPose(upward: ProcessInfo.processInfo.arguments.contains("--review-auto-pitch"))
                if await presentation.calibration.capture(using: provider) { resetManualDirection() }
            }
        }
        else { immersiveBody }
        #else
        immersiveBody
        #endif
    }
    private var interactiveContent:some View {
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
                        Button("向左轉") { adjustManualDirection(yaw: -15) }
                        Button("方向歸零") { resetDirectionFromControls() }
                        Button("向右轉") { adjustManualDirection(yaw: 15) }
                    }
                    .accessibilityIdentifier("recenterVideo").accessibilityHint("以目前觀看方向重新置中影片")
                    .disabled(!canAdjustManualDirection)
                    HStack {
                        Button("向上轉") { adjustManualDirection(pitch: 15) }
                        Button("向下轉") { adjustManualDirection(pitch: -15) }
                        Button("左傾") { adjustManualDirection(roll: 15) }
                        Button("右傾") { adjustManualDirection(roll: -15) }
                    }.accessibilityIdentifier("recenterVideo").accessibilityHint("以目前觀看方向重新置中影片")
                    .disabled(!canAdjustManualDirection)
                    Button("重新置中") {
                        presentation.calibration.requestRecenter(); presentation.calibrationRequest += 1
                    }.accessibilityIdentifier("recenterVideo").accessibilityHint("以目前觀看方向重新置中影片")
                    .disabled(!canAdjustManualDirection)
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
        // Keep all background commands exclusive. The system owns press/tap timing.
        .gesture(LongPressGesture(minimumDuration:0.5, maximumDistance:10).targetedToEntity(where:.has(ControllerBackgroundTarget.self))
            .exclusively(before:SpatialTapGesture(count:2).targetedToEntity(where:.has(ControllerBackgroundTarget.self)))
            .exclusively(before:SpatialTapGesture(count:1).targetedToEntity(where:.has(ControllerBackgroundTarget.self)))
            .onEnded { result in
                let input:VRBackgroundInteraction.Event;let entity:Entity
                switch result {
                case .first(.first(let event)):
                    guard event.gestureValue else{return}
                    input = .longPress;entity=event.entity
                case .first(.second(let event)):input = .tap(count:2);entity=event.entity
                case .second(let event):input = .tap(count:1);entity=event.entity
                }
                switch VRBackgroundInteraction.action(event:input,isBackground:entity.name.hasPrefix("show-controls-"),active:presentation.active,
                    testPattern:presentation.testPattern,moving:presentation.movingControls,scrubbing:presentation.scrubbing) {
                case .none:break
                case .toggle:cancelControllerResetSample();presentation.toggleControlsFromBackground()
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
                    cancelControllerResetSample()
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
                guard draggingControls else{return}
                draggingControls=false;presentation.movingControls=false
                controlVisual.poseTask?.cancel();controlVisual.poseTask=nil
                controlVisual.dragPointer=nil
                faceViewerAfterDrag()
                presentation.scheduleHide()
            })
    }
    // Bound SwiftUI type inference without changing the view or modifier order.
    private var observedContent:some View {
        interactiveContent
        .onChange(of: presentation.player?.isPaused) { _, _ in presentation.revealControls() }
        .onChange(of: presentation.player?.isPreparing) { _, preparing in
            if preparing == false,presentation.navigationVisibility != nil {presentation.endControllerNavigation()}
            else {presentation.revealControls()}
        }
        .onChange(of: presentation.player?.isPlaying) { _, _ in presentation.revealControls() }
        // Re-evaluate the timer without revealing controls hidden by the user.
        .onChange(of: presentation.player?.speedStatus.selected) { _, _ in presentation.scheduleHide() }
        .onChange(of: renderer.error) { _, error in
            if let error {presentation.player?.persistDiagnostics(event:.rendererFailed);presentation.message=error;presentation.holdControls()}
        }
        .onChange(of: systemRenderer.lastSubmittedSession) {_,session in
            if let session {presentation.player?.markRendererSubmitted(session:session,enqueuedAt:systemRenderer.lastSubmittedAt)}
        }
        .onChange(of: systemRenderer.error) {_,error in
            guard let error else{return}
            playbackBoundaries.begin(4)
            playbackBoundaries.record(.failure,player:presentation.player,fields:[.outcome:2])
            presentation.message=error
            presentation.player?.persistDiagnostics(event:.rendererFailed)
            playbackBoundaries.record(.stopEntered,player:presentation.player,fields:[.outcome:2])
            presentation.player?.stop()
            playbackBoundaries.record(.stopReturned,player:presentation.player,fields:[.outcome:2])
            presentation.holdControls()
        }
        .onChange(of: presentation.message) {_,message in if message != nil {presentation.endControllerNavigation(showError:true);presentation.holdControls()}}
        .onChange(of: presentation.settings) { _, _ in cancelControllerResetSample();updateControllerReference() }
        .onChange(of: presentation.calibrationRequest) { _, _ in cancelControllerResetSample() }
        .onChange(of: presentation.player.map(ObjectIdentifier.init)) { _, _ in cancelControllerResetSample();synchronizeScrubOwner() }
        .onChange(of: presentation.advancing) { _, value in if value {cancelControllerResetSample()} }
        .onChange(of: presentation.scrubbing) { _, value in if value {cancelControllerResetSample()} }
        .onChange(of: presentation.settingsVisible) { _, _ in presentation.revealControls() }
        .onAppear { presentation.revealControls() }
    }
    private var scrubObservedContent:some View {
        observedContent
        .onChange(of: presentation.player?.playbackGeneration) { _, _ in synchronizeScrubOwner() }
        .onDisappear {cancelScrubInteraction()}
    }
    private var immersiveBody:some View {
        scrubObservedContent
        .onChange(of:ImmersiveControllerUIDiagnosticState.state(presentation),initial:true) {_,_ in
            controllerUIDiagnostics.record(presentation:presentation)
        }
        .task {
            while !Task.isCancelled {
                if let player=presentation.player,player.isPlaying || player.isPreparing || presentation.scrubbing || presentation.stopping {
                    let projection=VRProjection.allCases.firstIndex(of:presentation.settings.projection) ?? 0
                    let layout=VRLayout.allCases.firstIndex(of:presentation.settings.layout) ?? 0
                    let route=presentation.settings.projection == .equidistantFisheye180 ? 1:0
                    var values=renderer.logValues
                    values.merge(controllerUIDiagnostics.currentValues(presentation:presentation)){_,new in new}
                    player.persistDiagnostics(projection:projection,layout:layout,route:route,rendererValues:values)
                }
                do {try await Task.sleep(for:.seconds(1))}catch{return}
            }
        }
        .task(id: UpdateKey(image: presentation.image.map(ObjectIdentifier.init), settings: presentation.videoSettings,pixel:presentation.player?.pixelFrame.map(ObjectIdentifier.init))) {
            playbackBoundaries.observeFrame(presentation.player)
            systemRenderer.onRecoverableInterruption = { [weak player=presentation.player, boundaries=playbackBoundaries] session in
                boundaries.record(.upstreamPauseEntered,player:player,once:false)
                guard let player,player.pixelFrame?.session == session else{
                    boundaries.record(.upstreamPauseReturned,player:player,fields:[.outcome:1],once:false)
                    return false
                }
                player.pauseForBackground()
                let accepted=player.isPlaying && !player.isPreparing && player.isPaused && player.pixelFrame?.session == session
                boundaries.record(.upstreamPauseReturned,player:player,fields:[.outcome:accepted ? 0:2],once:false)
                return accepted
            }
            systemRenderer.setSceneActive(scenePhase == .active)
            #if VISTA_SYSTEM_VIDEO_EXPERIMENT
            if !presentation.testPattern,let frame=presentation.player?.pixelFrame {
                if #available(visionOS 26.0,*),SystemVideoSamples.supports(frame,settings:presentation.videoSettings) {
                    playbackBoundaries.record(.stopEntered,player:presentation.player,fields:[.operation:2])
                    renderer.stop()
                    playbackBoundaries.record(.stopReturned,player:presentation.player,fields:[.operation:2])
                    playbackBoundaries.record(.submitEntered,player:presentation.player,fields:[.operation:1])
                    systemRenderer.submit(frame,settings:presentation.videoSettings)
                    playbackBoundaries.record(.submitReturned,player:presentation.player,fields:[.operation:1])
                } else {
                    playbackBoundaries.record(.submitEntered,player:presentation.player,fields:[.operation:2])
                    systemRenderer.stop()
                    renderer.submit(frame:frame,settings:presentation.videoSettings,metrics:presentation.player?.metrics)
                    playbackBoundaries.record(.submitReturned,player:presentation.player,fields:[.operation:2])
                }
            } else {
                playbackBoundaries.record(.submitEntered,player:presentation.player,fields:[.operation:2])
                systemRenderer.stop()
                renderer.submit(image:presentation.image,settings:presentation.videoSettings,metrics:presentation.player?.metrics)
                playbackBoundaries.record(.submitReturned,player:presentation.player,fields:[.operation:2])
            }
            #else
            renderer.submit(image: presentation.image, settings: presentation.videoSettings,metrics:presentation.player?.metrics)
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
            cancelControllerResetSample()
            if await presentation.calibration.capture(using: DeviceInitialPose()) { resetManualDirection();updateControllerReference() }
        }
        .onChange(of: scenePhase) { old, phase in
            LifecycleDiagnostics.shared.record(.scenePhase,[.scope:2,.previousPhase:old.diagnosticValue,.phase:phase.diagnosticValue])
            playbackBoundaries.begin(3)
            let sceneContext=playbackBoundaries.trace.context(),sceneGeneration=playbackBoundaries.generation
            playbackBoundaries.record(.sceneEntered,player:presentation.player,fields:[.previousPhase:old.diagnosticValue,.outcome:phase.diagnosticValue,.active:phase == .active ? 1:0])
            defer {playbackBoundaries.record(.sceneReturned,player:presentation.player,fields:[.outcome:phase.diagnosticValue,.active:phase == .active ? 1:0],context:sceneContext,capturedGeneration:sceneGeneration)}
            systemRenderer.setSceneActive(phase == .active)
            presentation.player?.setPlaybackSceneActive(phase == .active)
            if phase != .active {cancelControllerResetSample()}
            // Preserve Build59/60 upstream policy: inactive alone never pauses or stops playback.
            if phase == .background {
                playbackBoundaries.record(.pauseEntered,player:presentation.player)
                presentation.player?.pauseForBackground()
                playbackBoundaries.record(.pauseReturned,player:presentation.player)
                presentation.holdControls()
            } else if phase == .active {
                // Paused VideoOutput need not emit a new pixel. Re-submit the retained
                // frame explicitly, without seeking, restarting audio, or reconnecting.
                #if VISTA_SYSTEM_VIDEO_EXPERIMENT
                if !presentation.testPattern,let frame=presentation.player?.pixelFrame,
                   #available(visionOS 26.0,*),SystemVideoSamples.supports(frame,settings:presentation.videoSettings) {
                    playbackBoundaries.observeFrame(presentation.player)
                    playbackBoundaries.record(.submitEntered,player:presentation.player,fields:[.operation:1])
                    systemRenderer.submit(frame,settings:presentation.videoSettings)
                    playbackBoundaries.record(.submitReturned,player:presentation.player,fields:[.operation:1])
                }
                #endif
            }
        }
        .onAppear{
            controllerUIDiagnostics.record(.viewAppeared,presentation:presentation)
            presentation.player?.setPlaybackSceneActive(scenePhase == .active)
            playbackBoundaries.begin(1)
            playbackBoundaries.record(.sceneEntered,player:presentation.player,fields:[.outcome:scenePhase.diagnosticValue,.active:scenePhase == .active ? 1:0])
            LifecycleDiagnostics.shared.record(.viewAppear,[.scope:2,.phase:scenePhase.diagnosticValue])
            playbackBoundaries.record(.sceneReturned,player:presentation.player,fields:[.outcome:scenePhase.diagnosticValue,.active:scenePhase == .active ? 1:0])
        }
        .onDisappear {
            controllerUIDiagnostics.record(.viewDisappeared,presentation:presentation)
            playbackBoundaries.begin(5)
            playbackBoundaries.record(.stopEntered,player:presentation.player)
            defer {playbackBoundaries.record(.stopReturned,player:presentation.player)}
            LifecycleDiagnostics.shared.record(.viewDisappear,[.scope:2])
            cancelControllerResetSample()
            presentation.calibration.cancel()
            controlVisual.resetTrace.cancel()
            controlVisual.resetFrameSubscription?.cancel();controlVisual.resetFrameSubscription=nil
            controlVisual.fadeTask?.cancel();controlVisual.fadeTask=nil
            controlVisual.facingTask?.cancel();controlVisual.facingTask=nil
            controlVisual.poseTask?.cancel();controlVisual.poseTask=nil
            controlVisual.dragPointer=nil;draggingControls=false
            presentation.player?.setPlaybackSceneActive(false)
            renderer.stop();systemRenderer.stop(); presentation.finishSession()
            controllerUIDiagnostics.record(.stopCompleted,presentation:presentation)
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
    private var displayedSpeedStatus:PlaybackSpeedStatus {
        #if DEBUG
        if let reviewSpeedStatus {return reviewSpeedStatus}
        #endif
        return presentation.player?.speedStatus ?? PlaybackSpeedStatus()
    }
    private var displayedBuffering:Bool {
        #if DEBUG
        if let reviewSpeedStatus {return reviewSpeedStatus.showsBufferingIndicator}
        #endif
        return presentation.player.map {$0.isBuffering && !$0.isPaused} ?? false
    }
    private var displayedVideoInfo:VideoTrackInfo? {
        #if DEBUG
        if let reviewVideoInfo {return reviewVideoInfo}
        #endif
        return presentation.player?.trackInfo
    }
    private func progressDurationText(_ player:PlaybackController?)->String {
        #if DEBUG
        if let reviewProgressDurationText {return reviewProgressDurationText}
        #endif
        return PlaybackProgress.time(PlaybackProgress.duration(player?.trackInfo?.duration))
    }
    private var speedStatusBelowButton:some View {
        // The empty 1× slot keeps the control row stable without a hidden text/AX node.
        // Overlay sizing never changes the accelerator or its neighbours' hit regions.
        ZStack {
            if displayedSpeedStatus.selected>1 {
                Text(displayedSpeedStatus.text).font(.caption.monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityIdentifier("playbackSpeed")
            }
        }.frame(width:176,height:speedStatusLineHeight)
            .allowsHitTesting(false).hoverEffectDisabled()
    }
    @ViewBuilder private var playerControls: some View {
        VStack(spacing: 12) {
            HStack(alignment:.top,spacing:8) {
                Button {
                    guard !presentation.stopping else { return }
                    presentation.stopping = true
                    let diagnosticState=controllerUIDiagnostics
                    diagnosticState.record(.stopBegan,presentation:presentation)
                    presentation.onCancelNavigation?()
                    presentation.player?.stop()
                    Task {
                        await dismiss(); presentation.finishSession()
                        diagnosticState.record(.stopCompleted,presentation:presentation)
                    }
                } label: { Image(systemName:"chevron.backward") }
                .accessibilityLabel("停止並返回瀏覽").accessibilityIdentifier("immersiveStop")
                .disabled(presentation.stopping).frame(height:44)
                HStack(alignment:.top,spacing:0) {
                    ControllerFilenameTitle(title:presentation.fileTitle,readiness:submittedAccessibilityValue)
                        .frame(minWidth:0,maxWidth:.infinity,alignment:.leading)
                        .padding(.leading,8).padding(.vertical,6).contentShape(Rectangle())
                    // Match the progress row's fixed duration width and 10pt gap, then inset 16pt.
                    Text(progressDurationText(presentation.player))
                        .font(.caption.monospacedDigit()).fixedSize()
                        .hidden().accessibilityHidden(true).padding(.leading,26)
                }
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
                    Button { presentation.revealControls(); player.resetSpeed() } label: { Text("1×").monospacedDigit() }
                        .accessibilityLabel("恢復 1 倍速").accessibilityIdentifier("immersiveBack")
                        .disabled(!player.canResetSpeed || presentation.advancing || presentation.requiresFormatConfirmation)
                    Button {
                        if player.isPlaying { player.togglePause() } else { presentation.onReplay?() }
                        presentation.revealControls()
                    } label: { Image(systemName: player.isPlaying && !player.isPaused ? "pause.fill" : "play.fill") }
                        .accessibilityLabel(player.isPlaying && !player.isPaused ? "暫停" : "播放")
                        .accessibilityIdentifier("immersivePause")
                        .disabled(player.isPreparing || presentation.advancing || presentation.requiresFormatConfirmation)
                    Button { presentation.revealControls(); player.increaseSpeed() } label: { Image(systemName:"forward.fill") }
                        .accessibilityLabel("加速 0.5 倍").accessibilityIdentifier("immersiveForward")
                        .accessibilityHint("最高 \(PlaybackSpeedStatus.upperLimit) 倍速，依影片支援能力開放")
                        .disabled(!player.canIncreaseSpeed || presentation.advancing || presentation.requiresFormatConfirmation)
                        .overlay(alignment:.bottom) {
                            speedStatusBelowButton.alignmentGuide(.bottom) {$0[.top]-4}
                        }
                    Button { presentation.onNext?(); presentation.holdControls() } label: { Image(systemName: "forward.end.fill") }
                        .accessibilityLabel("下一個影片").accessibilityIdentifier("immersiveNext")
                        .disabled(!presentation.canAdvance || presentation.advancing)
                    Button { presentation.settingsVisible.toggle(); presentation.revealControls() } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("影片格式設定").accessibilityIdentifier("immersiveSettings")
                }.buttonStyle(.borderless).font(.title3).disabled(presentation.stopping || presentation.scrubbing)
                    .padding(.bottom,speedStatusLineHeight+4)
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
            }
            if presentation.settingsVisible || presentation.requiresFormatConfirmation {
                Divider()
                VRSettingsView(presentation: presentation) { presentation.onFormatChanged?(); presentation.holdControls() }
                if presentation.requiresFormatConfirmation {
                    Button("使用目前格式並播放") { presentation.onFormatChanged?(); presentation.onReplay?() }
                        .accessibilityIdentifier("immersiveConfirmFormat")
                }
                angleRuler(vertical:false).padding(.leading,56)
                HStack(spacing:8) {
                    angleRuler(vertical:true)
                    ZStack {
                    ringControl("重設影片方向", angle: -90, outer: true, identifier: "recenterVideo", hint: "以目前觀看方向重新置中影片，成功後清除自動補償與手動轉向；也可長按影片背景", action:resetVideoDirection).disabled(!canAdjustManualDirection)
                    ringControl("重設\n影片格式", angle: -165, outer: true, identifier: "clearVRFormat", hint: "清除此片保存格式，不重設方向或控制器位置") {
                        presentation.onClearFormat?(); presentation.holdControls()
                    }.disabled(!presentation.canClearFormat || presentation.advancing)
                        .opacity(!presentation.canClearFormat || presentation.advancing ? 0.35:1)
                        .hoverEffectDisabled(!presentation.canClearFormat || presentation.advancing)
                    ringControl("重設\n控制器\n位置", angle: -15, outer: true, identifier: "resetControllerPosition", hint: "也可雙擊影片背景", action: resetControllerPosition)
                    ringControl("arrowtriangle.up.fill", angle: -90, outer: false, identifier: "directionUp", hint: "向上轉，每次15度") { adjustManualDirection(pitch: 15) }.disabled(!canAdjustManualDirection)
                    ringControl("arrowtriangle.left.fill", angle: -180, outer: false, identifier: "directionLeft", hint: "向左轉，每次15度") { adjustManualDirection(yaw: -15) }.disabled(!canAdjustManualDirection)
                    ringControl("arrowtriangle.right.fill", angle: 0, outer: false, identifier: "directionRight", hint: "向右轉，每次15度") { adjustManualDirection(yaw: 15) }.disabled(!canAdjustManualDirection)
                    ringControl("arrowtriangle.down.fill", angle: 90, outer: false, identifier: "directionDown", hint: "向下轉，每次15度") { adjustManualDirection(pitch: -15) }.disabled(!canAdjustManualDirection)
                    Button(action:resetDirectionFromControls) {
                        Text("歸零").font(.caption).frame(width:54,height:54)
                    }.buttonStyle(CenterRingFeedbackStyle()).disabled(!canAdjustManualDirection)
                        .accessibilityLabel("方向歸零").accessibilityIdentifier("directionZero")
                        .accessibilityValue("yaw=\(VRManualAngleDisplay.normalized(presentation.videoSettings.yawDegrees)),pitch=\(VRManualAngleDisplay.normalized(presentation.videoSettings.pitchDegrees)),roll=\(VRManualAngleDisplay.normalized(presentation.videoSettings.rollDegrees))")
                        .accessibilityHint("清除自動補償與手動轉向，不重新採樣觀看方向").position(x:190,y:180)
                    }.frame(width:380,height:286)
                }
                Text("角度含自動補償與手動調整，相對本次取樣；每格 15°")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Text("看向影片背景：單擊顯示／隱藏；雙擊重設控制器位置；長按重設影片方向")
                    .fixedSize(horizontal:false,vertical:true)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("resetControllerGestureHint")
                if let info=displayedVideoInfo {
                    HStack(spacing:6) {
                        Text("\(info.codec) · \(info.width) × \(info.height) · \(info.averageBitrateText)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
                            .accessibilityIdentifier("controllerVideoInfo")
                            .accessibilityHint("位元率是視訊軌平均估計值，不含音訊與容器，不是即時位元率；破折號表示未知")
                        // Keep the info text stable across brief waits; absent when collapsed.
                        ZStack {
                            if displayedBuffering {
                                ProgressView().controlSize(.mini)
                                    .accessibilityLabel("等待播放")
                                    .accessibilityIdentifier("controllerVideoInfoBuffering")
                            }
                        }.frame(width:14,height:14)
                    }
                    if !info.hasAudio {Text("影片無音軌").font(.caption).foregroundStyle(.secondary)}
                }

            }
        }.padding(16).frame(width: 480)
            .glassBackgroundEffect()
            .allowsHitTesting(presentation.controlsVisible)
            .accessibilityHidden(!presentation.controlsVisible)
            .onHover { hovering in if hovering { presentation.holdControls() } else { presentation.scheduleHide() } }
    }
    private var angleReadoutAvailable:Bool {
        canAdjustManualDirection && presentation.controlsVisible && !presentation.stopping &&
        !presentation.movingControls && !presentation.scrubbing && scenePhase == .active
    }
    private func angleRuler(vertical:Bool)->some View {
        AngleRulerReadout(value:vertical ? presentation.videoSettings.pitchDegrees:presentation.videoSettings.yawDegrees,
            vertical:vertical,available:angleReadoutAvailable)
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
    private func cancelScrubInteraction() {
        scrubInteraction.cancel();presentation.scrubbing=false
    }
    private func synchronizeScrubOwner() {
        scrubInteraction.retainOnly(owner:presentation.player?.playbackGeneration)
        presentation.scrubbing=scrubInteraction.isActive
    }
    @ViewBuilder private func playbackProgress(_ player:PlaybackController)->some View {
        let duration=PlaybackProgress.duration(player.trackInfo?.duration)
        let scrubOwner=player.playbackGeneration
        let enabled=duration != nil && !player.isPreparing && !presentation.advancing && !presentation.stopping && !presentation.requiresFormatConfirmation
        HStack(spacing:10) {
            Text(PlaybackProgress.time(presentation.scrubbing ? scrubPosition:player.position))
                .accessibilityIdentifier("playbackElapsed")
            Slider(value:Binding(get:{presentation.scrubbing ? scrubPosition:PlaybackProgress.clamp(player.position,duration:duration)},set:{value in
                guard presentation.player === player,player.playbackGeneration==scrubOwner else{return}
                scrubInteraction.update(value,owner:scrubOwner,initialPosition:PlaybackProgress.clamp(player.position,duration:duration))
                if !presentation.scrubbing {
                    presentation.scrubbing=true;presentation.holdControls()
                    controllerUIDiagnostics.record(.sliderValueBegan,presentation:presentation)
                }
                scrubPosition=value
            }),in:0...(duration ?? 1),onEditingChanged:{ editing in
                guard presentation.player === player,player.playbackGeneration==scrubOwner else{return}
                if editing {
                    scrubInteraction.begin(owner:scrubOwner,position:PlaybackProgress.clamp(player.position,duration:duration))
                    if !presentation.scrubbing {scrubPosition=PlaybackProgress.clamp(player.position,duration:duration)}
                    presentation.scrubbing=true;presentation.holdControls()
                    controllerUIDiagnostics.record(.sliderEditingBegan,presentation:presentation)
                }
                else {
                    let target=scrubInteraction.finish(owner:scrubOwner);presentation.scrubbing=false
                    controllerUIDiagnostics.record(.sliderEnded,presentation:presentation)
                    if let target,enabled,presentation.active,!presentation.stopping,presentation.player === player {player.seek(to:target)}
                    presentation.revealControls()
                }
            }).disabled(!enabled)
                .id(scrubOwner)
                .onDisappear {if scrubInteraction.owner==scrubOwner {cancelScrubInteraction()}}
                .accessibilityLabel("播放進度")
                .accessibilityIdentifier("playbackSeek")
                .accessibilityHint("拖曳後放開以跳轉。")
            Text(progressDurationText(player)).accessibilityIdentifier("playbackDuration")
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
        guard !presentation.movingControls,!presentation.scrubbing,canAdjustManualDirection else{return}
        cancelControllerResetSample()
        presentation.calibration.requestRecenter();presentation.calibrationRequest += 1
    }
    private func cancelControllerResetSample() {
        controlVisual.resetRequest.cancel()
        controlVisual.resetPoseTask?.cancel();controlVisual.resetPoseTask=nil
    }
    private func resetControllerPosition() {
        guard !presentation.movingControls,!presentation.scrubbing else{return}
        cancelControllerResetSample()
        controlVisual.facingTask?.cancel()
        if presentation.navigationVisibility != nil {presentation.navigationVisibility=true}
        presentation.controlsVisible=true
        presentation.scheduleHide()
        guard presentation.active,!presentation.stopping,!presentation.advancing,
              presentation.calibration.status != .capturing else {
            applyControllerReset(pose:nil);return
        }
        let ticket=controlVisual.resetRequest.begin()
        let player=presentation.player,entity=controlEntity
        let calibrationRequest=presentation.calibrationRequest,settings=presentation.settings
        controlVisual.resetPoseTask=Task { @MainActor in
            let pose=try? await DeviceInitialPose(resetSample:true).sample()
            guard !Task.isCancelled,controlVisual.resetRequest.isCurrent(ticket) else{return}
            guard presentation.active,!presentation.stopping,!presentation.advancing,
                  !presentation.movingControls,!presentation.scrubbing,scenePhase == .active,
                  presentation.player === player,controlEntity === entity,
                  presentation.calibrationRequest==calibrationRequest,presentation.settings==settings,
                  presentation.calibration.status != .capturing else {
                cancelControllerResetSample();return
            }
            guard controlVisual.resetRequest.finish(ticket) else{return}
            controlVisual.resetPoseTask=nil
            applyControllerReset(pose:pose)
        }
    }
    private func applyControllerReset(pose:VRInitialPose?) {
        controlVisual.resetFrameSubscription?.cancel();controlVisual.resetFrameSubscription=nil
        let resetTicket=controlVisual.resetTrace.begin()
        controlVisual.resetStarted=ProcessInfo.processInfo.systemUptime
        recordControllerReset(.before,ticket:resetTicket,controls:controlEntity)
        controlVisual.facingTask?.cancel()
        controlVisual.worldFrame=VRControllerWorldFrame.frame(parentWorld:controllerReference.orientation(relativeTo:nil))
        if let pose {
            controlVisual.viewer=controllerReference.convert(position:pose.position,from:nil)
            controlVisual.cachedHead=pose.orientation;controlVisual.poseCacheSource=3
            controlVisual.poseCacheWritten=ProcessInfo.processInfo.systemUptime
        }
        controlVisual.orientation=VRControllerVisualLevel.facing(position:VRControllerPlacement.origin,viewer:controlVisual.viewer,
            frame:controlVisual.worldFrame,viewingHead:pose?.orientation,previous:controlVisual.orientation)
        presentation.controlsOffset = .zero
        if presentation.navigationVisibility != nil {presentation.navigationVisibility=true}
        presentation.controlsVisible=true
        presentation.scheduleHide()
        // The sampled orientation is not observable; commit it even when reset position is already zero.
        placeControls(controlEntity)
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
    private var canAdjustManualDirection: Bool {
        presentation.calibration.allowsManualDirection(isLoading: presentation.advancing)
    }
    private func adjustManualDirection(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) {
        guard canAdjustManualDirection else { return }
        presentation.settings.yawDegrees += yaw
        presentation.settings.pitchDegrees += pitch
        presentation.settings.rollDegrees += roll
    }
    private func resetDirectionFromControls() {
        guard canAdjustManualDirection else { return }
        presentation.calibration.resetDirection(&presentation.settings)
    }
    private func resetManualDirection() {
        presentation.settings.yawDegrees = 0; presentation.settings.pitchDegrees = 0; presentation.settings.rollDegrees = 0
    }
    private func updateControllerReference() {
        guard let entry=controllerEntryPose else{return}
        // Keep controller placement independent of the automatic video comfort offset.
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
        controlVisual.worldFrame=VRControllerWorldFrame.frame(parentWorld:controllerReference.orientation(relativeTo:nil))
        controlVisual.cachedHead=(presentation.calibration.pose ?? entry).orientation
        controlVisual.poseCacheSource=presentation.calibration.pose == nil ? 0:1
        controlVisual.poseCacheWritten=ProcessInfo.processInfo.systemUptime
        if !draggingControls && !presentation.preservePlacementAcrossFiles {controlVisual.orientation=VRControllerVisualLevel.facing(position:VRControllerPlacement.origin+presentation.controlsOffset,viewer:viewer,frame:controlVisual.worldFrame,viewingHead:controlVisual.cachedHead,previous:controlVisual.orientation)}
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
        if let ticket=controlVisual.resetTrace.applied() {
            recordControllerReset(.applied,ticket:ticket,controls:controls)
            controlVisual.resetFrameSubscription=controls.scene?.subscribe(to:SceneEvents.Update.self) { [weak controls] _ in
                guard let controls,controlVisual.resetTrace.nextFrame(ticket:ticket) else{return}
                controlVisual.resetFrameSubscription?.cancel();controlVisual.resetFrameSubscription=nil
                recordControllerReset(.nextSceneUpdate,ticket:ticket,controls:controls)
            }
        }
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
        // Existing drag-only tracking provides a consistent viewer position and viewing frame.
        // Full viewer-relative facing includes height; the center projection stays visually level.
        // Keep the last valid position on tracking loss, with the existing sampling lifecycle.
        controlVisual.poseTask=Task { @MainActor in
            guard presentation.calibration.status != .capturing else{return}
            try? await DeviceInitialPose().duringDrag { pose in
                guard !Task.isCancelled,presentation.movingControls,controls.parent === parent else{return}
                controlVisual.viewer=parent.convert(position:pose.position,from:nil)
                controlVisual.worldFrame=VRControllerWorldFrame.frame(parentWorld:parent.orientation(relativeTo:nil))
                controlVisual.cachedHead=pose.orientation;controlVisual.poseCacheSource=2
                controlVisual.poseCacheWritten=ProcessInfo.processInfo.systemUptime
            }
        }
        controlVisual.facingTask=Task { @MainActor in
            var last=ContinuousClock.now
            while !Task.isCancelled,presentation.movingControls,!presentation.stopping,controls.parent === parent {
                let now=ContinuousClock.now
                let duration=last.duration(to:now).components
                let elapsed=Float(duration.seconds)+Float(duration.attoseconds)/1e18
                last=now
                let target=VRControllerVisualLevel.facing(position:controls.position,viewer:controlVisual.viewer,frame:controlVisual.worldFrame,viewingHead:controlVisual.cachedHead,previous:controlVisual.orientation)
                let levelFrame=VRControllerVisualLevel.levelingFrame(position:controls.position,viewer:controlVisual.viewer,frame:controlVisual.worldFrame,viewingHead:controlVisual.cachedHead)
                controlVisual.orientation=VRControllerVisualLevel.approaching(controlVisual.orientation,target:target,frame:levelFrame,elapsed:elapsed)
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
            // Release uses the same last valid viewing sample, without a late resample.
            guard !Task.isCancelled,!presentation.stopping,controls.parent === parent else{return}
            let viewer=controlVisual.viewer
            let target=VRControllerVisualLevel.facing(position:position,viewer:viewer,frame:controlVisual.worldFrame,viewingHead:controlVisual.cachedHead,previous:start)
            let levelFrame=VRControllerVisualLevel.levelingFrame(position:position,viewer:viewer,frame:controlVisual.worldFrame,viewingHead:controlVisual.cachedHead)
            for step in 1...(reduceMotion ? 1:12) {
                guard !Task.isCancelled else{return}
                let t=reduceMotion ? Float(1):Float(step)/12
                controlVisual.orientation=VRControllerVisualLevel.interpolating(start,target:target,frame:levelFrame,fraction:t*t*(3-2*t))
                controls.orientation=controlVisual.orientation
                if !reduceMotion {do {try await Task.sleep(for:.milliseconds(16))} catch{return}}
            }
        }
    }
    private func recordControllerReset(_ phase:ControllerResetLogPhase,ticket:Int,controls:Entity?) {
        let parent=controls?.parent
        let video:Entity?=systemRenderer.ready && systemRenderer.entity.isEnabled ? systemRenderer.entity:(renderer.ready && renderer.entity.isEnabled ? renderer.entity:nil)
        var values=ControllerResetLog.values(sequence:ticket,phase:phase,world:controls?.transformMatrix(relativeTo:nil),
            parent:parent?.transformMatrix(relativeTo:nil),local:controls?.transform.matrix,intended:controlVisual.orientation,
            frame:controlVisual.worldFrame,cachedHead:controlVisual.cachedHead,video:video?.orientation(relativeTo:nil),
            localPosition:controls?.position,cachedViewer:controlVisual.viewer,offset:presentation.controlsOffset)
        let now=ProcessInfo.processInfo.systemUptime
        values[.crElapsedMS]=(now-controlVisual.resetStarted)*1000
        values[.crPoseSource]=Double(controlVisual.poseCacheSource)
        if let written=controlVisual.poseCacheWritten {values[.crPoseAgeMS]=(now-written)*1000}
        values[.crExpectedParent]=parent === controllerReference ? 1:0
        values[.crHasScene]=controls?.scene == nil ? 0:1
        values[.crPreservePlacement]=presentation.preservePlacementAcrossFiles ? 1:0
        values[.crVisible]=presentation.controlsVisible ? 1:0
        values[.crMoving]=presentation.movingControls ? 1:0;values[.crScrubbing]=presentation.scrubbing ? 1:0
        switch presentation.calibration.status {case .idle:values[.crCalibration]=0;case .capturing:values[.crCalibration]=1;case .ready:values[.crCalibration]=2;case .unavailable:values[.crCalibration]=3}
        values[.crAutoPitch]=presentation.calibration.automaticPitchDegrees
        values[.crManualYaw]=presentation.settings.yawDegrees;values[.crManualPitch]=presentation.settings.pitchDegrees;values[.crManualRoll]=presentation.settings.rollDegrees
        values[.projection]=Double(VRProjection.allCases.firstIndex(of:presentation.settings.projection) ?? 0)
        values[.layout]=Double(VRLayout.allCases.firstIndex(of:presentation.settings.layout) ?? 0)
        values[.route]=video === systemRenderer.entity ? 0:(video === renderer.entity ? 1:-1)
        let status=PlaybackLogStore.shared.status;values[.logFailures]=Double(status.failures);values[.logDropped]=Double(status.dropped)
        PlaybackLogStore.shared.enqueue(PlaybackLogRecord(event:.controllerReset,values:values))
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
    var resetTrace=ControllerResetTrace()
    var resetRequest=VRControllerResetRequest()
    var resetPoseTask:Task<Void,Never>?
    var resetFrameSubscription:(any Cancellable)?
    var resetStarted:Double=0
    var cachedHead:simd_quatf?
    var poseCacheSource:Int = -1
    var poseCacheWritten:Double?
    var orientation=VRControllerWorldFrame.facing(position:VRControllerPlacement.origin,viewer:.zero,frame:simd_quatf(angle:0,axis:[0,1,0]),previous:simd_quatf(angle:0,axis:[0,1,0]))
    var facingTask:Task<Void,Never>?
    var poseTask:Task<Void,Never>?
    var viewer=SIMD3<Float>.zero
    var worldFrame=simd_quatf(angle:0,axis:[0,1,0])
    var dragPointer:SIMD3<Float>?
    var localGrab=SIMD3<Float>.zero
    var fadeTarget:Bool?
    var fadeTask:Task<Void,Never>?
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

#if DEBUG
private struct ControllerReviewPose: VRInitialPoseProvider {
    let upward: Bool
    func sample() async throws -> VRInitialPose? {
        var matrix = simd_float4x4(VRInitialPose.manualRotation(yaw: 0, pitch: upward ? 45 : 0, roll: 0))
        matrix.columns.3 = [0, 1.2, 0, 1]
        return VRInitialPose(matrix: matrix)
    }
}
#endif



/// Use native text layout, not character count, to keep a complete title large whenever one line fits.
private struct ControllerFilenameTitle:View {
    let title:String
    let readiness:String
    var body:some View {
        Group {
            if title.contains(where:\.isNewline) {
                compactTitle
            } else {
                ViewThatFits(in:.horizontal) {
                    titleText(font:.title3,mode:"large")
                        .lineLimit(1).fixedSize(horizontal:true,vertical:true)
                    compactTitle
                }
            }
        }.multilineTextAlignment(.leading)
    }
    private var compactTitle:some View {
        titleText(font:.caption,mode:"compact")
            .lineLimit(nil).fixedSize(horizontal:false,vertical:true)
    }
    private func titleText(font:Font,mode:String)->some View {
        Text(title).font(font)
            .accessibilityLabel(title)
            .accessibilityIdentifier("immersiveFileTitle")
            .accessibilityValue(reviewValue(mode:mode))
    }
    private func reviewValue(mode:String)->String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--review-file-title-layout") {
            return readiness+";titleLayout="+mode
        }
        #endif
        return readiness
    }
}

/// Display-only angle ruler. Direction changes remain on the existing 15-degree buttons.
private struct AngleRulerReadout:View {
    let value:Double
    let vertical:Bool
    let available:Bool
    private let extent:CGFloat=240
    private var tickStep:CGFloat {vertical ? 30:60}
    private var centre:Double {
        let visible=vertical ? 60.0:30.0
        return value-min(max(value,-visible),visible)
    }
    var body:some View {
        VStack(spacing:4) {
            // Retain the original two-line header height so the track and controls do not move.
            VStack(spacing:4) {
                Text(vertical ? "垂直":"水平")
                Text(VRManualAngleDisplay.text(value)).fixedSize()
            }.hidden().accessibilityHidden(true)
                .frame(width:vertical ? 56:nil)
                .overlay(alignment:vertical ? .leading:.bottom) {
                    HStack(alignment:.firstTextBaseline,spacing:6) {
                        Text(vertical ? "垂直":"水平")
                            .accessibilityIdentifier(vertical ? "manualVerticalTitle":"manualHorizontalTitle")
                        Text(VRManualAngleDisplay.text(value))
                            .accessibilityIdentifier(vertical ? "manualVerticalAngle":"manualHorizontalAngle")
                    }.fixedSize(horizontal:true,vertical:false)
                }
            ZStack(alignment:.topLeading) {
                Path { p in
                    if vertical {p.move(to:.init(x:42,y:0));p.addLine(to:.init(x:42,y:extent))}
                    else {p.move(to:.init(x:0,y:28));p.addLine(to:.init(x:extent,y:28))}
                }.stroke(.secondary,lineWidth:1)
                ForEach(-4...4,id:\.self) { index in
                    let pos=extent/2+CGFloat(index)*tickStep
                    if pos>=0 && pos<=extent {
                        let angle=centre+Double(index*15)*(vertical ? -1:1)
                        Group {
                            if vertical {
                                Rectangle().fill(.secondary).frame(width:8,height:1).position(x:42,y:pos)
                                if index%2 == 0 {Text(VRManualAngleDisplay.text(angle)).font(.caption2).fixedSize().position(x:15,y:pos)}
                            } else {
                                Rectangle().fill(.secondary).frame(width:1,height:8).position(x:pos,y:28)
                                if index%2 == 0 {Text(VRManualAngleDisplay.text(angle)).font(.caption2).fixedSize().position(x:pos,y:46)}
                            }
                        }.allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                let offset=CGFloat(value-centre)/15*tickStep*(vertical ? -1:1)
                Image(systemName:vertical ? "arrowtriangle.right.fill":"arrowtriangle.down.fill")
                    .font(.caption).foregroundStyle(.primary)
                    .position(x:vertical ? 30:extent/2+offset,y:vertical ? extent/2+offset:14)
            }.frame(width:vertical ? 56:extent,height:vertical ? extent:60)
                .accessibilityHidden(true)
        }.font(.caption).frame(width:vertical ? 56:nil)
            .opacity(available ? 1:0.35)
            .allowsHitTesting(false)
    }
}
