import Foundation
import Observation
import simd

/// Ephemeral rigid pose; selected components may enter bounded diagnostics, never per-file preferences.
public struct VRInitialPose: Sendable {
    public let position: SIMD3<Float>
    public let orientation: simd_quatf
    public private(set) var sampleTiming:VRPoseSampleTiming?
    public func withSampleTiming(_ timing:VRPoseSampleTiming)->Self {var copy=self;copy.sampleTiming=timing;return copy}
    public init?(matrix: simd_float4x4) {
        let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
        guard columns.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }),
              abs(columns[0].w) < 0.001, abs(columns[1].w) < 0.001, abs(columns[2].w) < 0.001,
              abs(columns[3].w - 1) < 0.001 else { return nil }
        let axes = columns.prefix(3).map { SIMD3($0.x, $0.y, $0.z) }
        guard axes.allSatisfy({ abs(simd_length_squared($0) - 1) < 0.01 }),
              abs(simd_dot(axes[0], axes[1])) < 0.01, abs(simd_dot(axes[0], axes[2])) < 0.01,
              abs(simd_dot(axes[1], axes[2])) < 0.01 else { return nil }
        let rotation = simd_float3x3(columns: (axes[0], axes[1], axes[2]))
        guard simd_determinant(rotation) > 0.99 else { return nil }
        position = SIMD3(columns[3].x, columns[3].y, columns[3].z)
        orientation = simd_normalize(simd_quatf(rotation))
    }
    public static func manualRotation(yaw: Double, pitch: Double, roll: Double) -> simd_quatf {
        func radians(_ value: Double) -> Float {
            value.isFinite ? Float(value.truncatingRemainder(dividingBy: 360) * .pi / 180) : 0
        }
        return simd_quatf(angle: radians(yaw), axis: [0,1,0])
            * simd_quatf(angle: radians(pitch), axis: [1,0,0])
            * simd_quatf(angle: radians(roll), axis: [0,0,1])
    }
}
/// Anonymous low-frequency stages. No world pose, gaze point, or frame contents.
public enum VRRecenterPhase:Int,Sendable {
    case recognizer=1,resolved,gates,requested,captureBegin,providerBegin,runBegin,runEnd,providerEnd,captureEnd,offsetsCleared,placementApplied,moveCleanup,recognizerCancelled,backgroundActionReturned,targetSnapshot,rotationSnapshot,sampleTiming,rotationTerminated
}
public struct VRRecenterTrace:Sendable {
    public let id:UInt64,origin:Int,generation:Int
    private let started:Double
    public func withGeneration(_ value:Int)->Self {Self(id:id,origin:origin,generation:value,started:started)}
    public func record(_ phase:VRRecenterPhase,outcome:Int=0,fields:[LifecycleField:Double]=[:]) {
        var values:[LifecycleField:Double]=[.request:Double(id),.operation:Double(origin),.generation:Double(generation),.phase:Double(phase.rawValue),.outcome:Double(outcome),.durationMS:(ProcessInfo.processInfo.systemUptime-started)*1000]
        values.merge(fields){_,new in new}
        LifecycleDiagnostics.shared.record(.videoRecenter,values)
    }
    @MainActor public static func begin(origin:Int,generation:Int)->Self {
        VRRecenterSequence.next &+= 1
        return Self(id:VRRecenterSequence.next,origin:origin,generation:generation,started:ProcessInfo.processInfo.systemUptime)
    }
}
@MainActor private enum VRRecenterSequence {static var next:UInt64=0}

public protocol VRInitialPoseProvider: Sendable {
    /// Return one valid pose or nil. Implementations must stop acquisition when done/cancelled.
    func sample() async throws -> VRInitialPose?
    func sample(trace:VRRecenterTrace?) async throws -> VRInitialPose?
}
public extension VRInitialPoseProvider {
    func sample(trace:VRRecenterTrace?) async throws -> VRInitialPose? {try await sample()}
}

/// Comfort offset evaluated at initial capture and explicit video recenter. Head elevation is not body posture.
public enum VRInitialViewCompensation {
    /// A test hypothesis, not an Apple posture threshold or a validated ergonomic boundary.
    public static let upwardThresholdDegrees: Float = 30
    public static let upwardPitchDegrees: Double = 15

    public static func pitchDegrees(for pose: VRInitialPose) -> Double {
        let forward = pose.orientation.act(SIMD3<Float>(0, 0, -1))
        let threshold = sin(upwardThresholdDegrees * .pi / 180)
        // Include the exact boundary despite Float quaternion roundoff.
        return forward.y >= threshold - 0.000001 ? upwardPitchDegrees : 0
    }
}

@MainActor @Observable public final class VRViewCalibration {
    public enum Status: String, Sendable { case idle, capturing, ready, unavailable }
    public private(set) var status: Status = .idle
    public private(set) var pose: VRInitialPose?
    public private(set) var automaticPitchDegrees: Double = 0
    /// Independent controller basis: initial load or an explicitly accepted fresh controller reset.
    public private(set) var controllerPose: VRInitialPose?
    public private(set) var controllerRevision = 0
    public var initialControllerTiltDegrees: Float {controllerPose.map(VRControllerTiltTrial.degrees(for:)) ?? 0}
    public var initialControllerYawDegrees: Float {controllerPose.map {VRControllerSideYaw.referenceYaw($0.orientation)} ?? 0}
    /// Production reset samples must have a recent, valid host query interval. Sensor age is unavailable.
    @discardableResult public func acceptControllerReset(_ sample:VRInitialPose?,at now:Double)->Bool {
        guard let sample,let age=sample.sampleTiming?.elapsedSinceQueryMS(at:now),age<=300 else{return false}
        controllerPose=sample;controllerRevision += 1
        return true
    }
    /// Rendering and readouts share one offset in the raw captured frame. Never persist this copy.
    public func videoSettings(for manual: VRSettings) -> VRSettings {
        var total = manual
        total.pitchDegrees += automaticPitchDegrees
        return total
    }
    /// Zero this file's entire direction offset without taking another pose sample.
    public func resetDirection(_ manual: inout VRSettings) {
        generation += 1
        automaticPitchDegrees = 0
        manual.yawDegrees = 0; manual.pitchDegrees = 0; manual.rollDegrees = 0
    }
    /// Invalidates an in-flight manual edit after file, pose, or reset changes.
    public var directionGeneration: Int { generation }
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var requestedTrace:VRRecenterTrace?
    public struct CaptureResult:Sendable {
        public let generation:Int;public let trace:VRRecenterTrace
        public let poseDeltaDegrees:Double?;public let sampleTiming:VRPoseSampleTiming?
    }
    public private(set) var lastCapture:CaptureResult?
    public func isCurrent(_ result:CaptureResult)->Bool {result.generation==generation && status == .ready}
    public init() {}
    public func resetForNewFile() {
        generation += 1; pose = nil; automaticPitchDegrees = 0; controllerPose=nil;controllerRevision += 1
        requestedTrace=nil;lastCapture=nil
        status = .idle
    }
    public func requestRecenter(trace:VRRecenterTrace?=nil) {
        generation += 1; status = .idle
        requestedTrace=(trace ?? VRRecenterTrace.begin(origin:2,generation:generation)).withGeneration(generation)
        requestedTrace?.record(.requested)
    }
    /// Protect edits both before acquisition starts and while asynchronous preparation can reset them.
    public func allowsManualDirection(isLoading: Bool) -> Bool {
        !isLoading && (status == .ready || status == .unavailable)
    }
    public func cancel() {
        generation += 1
        if status == .capturing { status = pose == nil ? .idle : .ready }
    }
    @discardableResult public func capture(using provider:any VRInitialPoseProvider) async ->Bool {
        await captureResult(using:provider) != nil
    }
    public func captureResult(using provider:any VRInitialPoseProvider) async ->CaptureResult? {
        let request=requestedTrace ?? VRRecenterTrace.begin(origin:0,generation:generation)
        guard status == .idle else {request.record(.captureEnd,outcome:5);return nil}
        generation += 1;let ticket=generation
        let trace=request.withGeneration(ticket)
        status = .capturing;trace.record(.captureBegin)
        do {
            let result=try await provider.sample(trace:trace)
            try Task.checkCancellation()
            guard ticket==generation else {trace.record(.captureEnd,outcome:4);return nil}
            if let result {
                if let timing=result.sampleTiming {
                    guard let age=timing.elapsedSinceQueryMS(at:ProcessInfo.processInfo.systemUptime),age<=300 else {
                        status = .unavailable;trace.record(.captureEnd,outcome:6);return nil
                    }
                }
                let poseDelta=VRRecenterRotationMath.angleDegrees(pose?.orientation,result.orientation)
                pose=result
                if requestedTrace == nil && controllerPose == nil {controllerPose=result;controllerRevision += 1}
                automaticPitchDegrees=VRInitialViewCompensation.pitchDegrees(for:result)
                status = .ready
                let accepted=CaptureResult(generation:ticket,trace:trace,poseDeltaDegrees:poseDelta,sampleTiming:result.sampleTiming)
                lastCapture=accepted
                var fields:[LifecycleField:Double]=[.recenterKnownMask:poseDelta == nil ? 0:2,.recenterSensorAgeKnown:0]
                if let poseDelta {fields[.recenterPoseDeltaDegrees]=poseDelta}
                if let age=result.sampleTiming?.elapsedSinceQueryMS(at:ProcessInfo.processInfo.systemUptime) {fields[.recenterQueryToCaptureMS]=age}
                trace.record(.captureEnd,fields:fields)
                return accepted
            }
            status = .unavailable;trace.record(.captureEnd,outcome:1)
        } catch {
            guard ticket==generation else {trace.record(.captureEnd,outcome:4);return nil}
            status = Task.isCancelled ? (pose == nil ? .idle:.ready):.unavailable
            trace.record(.captureEnd,outcome:Task.isCancelled ? 3:2)
        }
        return nil
    }
}

