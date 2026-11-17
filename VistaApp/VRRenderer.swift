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
    @ObservationIgnored private var flowWorkerStarted:Double?
    /// Uses existing UI/status polling only. Startup/configuration work is excluded.
    func observeFlowStall() {
        if let started=flowWorkerStarted,ProcessInfo.processInfo.systemUptime-started>=0.2 {PlaybackFlowTrace.trigger(3)}
    }
    let entity = ModelEntity()
    var error: String?
    var ready = false
    var logValues: [PlaybackLogField: Double] = [:]
    private(set) var route = VistaL10n.text("原雙貼圖")
    #if DEBUG
    var reviewBusy: Bool { worker != nil }
    var reviewMeshCount = 0
    var reviewEpochCount = 0
    var reviewGPUFrames = 0
    var reviewLegacyFrames = 0
    #endif
    private enum Input { case image(CGImage), frame(DecodedVideoFrame)
        var flow:PlaybackFlowToken {if case .frame(let frame)=self{return frame.flow};return .none}
    }
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
    @ObservationIgnored private var heldToken:PlaybackFlowToken?
    @ObservationIgnored private var heldEpoch:FisheyeTextureEpoch?
    @ObservationIgnored private var blockedHoldInput:ObjectIdentifier?
    @ObservationIgnored private var blockedHoldFlow:UInt64?
    @ObservationIgnored private var lastOwnedFlow:UInt64=0
    @ObservationIgnored private var lastOutputBytes=0
    @ObservationIgnored private var sceneActive=true
    @ObservationIgnored private var drainSerial:UInt64=0
    static let holdByteLimit=256*1024*1024
    // Existing RGBA base-level estimate, not Metal/AV internal allocation size.
    private struct HoldOutputEstimate {let bytes:Int,width:Int,height:Int,count:Int,source:UInt64}
    @ObservationIgnored private var outputWidth=0
    @ObservationIgnored private var outputHeight=0
    @ObservationIgnored private var outputCount=0
    @ObservationIgnored private var lastOutputEstimate:HoldOutputEstimate?
    @ObservationIgnored private var maxOutputEstimate:HoldOutputEstimate?
    @ObservationIgnored private var outputMaxLogs=0
    @ObservationIgnored private var outputMaxSuppressed=0
    private func traceHoldOutputEstimate(_ value:HoldOutputEstimate,reason:Int64,parent:PlaybackFlowToken?=nil) {
        let flow=PlaybackFlowTrace.begin(.holdByteEstimate,parent:parent ?? PlaybackFlowToken(value.source),a:2,b:reason,c:Int64(bitPattern:value.source))
        PlaybackFlowTrace.mark(.holdByteValues,parent:flow,a:-1,b:Int64(value.bytes),c:Int64(value.bytes))
        PlaybackFlowTrace.mark(.holdByteDimensions,parent:flow,a:Int64(value.width),b:Int64(value.height),c:-1)
        PlaybackFlowTrace.mark(.holdByteLayout,parent:flow,a:Int64(value.count),b:-1,c:Int64(generation))
        PlaybackFlowTrace.mark(.holdByteIdentity,parent:flow,a:Int64(bitPattern:lastOwnedFlow),b:Int64(bitPattern:maxOutputEstimate?.source ?? 0),c:Int64(maxOutputEstimate?.bytes ?? 0))
        PlaybackFlowTrace.end(flow,.holdByteEstimate,a:Int64(outputMaxLogs),b:Int64(outputMaxSuppressed))
    }
    private func recordHoldOutputEstimate() {
        let value=HoldOutputEstimate(bytes:lastOutputBytes,width:outputWidth,height:outputHeight,count:outputCount,source:lastOwnedFlow)
        lastOutputEstimate=value
        if value.bytes>(maxOutputEstimate?.bytes ?? 0) {
            maxOutputEstimate=value
            if outputMaxLogs<8 {outputMaxLogs+=1;traceHoldOutputEstimate(value,reason:1)}
            else {outputMaxSuppressed+=1}
        }
    }
    private func snapshotHoldOutputEstimates() {
        if let value=lastOutputEstimate {traceHoldOutputEstimate(value,reason:2,parent:PlaybackFlowTrace.parent)}
        if let value=maxOutputEstimate {traceHoldOutputEstimate(value,reason:3,parent:PlaybackFlowTrace.parent)}
    }
    private func releaseHeldPresentation(reason:Int64,hide:Bool,newFlow:UInt64=0) {
        guard let heldToken else{return}
        PlaybackFlowTrace.mark(.presentationHoldRelease,parent:heldToken,a:reason,b:Int64(bitPattern:newFlow),c:Int64(lastOutputBytes))
        self.heldToken=nil;heldEpoch=nil;blockedHoldInput=nil;blockedHoldFlow=nil
        if hide {entity.model=nil;entity.isEnabled=false;ready=false}
    }
    func setSceneActive(_ active:Bool) {
        sceneActive=active
        if !active {
            blockedHoldInput=nil;blockedHoldFlow=nil
            if heldToken != nil {releaseHeldPresentation(reason:3,hide:true);stop()}
        }
    }
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
        if (blockedHoldInput != nil || blockedHoldFlow != nil),(blockedHoldFlow.map{$0==frame.flow.id} ?? (blockedHoldInput==ObjectIdentifier(frame))) {
            PlaybackFlowTrace.mark(.presentationHoldState,parent:heldToken ?? PlaybackFlowToken.none,a:3,b:Int64(generation),c:2)
            return
        }
        enqueue(.frame(frame), key: Key(settings: settings, session: frame.session,
                                      width: CVPixelBufferGetWidth(frame.pixel), height: CVPixelBufferGetHeight(frame.pixel)), metrics: metrics)
    }
    #if VISTA_VLC_CANDIDATE
    @ObservationIgnored private var draining=false
    func stopAndDrain(preservingPresentedImage preserve:Bool=false,blockedInput:DecodedVideoFrame?=nil) async {
        drainSerial &+= 1
        let serial=drainSerial
        draining=true
        defer {if serial==drainSerial {draining=false}}
        if preserve {snapshotHoldOutputEstimates()}
        let canHold=preserve && sceneActive && (heldToken != nil ||
            (ready && entity.isEnabled && entity.model != nil && lastOutputBytes>0 && lastOutputBytes<=Self.holdByteLimit))
        if canHold {
            let flow=PlaybackFlowTrace.begin(.presentationHold,a:2,b:Int64(generation),c:Int64(lastOutputBytes))
            defer {PlaybackFlowTrace.end(flow,.presentationHold,a:heldToken == nil ? 0:1)}
            if heldToken == nil {heldToken=flow;heldEpoch=epoch}
            if let blockedInput {
                blockedHoldInput=ObjectIdentifier(blockedInput)
                blockedHoldFlow=blockedInput.flow.id == 0 ? nil:blockedInput.flow.id
            }
            PlaybackFlowTrace.mark(.presentationHoldState,parent:flow,a:10,b:Int64(bitPattern:blockedHoldFlow ?? 0),c:Int64(lastOutputBytes))
            PlaybackFlowTrace.mark(.presentationHoldState,parent:flow,a:11,b:Int64(bitPattern:lastOwnedFlow),c:Int64(generation))
            PlaybackFlowTrace.mark(.presentationHoldState,parent:flow,a:12,b:Int64(key?.session.map{PlaybackBoundaryIdentity.session($0)} ?? 0),c:2)
            generation += 1
            let ticket=generation
            pending=nil;key=nil;ready=false;worker?.cancel()
            let existing=worker;await existing?.value
            guard serial==drainSerial,ticket==generation,sceneActive,heldToken != nil else{return}
            // A submitted Metal write has completed now. Freeze its old output
            // model/epoch; future input creates a different writable epoch.
            epoch=nil;geometry=nil;gpuFailed=false
            context.clearCaches()
            PlaybackFlowTrace.mark(.presentationHoldState,parent:flow,a:2,b:Int64(ticket),c:1)
            return
        }
        PlaybackFlowTrace.mark(.presentationHoldState,a:2,b:preserve ? 1:0,c:Int64(lastOutputBytes))
        stop()
        if preserve,let blockedInput {
            blockedHoldInput=ObjectIdentifier(blockedInput)
            blockedHoldFlow=blockedInput.flow.id == 0 ? nil:blockedInput.flow.id
        }
        let ticket=generation
        let existing=worker;await existing?.value
        guard serial==drainSerial,ticket==generation else{return}
        context.clearCaches()
    }
    #endif
    private func enqueue(_ input: Input, key next: Key, metrics: PlaybackMetrics?) {
        #if VISTA_VLC_CANDIDATE
        guard !draining else{return}
        #endif
        let flow=PlaybackFlowTrace.begin(.presentSubmit,parent:input.flow,a:Int64(generation));defer{PlaybackFlowTrace.end(flow,.presentSubmit)}
        metrics?.mark(.submitted)
        if let pending {PlaybackFlowTrace.mark(.coalesce,parent:pending.0.flow,a:Int64(input.flow.id))}
        if pending != nil { pending?.2?.mark(.coalesced); logValues[.coalesced, default: 0] += 1 }
        if key != next {
            generation += 1; epoch = nil; gpuFailed = false; key = next
            if heldToken == nil {entity.isEnabled = false;entity.model=nil}
            geometry = nil; ready = false
        }
        pending = (input, next.settings, metrics)
        startWorker()
    }
    private func startWorker() {
        guard worker == nil, pending != nil else { return }
        worker = Task {
            while let next = pending, !Task.isCancelled {
                pending = nil
                await PlaybackFlowTrace.$parent.withValue(next.0.flow){await update(next.0, settings: next.1, metrics: next.2, ticket: generation)}
            }
            worker = nil
            startWorker()
        }
    }
    func stop() {
        blockedHoldInput=nil;blockedHoldFlow=nil
        releaseHeldPresentation(reason:2,hide:true)
        guard key != nil || pending != nil || worker != nil || ready else { return }
        generation += 1; pending = nil; key = nil; worker?.cancel()
        epoch = nil; geometry = nil; entity.model = nil; entity.isEnabled = false; ready = false
    }
    private func update(_ input: Input, settings: VRSettings, metrics: PlaybackMetrics?, ticket: Int) async {
        flowWorkerStarted=ready ? ProcessInfo.processInfo.systemUptime:nil
        let flow=PlaybackFlowTrace.begin(.worker,parent:input.flow,a:Int64(ticket));defer{observeFlowStall();flowWorkerStarted=nil;PlaybackFlowTrace.end(flow,.worker,a:Task.isCancelled ? 1:0,b:Int64(generation))}
        do {
            if material == nil {
                guard let url = materialURL ?? Bundle.main.url(forResource: "StereoscopicMaterial", withExtension: "usda") else { throw CocoaError(.fileReadNoSuchFile) }
                let trace=PlaybackFlowTrace.begin(.material);defer{PlaybackFlowTrace.end(trace,.material)}
                material = try await ShaderGraphMaterial(named: "/Root/Material", from: url)
            }
            try Task.checkCancellation()
            guard ticket == generation else { PlaybackFlowTrace.mark(.discard,a:Int64(ticket),b:Int64(generation)); metrics?.mark(.stale); return }
            if case let .frame(frame) = input, useGPU, !gpuFailed,
               settings.projection == .equidistantFisheye180, FisheyeTextureEpoch.supports(frame), let queue {
                do {
                    try await updateGPU(frame, settings: settings, metrics: metrics, ticket: ticket, queue: queue)
                    return
                } catch is CancellationError { throw CancellationError() }
                catch {
                    guard ticket == generation else { PlaybackFlowTrace.mark(.discard,a:Int64(ticket),b:Int64(generation)); metrics?.mark(.stale); return }
                    // A failed GPU epoch is not reused. Retain the established image path for this configuration.
                    PlaybackFlowTrace.mark(.failure,a:1)
                    epoch = nil; gpuFailed = true
                    if heldToken == nil {entity.model=nil}
                    geometry = nil
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
        } catch is CancellationError { PlaybackFlowTrace.mark(.discard,a:1);metrics?.mark(.stale) }
        catch {
            guard ticket == generation else { return }
            releaseHeldPresentation(reason:4,hide:true)
            entity.isEnabled = false; ready = false; self.error = VistaL10n.text("無法建立 VR 投影。請返回視窗重試。")
        }
    }
    private func updateGPU(_ frame: DecodedVideoFrame, settings: VRSettings, metrics: PlaybackMetrics?, ticket: Int, queue: any MTLCommandQueue) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        let active: FisheyeTextureEpoch
        let needsBind = epoch == nil
        if let epoch { active = epoch }
        else {
            let trace=PlaybackFlowTrace.begin(.gpuEpoch);defer{PlaybackFlowTrace.end(trace,.gpuEpoch)}
            active = try await FisheyeTextureEpoch(width: CVPixelBufferGetWidth(frame.pixel), height: CVPixelBufferGetHeight(frame.pixel), layout: settings.layout)
            try Task.checkCancellation()
            guard ticket == generation else { PlaybackFlowTrace.mark(.discard,a:Int64(ticket),b:Int64(generation)); metrics?.mark(.stale); return }
            epoch = active
            #if DEBUG
            reviewEpochCount += 1
            #endif
        }
        guard let command = queue.makeCommandBuffer() else { throw CocoaError(.coderInvalidValue) }
        try PlaybackFlowTrace.measure(.gpuEncode,parent:frame.flow){try active.encode(frame.pixel, context: context, command: command)}
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { completed in
                PlaybackFlowTrace.mark(.gpuComplete,parent:frame.flow,a:Int64(completed.status.rawValue))
                if completed.gpuEndTime>=completed.gpuStartTime,completed.gpuStartTime>0 {
                    PlaybackFlowTrace.mark(.gpuTimes,parent:frame.flow,a:Int64(completed.gpuStartTime*1e6),b:Int64(completed.gpuEndTime*1e6))
                }
                continuation.resume()
            }
            PlaybackFlowTrace.measure(.gpuCommit,parent:frame.flow){command.commit()}
        }
        PlaybackFlowTrace.mark(.gpuResume,parent:frame.flow)
        // Source planes and the epoch stay alive until GPU completion, including after stop/cancellation.
        withExtendedLifetime((frame, active)) {}
        try Task.checkCancellation()
        guard ticket == generation else { PlaybackFlowTrace.mark(.discard,a:Int64(ticket),b:Int64(generation)); metrics?.mark(.stale); return }
        guard command.status == .completed else { throw CocoaError(.coderInvalidValue) }
        if needsBind || entity.model == nil {
            try bind(active.resources, settings: settings, width: Int(active.crops[0].width), height: Int(active.crops[0].height))
        }
        let textureSeconds = ProcessInfo.processInfo.systemUptime - start
        metrics?.record(.texture, seconds: textureSeconds)
        logValues[.textureMS, default: 0] += textureSeconds * 1000
        logValues[.textureCount, default: 0] += 1
        lastOutputBytes=active.crops.reduce(0){$0+Int($1.width)*Int($1.height)*4}
        outputWidth=Int(active.crops[0].width);outputHeight=Int(active.crops[0].height);outputCount=active.crops.count
        route = VistaL10n.text("SDR GPU 重用貼圖")
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
        let leftTexture:TextureResource
        do {let trace=PlaybackFlowTrace.begin(.textureLeft);defer{PlaybackFlowTrace.end(trace,.textureLeft)};leftTexture=try await TextureResource(image:left,options:.init(semantic:.color))}
        let rightTexture:TextureResource
        do {let trace=PlaybackFlowTrace.begin(.textureRight,a:settings.layout == .mono ? 1:0);defer{PlaybackFlowTrace.end(trace,.textureRight)};rightTexture=settings.layout == .mono ? leftTexture:try await TextureResource(image:right,options:.init(semantic:.color))}
        let textureSeconds = ProcessInfo.processInfo.systemUptime - start
        metrics?.record(.texture, seconds: textureSeconds)
        logValues[.textureMS, default: 0] += textureSeconds * 1000
        logValues[.textureCount, default: 0] += 1
        try Task.checkCancellation()
        guard ticket == generation else { PlaybackFlowTrace.mark(.discard,a:Int64(ticket),b:Int64(generation)); metrics?.mark(.stale); return }
        try bind([leftTexture, rightTexture], settings: settings, width: left.width, height: left.height)
        lastOutputBytes=left.width*left.height*4*(settings.layout == .mono ? 1:2)
        outputWidth=left.width;outputHeight=left.height;outputCount=settings.layout == .mono ? 1:2
        route = gpuFailed ? VistaL10n.text("原雙貼圖回退（GPU 更新失敗）") : VistaL10n.text("原雙貼圖")
        finish(settings: settings, metrics: metrics)
        #if DEBUG
        reviewLegacyFrames += 1
        #endif
    }
    private func bind(_ resources: [TextureResource], settings: VRSettings, width: Int, height: Int) throws {
        let trace=PlaybackFlowTrace.begin(.bind);defer{PlaybackFlowTrace.end(trace,.bind)}
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
        lastOwnedFlow=PlaybackFlowTrace.parent.id
        recordHoldOutputEstimate()
        releaseHeldPresentation(reason:1,hide:false,newFlow:lastOwnedFlow)
        blockedHoldInput=nil;blockedHoldFlow=nil
        entity.isEnabled = true; ready = true; error = nil; metrics?.mark(.uploaded)
        PlaybackFlowTrace.mark(.entity,a:Int64(generation))
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
