import SwiftUI
import RealityKit
import Observation

@MainActor @Observable final class VRPresentation {
    var settings = VRSettings()
    var player: PlaybackController?
    var testPattern = false
    var active = false
    var opening = false
    var message: String?
    var image: CGImage? { testPattern ? Self.pattern : player?.frame?.image }
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
    var body: some View {
        Picker("投影", selection: $presentation.settings.projection) {
            ForEach(VRProjection.allCases, id: \.self) { Text($0.title).tag($0) }
        }.accessibilityIdentifier("vrProjection")
        Picker("排列", selection: $presentation.settings.layout) {
            ForEach(VRLayout.allCases, id: \.self) { Text($0.title).tag($0) }
        }.accessibilityIdentifier("vrLayout")
        if presentation.settings.layout != .mono { Toggle("交換左右眼", isOn: $presentation.settings.swapEyes) }
    }
}

@MainActor @Observable final class VRRenderer {
    let entity = ModelEntity()
    var error: String?
    var ready = false
    private var material: ShaderGraphMaterial?
    private var projection: VRProjection?
    @ObservationIgnored private var pending: (CGImage?, VRSettings)?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var latestSettings: VRSettings?
    func submit(image: CGImage?, settings: VRSettings) {
        if image == nil || settings != latestSettings { generation += 1 }
        latestSettings = settings
        pending = (image, settings)
        if image == nil { entity.isEnabled = false; ready = false }
        guard worker == nil else { return }
        worker = Task {
            while let next = pending, !Task.isCancelled {
                pending = nil
                await update(image: next.0, settings: next.1, generation: generation)
            }
            worker = nil
            if let next = pending { submit(image: next.0, settings: next.1) }
        }
    }
    func stop() {
        generation += 1; pending = nil; worker?.cancel()
        entity.isEnabled = false; ready = false
    }
    private func update(image: CGImage?, settings: VRSettings, generation expected: Int) async {
        guard let image else { entity.isEnabled = false; ready = false; return }
        do {
            if material == nil {
                guard let url = Bundle.main.url(forResource: "StereoscopicMaterial", withExtension: "usda") else { throw CocoaError(.fileReadNoSuchFile) }
                material = try await ShaderGraphMaterial(named: "/Root/Material", from: url)
            }
            try Task.checkCancellation()
            guard let leftRect = settings.crop(width: image.width, height: image.height, rightEye: false),
                  let rightRect = settings.crop(width: image.width, height: image.height, rightEye: true),
                  let left = image.cropping(to: leftRect), let right = image.cropping(to: rightRect),
                  var material else { throw CocoaError(.coderInvalidValue) }
            let leftTexture = try await TextureResource(image: left, options: .init(semantic: .color))
            let rightTexture = settings.layout == .mono ? leftTexture : try await TextureResource(image: right, options: .init(semantic: .color))
            try Task.checkCancellation()
            guard expected == generation else { return }
            try material.setParameter(name: "LeftTexture", value: .textureResource(leftTexture))
            try material.setParameter(name: "RightTexture", value: .textureResource(rightTexture))
            if projection != settings.projection || entity.model == nil {
                let data = VRMesh(projection: settings.projection)
                var descriptor = MeshDescriptor(name: "Vista panorama")
                descriptor.positions = MeshBuffers.Positions(data.positions)
                descriptor.normals = MeshBuffers.Normals(data.normals)
                descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(data.uv)
                descriptor.primitives = .triangles(data.indices)
                entity.model = ModelComponent(mesh: try MeshResource.generate(from: [descriptor]), materials: [material])
                projection = settings.projection
            } else { entity.model?.materials = [material] }
            entity.orientation = simd_quatf(angle: Float(settings.yawDegrees * .pi / 180), axis: [0, 1, 0])
            entity.isEnabled = true; ready = true; error = nil
        } catch is CancellationError { }
        catch { guard expected == generation else { return }; entity.isEnabled = false; ready = false; self.error = "無法建立 VR 投影。請返回視窗重試。" }
    }
}

struct VRImmersiveView: View {
    @Environment(VRPresentation.self) private var presentation
    @Environment(\.dismissImmersiveSpace) private var dismiss
    @State private var renderer = VRRenderer()
    private struct UpdateKey: Hashable { let image: ObjectIdentifier?; let settings: VRSettings }
    var body: some View {
        RealityView { content, attachments in
            content.add(renderer.entity)
            if let controls = attachments.entity(for: "controls") {
                controls.position = [0, 1.25, -1.5]
                content.add(controls)
            }
        } attachments: {
            Attachment(id: "controls") {
                VStack {
                    if presentation.testPattern { Text("投影測試圖，非影片播放").accessibilityIdentifier("vrTestPattern") }
                    if let error = renderer.error { Text(error).accessibilityIdentifier("vrError") }
                    else if renderer.ready { Text(presentation.settings.projection.title).accessibilityIdentifier("vrReady") }
                    else { ProgressView("準備投影…") }
                    Text(presentation.settings.layout.title).accessibilityIdentifier("vrLayoutReady")
                    HStack {
                        Button("向左轉") { presentation.settings.yawDegrees -= 15 }
                        Button("方向歸零") { presentation.settings.yawDegrees = 0 }
                        Button("向右轉") { presentation.settings.yawDegrees += 15 }
                    }
                    if !presentation.testPattern, let player = presentation.player {
                        Button(player.isPaused ? "繼續" : "暫停", action: player.togglePause).disabled(player.isPreparing || !player.isPlaying)
                    }
                    Button("返回視窗") { Task { await dismiss(); presentation.active = false } }.accessibilityIdentifier("closeVR")
                }.padding().glassBackgroundEffect()
            }
        }
        .task(id: UpdateKey(image: presentation.image.map(ObjectIdentifier.init), settings: presentation.settings)) {
            renderer.submit(image: presentation.image, settings: presentation.settings)
        }
        .onDisappear { renderer.stop(); presentation.active = false; presentation.player = nil; presentation.testPattern = false }
    }
}