/// Host-call timing only. DeviceAnchor has no sensor timestamp in the deployed SDK.
public struct VRPoseSampleTiming:Sendable {
    public let queryStarted:Double,queryFinished:Double
    public init(queryStarted:Double,queryFinished:Double){self.queryStarted=queryStarted;self.queryFinished=queryFinished}
    public var queryMS:Double? {Self.intervalMS(queryStarted,queryFinished)}
    public func elapsedSinceQueryMS(at now:Double)->Double? {guard queryMS != nil else{return nil};return Self.intervalMS(queryFinished,now)}
    private static func intervalMS(_ a:Double,_ b:Double)->Double? {guard a.isFinite,b.isFinite,b>=a else{return nil};return (b-a)*1000}
}
public enum VRRecenterRotationMath {
    public static func normalized(_ q:simd_quatf?)->simd_quatf? {
        guard let q,q.vector.x.isFinite,q.vector.y.isFinite,q.vector.z.isFinite,q.vector.w.isFinite else{return nil}
        let length=simd_length(q.vector);guard length.isFinite,length>0.000001 else{return nil}
        return simd_quatf(vector:q.vector/length)
    }
    public static func angleDegrees(_ a:simd_quatf?,_ b:simd_quatf?)->Double? {
        guard let a=normalized(a),let b=normalized(b) else{return nil}
        // Double dot avoids Float acos magnification near identical rotations; q and -q are equivalent.
        let av=a.vector,bv=b.vector
        let dot=abs(Double(av.x)*Double(bv.x)+Double(av.y)*Double(bv.y)+Double(av.z)*Double(bv.z)+Double(av.w)*Double(bv.w))
        let an=sqrt(Double(simd_length_squared(SIMD4<Double>(Double(av.x),Double(av.y),Double(av.z),Double(av.w)))))
        let bn=sqrt(Double(simd_length_squared(SIMD4<Double>(Double(bv.x),Double(bv.y),Double(bv.z),Double(bv.w)))))
        return 2*acos(min(1,max(0,dot/(an*bn))))*180 / .pi
    }
    public static func total(parent:simd_quatf?,child:simd_quatf?)->simd_quatf? {
        guard let p=normalized(parent),let c=normalized(child) else{return nil};return normalized(p*c)
    }
}
/// Weak identities only: epochs are local anonymous labels, never addresses or entity ownership.
@MainActor public final class VRRecenterReferenceIdentity {
    private weak var reference:AnyObject?,placement:AnyObject?
    private var wasInScene=false,initialized=false
    private var epoch=0
    public init(){}
    public func sample(reference:AnyObject?,placement:AnyObject,inScene:Bool)->Int {
        if !initialized || self.reference !== reference || self.placement !== placement || wasInScene != inScene {
            epoch += 1;initialized=true
        }
        self.reference=reference;self.placement=placement;wasInScene=inScene
        return epoch
    }
}
/// Rotations in placement's actual parent coordinates, not world coordinates. Never encoded.
public struct VRRecenterRotationSnapshot {
    public let route:Int,parent:simd_quatf?,child:simd_quatf?,parentMatches:Bool
    public let referenceEpoch:Int,inScene:Bool,hasReference:Bool,enabled:Bool
    public init(route:Int,parent:simd_quatf?,child:simd_quatf?,parentMatches:Bool,
                referenceEpoch:Int,inScene:Bool,hasReference:Bool,enabled:Bool){
        self.route=route;self.parent=parent;self.child=child;self.parentMatches=parentMatches
        self.referenceEpoch=referenceEpoch;self.inScene=inScene;self.hasReference=hasReference;self.enabled=enabled
    }
    /// bits: scene, reference, direct child, enabled hierarchy, valid placement rotation, valid child rotation.
    public var validity:Int {
        (inScene ? 1:0) | (hasReference ? 2:0) | (parentMatches ? 4:0) | (enabled ? 8:0)
        | (VRRecenterRotationMath.normalized(parent) != nil ? 16:0)
        | (VRRecenterRotationMath.normalized(child) != nil ? 32:0)
    }
    /// First unavailable condition; validity retains all conditions for independent analysis.
    public var unavailable:Int {
        if !inScene{return 1};if !hasReference{return 2};if !parentMatches{return 3};if !enabled{return 4}
        if VRRecenterRotationMath.normalized(parent)==nil{return 5}
        if VRRecenterRotationMath.normalized(child)==nil{return 6};return 0
    }
    public var total:simd_quatf? {unavailable==0 && route>=0 ? VRRecenterRotationMath.total(parent:parent,child:child):nil}
    public var diagnosticFields:[LifecycleField:Double] {
        [.recenterReferenceEpoch:Double(referenceEpoch),.recenterValidity:Double(validity),.recenterUnavailable:Double(unavailable),.recenterCoordinateDomain:1]
    }
}
public struct VRRecenterObservationScope:Equatable {
    public let request:Int,owner:ObjectIdentifier?,playbackGeneration:UUID?
    public init(request:Int,owner:ObjectIdentifier?,playbackGeneration:UUID?){self.request=request;self.owner=owner;self.playbackGeneration=playbackGeneration}
}
/// One bounded diagnostic request; mutations do not publish SwiftUI/Observation changes.
@MainActor public final class VRRecenterRotationObservation {
    private struct Pending {
        var trace:VRRecenterTrace;let scope:VRRecenterObservationScope,baseline:VRRecenterRotationSnapshot,offsetBefore:simd_quatf,started:Double
        var accepted:VRViewCalibration.CaptureResult?,offsetAfter:simd_quatf?,acceptedAt:Double?,firstObserved=false,placementObserved=false
    }
    private var pending:Pending?
    public var isPending:Bool {pending != nil}
    public init(){}
    public func begin(trace:VRRecenterTrace,scope:VRRecenterObservationScope,baseline:VRRecenterRotationSnapshot,offsetBefore:simd_quatf,now:Double) {
        cancel(reason:1)
        pending=Pending(trace:trace,scope:scope,baseline:baseline,offsetBefore:offsetBefore,started:now)
        var baselineFields=baseline.diagnosticFields
        baselineFields.merge([.scope:0,.recenterRoute:Double(baseline.route),.recenterBaselineRoute:Double(baseline.route),.recenterParentMatches:baseline.parentMatches ? 1:0,.recenterKnownMask:0,.recenterSensorAgeKnown:0]){_,new in new}
        trace.record(.rotationSnapshot,fields:baselineFields)
    }
    public func accept(_ result:VRViewCalibration.CaptureResult,scope:VRRecenterObservationScope,offsetAfter:simd_quatf,now:Double) {
        guard var p=pending,p.scope==scope,p.trace.id==result.trace.id else{return}
        p.trace=result.trace;p.accepted=result;p.offsetAfter=offsetAfter;p.acceptedAt=now;pending=p
    }
    /// source: 1 offsets cleared, 2 placement assignment, 3 existing submit return, 4 existing one-second observer.
    public func observe(scope:VRRecenterObservationScope,generation:Int,active:Bool,snapshot:VRRecenterRotationSnapshot,acceptedPose:simd_quatf?,now:Double,source:Int) {
        guard var p=pending else{return}
        guard p.scope==scope else{cancel(reason:2);return}
        guard active else{cancel(reason:3);return}
        guard let accepted=p.accepted,let offsetAfter=p.offsetAfter,let acceptedAt=p.acceptedAt else {
            if now.isFinite,now-p.started>=5 {cancel(reason:9)}
            return
        }
        guard accepted.generation==generation else{cancel(reason:4);return}
        var fields:[LifecycleField:Double]=[.scope:Double(source),.recenterRoute:Double(snapshot.route),.recenterBaselineRoute:Double(p.baseline.route),.recenterParentMatches:snapshot.parentMatches ? 1:0,.recenterSensorAgeKnown:0]
        fields.merge(snapshot.diagnosticFields){_,new in new}
        fields[.recenterBaselineReferenceEpoch]=Double(p.baseline.referenceEpoch)
        fields[.recenterBaselineValidity]=Double(p.baseline.validity)
        fields[.recenterBaselineUnavailable]=Double(p.baseline.unavailable)
        var known=0
        func put(_ field:LifecycleField,_ value:Double?,bit:Int){if let value,value.isFinite{fields[field]=value;known |= bit}}
        let sameRoute=p.baseline.route>=0 && snapshot.route==p.baseline.route
        let sameReference=p.baseline.referenceEpoch==snapshot.referenceEpoch
        let comparable=sameRoute && sameReference && p.baseline.unavailable==0 && snapshot.unavailable==0
        let expected=VRRecenterRotationMath.total(parent:acceptedPose,child:offsetAfter)
        put(.recenterTotalDeltaDegrees,comparable ? VRRecenterRotationMath.angleDegrees(p.baseline.total,snapshot.total):nil,bit:1)
        put(.recenterPoseDeltaDegrees,accepted.poseDeltaDegrees,bit:2)
        put(.recenterOffsetBeforeDegrees,VRRecenterRotationMath.angleDegrees(simd_quatf(real:1,imag:.zero),p.offsetBefore),bit:4)
        put(.recenterOffsetAfterDegrees,VRRecenterRotationMath.angleDegrees(simd_quatf(real:1,imag:.zero),offsetAfter),bit:8)
        put(.recenterOffsetDeltaDegrees,VRRecenterRotationMath.angleDegrees(p.offsetBefore,offsetAfter),bit:16)
        put(.recenterExpectedErrorDegrees,comparable ? VRRecenterRotationMath.angleDegrees(snapshot.total,expected):nil,bit:32)
        put(.recenterParentErrorDegrees,comparable ? VRRecenterRotationMath.angleDegrees(snapshot.parent,acceptedPose):nil,bit:64)
        if let age=accepted.sampleTiming?.elapsedSinceQueryMS(at:now){fields[.recenterQueryToObservationMS]=age}
        fields[.recenterKnownMask]=Double(known)
        if !sameRoute {p.trace.record(.rotationTerminated,outcome:5,fields:fields);pending=nil;return}
        if p.baseline.unavailable != 0 || snapshot.unavailable != 0 {p.trace.record(.rotationTerminated,outcome:11,fields:fields);pending=nil;return}
        if !sameReference {p.trace.record(.rotationTerminated,outcome:10,fields:fields);pending=nil;return}
        if expected==nil {p.trace.record(.rotationTerminated,outcome:12,fields:fields);pending=nil;return}
        // This tests actual software transforms. It is not a renderer/compositor presentation acknowledgement.
        let settled=fields[.recenterExpectedErrorDegrees].map{$0<=0.05} == true && fields[.recenterParentErrorDegrees].map{$0<=0.05} == true
        if settled {p.trace.record(.rotationSnapshot,outcome:1,fields:fields);pending=nil;return}
        if now.isFinite,now-acceptedAt>=2 {p.trace.record(.rotationTerminated,outcome:6,fields:fields);pending=nil;return}
        if !p.firstObserved || (source==2 && !p.placementObserved) {
            p.trace.record(.rotationSnapshot,fields:fields);p.firstObserved=true
            if source==2 {p.placementObserved=true}
        }
        pending=p
    }
    public func cancel(reason:Int,scope:VRRecenterObservationScope?=nil) {
        guard let p=pending,scope==nil || scope==p.scope else{return}
        p.trace.record(.rotationTerminated,outcome:reason);pending=nil
    }
}

