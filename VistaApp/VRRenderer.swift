import Foundation
import Observation
import RealityKit
import CoreImage
import CoreVideo
import Metal
#if SWIFT_PACKAGE
import VistaCore
import VistaMedia
#endif

/// App candidate: the same bounded renderer accepts native AVPlayer frames and legacy images.
@MainActor @Observable final class VRRenderer {
    let entity = ModelEntity()
    var error: String?
    var ready = false
    var logValues: [PlaybackLogField: Double] = [:]
    private(set) var route = "原雙貼圖"
    #if DEBUG
    var reviewBusy: Bool { worker != nil }
    var reviewMeshCount = 0
    var reviewEpochCount = 0
    var reviewGPUFrames = 0
    var reviewLegacyFrames = 0
    #endif
    private enum Input { case image(CGImage), frame(DecodedVideoFrame) }
    private struct Key: Equatable {
        let settings: VRSettings
        let session: UUID?
        let width: Int, height: Int
    }
    private var material: ShaderGraphMaterial?
    private let materialURL: URL?
    private let useGPU: Bool
    private let device = MTLCreateSystemDefaultDevice()
    @ObservationIgnored private lazy var context = device.map { CIContext(mtlDevice: $0) } ?? CIContext()
    @ObservationIgnored private lazy var queue = device?.makeCommandQueue()
    @ObservationIgnored private var pending: (Input, VRSettings, PlaybackMetrics?)?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var key: Key?
    @ObservationIgnored private var epoch: FisheyeTextureEpoch?
    @ObservationIgnored private var gpuFailed = false
    @ObservationIgnored private var geometry: (VRProjection, Int, Int)?
    static var candidateEnabled: Bool {
        #if VISTA_FISHEYE_GPU_CANDIDATE
        true
        #else
        false
        #endif
    }
    init(materialURL: URL? = nil, useGPU: Bool = VRRenderer.candidateEnabled) {
        self.materialURL = materialURL
        self.useGPU = useGPU
    }
    func submit(image: CGImage?, settings: VRSettings, metrics: PlaybackMetrics? = nil) {
        guard let image else { stop(); return }
        enqueue(.image(image), key: Key(settings: settings, session: nil, width: image.width, height: image.height), metrics: metrics)
    }
    func submit(frame: DecodedVideoFrame, settings: VRSettings, metrics: PlaybackMetrics? = nil) {
        enqueue(.frame(frame), key: Key(settings: settings, session: frame.session,
                                      width: CVPixelBufferGetWidth(frame.pixel), height: CVPixelBufferGetHeight(frame.pixel)), metrics: metrics)
    }
    private func enqueue(_ input: Input, key next: Key, metrics: PlaybackMetrics?) {
        metrics?.mark(.submitted)
        if pending != nil { pending?.2?.mark(.coalesced); logValues[.coalesced, default: 0] += 1 }
        if key != next {
            generation += 1; epoch = nil; gpuFailed = false; key = next
            entity.isEnabled = false; entity.model = nil; geometry = nil; ready = false
        }
        pending = (input, next.settings, metrics)
        startWorker()
    }
    private func startWorker() {
        guard worker == nil, pending != nil else { return }
        worker = Task {
            while let next = pending, !Task.isCancelled {
                pending = nil
                await update(next.0, settings: next.1, metrics: next.2, ticket: generation)
            }
            worker = nil
            startWorker()
        }
    }
    func stop() {
        guard key != nil || pending != nil || worker != nil || ready else { return }
        generation += 1; pending = nil; key = nil; worker?.cancel()
        epoch = nil; geometry = nil; entity.model = nil; entity.isEnabled = false; ready = false
    }
    private func update(_ input: Input, settings: VRSettings, metrics: PlaybackMetrics?, ticket: Int) async {
        do {
            if material == nil {
                guard let url = materialURL ?? Bundle.main.url(forResource: "StereoscopicMaterial", withExtension: "usda") else { throw CocoaError(.fileReadNoSuchFile) }
                material = try await ShaderGraphMaterial(named: "/Root/Material", from: url)
            }
            try Task.checkCancellation()
            guard ticket == generation else { metrics?.mark(.stale); return }
            if case let .frame(frame) = input, useGPU, !gpuFailed,
               settings.projection == .equidistantFisheye180, FisheyeTextureEpoch.supports(frame), let queue {
                do {
                    try await updateGPU(frame, settings: settings, metrics: metrics, ticket: ticket, queue: queue)
                    return
                } catch is CancellationError { throw CancellationError() }
                catch {
                    guard ticket == generation else { metrics?.mark(.stale); return }
                    // A failed GPU epoch is not reused. Retain the established image path for this configuration.
                    epoch = nil; gpuFailed = true; entity.model = nil; geometry = nil
                }
            }
            let image: CGImage?
            switch input {
            case let .image(value): image = value
            case let .frame(frame):
                let start = ProcessInfo.processInfo.systemUptime
                image = frame.makeImage(context: context)
                metrics?.record(.image, seconds: ProcessInfo.processInfo.systemUptime - start)
            }
            guard let image else { throw CocoaError(.coderInvalidValue) }
            try await updateLegacy(image, settings: settings, metrics: metrics, ticket: ticket)
        } catch is CancellationError { metrics?.mark(.stale) }
        catch {
            guard ticket == generation else { return }
            entity.isEnabled = false; ready = false; self.error = "無法建立 VR 投影。請返回視窗重試。"
        }
    }
    private func updateGPU(_ frame: DecodedVideoFrame, settings: VRSettings, metrics: PlaybackMetrics?, ticket: Int, queue: any MTLCommandQueue) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        let active: FisheyeTextureEpoch
        let needsBind = epoch == nil
        if let epoch { active = epoch }
        else {
            active = try await FisheyeTextureEpoch(width: CVPixelBufferGetWidth(frame.pixel), height: CVPixelBufferGetHeight(frame.pixel), layout: settings.layout)
            try Task.checkCancellation()
            guard ticket == generation else { metrics?.mark(.stale); return }
            epoch = active
            #if DEBUG
            reviewEpochCount += 1
            #endif
        }
        guard let command = queue.makeCommandBuffer() else { throw CocoaError(.coderInvalidValue) }
        try active.encode(frame.pixel, context: context, command: command)
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { _ in continuation.resume() }; command.commit()
        }
        // Source planes and the epoch stay alive until GPU completion, including after stop/cancellation.
        withExtendedLifetime((frame, active)) {}
        try Task.checkCancellation()
        guard ticket == generation else { metrics?.mark(.stale); return }
        guard command.status == .completed else { throw CocoaError(.coderInvalidValue) }
        if needsBind || entity.model == nil {
            try bind(active.resources, settings: settings, width: Int(active.crops[0].width), height: Int(active.crops[0].height))
        }
        let textureSeconds = ProcessInfo.processInfo.systemUptime - start
        metrics?.record(.texture, seconds: textureSeconds)
        logValues[.textureMS, default: 0] += textureSeconds * 1000
        logValues[.textureCount, default: 0] += 1
        route = "SDR GPU 重用貼圖"
        finish(settings: settings, metrics: metrics)
        #if DEBUG
        reviewGPUFrames += 1
        #endif
    }
    private func updateLegacy(_ image: CGImage, settings: VRSettings, metrics: PlaybackMetrics?, ticket: Int) async throws {
        epoch = nil
        guard let leftRect = settings.crop(width: image.width, height: image.height, rightEye: false),
              let rightRect = settings.crop(width: image.width, height: image.height, rightEye: true),
              let left = image.cropping(to: leftRect), let right = image.cropping(to: rightRect) else { throw CocoaError(.coderInvalidValue) }
        let start = ProcessInfo.processInfo.systemUptime
        let leftTexture = try await TextureResource(image: left, options: .init(semantic: .color))
        let rightTexture = settings.layout == .mono ? leftTexture : try await TextureResource(image: right, options: .init(semantic: .color))
        let textureSeconds = ProcessInfo.processInfo.systemUptime - start
        metrics?.record(.texture, seconds: textureSeconds)
        logValues[.textureMS, default: 0] += textureSeconds * 1000
        logValues[.textureCount, default: 0] += 1
        try Task.checkCancellation()
        guard ticket == generation else { metrics?.mark(.stale); return }
        try bind([leftTexture, rightTexture], settings: settings, width: left.width, height: left.height)
        route = gpuFailed ? "原雙貼圖回退（GPU 更新失敗）" : "原雙貼圖"
        finish(settings: settings, metrics: metrics)
        #if DEBUG
        reviewLegacyFrames += 1
        #endif
    }
    private func bind(_ resources: [TextureResource], settings: VRSettings, width: Int, height: Int) throws {
        guard var material else { throw CocoaError(.coderInvalidValue) }
        try material.setParameter(name: "LeftTexture", value: .textureResource(resources[0]))
        try material.setParameter(name: "RightTexture", value: .textureResource(resources[resources.count - 1]))
        if geometry?.0 != settings.projection || geometry?.1 != width || geometry?.2 != height || entity.model == nil {
            guard let data = VRMesh(projection: settings.projection, eyeWidth: width, eyeHeight: height) else { throw CocoaError(.coderInvalidValue) }
            var descriptor = MeshDescriptor(name: "Vista panorama")
            descriptor.positions = MeshBuffers.Positions(data.positions); descriptor.normals = MeshBuffers.Normals(data.normals)
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(data.uv); descriptor.primitives = .triangles(data.indices)
            entity.model = ModelComponent(mesh: try MeshResource.generate(from: [descriptor]), materials: [material])
            geometry = (settings.projection, width, height)
            #if DEBUG
            reviewMeshCount += 1
            #endif
        } else { entity.model?.materials = [material] }
    }
    private func finish(settings: VRSettings, metrics: PlaybackMetrics?) {
        entity.orientation = VRInitialPose.manualRotation(yaw: settings.yawDegrees, pitch: settings.pitchDegrees, roll: settings.rollDegrees)
        entity.isEnabled = true; ready = true; error = nil; metrics?.mark(.uploaded)
        logValues[.uploaded, default: 0] += 1
    }
}

