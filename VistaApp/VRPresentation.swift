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
import CoreMotion
import ARKit
import QuartzCore
import Spatial

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
        Text(VistaL10n.text("影片格式")).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).accessibilityAddTraits(.isHeader).accessibilityIdentifier("videoFormatHeading")
        HStack(spacing:8) {
            projectionChoice("180°",.equirectangular180)
            projectionChoice("360°",.equirectangular360)
            projectionChoice(VistaL10n.text("魚眼"),.equidistantFisheye180)
        }.accessibilityElement(children:.contain).accessibilityLabel(VistaL10n.text("投影"))
        HStack(spacing:8) {
            layoutChoice(VistaL10n.text("上下"),.overUnder)
            layoutChoice(VistaL10n.text("左右"),.sideBySide)
            layoutChoice(VistaL10n.text("單眼"),.mono)
        }.accessibilityElement(children:.contain).accessibilityLabel(VistaL10n.text("畫面排列"))
        if presentation.settings.projection == .equidistantFisheye180 {
            explanation.accessibilityIdentifier("fisheyeScope")
        } else {
            explanation.hidden().accessibilityHidden(true)
        }
    }
    private var explanation:some View {
        Text(VistaL10n.text("每眼須為置中的 180° 等距圓形影像，圓徑等於短邊；不適用前後雙魚眼 360° 或需鏡頭校正的素材。"))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal:false,vertical:true).allowsHitTesting(false)
    }
    private func projectionChoice(_ title:String,_ value:VRProjection)->some View {
        choice(title,description:value.title,selected:presentation.settings.projection == value,identifier:"projection-"+value.rawValue) {
            guard presentation.settings.projection != value else{return}
            presentation.settings.projection=value;edited()
        }
    }
    private func layoutChoice(_ title:String,_ value:VRLayout)->some View {
        choice(title,description:value.title,selected:presentation.settings.layout == value,identifier:"layout-"+value.rawValue) {
            guard presentation.settings.layout != value else{return}
            presentation.settings.layout=value;edited()
        }
    }
    private func choice(_ title:String,description:String,selected:Bool,identifier:String,action:@escaping ()->Void)->some View {
        Button(action:action) {
            Text(title).lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth:.infinity,minHeight:44).padding(.horizontal,6)
                .foregroundStyle(selected ? BrowserBluePalette.emphasis:Color.primary)
                .background(selected ? BrowserBluePalette.selection.opacity(0.35):Color.white.opacity(0.05),in:Capsule())
                .overlay(Capsule().strokeBorder(selected ? BrowserBluePalette.emphasis.opacity(0.7):.clear,lineWidth:1))
                .contentShape(.interaction,Capsule()).contentShape(.hoverEffect,Capsule())
        }.buttonStyle(.plain).hoverEffect(.highlight)
            .accessibilityLabel(description).accessibilityValue(selected ? VistaL10n.text("已選取"):VistaL10n.text("未選取"))
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
            hasDuration:PlaybackProgress.duration(player?.trackInfo?.duration) != nil,
            canRetargetPendingSeek:player?.canRetargetPendingSeek ?? false)
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
    @GestureState private var moveGestureActive=false
    @State private var moveGestureSerial:UInt64=0
    @State private var moveCancellationTask:Task<Void,Never>?
    @State private var moveTrace:VRRecenterTrace?
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
        entity.components.set(CollisionComponent(shapes:[.generateBox(size:VRControllerHandle.collisionSize)]))
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
        } update: { content, attachments in
            applyPlacement()
            placeControls(attachments.entity(for: "controls"))
        } attachments: {
            Attachment(id: "controls") {
                if !presentation.testPattern {
                    playerControls
                        .onGeometryChange3D(for:ControllerAttachmentGeometry.self,of:{proxy in
                            ControllerAttachmentGeometry(proxy:proxy)
                        },action:{value in
                            controlVisual.attachmentGeometry=value
                            controlVisual.attachmentChanged=CACurrentMediaTime()
                            controlVisual.attachmentRevision &+= 1
                        })
                } else {
                VStack {
                    if presentation.testPattern {
                        Text(VistaL10n.text("投影測試圖，非影片播放")).accessibilityIdentifier("vrTestPattern")
                        if presentation.settings.projection == .equidistantFisheye180 {
                            Text(VistaL10n.text("魚眼校準圖：環線 30°／60°／90°，上綠、右紅、下藍、左黃"))
                                .font(.caption).accessibilityIdentifier("fisheyeCalibration")
                        }
                    }
                    if presentation.calibration.status == .capturing {
                        ProgressView(VistaL10n.text("設定初始方向…"))
                    } else if presentation.calibration.status == .unavailable {
                        Text(VistaL10n.text("無法取得初始方向；可手動調整或重新置中。"))
                            .font(.caption).accessibilityIdentifier("initialPoseUnavailable")
                    }
                    if let error = renderer.error { Text(error).accessibilityIdentifier("vrError") }
                    else if renderer.ready { Text(presentation.settings.projection.title).accessibilityIdentifier("vrReady") }
                    else { ProgressView(VistaL10n.text("準備投影…")) }
                    Text(presentation.settings.layout.title).accessibilityIdentifier("vrLayoutReady")
                    HStack {
                        Button(VistaL10n.text("向左轉")) { adjustManualDirection(yaw: -15) }
                        Button(VistaL10n.text("方向歸零")) { resetDirectionFromControls() }
                        Button(VistaL10n.text("向右轉")) { adjustManualDirection(yaw: 15) }
                    }
                    .accessibilityIdentifier("recenterVideo").accessibilityHint(VistaL10n.text("以目前觀看方向重新置中影片"))
                    .disabled(!canAdjustManualDirection)
                    HStack {
                        Button(VistaL10n.text("向上轉")) { adjustManualDirection(pitch: 15) }
                        Button(VistaL10n.text("向下轉")) { adjustManualDirection(pitch: -15) }
                        Button(VistaL10n.text("左傾")) { adjustManualDirection(roll: 15) }
                        Button(VistaL10n.text("右傾")) { adjustManualDirection(roll: -15) }
                    }.accessibilityIdentifier("recenterVideo").accessibilityHint(VistaL10n.text("以目前觀看方向重新置中影片"))
                    .disabled(!canAdjustManualDirection)
                    Button(VistaL10n.text("重新置中")) {
                        presentation.calibration.requestRecenter(); presentation.calibrationRequest += 1
                    }.accessibilityIdentifier("recenterVideo").accessibilityHint(VistaL10n.text("以目前觀看方向重新置中影片"))
                    .disabled(!canAdjustManualDirection)
                        .accessibilityIdentifier("recenterVR")
                        .accessibilityValue(presentation.calibration.status == .ready ? VistaL10n.text("已取得初始方向") : VistaL10n.text("尚未取得初始方向"))
                    if !presentation.testPattern, let player = presentation.player {
                        Button(player.isPaused ? VistaL10n.text("繼續") : VistaL10n.text("暫停"), action: player.togglePause).disabled(player.isPreparing || !player.isPlaying)
                    }
                    Button(VistaL10n.text("返回視窗")) { Task { await dismiss(); presentation.active = false } }.accessibilityIdentifier("closeVR")
                }.padding().glassBackgroundEffect()
                }
            }
        }
        // Keep all background commands exclusive. The system owns press/tap timing.
        .gesture(LongPressGesture(minimumDuration:0.5, maximumDistance:25).targetedToEntity(where:.has(ControllerBackgroundTarget.self))
            .exclusively(before:SpatialTapGesture(count:2).targetedToEntity(where:.has(ControllerBackgroundTarget.self)))
            .exclusively(before:SpatialTapGesture(count:1).targetedToEntity(where:.has(ControllerBackgroundTarget.self)))
            .onEnded { result in
                let trace=VRRecenterTrace.begin(origin:1,generation:presentation.calibration.directionGeneration)
                let input:VRBackgroundInteraction.Event;let entity:Entity
                switch result {
                case .first(.first(let event)):
                    guard event.gestureValue else{trace.record(.resolved,outcome:1);return}
                    input = .longPress;entity=event.entity
                case .first(.second(let event)):input = .tap(count:2);entity=event.entity
                case .second(let event):input = .tap(count:1);entity=event.entity
                }
                let eventCode:Int
                switch input {case .longPress:eventCode=1;case .tap(let count):eventCode=count==2 ? 2:3}
                trace.record(.resolved,fields:[.cause:Double(eventCode)])
                let isBackground=entity.name.hasPrefix("show-controls-")
                let mask=backgroundGuardMask(isBackground:isBackground)
                if mask != 0 {trace.record(.gates,outcome:1,fields:[.detail:Double(mask),.parentRequest:Double(draggingControls ? moveTrace?.id ?? 0:0)])}
                defer {
                    trace.record(.backgroundActionReturned,fields:[.cause:Double(eventCode)])
                }
                switch VRBackgroundInteraction.action(event:input,isBackground:isBackground,active:presentation.active,
                    testPattern:presentation.testPattern,moving:presentation.movingControls,scrubbing:presentation.scrubbing) {
                case .none:break
                case .toggle:cancelControllerResetSample();presentation.toggleControlsFromBackground()
                case .reset:resetControllerPosition()
                case .recenterVideo:requestVideoRecenter(trace:trace)
                }

            })
        .simultaneousGesture(DragGesture(minimumDistance: 3).targetedToEntity(moveHandle)
            .updating($moveGestureActive){_,active,_ in active=true}
            .onChanged { value in
                if moveCancellationTask != nil {finishMoveGesture(normalRelease:false,reason:2)}
                guard presentation.controlsVisible,!presentation.scrubbing,let parent=controlEntity?.parent else{return}
                guard let controls=controlEntity else{return}
                let pointer=value.convert(value.location3D,from:.local,to:parent)
                if !draggingControls {
                    cancelControllerResetSample()
                    controlVisual.movePoseScope=controllerPoseScope(controls)
                    controlVisual.uprightAudit=VRControllerUprightAudit()
                    controlVisual.poseAudit.supersedeMotion()
                    draggingControls=true;moveGestureSerial &+= 1
                    moveTrace=VRRecenterTrace.begin(origin:3,generation:presentation.calibration.directionGeneration)
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
                finishMoveGesture(normalRelease:true,reason:0)
            })
    }
    // Bound SwiftUI type inference without changing the view or modifier order.
    /// Keep each original layout footprint; only the live label owns a 32pt target.
    private func compactPlaybackButton<Label:View>(borderlessFootprint:Bool=true,action:@escaping ()->Void,@ViewBuilder label:()->Label)->some View {
        let content=label()
        return Group {
            if borderlessFootprint {Button {} label:{content}.buttonStyle(.borderless)}
            else {Button {} label:{content}.buttonStyle(.automatic)}
        }
        .hidden().accessibilityHidden(true).allowsHitTesting(false)
        .overlay {
            Button(action:action) {
                content.frame(width:VRControllerHit.buttonDiameter,height:VRControllerHit.buttonDiameter)
                    .contentShape(.interaction,Circle()).contentShape(.hoverEffect,Circle())
            }.buttonStyle(.plain).hoverEffect(.highlight)
        }
    }
    private var previousVideoButton:some View {
        compactPlaybackButton(action:{presentation.onPrevious?();presentation.holdControls()}) {Image(systemName:"backward.end.fill")}
            .accessibilityLabel(VistaL10n.text("上一個影片")).accessibilityIdentifier("immersivePrevious")
            .disabled(!presentation.canGoBack || presentation.advancing)
    }
    private var observedContent:some View {
        interactiveContent
        .onChange(of:moveGestureActive){_,active in if !active {scheduleMoveCancellation()}}
        .onChange(of:presentation.controlsVisible){_,visible in if !visible {finishMoveGesture(normalRelease:false,reason:3)}}
        .onChange(of:presentation.scrubbing){_,scrubbing in if scrubbing {finishMoveGesture(normalRelease:false,reason:4)}}
        .onChange(of: presentation.player?.isPaused) { _, paused in
            presentation.revealControls()
            if #available(visionOS 26.0,*) {
                systemRenderer.observePresentationBoundary(reason:paused == true ? 7:8)
            }
        }
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
        .onChange(of: presentation.settings) { _, _ in cancelControllerResetSample() }
        .onChange(of: presentation.calibrationRequest) { _, _ in cancelControllerResetSample() }
        .onChange(of: presentation.player.map(ObjectIdentifier.init)) { _, _ in cancelControllerResetSample();synchronizeScrubOwner() }
        .onChange(of: presentation.advancing) { _, value in if value {cancelControllerResetSample()} }
        .onChange(of: presentation.scrubbing) { _, value in if value {cancelControllerResetSample()} }
        .onChange(of: presentation.settingsVisible) { _, _ in presentation.revealControls() }
        .onAppear { presentation.revealControls() }
    }
    private var scrubObservedContent:some View {
        observedContent
        #if VISTA_LOCAL_MKV_CANDIDATE
        .onChange(of:presentation.player?.mkvFatalMessage) {_,message in
            if message != nil {presentation.endControllerNavigation(showError:true);presentation.holdControls()}
        }
        .alert(VistaL10n.text("MKV 無法播放"),isPresented:Binding(
            get:{presentation.player?.mkvFatalMessage != nil},
            set:{if !$0 {presentation.player?.dismissMKVFailure()}})) {
            Button(VistaL10n.text("知道了"),role:.cancel) {presentation.player?.dismissMKVFailure()}
        } message: {
            Text(presentation.player?.mkvFatalMessage ?? "")
        }
        #endif
        .onChange(of: presentation.player?.playbackGeneration) { _, _ in synchronizeScrubOwner() }
        .onDisappear {cancelScrubInteraction()}
    }
    private var immersiveBody:some View {
        scrubObservedContent
        .task {
            while !Task.isCancelled {
                if let player=presentation.player,player.isPlaying || player.isPreparing || presentation.scrubbing || presentation.stopping {
                    systemRenderer.observeFlowStall();renderer.observeFlowStall()
                    let projection=VRProjection.allCases.firstIndex(of:presentation.settings.projection) ?? 0
                    let layout=VRLayout.allCases.firstIndex(of:presentation.settings.layout) ?? 0
                    let route=presentation.settings.projection == .equidistantFisheye180 ? 1:0
                    let values=renderer.logValues
                    player.persistDiagnostics(projection:projection,layout:layout,route:route,rendererValues:values)
                }
                do {try await Task.sleep(for:.seconds(1))}catch{return}
            }
        }
        .task(id: UpdateKey(image: presentation.image.map(ObjectIdentifier.init), settings: presentation.videoSettings,pixel:presentation.player?.pixelFrame.map(ObjectIdentifier.init))) {
            let flow=PlaybackFlowTrace.begin(.uiTask,parent:presentation.player?.pixelFrame?.flow ?? PlaybackFlowToken.none)
            defer{PlaybackFlowTrace.end(flow,.uiTask,a:Task.isCancelled ? 1:0)}
            playbackBoundaries.observeFrame(presentation.player)
            #if VISTA_VLC_CANDIDATE
            if let player=presentation.player {
                let ownerGeneration=player.playbackGeneration
                player.vlcPresentationDrain = { [weak player] preserve in
                    guard let player,presentation.player === player,
                          player.playbackGeneration==ownerGeneration else{throw CancellationError()}
                    let blockedInput=player.pixelFrame
                    await systemRenderer.stopAndDrain(preservingPresentedImage:preserve,blockedInput:blockedInput)
                    guard presentation.player === player,player.playbackGeneration==ownerGeneration else{throw CancellationError()}
                    await renderer.stopAndDrain(preservingPresentedImage:preserve,blockedInput:blockedInput)
                    guard presentation.player === player,player.playbackGeneration==ownerGeneration else{throw CancellationError()}
                }
            }
            #endif
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
            renderer.setSceneActive(scenePhase == .active)
            #if VISTA_SYSTEM_VIDEO_EXPERIMENT
            if !presentation.testPattern,let frame=presentation.player?.pixelFrame {
                if #available(visionOS 26.0,*),SystemVideoSamples.supports(frame,settings:presentation.videoSettings) {
                    playbackBoundaries.record(.stopEntered,player:presentation.player,fields:[.operation:2])
                    renderer.stop()
                    playbackBoundaries.record(.stopReturned,player:presentation.player,fields:[.operation:2])
                    playbackBoundaries.record(.submitEntered,player:presentation.player,fields:[.operation:1])
                    PlaybackFlowTrace.mark(.route,parent:frame.flow,a:1);systemRenderer.submit(frame,settings:presentation.videoSettings)
                    playbackBoundaries.record(.submitReturned,player:presentation.player,fields:[.operation:1])
                } else {
                    playbackBoundaries.record(.submitEntered,player:presentation.player,fields:[.operation:2])
                    systemRenderer.stop()
                    PlaybackFlowTrace.mark(.route,parent:frame.flow,a:2);renderer.submit(frame:frame,settings:presentation.videoSettings,metrics:presentation.player?.metrics)
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
                    if controllerEntryPose == nil {controllerEntryPose=VRInitialPose(matrix:controlsAnchor.transformMatrix(relativeTo:nil))}
                    updateControllerReference()
                    placeControls(controlEntity)
                    return
                }
                do {try await Task.sleep(for:.milliseconds(16))} catch{return}
            }
        }
        .task(id: presentation.calibrationRequest) {
            controlVisual.poseDetailTask?.cancel()
            cancelControllerResetSample()
            let request=presentation.calibrationRequest,owner=presentation.player
            let ownerGeneration=owner?.playbackGeneration
            let controllerRevision=presentation.calibration.controllerRevision
            if let result=await presentation.calibration.captureResult(using:DeviceInitialPose()) {
                guard !Task.isCancelled,presentation.calibrationRequest==request,
                      presentation.player === owner,owner?.playbackGeneration==ownerGeneration,
                      presentation.calibration.isCurrent(result) else {
                    result.trace.record(.offsetsCleared,outcome:1)
                    return
                }
                resetManualDirection()
                if presentation.calibration.controllerRevision != controllerRevision {updateControllerReference()}
                result.trace.record(.offsetsCleared)
            }
        }
        .onChange(of: scenePhase) { old, phase in
            LifecycleDiagnostics.shared.record(.scenePhase,[.scope:2,.previousPhase:old.diagnosticValue,.phase:phase.diagnosticValue])
            playbackBoundaries.begin(3)
            let sceneContext=playbackBoundaries.trace.context(),sceneGeneration=playbackBoundaries.generation
            playbackBoundaries.record(.sceneEntered,player:presentation.player,fields:[.previousPhase:old.diagnosticValue,.outcome:phase.diagnosticValue,.active:phase == .active ? 1:0])
            defer {playbackBoundaries.record(.sceneReturned,player:presentation.player,fields:[.outcome:phase.diagnosticValue,.active:phase == .active ? 1:0],context:sceneContext,capturedGeneration:sceneGeneration)}
            systemRenderer.setSceneActive(phase == .active)
            renderer.setSceneActive(phase == .active)
            presentation.player?.setPlaybackSceneActive(phase == .active)
            if phase != .active {
                controlVisual.poseDetailTask?.cancel()
                cancelControllerResetSample();finishMoveGesture(normalRelease:false,reason:5)
            }
            // Inactive alone never pauses or stops playback.
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
                    let flow=PlaybackFlowTrace.begin(.uiTask,parent:presentation.player?.pixelFrame?.flow ?? PlaybackFlowToken.none)
                    defer{PlaybackFlowTrace.end(flow,.uiTask,a:Task.isCancelled ? 1:0)}
                    playbackBoundaries.observeFrame(presentation.player)
                    playbackBoundaries.record(.submitEntered,player:presentation.player,fields:[.operation:1])
                    PlaybackFlowTrace.mark(.route,parent:frame.flow,a:1);systemRenderer.submit(frame,settings:presentation.videoSettings)
                    playbackBoundaries.record(.submitReturned,player:presentation.player,fields:[.operation:1])
                }
                #endif
            }
        }
        .onAppear{
            presentation.player?.setPlaybackSceneActive(scenePhase == .active)
            playbackBoundaries.begin(1)
            playbackBoundaries.record(.sceneEntered,player:presentation.player,fields:[.outcome:scenePhase.diagnosticValue,.active:scenePhase == .active ? 1:0])
            LifecycleDiagnostics.shared.record(.viewAppear,[.scope:2,.phase:scenePhase.diagnosticValue])
            playbackBoundaries.record(.sceneReturned,player:presentation.player,fields:[.outcome:scenePhase.diagnosticValue,.active:scenePhase == .active ? 1:0])
        }
        .onDisappear {
            controlVisual.poseDetailTask?.cancel();controlVisual.poseDetailTask=nil
            ControllerSynchronizedProbe.shared.stop()
            playbackBoundaries.begin(5)
            playbackBoundaries.record(.stopEntered,player:presentation.player)
            defer {playbackBoundaries.record(.stopReturned,player:presentation.player)}
            LifecycleDiagnostics.shared.record(.viewDisappear,[.scope:2])
            cancelControllerResetSample();finishMoveGesture(normalRelease:false,reason:6)
            presentation.calibration.cancel()
            controlVisual.fadeTask?.cancel();controlVisual.fadeTask=nil
            controlVisual.facingTask?.cancel();controlVisual.facingTask=nil
            controlVisual.poseTask?.cancel();controlVisual.poseTask=nil
            controlVisual.dragPointer=nil;draggingControls=false
            presentation.player?.setPlaybackSceneActive(false)
            renderer.stop();systemRenderer.stop(); presentation.finishSession()
        }
    }
    private var submittedAccessibilityValue:String {
        #if VISTA_SYSTEM_VIDEO_EXPERIMENT
        return (renderer.ready || systemRenderer.ready) ? VistaL10n.text("影格已提交"):VistaL10n.text("準備影像")
        #else
        return renderer.ready ? VistaL10n.text("影像已呈現"):VistaL10n.text("準備影像")
        #endif
    }
    private var candidateRouteText:String {
        #if VISTA_NATIVE_PLAYER_EXPERIMENT
        let label=VistaL10n.text("AVPlayer")
        #else
        let label=VistaL10n.text("系統呈現")
        #endif
        if let error=systemRenderer.error {return label+"："+error}
        if presentation.settings.projection == .equidistantFisheye180,renderer.ready { return label+VistaL10n.text("：魚眼投影，")+renderer.route }
        if let frame=presentation.player?.pixelFrame {
            if #available(visionOS 26.0,*) {
                if let reason=SystemVideoSamples.fallbackReason(frame,settings:presentation.settings) {return label+VistaL10n.text("相容回退：")+reason+VistaL10n.text("（原雙貼圖）")}
            } else {return label+VistaL10n.text("相容回退：系統版本（原雙貼圖）")}
        }
        return systemRenderer.ready ? label+VistaL10n.text("：送入 renderer，尚非雙眼驗收"):label+VistaL10n.text("：準備中")
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
                compactPlaybackButton(borderlessFootprint:false,action:{
                    guard !presentation.stopping else { return }
                    presentation.stopping = true
                    presentation.onCancelNavigation?()
                    presentation.player?.stop()
                    Task {
                        await dismiss(); presentation.finishSession()
                    }
                }) { Image(systemName:"chevron.backward") }
                .accessibilityLabel(VistaL10n.text("停止並返回瀏覽")).accessibilityIdentifier("immersiveStop")
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
            Text(VistaL10n.text("A 雙貼圖基準")).font(.caption2).accessibilityIdentifier("baselineVideoPath")
            #endif
            #if VISTA_NATIVE_PLAYER_EXPERIMENT
            Text(VistaL10n.text("AVPlayer・解碼方式未知")).font(.caption2)
            #else
            if PlaybackDecodingPolicy.simulatorSoftwareTest {
                Text(VistaL10n.text("模擬器軟體解碼測試")).font(.caption2).foregroundStyle(.orange)
            }
            #endif
            #endif
            if let player = presentation.player {
                playbackProgress(player)
                HStack(spacing: 16) {
                    previousVideoButton
                    compactPlaybackButton(action:{ presentation.revealControls(); player.resetSpeed() }) { Text("1×").monospacedDigit() }
                        .accessibilityLabel(VistaL10n.text("恢復 1 倍速")).accessibilityIdentifier("immersiveBack")
                        .disabled(!player.canResetSpeed || presentation.advancing || presentation.requiresFormatConfirmation)
                    compactPlaybackButton(action:{
                        if player.isPlaying { player.togglePause() } else { presentation.onReplay?() }
                        presentation.revealControls()
                    }) { Image(systemName: player.isPlaying && !player.isPaused ? "pause.fill" : "play.fill") }
                        .accessibilityLabel(player.isPlaying && !player.isPaused ? VistaL10n.text("暫停") : VistaL10n.text("播放"))
                        .accessibilityIdentifier("immersivePause")
                        .disabled(player.isPreparing || presentation.advancing || presentation.requiresFormatConfirmation)
                    compactPlaybackButton(action:{ presentation.revealControls(); player.increaseSpeed() }) { Image(systemName:"forward.fill") }
                        .accessibilityLabel(VistaL10n.text("加速 0.5 倍")).accessibilityIdentifier("immersiveForward")
                        .accessibilityHint(VistaL10n.text("最高 %@ 倍速，依影片支援能力開放" , String(describing: PlaybackSpeedStatus.upperLimit)))
                        .disabled(!player.canIncreaseSpeed || presentation.advancing || presentation.requiresFormatConfirmation)
                        .overlay(alignment:.bottom) {
                            speedStatusBelowButton.alignmentGuide(.bottom) {$0[.top]-4}
                        }
                    compactPlaybackButton(action:{ presentation.onNext?(); presentation.holdControls() }) { Image(systemName: "forward.end.fill") }
                        .accessibilityLabel(VistaL10n.text("下一個影片")).accessibilityIdentifier("immersiveNext")
                        .disabled(!presentation.canAdvance || presentation.advancing)
                    compactPlaybackButton(action:{ presentation.settingsVisible.toggle(); presentation.revealControls() }) { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel(VistaL10n.text("影片格式設定")).accessibilityIdentifier("immersiveSettings")
                }.buttonStyle(.borderless).font(.title3).disabled(presentation.stopping || presentation.scrubbing)
                    .padding(.bottom,speedStatusLineHeight+4)
                #if DEBUG && VISTA_DIAGNOSTIC_UI
                Button(VistaL10n.text("效能診斷")) {presentation.diagnosticsVisible.toggle();presentation.holdControls();if !presentation.diagnosticsVisible {presentation.scheduleHide()}}
                    .accessibilityIdentifier("playbackDiagnostics")
                if presentation.diagnosticsVisible {
                    Text("Vista \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "?"))\n" + player.diagnosticsText + "\n" + player.preparationText)
                        .font(.caption.monospacedDigit()).textSelection(.enabled)
                        .accessibilityIdentifier("playbackDiagnosticsResult")
                    Text(VistaL10n.text("各階段可能重疊；貼圖完成不代表螢幕已顯示。跳轉或重播會重新量測。"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                #endif
            }
            if presentation.settingsVisible || presentation.requiresFormatConfirmation {
                Divider()
                VRSettingsView(presentation: presentation) { presentation.onFormatChanged?(); presentation.holdControls() }
                if presentation.requiresFormatConfirmation {
                    Button(VistaL10n.text("使用目前格式並播放")) { presentation.onFormatChanged?(); presentation.onReplay?() }
                        .accessibilityIdentifier("immersiveConfirmFormat")
                }
                angleRuler(vertical:false).padding(.leading,56)
                HStack(spacing:8) {
                    angleRuler(vertical:true)
                    ZStack {
                    ringControl(VistaL10n.text("重設影片方向"), angle: -90, outer: true, identifier: "recenterVideo", hint: VistaL10n.text("以目前觀看方向重新置中影片，成功後清除自動補償與手動轉向；也可長按影片背景"), action:resetVideoDirection).disabled(!canAdjustManualDirection)
                    ringControl(VistaL10n.text("重設\n影片格式"), angle: -165, outer: true, identifier: "clearVRFormat", hint: VistaL10n.text("清除此片保存格式，不重設方向或控制器位置")) {
                        presentation.onClearFormat?(); presentation.holdControls()
                    }.disabled(!presentation.canClearFormat || presentation.advancing)
                        .opacity(!presentation.canClearFormat || presentation.advancing ? 0.35:1)
                        .hoverEffectDisabled(!presentation.canClearFormat || presentation.advancing)
                    ringControl(VistaL10n.text("重設\n控制器\n位置"), angle: -15, outer: true, identifier: "resetControllerPosition", hint: VistaL10n.text("也可雙擊影片背景"), action: resetControllerPosition)
                    ringControl("arrowtriangle.up.fill", angle: -90, outer: false, identifier: "directionUp", hint: VistaL10n.text("向上轉，每次15度")) { adjustManualDirection(pitch: 15) }.disabled(!canAdjustManualDirection)
                    ringControl("arrowtriangle.left.fill", angle: -180, outer: false, identifier: "directionLeft", hint: VistaL10n.text("向左轉，每次15度")) { adjustManualDirection(yaw: -15) }.disabled(!canAdjustManualDirection)
                    ringControl("arrowtriangle.right.fill", angle: 0, outer: false, identifier: "directionRight", hint: VistaL10n.text("向右轉，每次15度")) { adjustManualDirection(yaw: 15) }.disabled(!canAdjustManualDirection)
                    ringControl("arrowtriangle.down.fill", angle: 90, outer: false, identifier: "directionDown", hint: VistaL10n.text("向下轉，每次15度")) { adjustManualDirection(pitch: -15) }.disabled(!canAdjustManualDirection)
                    Button(action:resetDirectionFromControls) {
                        Text(VistaL10n.text("歸零")).font(.caption).frame(width:54,height:54)
                    }.buttonStyle(CenterRingFeedbackStyle()).disabled(!canAdjustManualDirection)
                        .accessibilityLabel(VistaL10n.text("方向歸零")).accessibilityIdentifier("directionZero")
                        .accessibilityValue("yaw=\(VRManualAngleDisplay.normalized(presentation.videoSettings.yawDegrees)),pitch=\(VRManualAngleDisplay.normalized(presentation.videoSettings.pitchDegrees)),roll=\(VRManualAngleDisplay.normalized(presentation.videoSettings.rollDegrees))")
                        .accessibilityHint(VistaL10n.text("清除自動補償與手動轉向，不重新採樣觀看方向")).position(x:190,y:180)
                    }.frame(width:380,height:286)
                }
                Text(VistaL10n.text("角度含自動補償與手動調整，每格 15°"))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Text(VistaL10n.text("看向影片背景：單擊顯示／隱藏控制器；雙擊重設控制器位置；長按重設影片方向。"))
                    .fixedSize(horizontal:false,vertical:true)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("resetControllerGestureHint")
                if let info=displayedVideoInfo {
                    HStack(spacing:6) {
                        Text(VistaL10n.text("%@ · %@ × %@ · %@" , String(describing: info.codec), String(describing: info.width), String(describing: info.height), String(describing: info.averageBitrateText)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
                            .accessibilityIdentifier("controllerVideoInfo")
                            .accessibilityHint(VistaL10n.text("位元率是視訊軌平均估計值，不含音訊與容器，不是即時位元率；破折號表示未知"))
                        // Keep the info text stable across brief waits; absent when collapsed.
                        ZStack {
                            if displayedBuffering {
                                ProgressView().controlSize(.mini)
                                    .accessibilityLabel(VistaL10n.text("等待播放"))
                                    .accessibilityIdentifier("controllerVideoInfoBuffering")
                            }
                        }.frame(width:14,height:14)
                    }
                    if !info.hasAudio {Text(VistaL10n.text("影片無音軌")).font(.caption).foregroundStyle(.secondary)}
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
            .accessibilityHint(VistaL10n.text("每次調整15度"))
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
        let enabled=duration != nil && (!player.isPreparing || player.canRetargetPendingSeek) && !presentation.advancing && !presentation.stopping && !presentation.requiresFormatConfirmation
        HStack(spacing:10) {
            Text(PlaybackProgress.time(presentation.scrubbing ? scrubPosition:player.progressPosition))
                .accessibilityIdentifier("playbackElapsed")
            CompactPlaybackProgress(value:Binding(get:{presentation.scrubbing ? scrubPosition:PlaybackProgress.clamp(player.progressPosition,duration:duration)},set:{value in
                guard presentation.player === player,player.playbackGeneration==scrubOwner else{return}
                scrubInteraction.update(value,owner:scrubOwner,initialPosition:PlaybackProgress.clamp(player.progressPosition,duration:duration))
                if !presentation.scrubbing {
                    presentation.scrubbing=true;presentation.holdControls()
                }
                scrubPosition=value
            }),in:0...(duration ?? 1),onEditingChanged:{ editing,request in
                guard presentation.player === player,player.playbackGeneration==scrubOwner else{
                    VRProgressInputSession.gate(request:request,mask:(presentation.player === player ? 0:1) | (player.playbackGeneration==scrubOwner ? 0:2),editing:editing);return
                }
                if editing {
                    scrubInteraction.begin(owner:scrubOwner,position:PlaybackProgress.clamp(player.progressPosition,duration:duration))
                    if !presentation.scrubbing {scrubPosition=PlaybackProgress.clamp(player.progressPosition,duration:duration)}
                    presentation.scrubbing=true;presentation.holdControls()
                }
                else {
                    let target=scrubInteraction.finish(owner:scrubOwner);presentation.scrubbing=false
                    let gate=(target == nil ? 4:0) | (enabled ? 0:8) | (presentation.active ? 0:16) | (presentation.stopping ? 32:0) | (presentation.player === player ? 0:1)
                    VRProgressInputSession.gate(request:request,mask:gate,editing:false)
                    if let target,enabled,presentation.active,!presentation.stopping,presentation.player === player {player.seek(to:target)}
                    presentation.revealControls()
                }
            },onCancelled:{
                if scrubInteraction.owner==scrubOwner {cancelScrubInteraction()}
            },diagnosticContext:{
                (presentation.player === player && player.playbackGeneration==scrubOwner ? 2:0)
                | (presentation.active ? 4:0) | (presentation.controlsVisible ? 8:0) | (presentation.movingControls ? 16:0)
                | (presentation.stopping ? 32:0) | (player.isPreparing ? 64:0) | (duration != nil ? 128:0)
                | (controlEntity?.isEnabledInHierarchy == true ? 256:0)
                | (presentation.player === player ? 512:0) | (player.playbackGeneration==scrubOwner ? 1024:0)
            }).disabled(!enabled)
                .id(scrubOwner)
                .onDisappear {if scrubInteraction.owner==scrubOwner {cancelScrubInteraction()}}
                .accessibilityLabel(VistaL10n.text("播放進度"))
                .accessibilityIdentifier("playbackSeek")
                .accessibilityHint(VistaL10n.text("拖曳後放開以跳轉。"))
            Text(progressDurationText(player)).accessibilityIdentifier("playbackDuration")
        }.font(.caption.monospacedDigit())
    }
    private func recordProgressVisibility(_ controls:Entity?,reason:Int) {
        let mask=(presentation.controlsVisible ? 1:0) | (presentation.movingControls ? 2:0) | (presentation.scrubbing ? 4:0)
            | (presentation.stopping ? 8:0) | (presentation.active ? 16:0) | (scenePhase == .active ? 32:0)
            | (presentation.settingsVisible ? 64:0) | (controls != nil ? 128:0)
            | (controls?.isEnabled == true ? 256:0) | (controls?.isEnabledInHierarchy == true ? 512:0)
        controlVisual.progressVisibility.record(mask:mask,reason:reason)
    }
    private func updateFade(_ controls:Entity,visible:Bool) {
        guard controlVisual.fadeTarget != visible else{return}
        controlVisual.fadeTarget=visible;controlVisual.fadeTask?.cancel()
        let start=controls.components[OpacityComponent.self]?.opacity ?? (visible ? 0:1)
        controls.isEnabled=true
        controls.components.set(OpacityComponent(opacity:start))
        if reduceMotion {controls.components.set(OpacityComponent(opacity:visible ? 1:0));controls.isEnabled=visible;recordProgressVisibility(controls,reason:2);return}
        controlVisual.fadeTask=Task { @MainActor in
            for step in 1...12 {
                do {try await Task.sleep(for:.milliseconds(16))} catch{return}
                guard !Task.isCancelled else{return}
                let t=Float(step)/12;let eased=t*t*(3-2*t)
                controls.components.set(OpacityComponent(opacity:start+((visible ? 1:0)-start)*eased))
            }
            controls.isEnabled=visible;recordProgressVisibility(controls,reason:2)
        }
    }
    private func resetVideoDirection() {requestVideoRecenter(trace:nil)}
    private func requestVideoRecenter(trace:VRRecenterTrace?) {
        let trace=trace ?? VRRecenterTrace.begin(origin:2,generation:presentation.calibration.directionGeneration)
        let mask=(presentation.movingControls ? 1:0) | (presentation.scrubbing ? 2:0) | (presentation.advancing ? 4:0) | (!canAdjustManualDirection ? 8:0)
        if mask != 0 {trace.record(.gates,outcome:2,fields:[.detail:Double(mask),.cause:4,.available:calibrationStatusCode])}
        guard !presentation.movingControls,!presentation.scrubbing,canAdjustManualDirection else{return}
        cancelControllerResetSample()
        presentation.calibration.requestRecenter(trace:trace);presentation.calibrationRequest += 1
    }
    private var calibrationStatusCode:Double {
        switch presentation.calibration.status {case .idle:0;case .capturing:1;case .ready:2;case .unavailable:3}
    }
    private func backgroundGuardMask(isBackground:Bool)->Int {
        (isBackground ? 0:1) | (presentation.active ? 0:2) | (presentation.testPattern ? 4:0) | (presentation.movingControls ? 8:0) | (presentation.scrubbing ? 16:0)
    }
    private func invalidateMoveCancellation() {
        moveGestureSerial &+= 1
        moveCancellationTask?.cancel();moveCancellationTask=nil
    }
    private func scheduleMoveCancellation() {
        guard draggingControls else{return}
        invalidateMoveCancellation();let serial=moveGestureSerial
        moveCancellationTask=Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,serial==moveGestureSerial,!moveGestureActive else{return}
            finishMoveGesture(normalRelease:false,reason:1)
        }
    }
    private func finishMoveGesture(normalRelease:Bool,reason:Int) {
        invalidateMoveCancellation()
        guard draggingControls else{return}
        let auditScope=controlVisual.movePoseScope;controlVisual.movePoseScope=nil
        draggingControls=false;presentation.movingControls=false
        controlVisual.poseTask?.cancel();controlVisual.poseTask=nil
        controlVisual.facingTask?.cancel();controlVisual.facingTask=nil
        controlVisual.dragPointer=nil
        if let controls=controlEntity,controllerPoseScope(controls)==auditScope,let parent=controls.parent {
            controlVisual.worldFrame=VRControllerWorldFrame.frame(parentWorld:parent.orientation(relativeTo:nil))
            controlVisual.orientation=VRControllerWorldFrame.upright(controls.orientation,frame:controlVisual.worldFrame,forwardTiltDegrees:presentation.calibration.initialControllerTiltDegrees)
            controlVisual.orientation=controllerLeveled(controlVisual.orientation,position:controls.position)
            controls.orientation=controlVisual.orientation
        }
        moveTrace?.record(.moveCleanup,outcome:normalRelease ? 0:1,fields:[.detail:Double(reason)])
        moveTrace=nil
        if !normalRelease,let controls=controlEntity,controllerPoseScope(controls)==auditScope {
            let request=controlVisual.poseAudit.reset(controllerPoseScope(controls))
            recordControllerPose(cause:8,request:request,controls:controls,cancelReason:reason)
        }
        guard normalRelease,let controls=controlEntity,controllerPoseScope(controls)==auditScope else{return}
        faceViewerAfterDrag();presentation.scheduleHide()
    }
    private func cancelControllerResetSample() {
        if let ticket=controlVisual.resetTicket {
            recordControllerReset(.cancelled,ticket:ticket,controls:controlEntity)
            controlVisual.resetTicket=nil
        }
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
        let ticket=controlVisual.resetRequest.begin()
        controlVisual.resetTicket=ticket;controlVisual.resetStarted=ProcessInfo.processInfo.systemUptime
        recordControllerReset(.before,ticket:ticket,controls:controlEntity)
        guard presentation.active,!presentation.stopping,!presentation.advancing,scenePhase == .active,
              controlEntity != nil,presentation.calibration.status != .capturing else {
            recordControllerReset(.unavailable,ticket:ticket,controls:controlEntity)
            controlVisual.resetTicket=nil;controlVisual.resetRequest.cancel();return
        }
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
            controlVisual.resetPoseTask=nil;controlVisual.resetTicket=nil
            guard let pose,VRControllerReference.placement(entry:pose,vertical:pose,horizontal:pose.orientation) != nil,
                  presentation.calibration.acceptControllerReset(pose,at:ProcessInfo.processInfo.systemUptime) else {
                recordControllerReset(.unavailable,ticket:ticket,controls:controlEntity,sample:pose);return
            }
            applyControllerReset(pose:pose)
            recordControllerReset(.applied,ticket:ticket,controls:controlEntity,sample:pose)
        }
    }
    private func applyControllerReset(pose:VRInitialPose) {
        controlVisual.facingTask?.cancel()
        // Rebase the default location as well as attitude from the same fresh head sample.
        controllerEntryPose=pose
        presentation.controlsOffset = .zero
        updateControllerReference(forceReset:true)
        controlVisual.poseCacheSource=3
        if presentation.navigationVisibility != nil {presentation.navigationVisibility=true}
        presentation.controlsVisible=true
        presentation.scheduleHide()
        // The sampled orientation is not observable; commit it even when reset position is already zero.
        placeControls(controlEntity)
        if let controls=controlEntity {
            let request=controlVisual.poseAudit.reset(controllerPoseScope(controls))
            recordControllerPose(cause:7,request:request,controls:controls)
        }
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
    private func updateControllerReference(forceReset:Bool=false) {
        guard let entry=controllerEntryPose else{return}
        let controllerPose=presentation.calibration.controllerPose
        // Video recenter and angle edits never replace this independent controller basis.
        let heading=controllerPose?.orientation ?? simd_quatf(angle:0,axis:[0,1,0])
        guard let basis=VRControllerReference.placement(entry:entry,vertical:controllerPose,horizontal:heading) else{return}
        let pose=basis.reference
        // A release animation must never apply its old target after a reference change.
        controlVisual.referenceRevision &+= 1
        if !draggingControls {controlVisual.facingTask?.cancel()}
        controlVisual.defaultPlacement=basis
        let oldReference=controllerReference.transformMatrix(relativeTo:nil)
        let oldLocal=Transform(scale:.one,rotation:controlVisual.orientation,translation:VRControllerPlacement.origin+presentation.controlsOffset).matrix
        controllerReference.position=pose.position;controllerReference.orientation=pose.orientation
        if let pointer=controlVisual.dragPointer {
            let world=oldReference * SIMD4(pointer,1)
            let local=simd_inverse(controllerReference.transformMatrix(relativeTo:nil)) * world
            controlVisual.dragPointer=SIMD3(local.x,local.y,local.z)
        }
        if !forceReset && (presentation.preservePlacementAcrossFiles || presentation.controlsOffset != .zero) {
            let local=Transform(matrix:VRControllerContinuity.rebased(local:oldLocal,oldReference:oldReference,newReference:controllerReference.transformMatrix(relativeTo:nil)))
            presentation.controlsOffset=local.translation-VRControllerPlacement.origin
            controlVisual.orientation=local.rotation
        }
        let viewer=controllerReference.convert(position:(controllerPose ?? entry).position,from:nil)
        controlVisual.viewer=viewer
        controlVisual.worldFrame=VRControllerWorldFrame.frame(parentWorld:controllerReference.orientation(relativeTo:nil))
        controlVisual.cachedHead=(controllerPose ?? entry).orientation
        controlVisual.poseCacheSource=controllerPose == nil ? 0:1
        controlVisual.poseCacheWritten=ProcessInfo.processInfo.systemUptime
        if !draggingControls && (forceReset || !presentation.preservePlacementAcrossFiles) {controlVisual.orientation=VRControllerWorldFrame.facing(position:VRControllerPlacement.origin+presentation.controlsOffset,viewer:viewer,frame:controlVisual.worldFrame,previous:controlVisual.orientation,forwardTiltDegrees:presentation.calibration.initialControllerTiltDegrees,yawOffsetDegrees:controllerSideYaw(position:VRControllerPlacement.origin+presentation.controlsOffset))}
    }
    private func placeControls(_ controls: Entity?) {
        guard let controls else { return }
        if controlEntity !== controls {controlVisual.entity=controls}
        // Controller range is centered on the video front, independently of restored vertical placement.
        // The right-front default is only a position within this coordinate frame, never its yaw origin.
        let parent: Entity = controllerReference
        if controls.parent != parent { parent.addChild(controls) }
        controls.position = presentation.testPattern ? [0, -0.25, -1.5] : VRControllerPlacement.origin + presentation.controlsOffset
        if !presentation.testPattern {
            controlVisual.worldFrame=VRControllerWorldFrame.frame(parentWorld:parent.orientation(relativeTo:nil))
            controlVisual.orientation=VRControllerWorldFrame.upright(controlVisual.orientation,frame:controlVisual.worldFrame,forwardTiltDegrees:presentation.calibration.initialControllerTiltDegrees)
        }
        controls.orientation = presentation.testPattern ? simd_quatf() : controlVisual.orientation
        updateFade(controls,visible:presentation.testPattern || presentation.controlsVisible)
        recordProgressVisibility(controls,reason:1)
        if moveHandle.parent != controls {controls.addChild(moveHandle)}
        moveHandle.isEnabled=false
        let bounds=controls.visualBounds(relativeTo:controls,excludeInactive:true)
        moveHandle.position=[0,bounds.min.y-VRControllerHandle.gap,0]
        moveHandle.isEnabled = !presentation.testPattern
        if !presentation.testPattern {
            controlVisual.orientation=controllerLeveled(controlVisual.orientation,position:controls.position)
            controls.orientation=controlVisual.orientation
        }
        if presentation.controlsVisible {moveHandle.components.set(InputTargetComponent(allowedInputTypes:.indirect))}
        else {moveHandle.components.remove(InputTargetComponent.self)}
        if !presentation.testPattern,presentation.active,controls.scene != nil,
           let request=controlVisual.poseAudit.loaded(controllerPoseScope(controls),state:controllerPoseEntryState) {
            recordControllerPose(cause:1+controllerPoseEntryState,request:request,controls:controls)
        }
    }
    private func updateDraggedPosition(_ controls:Entity) {
        guard let pointer=controlVisual.dragPointer,let parent=controls.parent else{return}
        let parentWorld=parent.orientation(relativeTo:nil)
        controlVisual.worldFrame=VRControllerWorldFrame.frame(parentWorld:parentWorld)
        let before=parentWorld * controls.orientation
        controlVisual.orientation=VRControllerWorldFrame.upright(controlVisual.orientation,frame:controlVisual.worldFrame,forwardTiltDegrees:presentation.calibration.initialControllerTiltDegrees)
        controlVisual.orientation=controllerLeveled(controlVisual.orientation,position:pointer,barOffset:moveHandle.position-controlVisual.localGrab)
        controls.orientation=controlVisual.orientation
        controlVisual.uprightAudit.observe(before:before,after:parentWorld * controls.orientation)
        let position=VRControllerPlacement.grabbedPosition(pointer:pointer,localGrab:controlVisual.localGrab,orientation:controlVisual.orientation,previous:controls.position)
        presentation.controlsOffset=position-VRControllerPlacement.origin
        controls.position=position
    }
    private func faceViewerDuringDrag() {
        controlVisual.poseDetailTask?.cancel()
        controlVisual.facingTask?.cancel();controlVisual.poseTask?.cancel()
        guard let controls=controlEntity,let parent=controls.parent else{return}
        // Existing drag-only tracking supplies the viewer sample; the 175 plane normal stays fixed by its tilt rule.
        // Only in-plane roll follows the sampled viewing perspective, with no new tracking session.
        // Keep the last valid position on tracking loss, with the existing sampling lifecycle.
        let serial=moveGestureSerial,scope=controllerPoseScope(controls)
        controlVisual.poseTask=Task { @MainActor in
            guard serial==moveGestureSerial,presentation.calibration.status != .capturing else{return}
            try? await DeviceInitialPose().duringDrag { pose in
                guard !Task.isCancelled,serial==moveGestureSerial,presentation.movingControls,controls.parent === parent,controllerPoseScope(controls)==scope else{return}
                controlVisual.viewer=parent.convert(position:pose.position,from:nil)
                controlVisual.worldFrame=VRControllerWorldFrame.frame(parentWorld:parent.orientation(relativeTo:nil))
                controlVisual.cachedHead=pose.orientation;controlVisual.poseCacheSource=2
                controlVisual.poseCacheWritten=ProcessInfo.processInfo.systemUptime
            }
        }
        controlVisual.facingTask=Task { @MainActor in
            var last=ContinuousClock.now
            while !Task.isCancelled,serial==moveGestureSerial,presentation.movingControls,!presentation.stopping,controls.parent === parent,controllerPoseScope(controls)==scope {
                let now=ContinuousClock.now
                let duration=last.duration(to:now).components
                let elapsed=Float(duration.seconds)+Float(duration.attoseconds)/1e18
                last=now
                controlVisual.worldFrame=VRControllerWorldFrame.frame(parentWorld:parent.orientation(relativeTo:nil))
                let target=VRControllerWorldFrame.facing(position:controls.position,viewer:controlVisual.viewer,frame:controlVisual.worldFrame,previous:controlVisual.orientation,forwardTiltDegrees:presentation.calibration.initialControllerTiltDegrees,yawOffsetDegrees:controllerSideYaw(position:controls.position))
                controlVisual.orientation=VRControllerWorldFrame.approaching(controlVisual.orientation,target:target,frame:controlVisual.worldFrame,elapsed:elapsed,forwardTiltDegrees:presentation.calibration.initialControllerTiltDegrees)
                // updateDraggedPosition samples the old actual attitude before committing this projection.
                updateDraggedPosition(controls)
                do {try await Task.sleep(for:.milliseconds(16))} catch{return}
            }
        }
    }
    private func faceViewerAfterDrag() {
        controlVisual.facingTask?.cancel()
        guard let controls=controlEntity, let parent=controls.parent else{return}
        // Correct synchronously at release, even if the following animation is cancelled.
        controlVisual.worldFrame=VRControllerWorldFrame.frame(parentWorld:parent.orientation(relativeTo:nil))
        controlVisual.orientation=VRControllerWorldFrame.upright(controls.orientation,frame:controlVisual.worldFrame,forwardTiltDegrees:presentation.calibration.initialControllerTiltDegrees)
        controlVisual.orientation=controllerLeveled(controlVisual.orientation,position:controls.position)
        controls.orientation=controlVisual.orientation
        let position=controls.position, start=controls.orientation
        let referenceRevision=controlVisual.referenceRevision
        let auditScope=controllerPoseScope(controls)
        let auditRequest=controlVisual.poseAudit.beginMotion(auditScope)
        recordControllerPose(cause:4,request:auditRequest,controls:controls)
        controlVisual.facingTask=Task { @MainActor in
            var completed=false
            defer {
                // A newer drag, owner, parent or file cannot receive this old terminal.
                if controllerPoseScope(controls)==auditScope,
                   controlVisual.poseAudit.endMotion(auditScope,request:auditRequest) {
                    recordControllerPose(cause:completed ? 5:6,request:auditRequest,controls:controls)
                }
            }
            // Release uses the same last valid viewing sample, without a late resample.
            guard !Task.isCancelled,!presentation.stopping,controls.parent === parent,
                  controllerPoseScope(controls)==auditScope,referenceRevision==controlVisual.referenceRevision else{return}
            let viewer=controlVisual.viewer
            let target=VRControllerWorldFrame.facing(position:position,viewer:viewer,frame:controlVisual.worldFrame,previous:start,forwardTiltDegrees:presentation.calibration.initialControllerTiltDegrees,yawOffsetDegrees:controllerSideYaw(position:position))
            for step in 1...(reduceMotion ? 1:12) {
                guard !Task.isCancelled,!presentation.stopping,controls.parent === parent,
                      controllerPoseScope(controls)==auditScope,referenceRevision==controlVisual.referenceRevision else{return}
                controlVisual.worldFrame=VRControllerWorldFrame.frame(parentWorld:parent.orientation(relativeTo:nil))
                let t=reduceMotion ? Float(1):Float(step)/12
                controlVisual.orientation=VRControllerWorldFrame.interpolating(start,target:target,frame:controlVisual.worldFrame,fraction:t*t*(3-2*t),forwardTiltDegrees:presentation.calibration.initialControllerTiltDegrees)
                controlVisual.orientation=controllerLeveled(controlVisual.orientation,position:controls.position)
                controls.orientation=controlVisual.orientation
                if !reduceMotion {do {try await Task.sleep(for:.milliseconds(16))} catch{return}}
            }
            guard !Task.isCancelled,!presentation.stopping,controllerPoseScope(controls)==auditScope,
                  referenceRevision==controlVisual.referenceRevision else{return}
            controlVisual.worldFrame=VRControllerWorldFrame.frame(parentWorld:parent.orientation(relativeTo:nil))
            controlVisual.orientation=VRControllerWorldFrame.upright(controls.orientation,frame:controlVisual.worldFrame,forwardTiltDegrees:presentation.calibration.initialControllerTiltDegrees)
            controlVisual.orientation=controllerLeveled(controlVisual.orientation,position:controls.position)
            controls.orientation=controlVisual.orientation
            completed=true
        }
    }
    private func controllerSideYaw(position:SIMD3<Float>)->Float {
        let worldOffset=controlVisual.worldFrame.inverse.act(position-controlVisual.viewer)
        let bias=VRControllerSideYaw.degrees(offsetWorld:worldOffset,
            referenceYawDegrees:presentation.calibration.initialControllerYawDegrees,
            enabled:presentation.calibration.initialControllerTiltDegrees>0 && !presentation.testPattern)
        controlVisual.sideYawRequested=bias
        controlVisual.sideYawBase=presentation.calibration.initialControllerYawDegrees
        controlVisual.sideYawRequestedAt=CACurrentMediaTime()
        return bias
    }
    private func controllerLeveled(_ rotation:simd_quatf,position:SIMD3<Float>,barOffset:SIMD3<Float>?=nil)->simd_quatf {
        guard presentation.calibration.initialControllerTiltDegrees>0,!presentation.testPattern else {
            controlVisual.levelStatus=1;controlVisual.levelRoll=0;return rotation
        }
        guard let head=controlVisual.cachedHead else {controlVisual.levelStatus=6;controlVisual.levelRoll=0;return rotation}
        let result=VRControllerViewLevel.solve(rotation:rotation,centerFromViewer:position-controlVisual.viewer,
            viewerRotation:controlVisual.worldFrame*head,barOffset:barOffset ?? moveHandle.position,enabled:true)
        controlVisual.levelStatus=result.status;controlVisual.levelRoll=result.rollDegrees
        return result.rotation
    }
    private func controllerPoseScope(_ controls:Entity)->VRControllerPoseAudit.Scope {
        .init(owner:presentation.player.map(ObjectIdentifier.init),generation:presentation.player?.playbackGeneration,
              panel:ObjectIdentifier(controls),parent:controls.parent.map(ObjectIdentifier.init))
    }
    private var controllerPoseEntryState:Int {
        presentation.calibration.controllerPose != nil && controllerEntryPose != nil ? 2:(controllerEntryPose != nil ? 1:0)
    }
    private func recordControllerPose(cause:Int,request:Int,controls:Entity,cancelReason:Int=0) {
        controlVisual.poseDetailTask?.cancel()
        if [2,3,5,7].contains(cause),controlVisual.syncAttempts<48 {
            let scope=controllerPoseScope(controls),epoch=controlVisual.poseAudit.epoch,revision=controlVisual.referenceRevision
            controlVisual.poseDetailTask=Task { @MainActor in
                do {try await Task.sleep(for:.milliseconds(200))} catch{return}
                guard !Task.isCancelled,presentation.active,scenePhase == .active,!presentation.movingControls,
                      controls.scene != nil,controllerPoseScope(controls)==scope,
                      controlVisual.referenceRevision==revision else{return}
                controlVisual.syncAttempts+=1
                let result=await ControllerSynchronizedProbe.shared.capture {anchor in controllerSynchronizedFrame(controls,anchor:anchor)}
                guard !Task.isCancelled,controls.scene != nil,controllerPoseScope(controls)==scope,
                      controlVisual.referenceRevision==revision else{return}
                recordControllerSynchronized(result,origin:cause,request:request,epoch:epoch,revision:revision)
            }
        }
        // Actual scene transforms only; no head-coordinate Euler inference or orientation mutation.
        let local=VRControllerPoseGeometry(controls.transform.matrix)
        var checkpoint:[PlaybackLogRecord]=[]
        for (role,entity) in [(1,Optional(controls)),(2,controls.parent),(3,Optional(moveHandle))] {
            let geometry=VRControllerPoseGeometry(entity?.scene == nil ? nil:entity?.transformMatrix(relativeTo:nil))
            var values:[PlaybackLogField:Double]=[
                .cpPoseRequest:Double(request),.cpPoseEpoch:Double(controlVisual.poseAudit.epoch),
                .cpPoseCause:Double(cause),.cpPoseCancelReason:Double(cancelReason),.cpPoseRole:Double(role),.cpPoseSpace:1,
                .cpPoseValidity:Double(geometry.validity),.cpPoseEntryState:Double(controllerPoseEntryState),
                .cpPoseParentExpected:(role==3 ? moveHandle.parent === controls:controls.parent === controllerReference) ? 1:0,
                .cpPoseHasScene:entity?.scene == nil ? 0:1,.cpPoseEnabled:entity?.isEnabledInHierarchy == true ? 1:0,
                .cpPoseVisible:presentation.controlsVisible ? 1:0,.cpPoseMoving:presentation.movingControls ? 1:0,
                .cpPoseSampleSource:Double(controlVisual.poseCacheSource)]
            func vector(_ v:SIMD3<Float>?,_ keys:[PlaybackLogField]) {
                guard let v,v.x.isFinite,v.y.isFinite,v.z.isFinite else{return};for i in 0..<3 {values[keys[i]]=Double(v[i])}
            }
            func quaternion(_ q:simd_quatf?,_ keys:[PlaybackLogField]) {
                guard let q else{return};for i in 0..<4 {values[keys[i]]=Double(q.vector[i])}
            }
            vector(geometry.position,[.cpPoseX,.cpPoseY,.cpPoseZ]);vector(geometry.scale,[.cpPoseScaleX,.cpPoseScaleY,.cpPoseScaleZ])
            vector(geometry.right,[.cpPoseRightX,.cpPoseRightY,.cpPoseRightZ]);vector(geometry.up,[.cpPoseUpX,.cpPoseUpY,.cpPoseUpZ])
            vector(geometry.forward,[.cpPoseForwardX,.cpPoseForwardY,.cpPoseForwardZ]);quaternion(geometry.quaternion,[.cpPoseQX,.cpPoseQY,.cpPoseQZ,.cpPoseQW])
            values[.cpPoseHorizontalDegrees]=geometry.horizontalDegrees;values[.cpPoseVerticalDegrees]=geometry.verticalDegrees
            if role==1 {
                values[.cpSYRequested]=Double(controlVisual.sideYawRequested);values[.cpSYBase]=Double(controlVisual.sideYawBase);values[.cpSYAt]=controlVisual.sideYawRequestedAt
                values[.cpSLRoll]=controlVisual.levelRoll;values[.cpSLStatus]=Double(controlVisual.levelStatus)
                values[.cpSTrialTilt]=Double(presentation.calibration.initialControllerTiltDegrees)
                values[.cpPoseDeferredFrom]=cause==9 ? Double(cancelReason):0
                let immersive=VRControllerPoseGeometry(controls.transformMatrix(relativeTo:.immersiveSpace))
                values[.cpPoseImmersiveKnown]=immersive.validity==63 ? 1:0
                vector(immersive.up,[.cpPoseImmersiveUpX,.cpPoseImmersiveUpY,.cpPoseImmersiveUpZ])
                vector(immersive.right,[.cpPoseImmersiveRightX,.cpPoseImmersiveRightY,.cpPoseImmersiveRightZ])
                var pending=Array(controls.children.prefix(33)),count=0,invalid=0,models=0,truncated=controls.children.count>33
                var maxVertical=0.0,maxHorizontal=0.0
                while !pending.isEmpty && count<32 {
                    let child=pending.removeLast();count+=1
                    let childPose=VRControllerPoseGeometry(child.transformMatrix(relativeTo:nil))
                    if let v=childPose.verticalDegrees,let h=childPose.horizontalDegrees {
                        maxVertical=max(maxVertical,abs(v));maxHorizontal=max(maxHorizontal,abs(h))
                    } else {invalid+=1}
                    if child.components[ModelComponent.self] != nil {models+=1}
                    let room=max(0,33-pending.count)
                    if child.children.count>room {truncated=true}
                    pending.append(contentsOf:child.children.prefix(room))
                }
                values[.cpPoseChildCount]=Double(count);values[.cpPoseChildInvalid]=Double(invalid)
                values[.cpPoseChildTruncated]=truncated || !pending.isEmpty ? 1:0
                values[.cpPoseChildMaxVertical]=maxVertical;values[.cpPoseChildMaxHorizontal]=maxHorizontal;values[.cpPoseModelCount]=Double(models)
                let bounds=controls.visualBounds(relativeTo:controls)
                let boundsKnown=[bounds.extents.x,bounds.extents.y,bounds.extents.z,bounds.center.x,bounds.center.y,bounds.center.z].allSatisfy({$0.isFinite}) && bounds.extents.x>=0 && bounds.extents.y>=0 && bounds.extents.z>=0
                values[.cpPoseBoundsKnown]=boundsKnown ? 1:0
                if boundsKnown {
                vector(bounds.extents,[.cpPoseBoundsX,.cpPoseBoundsY,.cpPoseBoundsZ])
                vector(bounds.center,[.cpPoseBoundsCenterX,.cpPoseBoundsCenterY,.cpPoseBoundsCenterZ])
                }
                if let head=controlVisual.cachedHead {quaternion(head,[.cpPoseHeadQX,.cpPoseHeadQY,.cpPoseHeadQZ,.cpPoseHeadQW])}
                if [4,5,6,8].contains(cause) {
                    values[.cpPoseDragSamples]=Double(controlVisual.uprightAudit.samples)
                    values[.cpPoseDragMaxBefore]=controlVisual.uprightAudit.maximumBefore
                    values[.cpPoseDragMaxAfter]=controlVisual.uprightAudit.maximumAfter
                    values[.cpPoseDragLastAfter]=controlVisual.uprightAudit.lastAfter
                }
                values[.cpPoseDistanceBasis]=controlVisual.defaultPlacement == nil ? 0:1
                values[.cpPoseDistanceScale]=Double(VRControllerPlacement.distanceScale)
                if let basis=controlVisual.defaultPlacement {
                    values[.cpPoseHeadForwardY]=Double(basis.headForwardY)
                    values[.cpPoseThresholdTriggered]=basis.thresholdTriggered ? 1:0
                    values[.cpPoseHeightOffset]=Double(basis.originalHeightOffset*VRControllerPlacement.distanceScale)
                    vector(basis.viewer,[.cpPoseViewerX,.cpPoseViewerY,.cpPoseViewerZ])
                    vector(basis.originalTarget,[.cpPoseOriginalX,.cpPoseOriginalY,.cpPoseOriginalZ])
                    vector(basis.target,[.cpPoseDefaultX,.cpPoseDefaultY,.cpPoseDefaultZ])
                }
                // Facing uses the latest cached sample, which may differ from defaultPlacement.viewer.
                // Source/age describe this cache; no eye-gaze or sensor-age claim is made.
                values[.cpPoseFacingKnown]=controlVisual.poseCacheSource>0 && controlVisual.cachedHead != nil ? 1:0
                let sampledWorld=controllerReference.transformMatrix(relativeTo:nil)*SIMD4(controlVisual.viewer,1)
                vector(SIMD3(sampledWorld.x,sampledWorld.y,sampledWorld.z),[.cpPoseFacingViewerX,.cpPoseFacingViewerY,.cpPoseFacingViewerZ])
                if let head=controlVisual.cachedHead {
                    vector(head.act(SIMD3<Float>(0,0,-1)),[.cpPoseFacingHeadForwardX,.cpPoseFacingHeadForwardY,.cpPoseFacingHeadForwardZ])
                }
                let checkpointStatus=ControllerCheckpointStore.shared.status
                values[.cpCheckpointRejected]=Double(checkpointStatus.rejected)
                values[.cpCheckpointWriteFailures]=Double(checkpointStatus.writeFailures)
                values[.cpCheckpointStatusFailures]=Double(checkpointStatus.statusWriteFailures)
                values[.cpCheckpointAccepting]=checkpointStatus.accepting ? 1:0
                values[.cpPoseLocalValidity]=Double(local.validity)
                vector(local.position,[.cpPoseLocalX,.cpPoseLocalY,.cpPoseLocalZ]);quaternion(local.quaternion,[.cpPoseLocalQX,.cpPoseLocalQY,.cpPoseLocalQZ,.cpPoseLocalQW])
            }
            if let at=controlVisual.poseCacheWritten {values[.cpPoseSampleAgeMS]=max(0,(ProcessInfo.processInfo.systemUptime-at)*1000)}
            let status=PlaybackLogStore.shared.status;values[.logFailures]=Double(status.failures);values[.logDropped]=Double(status.dropped)
            let record=PlaybackLogRecord(event:.controllerPose,values:values)
            PlaybackLogStore.shared.enqueue(record)
            if (1...3).contains(cause) || cause==9 {checkpoint.append(record)}
        }
        if !checkpoint.isEmpty {
            ControllerCheckpointStore.shared.enqueue(records:checkpoint,controllerInstance:controlVisual.checkpointInstance,
                playerGeneration:presentation.player?.playbackGeneration,referenceRevision:controlVisual.referenceRevision)
        }
    }

    private func controllerSynchronizedFrame(_ controls:Entity,anchor:DeviceAnchor?)->[PlaybackLogField:Double] {
        var values:[PlaybackLogField:Double]=[.cpSFrameBegin:CACurrentMediaTime()]
        var flags=0
        func matrix(_ value:simd_float4x4?,_ prefix:String,_ bit:Int) {
            guard let value else{return}
            for c in 0..<4 {for row in 0..<4 {
                guard value[c][row].isFinite else{return}
            }}
            flags |= 1<<bit
            for c in 0..<4 {for row in 0..<4 {
                if let key=PlaybackLogField(rawValue:"cpS\(prefix)\(c*4+row)"){values[key]=Double(value[c][row])}
            }}
        }
        matrix(controls.transformMatrix(relativeTo:nil),"M",0)
        matrix(controls.parent?.transformMatrix(relativeTo:nil),"P",1)
        matrix(controls.transform.matrix,"L",2)
        matrix(moveHandle.scene == nil ? nil:moveHandle.transformMatrix(relativeTo:nil),"H",3)
        matrix(placement.transformMatrix(relativeTo:nil),"B",6)
        if let pose=presentation.calibration.pose {
            var m=simd_float4x4(pose.orientation);m.columns.3=SIMD4(pose.position,1);matrix(m,"Q",7)
        }
        let video:Entity?=systemRenderer.ready && systemRenderer.entity.isEnabled ? systemRenderer.entity:(renderer.ready && renderer.entity.isEnabled ? renderer.entity:nil)
        matrix(video?.transformMatrix(relativeTo:nil),"V",8)
        matrix(video?.transform.matrix,"W",9)
        values[.cpSVideoRoute]=video === systemRenderer.entity ? 1:(video === renderer.entity ? 2:0)
        values[.cpSVideoParent]=video?.parent === placement ? 1:0
        values[.cpSVideoHasScene]=video?.scene == nil ? 0:1
        values[.cpSVideoReady]=video == nil ? 0:1;values[.cpSVideoEnabled]=video?.isEnabledInHierarchy==true ? 1:0
        values[.cpSPanelVisible]=presentation.controlsVisible && controls.isEnabledInHierarchy ? 1:0
        values[.cpSParentExpected]=controls.parent === controllerReference ? 1:0
        values[.cpSTrialTilt]=Double(presentation.calibration.initialControllerTiltDegrees)
        values[.cpSAutoPitch]=presentation.calibration.automaticPitchDegrees
        values[.cpSManualYaw]=presentation.settings.yawDegrees;values[.cpSManualPitch]=presentation.settings.pitchDegrees;values[.cpSManualRoll]=presentation.settings.rollDegrees
        values[.cpSEffectivePitch]=presentation.videoSettings.pitchDegrees
        // Resolve through shared Spatial ancestry; do not equate numeric ARKit and scene origins.
        values[.cpSSpaceMask]=0
        if #available(visionOS 26.0,*),let scene=controls.scene {
            let world=WorldReferenceCoordinateSpace.worldReference
            if let transform:ProjectiveTransform3DFloat=try? world.transform(from:scene) {
                matrix(transform.matrix,"F",13);values[.cpSSpaceMask,default:0]+=1
            }
            if #available(visionOS 27.0,*),let anchor {
                if let transform:ProjectiveTransform3DFloat=try? scene.transform(from:anchor.coordinateSpace(correction:.none)) {
                    matrix(transform.matrix,"D",11);values[.cpSSpaceMask,default:0]+=2
                }
                if let transform:ProjectiveTransform3DFloat=try? scene.transform(from:anchor.coordinateSpace(correction:.rendered)) {
                    matrix(transform.matrix,"E",12);values[.cpSSpaceMask,default:0]+=4
                }
            }
        }
        values[.cpSUIStatus]=controlVisual.attachmentGeometry == nil ? 1:5
        if let ui=controlVisual.attachmentGeometry {
            values[.cpSUIChanged]=controlVisual.attachmentChanged;values[.cpSUIRevision]=Double(controlVisual.attachmentRevision)
            values[.cpSUIWidth]=ui.size.x;values[.cpSUIHeight]=ui.size.y;values[.cpSUIDepth]=ui.size.z
        }
        values[.cpSYRequested]=Double(controlVisual.sideYawRequested);values[.cpSYBase]=Double(controlVisual.sideYawBase);values[.cpSYAt]=controlVisual.sideYawRequestedAt
        values[.cpSLRoll]=controlVisual.levelRoll;values[.cpSLStatus]=Double(controlVisual.levelStatus)
        values[.cpSLBasisUptime]=controlVisual.poseCacheWritten
        if let head=controlVisual.cachedHead {
            for (key,v) in zip([PlaybackLogField.cpSLQX,.cpSLQY,.cpSLQZ,.cpSLQW],[head.vector.x,head.vector.y,head.vector.z,head.vector.w]) {values[key]=Double(v)}
        }
        let viewer=controllerReference.convert(position:controlVisual.viewer,to:nil)
        values[.cpSLVX]=Double(viewer.x);values[.cpSLVY]=Double(viewer.y);values[.cpSLVZ]=Double(viewer.z)
        values[.cpSFlags]=Double(flags);values[.cpSFrameEnd]=CACurrentMediaTime()
        return values
    }
    private func recordControllerSynchronized(_ result:ControllerSynchronizedProbe.Result,origin:Int,request:Int,epoch:Int,revision:UInt64) {
        var records:[PlaybackLogRecord]=[]
        for (i,row) in [result.lower,result.upper,result.summary].enumerated() {
            var values=row
            values[.cpSSchema]=5;values[.cpSOrigin]=Double(origin);values[.cpSAttempt]=Double(controlVisual.syncAttempts)
            values[.cpPoseCause]=10;values[.cpPoseRequest]=Double(request);values[.cpPoseEpoch]=Double(epoch);values[.cpPoseRole]=Double(i+1)
            values[.cpSOutcome]=result.summary[.cpSOutcome]
            // Six decimal places retain microsecond times while bounding numeric serialization.
            var invalid=0
            for (key,value) in values {
                if !value.isFinite || abs(value)>=1e9 {values.removeValue(forKey:key);invalid+=1}
                else {values[key]=(value*1e6).rounded()/1e6}
            }
            values[.cpSInvalid]=Double(invalid)
            let record=PlaybackLogRecord(event:.controllerPose,values:values)
            records.append(record);PlaybackLogStore.shared.enqueue(record)
        }
        ControllerCheckpointStore.shared.enqueue(records:records,controllerInstance:controlVisual.checkpointInstance,
            playerGeneration:presentation.player?.playbackGeneration,referenceRevision:revision)
    }

    private func recordControllerReset(_ phase:ControllerResetLogPhase,ticket:Int,controls:Entity?,sample:VRInitialPose?=nil) {
        let parent=controls?.parent
        let video:Entity?=systemRenderer.ready && systemRenderer.entity.isEnabled ? systemRenderer.entity:(renderer.ready && renderer.entity.isEnabled ? renderer.entity:nil)
        var values=ControllerResetLog.values(sequence:ticket,phase:phase,world:controls?.transformMatrix(relativeTo:nil),
            parent:parent?.transformMatrix(relativeTo:nil),local:controls?.transform.matrix,intended:controlVisual.orientation,
            frame:controlVisual.worldFrame,cachedHead:controlVisual.cachedHead,video:video?.orientation(relativeTo:nil),
            localPosition:controls?.position,cachedViewer:controlVisual.viewer,offset:presentation.controlsOffset)
        let now=ProcessInfo.processInfo.systemUptime
        values[.crElapsedMS]=(now-controlVisual.resetStarted)*1000
        values[.crResetSamplePresent]=sample == nil ? 0:1
        if let ms=sample?.sampleTiming?.queryMS {values[.crResetQueryMS]=ms}
        if let ms=sample?.sampleTiming?.elapsedSinceQueryMS(at:now) {values[.crResetQueryAgeMS]=ms}
        values[.crControllerRevision]=Double(presentation.calibration.controllerRevision)
        values[.crControllerTilt]=Double(presentation.calibration.initialControllerTiltDegrees)
        values[.crControllerYaw]=Double(presentation.calibration.initialControllerYawDegrees)
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
    private var recenterObservationScope:VRRecenterObservationScope {
        .init(request:presentation.calibrationRequest,owner:presentation.player.map(ObjectIdentifier.init),
              playbackGeneration:presentation.player?.playbackGeneration)
    }
    private var recenterRotationSnapshot:VRRecenterRotationSnapshot {
        let system=systemRenderer.ready && systemRenderer.entity.isEnabled
        let custom=renderer.ready && renderer.entity.isEnabled
        let video:Entity?=system != custom ? (system ? systemRenderer.entity:renderer.entity):nil
        let route=video == nil ? -1:(system ? 0:1)
        let reference=placement.parent,inScene=placement.scene != nil
        let epoch=controlVisual.recenterReference.sample(reference:reference,placement:placement,inScene:inScene)
        let attached=video?.parent === placement
        return .init(route:route,parent:reference.map{placement.orientation(relativeTo:$0)},
                     child:attached ? video?.orientation(relativeTo:placement):nil,parentMatches:attached,
                     referenceEpoch:epoch,inScene:inScene,hasReference:reference != nil,
                     enabled:video?.isEnabledInHierarchy==true)
    }
    private func recordRecenterRotation(source:Int) {
        guard controlVisual.recenterRotation.isPending else{return}
        controlVisual.recenterRotation.observe(scope:recenterObservationScope,generation:presentation.calibration.directionGeneration,
            active:presentation.active && scenePhase == .active && !presentation.stopping,
            snapshot:recenterRotationSnapshot,acceptedPose:presentation.calibration.pose?.orientation,
            now:ProcessInfo.processInfo.systemUptime,source:source)
    }
    private func recordRecenterTarget(_ entity:Entity,trace:VRRecenterTrace) {
        var target = -1
        for axis in 0..<3 {for (index,sign) in [Float(-1),Float(1)].enumerated() {
            if entity.name=="show-controls-\(axis)-\(sign)" {target=axis*2+index}
        }}
        trace.record(.targetSnapshot,fields:[.recenterTarget:Double(target),
            .recenterTargetEnabled:entity.isEnabledInHierarchy ? 1:0,.recenterTargetScene:entity.scene == nil ? 0:1,
            .recenterParentMatches:entity.parent === placement ? 1:0,
            .recenterControlsVisible:presentation.controlsVisible ? 1:0,
            .recenterSettingsVisible:presentation.settingsVisible ? 1:0,.recenterRoute:Double(recenterRotationSnapshot.route)])
    }
    private func applyPlacement() {
        if let pose = presentation.calibration.pose {
            placement.position = pose.position; placement.orientation = pose.orientation
        } else {
            placement.position = [0, 1.5, 0]; placement.orientation = simd_quatf()
        }
        if let result=presentation.calibration.lastCapture,presentation.calibration.isCurrent(result),
           controlVisual.recenterAppliedTrace != result.trace.id {
            controlVisual.recenterAppliedTrace=result.trace.id
            result.trace.record(.placementApplied,fields:[.active:scenePhase == .active ? 1:0,.available:placement.scene == nil ? 0:1])
        }
    }
}

@MainActor private final class ControllerVisualState {
    let checkpointInstance=UUID()
    var sideYawRequested:Float=0,sideYawBase:Float=0
    var sideYawRequestedAt:Double=0
    var levelRoll:Double=0
    var levelStatus=1
    var referenceRevision:UInt64=0
    var uprightAudit=VRControllerUprightAudit()
    var defaultPlacement:VRControllerReference.Placement?
    var poseAudit=VRControllerPoseAudit()
    var movePoseScope:VRControllerPoseAudit.Scope?
    var recenterAppliedTrace:UInt64=0
    let recenterRotation=VRRecenterRotationObservation()
    let recenterReference=VRRecenterReferenceIdentity()
    let progressVisibility=VRProgressVisibilityDiagnostics()
    var entity:Entity?
    var resetTrace=ControllerResetTrace()
    var resetRequest=VRControllerResetRequest()
    var resetTicket:Int?
    var poseDetailTask:Task<Void,Never>?
    var syncAttempts=0
    var attachmentGeometry:ControllerAttachmentGeometry?
    var attachmentChanged:Double=0
    var attachmentRevision:UInt64=0

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

/// Independent, nonoverlapping hit surfaces, with one shared edit owner.
private struct CompactPlaybackProgress:View {
    @Binding var value:Double
    let bounds:ClosedRange<Double>
    let onEditingChanged:(Bool,UInt64)->Void
    let onCancelled:()->Void
    let diagnosticContext:()->Int
    @Environment(\.isEnabled) private var isEnabled
    @State private var input=VRProgressInputSession()
    @State private var coordinateSpace=UUID()
    init(value:Binding<Double>,in bounds:ClosedRange<Double>,onEditingChanged:@escaping (Bool,UInt64)->Void,onCancelled:@escaping ()->Void,diagnosticContext:@escaping ()->Int) {
        _value=value;self.bounds=bounds;self.onEditingChanged=onEditingChanged;self.onCancelled=onCancelled;self.diagnosticContext=diagnosticContext
    }
    private var context:Int {diagnosticContext() | (isEnabled ? 1:0)}
    var body:some View {
        GeometryReader { geometry in
            let radius=VRControllerHit.thumbHitDiameter/2
            let travel=max(geometry.size.width-VRControllerHit.thumbHitDiameter,0)
            let fraction=VRProgressDragState.fraction(value,in:bounds)
            ZStack(alignment:.leading) {
                ZStack(alignment:.leading) {
                    Capsule().fill(.secondary.opacity(0.35)).frame(width:travel,height:VRControllerHit.trackHeight).offset(x:radius)
                    Capsule().fill(.tint).frame(width:CGFloat(fraction)*travel,height:VRControllerHit.trackHeight).offset(x:radius)
                }.allowsHitTesting(false)
                // Fixed child identities and full-row frames: moving the visual thumb does not move gesture coordinates.
                ProgressInputSurface(route:2,fraction:fraction,space:coordinateSpace,
                    changed:{update($0,route:2,token:$1,width:geometry.size.width)},
                    ended:{finish($0,route:2,token:$1,width:geometry.size.width)},cancelled:{cancel(token:$0,reason:$1)})
                ProgressInputSurface(route:1,fraction:fraction,space:coordinateSpace,
                    changed:{update($0,route:1,token:$1,width:geometry.size.width)},
                    ended:{finish($0,route:1,token:$1,width:geometry.size.width)},cancelled:{cancel(token:$0,reason:$1)})
            }.frame(width:geometry.size.width,height:VRControllerHit.thumbHitDiameter,alignment:.leading)
                .coordinateSpace(name:coordinateSpace)
        }
        .frame(maxWidth:.infinity).frame(height:VRControllerHit.thumbHitDiameter)
        .opacity(isEnabled ? 1:0.4).allowsHitTesting(isEnabled)
        .onChange(of:isEnabled){_,enabled in if !enabled {cancel(token:input.token,reason:2)}}
        .onDisappear {cancel(token:input.token,reason:3)}
        .accessibilityElement(children:.ignore)
        .accessibilityValue(PlaybackProgress.time(value))
        .accessibilityAdjustableAction { direction in
            guard isEnabled,!input.isActive else{return}
            let step=min(10,bounds.upperBound-bounds.lowerBound)
            guard step>0 else{return}
            let next:Double
            switch direction {
            case .increment:next=min(value+step,bounds.upperBound)
            case .decrement:next=max(value-step,bounds.lowerBound)
            @unknown default:return
            }
            guard next != value,let token=input.beginAX(value:value,context:context) else{return}
            let request=input.requestID
            onEditingChanged(true,request);value=next
            if let id=input.finish(token:token,context:context,value:value){onEditingChanged(false,id)}
        }
    }
    private func update(_ event:DragGesture.Value,route:Int,token:UInt64?,width:CGFloat)->UInt64? {
        let wasActive=input.isActive
        guard let result=input.update(route:route,token:token,x:Double(event.startLocation.x),y:Double(event.startLocation.y),
            translation:Double(event.translation.width),width:Double(width),value:value,bounds:bounds,context:context) else{
            if wasActive,!input.isActive {onCancelled()};return nil
        }
        if result.began {onEditingChanged(true,result.request)}
        value=result.value;return result.token
    }
    private func finish(_ event:DragGesture.Value,route:Int,token:UInt64?,width:CGFloat) {
        guard let token,token==input.token else{return}
        guard update(event,route:route,token:token,width:width) != nil else{return}
        if let id=input.finish(token:token,context:context,value:value){onEditingChanged(false,id)}
    }
    private func cancel(token:UInt64?,reason:Int) {
        if input.cancel(token:token,reason:reason,context:context,value:value){onCancelled()}
    }
}
/// GestureState is used solely for existing cancellation control, never diagnostic observation.
private struct ProgressInputSurface:View {
    let route:Int,fraction:Double,space:UUID
    let changed:(DragGesture.Value,UInt64?)->UInt64?
    let ended:(DragGesture.Value,UInt64?)->Void
    let cancelled:(UInt64,Int)->Void
    @GestureState private var active=false
    @State private var lifecycle=VRProgressSurfaceLifecycle()
    var body:some View {
        let shape=ProgressSurfaceShape(fraction:fraction,route:route)
        hoverSurface.contentShape(.interaction,shape)
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named(space))
                .updating($active){_,state,_ in state=true}
                .onChanged { event in
                    lifecycle.prepare{cancelled($0,4)}
                    guard !lifecycle.rejected else{return}
                    if let token=changed(event,lifecycle.token){lifecycle.accepted(token)}else{lifecycle.reject()}
                }
                .onEnded { event in ended(event,lifecycle.ended()) })
            .onChange(of:active){_,active in if !active {lifecycle.schedule{cancelled($0,1)}}}
            .onDisappear {lifecycle.cancel{cancelled($0,3)}}
    }
    @ViewBuilder private var hoverSurface:some View {
        let shape=ProgressSurfaceShape(fraction:fraction,route:route)
        if route==1 {
            // Full-row host and stable gesture coordinates; only visual circles move.
            GeometryReader { geometry in
                let radius=VRControllerHit.thumbHitDiameter/2
                let travel=max(geometry.size.width-VRControllerHit.thumbHitDiameter,0)
                let center=radius+CGFloat(min(max(fraction,0),1))*travel
                ZStack(alignment:.leading) {
                    Circle().fill(.gray.opacity(0.35))
                        .frame(width:VRControllerHit.thumbHitDiameter,height:VRControllerHit.thumbHitDiameter)
                        .contentShape(.hoverEffect,Circle())
                        .hoverEffect { effect,isActive,_ in effect.opacity(isActive ? 1:0) }
                        .offset(x:center-radius)
                    Circle().fill(.white)
                        .frame(width:VRControllerHit.thumbDiameter,height:VRControllerHit.thumbDiameter)
                        .offset(x:center-VRControllerHit.thumbDiameter/2)
                }
                .frame(width:geometry.size.width,height:VRControllerHit.thumbHitDiameter,alignment:.leading)
            }
            .contentShape(.hoverEffect,shape)
            .hoverEffect(.highlight)
            // This group is deliberately inside route 1, never the row or track.
            .hoverEffectGroup()
        } else {
            Color.clear.contentShape(.hoverEffect,shape).hoverEffect(.highlight)
        }
    }
}
private struct ProgressSurfaceShape:Shape {
    var fraction:Double,route:Int
    func path(in rect:CGRect)->Path {
        let radius=VRControllerHit.thumbHitDiameter/2
        let travel=max(rect.width-VRControllerHit.thumbHitDiameter,0)
        let center=rect.minX+radius+CGFloat(min(max(fraction,0),1))*travel
        var thumb=Path();thumb.addEllipse(in:CGRect(x:center-radius,y:rect.midY-radius,width:2*radius,height:2*radius))
        if route==1{return thumb}
        // No boolean circle subtraction: exclude its full horizontal 32pt bounding interval.
        let left=leftSegment(in:rect,cut:center-radius)
        let mirroredCut=rect.minX+rect.maxX-(center+radius)
        var result=left
        result.addPath(leftSegment(in:rect,cut:mirroredCut),transform:CGAffineTransform(a:-1,b:0,c:0,d:1,tx:rect.minX+rect.maxX,ty:0))
        return result
    }
    private func leftSegment(in rect:CGRect,cut:CGFloat)->Path {
        let left=rect.minX+VRControllerHit.thumbHitDiameter/2
        let travel=max(rect.width-VRControllerHit.thumbHitDiameter,0)
        let h=min(VRControllerHit.trackHitHeight/2,travel/2)
        guard h>0,cut>left else{return Path()}
        let cx=left+h,cy=rect.midY
        var path=Path()
        if cut<cx {
            let angle=acos(Double((cut-cx)/h)),half=h*CGFloat(sin(angle))
            path.move(to:CGPoint(x:cut,y:cy-half))
            path.addArc(center:CGPoint(x:cx,y:cy),radius:h,startAngle:.radians(-angle),endAngle:.radians(angle-2 * .pi),clockwise:true)
            path.closeSubpath()
        } else {
            path.move(to:CGPoint(x:cut,y:cy-h));path.addLine(to:CGPoint(x:cx,y:cy-h))
            path.addArc(center:CGPoint(x:cx,y:cy),radius:h,startAngle:.degrees(-90),endAngle:.degrees(-270),clockwise:true)
            path.addLine(to:CGPoint(x:cut,y:cy+h));path.closeSubpath()
        }
        return path
    }
}

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
                Text(vertical ? VistaL10n.text("垂直"):VistaL10n.text("水平"))
                Text(VRManualAngleDisplay.text(value)).fixedSize()
            }.hidden().accessibilityHidden(true)
                .frame(width:vertical ? 56:nil)
                .overlay(alignment:vertical ? .leading:.bottom) {
                    HStack(alignment:.firstTextBaseline,spacing:6) {
                        Text(vertical ? VistaL10n.text("垂直"):VistaL10n.text("水平"))
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


/// SwiftUI's last reported view geometry, not compositor pixels or an eye-gaze sample.
private struct ControllerAttachmentGeometry:Equatable {
    let size:SIMD3<Double>
    @MainActor init(proxy:GeometryProxy3D) {size=SIMD3(proxy.size.width,proxy.size.height,proxy.size.depth)}
}
@MainActor private final class ControllerSynchronizedProbe {
    static let shared=ControllerSynchronizedProbe()
    struct Result {
        var lower:[PlaybackLogField:Double]=[:]
        var upper:[PlaybackLogField:Double]=[:]
        var summary:[PlaybackLogField:Double]=[:]
    }
    private struct Frame {let time:Double;let values:[PlaybackLogField:Double]}
    private let manager=CMMotionManager()
    private var activeSession:ARKitSession?
    func stop(){activeSession?.stop();manager.stopDeviceMotionUpdates()}
    func capture(snapshot:@MainActor (DeviceAnchor?)->[PlaybackLogField:Double]) async ->Result {
        let started=CACurrentMediaTime()
        var result=Result(),queries=0,missing=0,untracked=0,badTime=0
        var frames:[Frame]=[],firstOffset:Double?,lastOffset=0.0
        result.summary[.cpSOutcome]=1
        result.summary[.cpSAvailable]=manager.isDeviceMotionAvailable ? 1:0
        if #available(visionOS 27.2,*) {result.summary[.cpSAuthorization]=Double(CMMotionManager.authorizationStatus.rawValue)}
        guard WorldTrackingProvider.isSupported,WorldTrackingProvider.requiredAuthorizations.isEmpty,
              manager.isDeviceMotionAvailable else{return result}
        let session=ARKitSession(),provider=WorldTrackingProvider()
        guard let token=ControllerPoseProbeGate.shared.beginProbe(stop:{session.stop()}) else {result.summary[.cpSOutcome]=2;return result}
        activeSession=session
        manager.deviceMotionUpdateInterval=0.02;manager.startDeviceMotionUpdates()
        let timeout=Task { @MainActor in
            do {try await Task.sleep(for:.milliseconds(750))}catch{return}
            session.stop()
        }
        defer {
            timeout.cancel();session.stop();ControllerPoseProbeGate.shared.endProbe(token)
            if activeSession === session {activeSession=nil;manager.stopDeviceMotionUpdates()}
        }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard ControllerPoseProbeGate.shared.hasProbe(token) else {result.summary[.cpSOutcome]=5;return result}
                try await session.run([provider])
                result.summary[.cpSOutcome]=6
                for _ in 0..<32 {
                    try Task.checkCancellation()
                    guard ControllerPoseProbeGate.shared.hasProbe(token) else {result.summary[.cpSOutcome]=5;break}
                    guard CACurrentMediaTime()-started<0.65 else {result.summary[.cpSOutcome]=4;break}
                    if provider.state == .running {
                        let uptime=ProcessInfo.processInfo.systemUptime,now=CACurrentMediaTime()
                        lastOffset=now-uptime
                        if firstOffset==nil {firstOffset=lastOffset}
                        guard ControllerSyncPolicy.clockStable(first:firstOffset!,current:lastOffset) else {result.summary[.cpSOutcome]=7;break}
                        let begin=CACurrentMediaTime(),anchor=provider.queryDeviceAnchor(atTimestamp:now),end=CACurrentMediaTime()
                        queries+=1
                        if let anchor {
                            if anchor.trackingState != .tracked {untracked+=1}
                            else if let pose=VRInitialPose(matrix:anchor.originFromAnchorTransform) {
                                let at=anchor.timestamp
                                if !now.isFinite || (frames.last.map{now <= $0.time} ?? false) {badTime+=1}
                                else {
                                    var values=snapshot(anchor)
                                    values[.cpSQueryAt]=now;values[.cpSQueryBegin]=begin;values[.cpSQueryEnd]=end
                                    values[.cpSAnchorAt]=at;values[.cpSAnchorTracked]=2
                                    values[.cpSAnchorTimeKnown]=at.isFinite && at>0 ? 1:0
                                    values[.cpSTimeBasis]=1 // API returns predicted pose for the requested current timestamp.
                                    let positionKeys:[PlaybackLogField]=[.cpSHeadX,.cpSHeadY,.cpSHeadZ]
                                    for i in 0..<3 {values[positionKeys[i]]=Double(pose.position[i])}
                                    let rotationKeys:[PlaybackLogField]=[.cpSHeadQX,.cpSHeadQY,.cpSHeadQZ,.cpSHeadQW]
                                    for i in 0..<4 {values[rotationKeys[i]]=Double(pose.orientation.vector[i])}
                                    if let frameBegin=values[.cpSFrameBegin],let frameEnd=values[.cpSFrameEnd],
                                       frameEnd-frameBegin<=0.010,frameEnd-now<=0.015 {
                                        frames.append(Frame(time:now,values:values))
                                    } else {badTime+=1}
                                }
                            } else {missing+=1}
                        } else {missing+=1}
                        if let motion=manager.deviceMotion {
                            let at=motion.timestamp+lastOffset
                            if let (lo,hi)=ControllerSyncPolicy.bracket(frames.map(\.time),target:at),
                               now-at>=0,now-at<=0.15 {
                                result.lower=frames[lo].values;result.upper=frames[hi].values
                                let g=motion.gravity,r=motion.rotationRate,a=motion.userAcceleration
                                let values=[motion.timestamp,at,g.x,g.y,g.z,r.x,r.y,r.z,a.x,a.y,a.z]
                                if values.allSatisfy({$0.isFinite}) {
                                    let span=frames[hi].time-frames[lo].time
                                    result.summary.merge([.cpSOutcome:0,.cpSRawMotionAt:motion.timestamp,.cpSMotionAt:at,
                                        .cpSMotionAge:(now-at)*1000,.cpSClockAt:now,.cpSSpanMS:span*1000,.cpSWeight:(at-frames[lo].time)/span,
                                        .cpSGX:g.x,.cpSGY:g.y,.cpSGZ:g.z,.cpSRX:r.x,.cpSRY:r.y,.cpSRZ:r.z,.cpSAX:a.x,.cpSAY:a.y,.cpSAZ:a.z]){_,n in n}
                                    break
                                }
                            }
                        }
                    } else if provider.state == .stopped {result.summary[.cpSOutcome]=5;break}
                    try await Task.sleep(for:.milliseconds(20))
                }
                if result.summary[.cpSOutcome] != 0 {
                    result.lower=frames.first?.values ?? snapshot(nil);result.upper=frames.last?.values ?? result.lower
                }
                result.summary[.cpSWindowMS]=(CACurrentMediaTime()-started)*1000
                result.summary[.cpSQueries]=Double(queries);result.summary[.cpSMissing]=Double(missing)
                result.summary[.cpSUntracked]=Double(untracked);result.summary[.cpSBadTime]=Double(badTime)
                result.summary[.cpSClockFirst]=firstOffset;result.summary[.cpSClockLast]=lastOffset
                return result
            } onCancel:{session.stop()}
        } catch {
            result.summary[.cpSOutcome]=Task.isCancelled ? 5:3
            result.summary[.cpSWindowMS]=(CACurrentMediaTime()-started)*1000
            result.summary[.cpSQueries]=Double(queries);result.lower=frames.first?.values ?? [:];result.upper=frames.last?.values ?? [:]
            return result
        }
    }
}