/// Ephemeral controller displacement in the frozen viewing coordinate system.
public enum VRControllerPlacement {
    public static let legacyHeightOrigin = SIMD3<Float>(0.65, -0.18, -1.5)
    public static let initialYaw:Float = 45 * .pi/180
    public static let distanceScale:Float = 2 / 3
    public static let originalOrigin:SIMD3<Float> = {
        let radius=hypot(legacyHeightOrigin.x,legacyHeightOrigin.z)
        return SIMD3(radius*sin(initialYaw),legacyHeightOrigin.y,-radius*cos(initialYaw))
    }()
    public static let origin = originalOrigin * distanceScale
    public static let maximumYaw:Float = 175 * .pi/180
    public static func constrained(_ offset: SIMD3<Float>, previous:SIMD3<Float>? = nil) -> SIMD3<Float> {
        guard offset.x.isFinite, offset.y.isFinite, offset.z.isFinite else { return .zero }
        let point=origin+offset
        let radius=hypot(point.x,point.z)
        let prior=previous ?? origin
        var yaw=radius>0.05 ? atan2(point.x,-point.z):atan2(prior.x,-prior.z)
        if previous != nil {
            let priorYaw=atan2(prior.x,-prior.z)
            if yaw-priorYaw > .pi {yaw -= 2 * .pi}
            if yaw-priorYaw < -.pi {yaw += 2 * .pi}
        }
        yaw=min(max(yaw,-maximumYaw),maximumYaw)
        let distance=min(max(radius,1),2.2)
        return SIMD3(distance*sin(yaw),min(max(point.y,-0.83),0.67),-distance*cos(yaw))-origin
    }
}