@MainActor private final class FisheyeTextureEpoch {
    let crops: [CGRect]
    let textures: [LowLevelTexture]
    let resources: [TextureResource]
    let height: Int
    static func supports(_ frame: DecodedVideoFrame) -> Bool {
        guard frame.transform == .identity else { return false }
        let pixel = frame.pixel
        let transfer = CVBufferCopyAttachment(pixel, kCVImageBufferTransferFunctionKey, nil) as? String
        let primaries = CVBufferCopyAttachment(pixel, kCVImageBufferColorPrimariesKey, nil) as? String
        return transfer == kCVImageBufferTransferFunction_ITU_R_709_2 as String && primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String
    }
    init(width: Int, height: Int, layout: VRLayout) async throws {
        self.height = height
        var settings = VRSettings(); settings.layout = layout
        crops = try (0..<(layout == .mono ? 1 : 2)).map {
            guard let rect = settings.crop(width: width, height: height, rightEye: $0 == 1) else { throw CocoaError(.coderInvalidValue) }
            return rect
        }
        var textures: [LowLevelTexture] = [], resources: [TextureResource] = []
        for rect in crops {
            let width = Int(rect.width), height = Int(rect.height)
            let texture = try LowLevelTexture(descriptor: .init(pixelFormat: .bgra8Unorm_srgb, width: width, height: height,
                mipmapLevelCount: Int(log2(Double(max(width, height)))) + 1, textureUsage: [.shaderRead, .shaderWrite, .renderTarget]))
            textures.append(texture); resources.append(try await TextureResource(from: texture))
        }
        self.textures = textures; self.resources = resources
    }
    func encode(_ pixel: CVPixelBuffer, context: CIContext, command: any MTLCommandBuffer) throws {
        let image = CIImage(cvPixelBuffer: pixel)
        var outputs: [any MTLTexture] = []
        for (index, target) in textures.enumerated() {
            let crop = crops[index]
            let rect = CGRect(x: crop.minX, y: CGFloat(height) - crop.maxY, width: crop.width, height: crop.height)
            let eye = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            let texture = target.replace(using: command); outputs.append(texture)
            let destination = CIRenderDestination(width: Int(crop.width), height: Int(crop.height), pixelFormat: texture.pixelFormat, commandBuffer: command, mtlTextureProvider: { texture })
            destination.isFlipped = true; destination.colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            _ = try context.startTask(toRender: eye, to: destination)
        }
        guard let encoder = command.makeBlitCommandEncoder() else { throw CocoaError(.coderInvalidValue) }
        for texture in outputs { encoder.generateMipmaps(for: texture) }
        encoder.endEncoding()
    }
}