/// Explicit app-owned targets. OS gaze tolerance remains system-controlled.
public enum VRControllerHit {
    public static let buttonDiameter:CGFloat=32
    public static let thumbDiameter:CGFloat=20
    public static let thumbHitDiameter:CGFloat=32
    public static let trackHeight:CGFloat=4
    public static let trackHitHeight:CGFloat=12
}

/// One gesture owns both thumb and track. Only its caller commits on release.
public struct VRProgressDragState:Sendable {
    private var origin:Double?
    private var travel:Double=0
    public var isActive:Bool {origin != nil}
    public init() {}
    public static func fraction(_ value:Double,in range:ClosedRange<Double>)->Double {
        guard value.isFinite,range.lowerBound.isFinite,range.upperBound.isFinite,
              range.upperBound>range.lowerBound else{return 0}
        return min(max((value-range.lowerBound)/(range.upperBound-range.lowerBound),0),1)
    }
    public mutating func update(startX:Double,startY:Double,translation:Double,width:Double,value:Double,in range:ClosedRange<Double>,startOnThumb:Bool?=nil)->Double? {
        let diameter=Double(VRControllerHit.thumbHitDiameter),radius=diameter/2
        guard startX.isFinite,startY.isFinite,translation.isFinite,width.isFinite,width>diameter,
              value.isFinite,range.lowerBound.isFinite,range.upperBound.isFinite,range.upperBound>range.lowerBound else{return nil}
        if origin == nil {
            travel=width-diameter
            let fraction=Self.fraction(value,in:range),center=radius+fraction*travel
            // A thumb grab preserves its offset; a track press previews that location.
            let inThumb=pow(startX-center,2)+pow(startY-radius,2)<=radius*radius
            origin=(startOnThumb ?? inThumb) ? fraction:min(max((startX-radius)/travel,0),1)
        }
        let fraction=min(max(origin!+translation/travel,0),1)
        return range.lowerBound+fraction*(range.upperBound-range.lowerBound)
    }
    public mutating func cancel(){origin=nil;travel=0}
}

/// Stable progress coordinates. Track keeps the original capsule outside the thumb horizontal bounding interval.
public enum VRProgressHitRegion {
    public static func thumb(x:Double,y:Double,width:Double,fraction:Double)->Bool {
        let r=Double(VRControllerHit.thumbHitDiameter)/2,t=max(width-2*r,0)
        return pow(x-(r+min(max(fraction,0),1)*t),2)+pow(y-r,2)<=r*r
    }
    public static func track(x:Double,y:Double,width:Double,fraction:Double)->Bool {
        let r=Double(VRControllerHit.thumbHitDiameter)/2,h=Double(VRControllerHit.trackHitHeight)/2
        let halfWidth=max((width-2*r)/2,0),corner=min(h,halfWidth)
        let dx=max(abs(x-width/2)-(halfWidth-corner),0),dy=max(abs(y-r)-(h-corner),0)
        let center=r+min(max(fraction,0),1)*max(width-2*r,0)
        return width>2*r && dx*dx+dy*dy<=corner*corner && abs(x-center)>=r
    }
}
/// Plain callback-owned state. No Observation/SwiftUI publication, positions, or input device data.
@MainActor public final class VRProgressInputSession {
    private static var nextID:UInt64=0,nextScope:UInt64=0
    private let scope:UInt64
    private var nextToken:UInt64=0
    public private(set) var token:UInt64?,route:Int?
    private var drag=VRProgressDragState(),request:UInt64=0,started:Double=0,initialValue:Double=0
    private var recording=false,lastContext=0
    public struct Update {public let value:Double,began:Bool,token:UInt64,request:UInt64}
    public init(){Self.nextScope &+= 1;scope=Self.nextScope}
    public var isActive:Bool {token != nil}
    public var requestID:UInt64 {request}
    private func record(_ phase:Int,reason:Int=0,context:Int,fields:[LifecycleField:Double]=[:]) {
        guard recording else{return}
        var values:[LifecycleField:Double]=[.request:Double(request),.session:Double(scope),.phase:Double(phase),.progressRoute:Double(route ?? 0),
            .progressReason:Double(reason),.progressState:Double(context),.durationMS:max(0,ProcessInfo.processInfo.systemUptime-started)*1000]
        values.merge(fields.filter{$0.value.isFinite}){_,new in new};LifecycleDiagnostics.shared.record(.progressInput,values)
    }
    /// token nil requests ownership; a different active surface cannot steal it.
    public func update(route:Int,token supplied:UInt64?,x:Double,y:Double,translation:Double,width:Double,value:Double,bounds:ClosedRange<Double>,context:Int)->Update? {
        let began=token==nil
        if began {
            guard supplied==nil else{return nil}
            nextToken &+= 1;token=nextToken;self.route=route;drag.cancel()
            Self.nextID &+= 1;request=Self.nextID;started=ProcessInfo.processInfo.systemUptime
            initialValue=value;recording=true;lastContext=context
            record(1,context:context)
        } else {
            guard supplied==token,self.route==route else {
                if supplied==nil {
                    Self.nextID &+= 1
                    let values:[LifecycleField:Double]=[.request:Double(Self.nextID),.parentRequest:Double(request),.session:Double(scope),.phase:1,.progressRoute:Double(route),.progressState:Double(context),.progressReason:7]
                    LifecycleDiagnostics.shared.record(.progressInput,values)
                    var terminal=values;terminal[.phase]=3;LifecycleDiagnostics.shared.record(.progressInput,terminal)
                }
                return nil
            }
        }
        lastContext=context
        guard context & 3 == 3 else{cancel(token:token,reason:context & 2 == 0 ? 5:2,context:context,value:value);return nil}
        guard let next=drag.update(startX:x,startY:y,translation:translation,width:width,value:value,in:bounds,startOnThumb:route==1) else {
            cancel(token:token,reason:6,context:context,value:value);return nil
        }
        return Update(value:next,began:began,token:token!,request:request)
    }
    @discardableResult public func finish(token supplied:UInt64?,context:Int,value:Double)->UInt64? {
        guard let supplied,supplied==token else{return nil}
        let id=request
        record(3,reason:0,context:context)
        token=nil;route=nil;drag.cancel();return id
    }
    @discardableResult public func cancel(token supplied:UInt64?,reason:Int,context:Int,value:Double)->Bool {
        guard let supplied,supplied==token else{return false}
        record(3,reason:reason,context:context,fields:[.progressDelta:value-initialValue])
        token=nil;route=nil;drag.cancel();return true
    }
    /// AX remains one synchronous edit; it cannot take ownership from a pinch.
    public func beginAX(value:Double,context:Int)->UInt64? {
        guard token==nil else{return nil}
        nextToken &+= 1;token=nextToken;route=3;Self.nextID &+= 1;request=Self.nextID
        started=ProcessInfo.processInfo.systemUptime;initialValue=value;recording=true
        record(1,context:context)
        guard context & 3 == 3 else{cancel(token:token,reason:context & 2 == 0 ? 5:2,context:context,value:value);return nil}
        return token
    }
    public static func gate(request:UInt64,mask:Int,editing:Bool) {
        guard request != 0 else{return}
        LifecycleDiagnostics.shared.record(.progressInput,[.request:Double(request),.phase:4,.progressCommitMask:Double(mask),.detail:editing ? 1:0])
    }
}
/// Surface cancellation is ticketed; no stale async cleanup may close a new gesture.
@MainActor public final class VRProgressSurfaceLifecycle {
    public private(set) var token:UInt64?
    public private(set) var rejected=false
    private var revision:UInt64=0,task:Task<Void,Never>?
    public init(){}
    public func prepare(_ cancel:(UInt64)->Void) {
        if task != nil {if let token{cancel(token)};self.token=nil}
        invalidate()
    }
    public func accepted(_ token:UInt64){self.token=token}
    public func reject(){rejected=true}
    public func ended()->UInt64? {invalidate();defer{token=nil;rejected=false};return token}
    public func cancel(_ action:(UInt64)->Void){invalidate();if let token{action(token)};token=nil;rejected=false}
    public func schedule(_ action:@escaping @MainActor (UInt64)->Void) {
        if token==nil {rejected=false;return};guard let token else{return};invalidate();let version=revision
        task=Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,!Task.isCancelled,self.revision==version,self.token==token else{return}
            self.task=nil;self.token=nil;action(token)
        }
    }
    private func invalidate(){revision &+= 1;task?.cancel();task=nil}
}
@MainActor public final class VRProgressVisibilityDiagnostics {
    private var last:Int?,count=0
    public init(){}
    public func record(mask:Int,reason:Int){
        guard last != mask else{return};last=mask
        count += 1
        LifecycleDiagnostics.shared.record(.progressVisibility,[.progressState:Double(mask),.progressReason:Double(reason),.epoch:Double(count)])
    }
}


/// A planar capsule: no beveled box edge or protruding fill layer.
public enum VRControllerHandle {
    public static let width:Float = 0.132
    public static let height:Float = 0.008
    public static let gap:Float = 0.012
    // Match the visible bounds; do not enlarge the indirect-input target.
    public static let collisionSize=SIMD3<Float>(width,height,0.008)
    public static var outline:[SIMD3<Float>] {
        let radius=height/2, center=(width-height)/2
        return (0..<34).map { index in
            let right=index<17
            let angle = Float(index % 17) * .pi/16 + (right ? -.pi/2 : .pi/2)
            return SIMD3((right ? center : -center)+radius*cos(angle),radius*sin(angle),0)
        }
    }
}

extension VRControllerPlacement {
    /// +Z faces the viewer. Keep the calibrated up axis, limit pitch, and preserve yaw at the poles.
    public static func facing(position:SIMD3<Float>, viewer:SIMD3<Float> = .zero,
                              previous:simd_quatf = simd_quatf())->simd_quatf {
        let direction=viewer-position
        guard direction.x.isFinite,direction.y.isFinite,direction.z.isFinite,
              simd_length_squared(direction)>0.0025 else{return previous}
        let horizontal=hypot(direction.x,direction.z)
        // Near vertical the horizontal direction is undefined: keep the previous stable attitude.
        guard horizontal>0.05 else{return previous}
        let yaw=atan2(direction.x,direction.z)
        let pitch = -min(max(atan2(direction.y,horizontal),-.pi/3),.pi/3)
        var result=simd_quatf(angle:yaw,axis:[0,1,0])*simd_quatf(angle:pitch,axis:[1,0,0])
        if simd_dot(result.vector,previous.vector)<0 {result=simd_quatf(vector:-result.vector)}
        return result
    }
}

/// Frame-rate independent, speed-limited controller turning; no position mutation.
extension VRControllerPlacement {
    public static func approaching(_ current:simd_quatf, target:simd_quatf, elapsed:Float)->simd_quatf {
        guard elapsed.isFinite,elapsed>0 else{return current}
        let dot=min(max(abs(simd_dot(current.vector,target.vector)),0),1)
        let angle=2*acos(dot)
        guard angle>0.00001 else{return target}
        let dt=min(elapsed,0.05)
        let a=current.act(SIMD3<Float>(0,0,1)),b=target.act(SIMD3<Float>(0,0,1))
        let yawDelta=atan2(sin(atan2(b.x,b.z)-atan2(a.x,a.z)),cos(atan2(b.x,b.z)-atan2(a.x,a.z)))
        let pitchDelta=atan2(b.y,hypot(b.x,b.z))-atan2(a.y,hypot(a.x,a.z))
        // Conservative arc-length bound also preserves the previous angular speed limit.
        let bound=max(angle,abs(yawDelta)+abs(pitchDelta))
        let amount=min(1-exp(-12*dt),(.pi*1.5*dt)/bound)
        return uprightInterpolation(current, target:target, fraction:amount)
    }
    /// Interpolate heading and pitch separately: quaternion slerp can introduce roll between upright endpoints.
    public static func uprightInterpolation(_ current:simd_quatf, target:simd_quatf, fraction:Float)->simd_quatf {
        guard fraction.isFinite else { return current }
        func angles(_ q:simd_quatf)->SIMD2<Float> {
            let front=q.act(SIMD3<Float>(0,0,1))
            let right=q.act(SIMD3<Float>(1,0,0))
            let yaw=hypot(front.x,front.z)>0.0001 ? atan2(front.x,front.z):atan2(-right.z,right.x)
            return SIMD2(yaw,-atan2(front.y,hypot(front.x,front.z)))
        }
        let a=angles(current),b=angles(target)
        let delta=atan2(sin(b.x-a.x),cos(b.x-a.x)),t=min(max(fraction,0),1)
        let pitch=min(max(a.y+(b.y-a.y)*t,-Float.pi/3),Float.pi/3)
        var q=simd_quatf(angle:a.x+delta*t,axis:[0,1,0])*simd_quatf(angle:pitch,axis:[1,0,0])
        if simd_dot(q.vector,current.vector)<0 {q=simd_quatf(vector:-q.vector)}
        return q
    }
    public static func grabbedPosition(pointer:SIMD3<Float>,localGrab:SIMD3<Float>,orientation:simd_quatf,previous:SIMD3<Float>? = nil)->SIMD3<Float> {
        origin+constrained(pointer-orientation.act(localGrab)-origin,previous:previous)
    }
}

/// Horizontal orbit keeps the existing heading; height uses the sampled viewer plus a fixed world-up offset.
/// The default is scaled about the available calibrated viewer (entry before calibration).
/// Keep horizontal placement; height is world-up relative to the captured viewer.
/// The shared head-elevation threshold selects a small height offset, not a body-posture label.
public enum VRControllerReference {
    public struct Placement:Sendable {
        public let reference:VRInitialPose
        public let viewer,originalTarget,target:SIMD3<Float>
        public let headForwardY:Float,thresholdTriggered:Bool,originalHeightOffset:Float
    }
    public static func placement(entry:VRInitialPose,vertical:VRInitialPose?=nil,horizontal:simd_quatf?=nil)->Placement? {
        let rawHeading=horizontal ?? entry.orientation
        let length=simd_length_squared(rawHeading.vector)
        guard length.isFinite,length>0.000001 else{return nil}
        let heading=simd_normalize(rawHeading)
        let forward=heading.act(SIMD3<Float>(0,0,-1))
        let right=heading.act(SIMD3<Float>(1,0,0))
        let yaw:Float
        if hypot(forward.x,forward.z)>0.001 {yaw=atan2(-forward.x,-forward.z)}
        else {yaw=atan2(-right.z,right.x)}
        let rotation=simd_quatf(angle:yaw,axis:[0,1,0])
        let viewer=vertical ?? entry
        let headForwardY=viewer.orientation.act(SIMD3<Float>(0,0,-1)).y
        let thresholdTriggered=VRInitialViewCompensation.pitchDegrees(for:viewer)>0
        var originalHeightOffset:Float=thresholdTriggered ? 0.12: -0.075
        var oldReference=entry.position
        oldReference.y=viewer.position.y+originalHeightOffset-VRControllerPlacement.originalOrigin.y
        var originalTarget=oldReference+rotation.act(VRControllerPlacement.originalOrigin)
        if thresholdTriggered {
            // 171 manual placements sat 4–10 degrees below head-forward. Preserve full distance,
            // keep the panel upright, and change only the high-elevation default position.
            let delta=originalTarget-viewer.position
            let horizontalLength=hypot(delta.x,delta.z)
            if horizontalLength>0.001 {
                let elevation=min(Float.pi/4,max(22 * Float.pi/180,asin(max(-1,min(1,headForwardY)))-8 * Float.pi/180))
                let distance=simd_length(delta)
                let flat=SIMD3<Float>(delta.x/horizontalLength,0,delta.z/horizontalLength)
                originalTarget=viewer.position+distance*(flat*cos(elevation)+SIMD3<Float>(0,1,0)*sin(elevation))
                originalHeightOffset=originalTarget.y-viewer.position.y
            }
        }
        let target=viewer.position+(originalTarget-viewer.position)*VRControllerPlacement.distanceScale
        let position=target-rotation.act(VRControllerPlacement.origin)
        var matrix=simd_float4x4(rotation);matrix.columns.3=SIMD4(position,1)
        guard let reference=VRInitialPose(matrix:matrix) else{return nil}
        return Placement(reference:reference,viewer:viewer.position,originalTarget:originalTarget,target:target,headForwardY:headForwardY,thresholdTriggered:thresholdTriggered,originalHeightOffset:originalHeightOffset)
    }
    public static func pose(entry:VRInitialPose,vertical:VRInitialPose?=nil,horizontal:simd_quatf?=nil)->VRInitialPose? {
        placement(entry:entry,vertical:vertical,horizontal:horizontal)?.reference
    }
}

/// Re-express an existing controller transform without moving it in scene coordinates.
public enum VRControllerContinuity {
 public static func rebased(local:simd_float4x4,oldReference:simd_float4x4,newReference:simd_float4x4)->simd_float4x4 {
  simd_inverse(newReference) * oldReference * local
 }
}

/// Orientation math in a captured viewer frame, independent of the placement parent's axes.
/// Placement limits remain in the video-heading frame; only the panel attitude uses this frame.
public enum VRControllerViewFrame {
    public static func localFrame(viewerWorld:simd_quatf,parentWorld:simd_quatf)->simd_quatf {
        func valid(_ q:simd_quatf)->simd_quatf {
            let length=simd_length_squared(q.vector)
            return length.isFinite && length>0.000001 ? simd_normalize(q):simd_quatf(angle:0,axis:[0,1,0])
        }
        return simd_normalize(valid(parentWorld).inverse * valid(viewerWorld))
    }
    public static func facing(position:SIMD3<Float>,viewer:SIMD3<Float>,frame:simd_quatf,previous:simd_quatf)->simd_quatf {
        frame * VRControllerPlacement.facing(position:frame.inverse.act(position-viewer),
            previous:frame.inverse * previous)
    }
    public static func approaching(_ current:simd_quatf,target:simd_quatf,frame:simd_quatf,elapsed:Float)->simd_quatf {
        frame * VRControllerPlacement.approaching(frame.inverse * current,target:frame.inverse * target,elapsed:elapsed)
    }
    public static func interpolating(_ current:simd_quatf,target:simd_quatf,frame:simd_quatf,fraction:Float)->simd_quatf {
        frame * VRControllerPlacement.uprightInterpolation(frame.inverse * current,target:frame.inverse * target,fraction:fraction)
    }
}

/// Reversible user-requested angle experiment; not a physical-vertical correction.
public enum VRControllerTiltTrial {
    public static func degrees(for pose:VRInitialPose)->Float {
        guard VRInitialViewCompensation.pitchDegrees(for:pose)>0 else{return 0}
        let y=pose.orientation.act(SIMD3<Float>(0,0,-1)).y
        return asin(min(1,max(-1,y))) * 180 / .pi
    }
    public static func rotation(_ degrees:Float)->simd_quatf {
        let safe=degrees.isFinite ? min(90,max(0,degrees)):0
        return simd_quatf(angle:safe * .pi/180,axis:[1,0,0])
    }
}

/// Yaw follows the viewer horizontally. A user-directed optional 175 tilt is applied after yaw.
/// Positive local X tips the panel top toward its front (+Z), i.e. toward the viewer.
/// Placement limits and height remain in the existing video-heading reference.
public enum VRControllerWorldFrame {
    public static func frame(parentWorld:simd_quatf)->simd_quatf {
        let length=simd_length_squared(parentWorld.vector)
        return length.isFinite && length>0.000001 ? simd_normalize(parentWorld).inverse:simd_quatf(angle:0,axis:[0,1,0])
    }
    private static func yawOnly(_ value:simd_quatf)->simd_quatf {
        let front=value.act(SIMD3<Float>(0,0,1)),right=value.act(SIMD3<Float>(1,0,0))
        let yaw=hypot(front.x,front.z)>0.0001 ? atan2(front.x,front.z):atan2(-right.z,right.x)
        var q=simd_quatf(angle:yaw,axis:[0,1,0])
        if simd_dot(q.vector,value.vector)<0 {q=simd_quatf(vector:-q.vector)}
        return q
    }
    /// Always project pitch/roll, even when heading movement is below its speed/deadband threshold.
    public static func upright(_ local:simd_quatf,frame:simd_quatf,forwardTiltDegrees:Float=0)->simd_quatf {
        simd_normalize(frame * yawOnly(frame.inverse * local) * VRControllerTiltTrial.rotation(forwardTiltDegrees))
    }
    public static func facing(position:SIMD3<Float>,viewer:SIMD3<Float>,frame:simd_quatf,previous:simd_quatf,forwardTiltDegrees:Float=0,yawOffsetDegrees:Float=0)->simd_quatf {
        let relative=frame.inverse.act(position-viewer)
        // Discard height only for attitude. Never modify the stored panel position.
        let uprightPrevious=yawOnly(frame.inverse * previous)
        return frame * VRControllerPlacement.facing(position:[relative.x,0,relative.z],previous:uprightPrevious) * VRControllerSideYaw.rotation(yawOffsetDegrees) * VRControllerTiltTrial.rotation(forwardTiltDegrees)
    }
    public static func approaching(_ current:simd_quatf,target:simd_quatf,frame:simd_quatf,elapsed:Float,forwardTiltDegrees:Float=0)->simd_quatf {
        upright(frame * VRControllerPlacement.approaching(yawOnly(frame.inverse * current),target:yawOnly(frame.inverse * target),elapsed:elapsed),frame:frame,forwardTiltDegrees:forwardTiltDegrees)
    }
    public static func interpolating(_ current:simd_quatf,target:simd_quatf,frame:simd_quatf,fraction:Float,forwardTiltDegrees:Float=0)->simd_quatf {
        upright(frame * VRControllerPlacement.uprightInterpolation(yawOnly(frame.inverse * current),target:yawOnly(frame.inverse * target),fraction:fraction),frame:frame,forwardTiltDegrees:forwardTiltDegrees)
    }
}

/// Called only after SwiftUI resolves exclusive background gestures; never recognizes timing.
public enum VRBackgroundInteraction {
    public enum Event:Equatable,Sendable {case tap(count:Int),longPress}
    public enum Action:Equatable,Sendable {case none,toggle,reset,recenterVideo}
    public static func action(event:Event,isBackground:Bool,active:Bool,testPattern:Bool,moving:Bool,scrubbing:Bool)->Action {
        guard isBackground,active,!testPattern,!moving,!scrubbing else{return .none}
        switch event {case .tap(count:1):return .toggle;case .tap(count:2):return .reset;case .longPress:return .recenterVideo;default:return .none}
    }
}

/// Display only: total direction offset relative to the captured video frame, never world heading.
public enum VRManualAngleDisplay {
    public static func normalized(_ degrees:Double)->Int {
        guard degrees.isFinite else{return 0}
        var n=degrees.truncatingRemainder(dividingBy:360)
        if n>180 {n-=360};if n < -180 {n+=360}
        return Int(n.rounded())
    }
    public static func text(_ degrees:Double)->String {
        let n=normalized(degrees);return n>0 ? "+\(n)°":"\(n)°"
    }
}

/// One short reset sample may finish only while its originating interaction is still current.
public struct VRControllerResetRequest:Sendable {
    private var sequence=0
    private var pending:Int?
    public init() {}
    public mutating func begin()->Int {sequence += 1;pending=sequence;return sequence}
    public mutating func cancel() {pending=nil}
    public func isCurrent(_ ticket:Int)->Bool {pending==ticket}
    public mutating func finish(_ ticket:Int)->Bool {
        guard pending==ticket else{return false}
        pending=nil;return true
    }
}


/// Unbounded 15-degree manual rotation; ruler edges are only a moving display window.
public enum VRManualAngleDrag {
    public static func value(start:Double,translation:Double,vertical:Bool)->Double {
        guard start.isFinite,translation.isFinite else{return start.isFinite ? start:0}
        let steps=(translation / (vertical ? 30:60) * (vertical ? -1:1)).rounded()
        let result=start+steps*15
        return result.isFinite ? result:start
    }
}

/// Owns only the edited manual axis, never the displayed automatic + manual total.
/// An invalidated physical drag stays invalid until its end; it cannot restart on the next file.
public struct VRManualAngleDragTransaction<Context:Equatable> {
    public let start:Double
    private let context:Context
    public private(set) var lastValue:Double
    public private(set) var invalidated=false
    public init(manual:Double,context:Context) {start=manual;lastValue=manual;self.context=context}
    public mutating func update(translation:Double,vertical:Bool,manual:Double,context:Context,enabled:Bool)->Double? {
        guard !invalidated,self.context==context,manual==lastValue else {invalidated=true;return nil}
        guard enabled else{return nil}
        let value=VRManualAngleDrag.value(start:start,translation:translation,vertical:vertical)
        lastValue=value
        return value
    }
    public mutating func invalidate() {invalidated=true}
    public func restoredValue(manual:Double,context:Context)->Double? {
        // Never overwrite an intervening button edit, reset, calibration, or new file.
        !invalidated && self.context==context && manual==lastValue ? start:nil
    }
}


/// Only the active pointer may release the shared background / move-handle exclusion.
public struct VRManualAngleDragOwnership {
    public private(set) var owner:UUID?
    public init() {}
    @discardableResult public mutating func acquire(_ token:UUID)->Bool {
        guard owner == nil || owner == token else{return false}
        owner=token;return true
    }
    @discardableResult public mutating func release(_ token:UUID)->Bool {
        guard owner == token else{return false}
        owner=nil;return true
    }
}

/// Diagnostic geometry only. Scene +Y is the system world-up proxy, not a
/// measured gravity vector or detected floor. No pose is changed by this type.
public struct VRControllerPoseGeometry {
 public let validity:Int
 public let position:SIMD3<Float>?
 public let scale:SIMD3<Float>?
 public let right:SIMD3<Float>?,up:SIMD3<Float>?,forward:SIMD3<Float>?
 public let quaternion:simd_quatf?
 public let horizontalDegrees:Double?,verticalDegrees:Double?
 public init(_ matrix:simd_float4x4?) {
  var flags=0
  var p:SIMD3<Float>?,s:SIMD3<Float>?,x:SIMD3<Float>?,y:SIMD3<Float>?,z:SIMD3<Float>?,q:simd_quatf?
  var horizontal:Double?,vertical:Double?
  if let m=matrix {
   flags |= 1
   let columns=[m.columns.0,m.columns.1,m.columns.2,m.columns.3]
   if columns.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite}) {
    flags |= 2;p=SIMD3(m.columns.3.x,m.columns.3.y,m.columns.3.z)
    if abs(m.columns.0.w)<0.0001 && abs(m.columns.1.w)<0.0001 && abs(m.columns.2.w)<0.0001 && abs(m.columns.3.w-1)<0.0001 {
     flags |= 4
     let axes=columns.prefix(3).map{SIMD3($0.x,$0.y,$0.z)}
     let lengths=axes.map{simd_length($0)}
     if lengths.allSatisfy({$0.isFinite && $0>0.000001}) {
      flags |= 8;s=SIMD3(lengths[0],lengths[1],lengths[2])
      let a=axes[0]/lengths[0],b=axes[1]/lengths[1],c=axes[2]/lengths[2]
      if abs(simd_dot(a,b))<0.0001 && abs(simd_dot(a,c))<0.0001 && abs(simd_dot(b,c))<0.0001 {
       flags |= 16
       let basis=simd_float3x3(columns:(a,b,c))
       if simd_determinant(basis)>0.999 {
        flags |= 32;x=a;y=b;z=c;q=simd_normalize(simd_quatf(basis))
        horizontal=asin(Double(min(1,max(-1,a.y))))*180 / .pi
        vertical=acos(Double(min(1,max(-1,b.y))))*180 / .pi
       }
      }
     }
    }
   }
  }
  validity=flags;position=p;scale=s;right=x;up=y;forward=z;quaternion=q
  horizontalDegrees=horizontal;verticalDegrees=vertical
 }
}

/// Non-observable scalar bookkeeping; never participates in gesture recognition.
public struct VRControllerPoseAudit {
 public struct Scope:Equatable {
  public let owner:ObjectIdentifier?,generation:UUID?,panel:ObjectIdentifier,parent:ObjectIdentifier?
  public init(owner:ObjectIdentifier?,generation:UUID?,panel:ObjectIdentifier,parent:ObjectIdentifier?){self.owner=owner;self.generation=generation;self.panel=panel;self.parent=parent}
 }
 public private(set) var epoch=0
 private var scope:Scope?,sequence=0,loadedMask=0,motion:Int?
 public init(){}
 private mutating func adopt(_ value:Scope){if scope != value {scope=value;epoch+=1;loadedMask=0;motion=nil}}
 private mutating func next()->Int {sequence+=1;return sequence}
 public mutating func loaded(_ value:Scope,state:Int)->Int? {
  adopt(value);guard (0...2).contains(state) else{return nil}
  let bit=1<<state;guard loadedMask & bit == 0 else{return nil};loadedMask |= bit;return next()
 }
 public mutating func beginMotion(_ value:Scope)->Int {adopt(value);let id=next();motion=id;return id}
 public mutating func endMotion(_ value:Scope,request:Int)->Bool {
  guard scope==value,motion==request else{return false};motion=nil;return true
 }
 public mutating func reset(_ value:Scope)->Int {adopt(value);motion=nil;return next()}
 public mutating func supersedeMotion(){motion=nil}
}

/// Fixed scalar summary; no logging or observation in the drag loop. Quaternion residuals
/// complement (and do not replace) actual terminal matrix/basis packets.
public struct VRControllerUprightAudit:Sendable {
    public private(set) var samples=0
    public private(set) var maximumBefore:Double?
    public private(set) var maximumAfter:Double?
    public private(set) var lastAfter:Double?
    public init() {}
    public mutating func observe(before:simd_quatf,after:simd_quatf) {
        func tilt(_ q:simd_quatf)->Double? {
            let length=simd_length_squared(q.vector)
            guard length.isFinite,length>0.000001 else{return nil}
            let up=simd_normalize(q).act(SIMD3<Float>(0,1,0))
            return Double(atan2(hypot(up.x,up.z),up.y))*180 / .pi
        }
        guard let a=tilt(before),let b=tilt(after) else{return}
        if samples<Int.max {samples+=1}
        maximumBefore=max(maximumBefore ?? a,a);maximumAfter=max(maximumAfter ?? b,b);lastAfter=b
    }
}

/// Bounded diagnostic-only pairing. No extrapolation or playback/placement policy.
public enum ControllerSyncPolicy {
    public static func bracket(_ times:[Double],target:Double)->(Int,Int)? {
        guard target.isFinite,times.count>=2,times.count<=32,
              times.allSatisfy({$0.isFinite}),zip(times,times.dropFirst()).allSatisfy({$0<$1}) else{return nil}
        for i in 1..<times.count where times[i-1]<=target && target<=times[i] {
            return times[i]-times[i-1]<=0.040 ? (i-1,i):nil
        }
        return nil
    }
    public static func clockStable(first:Double,current:Double)->Bool {
        first.isFinite && current.isFinite && abs(first-current)<=0.002
    }
}
/// Normal pose acquisition always preempts diagnostics; callbacks run outside the lock.
public final class ControllerPoseProbeGate:@unchecked Sendable {
    public static let shared=ControllerPoseProbeGate()
    private let lock=NSLock()
    private var normal=Set<UUID>()
    private var probe:(UUID,@Sendable ()->Void)?
    public init(){}
    public func beginNormal()->UUID {
        let token=UUID();lock.lock();normal.insert(token);let cancel=probe?.1;probe=nil;lock.unlock()
        cancel?();return token
    }
    public func endNormal(_ token:UUID){lock.lock();normal.remove(token);lock.unlock()}
    public func beginProbe(stop:@escaping @Sendable ()->Void)->UUID? {
        lock.lock();defer{lock.unlock()};guard normal.isEmpty,probe==nil else{return nil}
        let token=UUID();probe=(token,stop);return token
    }
    public func hasProbe(_ token:UUID)->Bool {lock.lock();defer{lock.unlock()};return probe?.0==token}
    public func endProbe(_ token:UUID){lock.lock();if probe?.0==token {probe=nil};lock.unlock()}
}

/// Roll-only levelling in the sampled viewer's perspective. This is not a gravity measurement.
/// Input/output rotations are in the same parent frame; position and plane normal are unchanged.
public enum VRControllerViewLevel {
    public struct Result {public let rotation:simd_quatf;public let rollDegrees:Double;public let status:Int}
    public static func solve(rotation:simd_quatf,centerFromViewer:SIMD3<Float>,viewerRotation:simd_quatf,
                             barOffset:SIMD3<Float>,enabled:Bool)->Result {
        func unchanged(_ status:Int)->Result {.init(rotation:rotation,rollDegrees:0,status:status)}
        guard enabled else{return unchanged(1)}
        let floats=[rotation.vector.x,rotation.vector.y,rotation.vector.z,rotation.vector.w,
                    viewerRotation.vector.x,viewerRotation.vector.y,viewerRotation.vector.z,viewerRotation.vector.w,
                    centerFromViewer.x,centerFromViewer.y,centerFromViewer.z,barOffset.x,barOffset.y,barOffset.z]
        guard floats.allSatisfy({$0.isFinite}),abs(simd_length_squared(rotation.vector)-1)<0.01,
              abs(simd_length_squared(viewerRotation.vector)-1)<0.01 else{return unchanged(2)}
        let camera=viewerRotation.inverse
        func double(_ v:SIMD3<Float>)->SIMD3<Double>{SIMD3(Double(v.x),Double(v.y),Double(v.z))}
        let right=double(camera.act(rotation.act([1,0,0])))
        let up=double(camera.act(rotation.act([0,1,0])))
        let normal=rotation.act([0,0,1])
        let center=double(camera.act(centerFromViewer+normal*barOffset.z))
        guard center.z < -0.01 else{return unchanged(3)}
        let a=right.y*center.z-right.z*center.y,b=up.y*center.z-up.z*center.y
        let c=Double(barOffset.y)*(right.y*up.z-right.z*up.y),radius=hypot(a,b)
        guard radius>1e-8,abs(c)<=radius else{return unchanged(4)}
        let phase=atan2(b,a),alpha=acos(max(-1,min(1,-c/radius)))
        func wrap(_ x:Double)->Double{atan2(sin(x),cos(x))}
        let x=wrap(phase-alpha),y=wrap(phase+alpha),roll=abs(x)<=abs(y) ? x:y
        // Avoid flipping the visible left/right order or correcting an edge-on/behind-camera panel.
        guard abs(roll)<=Double.pi/2 else{return unchanged(5)}
        let result=simd_normalize(rotation*simd_quatf(angle:Float(roll),axis:[0,0,1]))
        let rr=double(camera.act(result.act([1,0,0]))),uu=double(camera.act(result.act([0,1,0])))
        let bar=center+rr*Double(barOffset.x)+uu*Double(barOffset.y)
        let left=bar-rr*Double(VRControllerHandle.width/2),rightEnd=bar+rr*Double(VRControllerHandle.width/2)
        guard left.z < -0.01,rightEnd.z < -0.01,
              rightEnd.x / -rightEnd.z > left.x / -left.z else{return unchanged(5)}
        return .init(rotation:result,rollDegrees:roll*180/Double.pi,status:0)
    }
}

/// Small user-requested side facing adjustment. Stable load heading prevents head turns from
/// cancelling the adjustment while inspecting a side panel. Targets are absolute, never cumulative.
public enum VRControllerSideYaw {
    public static let maximumDegrees:Float=5
    public static func referenceYaw(_ orientation:simd_quatf)->Float {
        let forward=orientation.act(SIMD3<Float>(0,0,-1)),right=orientation.act(SIMD3<Float>(1,0,0))
        let radians=hypot(forward.x,forward.z)>0.001 ? atan2(-forward.x,-forward.z):atan2(-right.z,right.x)
        return radians.isFinite ? radians*180 / .pi:0
    }
    public static func degrees(offsetWorld:SIMD3<Float>,referenceYawDegrees:Float,enabled:Bool)->Float {
        guard enabled,offsetWorld.x.isFinite,offsetWorld.y.isFinite,offsetWorld.z.isFinite,
              referenceYawDegrees.isFinite else{return 0}
        let length=hypot(offsetWorld.x,offsetWorld.z)
        guard length>0.001 else{return 0}
        let yaw=referenceYawDegrees * .pi/180
        let right=SIMD3<Float>(cos(yaw),0,-sin(yaw))
        // Positive lateral distance is to the user's right: negative yaw brings that edge forward.
        return -maximumDegrees*min(1,max(-1,simd_dot(offsetWorld,right)/length))
    }
    public static func rotation(_ degrees:Float)->simd_quatf {
        let safe=degrees.isFinite ? min(maximumDegrees,max(-maximumDegrees,degrees)):0
        return simd_quatf(angle:safe * .pi/180,axis:[0,1,0])
    }
}
