import Foundation

/// One recovery allowance per automatic slowdown chain. Observations never change
/// speed or seek on their own. The driver owns intent checks and serialized seek.
struct VLCClockResyncPolicy {
    struct Input: Equatable {
        var now: Double
        var lastFrameAt: Double
        var eligible: Bool
        var rateConfirmed: Bool
        var effectiveRate: Double
        var selectedRate: Double
        var nowUS: Int64
        var sampleUS: Int64
        var queuePTS: Int64
        var queueTick: Int64
        var dropTick: Int64
        var queueCount: UInt64
        var queueValid: UInt64
        var queueInvalid: UInt64
        var queueRepeat: UInt64
        var queueBackward: UInt64
        var admitted: UInt64
        var pop: UInt64
        var lateDrop: UInt64
        var renderNormal: UInt64
        var errors: UInt64
        var dropDeltaMS: Double
        var dropThresholdMS: Double
        var dropRate: Double
        // v2 native snapshot: atomically paired with the last late-drop record.
        // Absence closes the early branch; legacy recovery remains available.
        var dropPTS: Int64 = -1
        var dropClockID: UInt32 = 0
        var dropContextValid: Bool = false
        var dropContextRate: Double = 0
        var dropReference: UInt64 = 0
    }
    var costGuard = VLCResyncCostGuard()
    private(set) var recoveryRate=2.0
    static func validRecoveryRate(_ rate:Double)->Bool {
        rate.isFinite && rate>=2 && rate<=5 && (rate*2).rounded()==rate*2
    }
    /// Retarget only an unused allowance; do not create another sampling chain.
    mutating func retargetFloor(now:Double) {
        guard armed,!spent,recoveryRate != 2 else{return}
        recoveryRate=2;armedAt=now;previous=nil;earlyPrevious=nil;earlyTooSoonCache=nil;earlyDispatchEvidence=nil
    }
    private(set) var armed = false
    private(set) var spent = false
    private(set) var triggerCount: UInt64 = 0
    private var armedAt: Double?
    private var previous: Input?
    private var earlyPrevious: Input? {
        didSet { if earlyPrevious != oldValue { earlyTooSoonCache=nil } }
    }
    // One fully checked fresh intermediate sample. It is not a second
    // baseline and never extends the original baseline's lifetime.
    private var earlyTooSoonCache: (baselineUS:Int64, input:Input)?
    struct Baselines: Equatable {
        let legacy: Int64?, early: Int64?
    }
    var baselines: Baselines { .init(legacy:previous?.sampleUS,early:earlyPrevious?.sampleUS) }
    // A rejected sample is never evidence. This only permits the remaining
    // budgeted read after a fresh, otherwise valid old-rate context mismatch.
    private(set) var oldContextRetrySampleUS: Int64?
    /// Candidate thresholds, not hardware limits or universally proven cutoffs.
    static let earlyNoFrameSeconds = 0.5
    static let earlySpacingUS: Int64 = 150_000
    static let earlyMaximumSpacingUS: Int64 = 250_000
    static let earlyMinimumLateMS = 100.0
    static let earlyMinimumRemainingMS = 600.0
    static let earlyMaximumMappingErrorMS = 10.0
    enum TriggerPath: Int { case none=0, legacy=1, earlySevere=2 }
    enum EarlyReason: Int {
        case none=0, baseline=1, ineligible=2, stale=3, context=4, notSevere=5
        case repeatedPTS=6, mappingChanged=7, counterReset=8, outputProgress=9
        case catchingUp=10, accepted=11, tooSoon=12, tooFar=13, insufficientProgress=14
    }
    struct EarlyEvidence {
        var sequence: UInt64 = 0
        var reason: EarlyReason = .none
        var firstSampleUS: Int64 = 0, secondSampleUS: Int64 = 0
        var firstDropPTS: Int64 = -1, secondDropPTS: Int64 = -1
        var firstLateMS: Double = -1, secondLateMS: Double = -1
        var estimatedRemainingMS: Double = -1, mappingErrorMS: Double = 0
        var contextRate: Double = 0
        var firstReference: UInt64 = 0, secondReference: UInt64 = 0
        var dropsAdvanced: UInt64 = 0
    }
    struct EarlyDispatchEvidence: Sendable {
        let sampleUS:Int64,dropPTS:Int64,dropTick:Int64
        let deltaMS:Double,thresholdMS:Double,rate:Double,minimumLateMS:Double,severityMultiplier:Double,clockID:UInt32,reference:UInt64
        init(_ x:Input,minimumLateMS:Double=VLCClockResyncPolicy.earlyMinimumLateMS,severityMultiplier:Double=6) {
            self.minimumLateMS=minimumLateMS;self.severityMultiplier=severityMultiplier
            sampleUS=x.sampleUS;dropPTS=x.dropPTS;dropTick=x.dropTick
            deltaMS=x.dropDeltaMS;thresholdMS=x.dropThresholdMS;rate=x.selectedRate
            clockID=x.dropClockID;reference=x.dropReference
        }
        func permits(nowUS:Int64,pts:Int64,tick:Int64,deltaMS:Double,thresholdMS:Double,
                     clockID:UInt32,contextValid:Bool,contextRate:Double,reference:UInt64)->Bool {
            guard nowUS>=sampleUS,nowUS-sampleUS<=250_000,tick>0,tick<=nowUS,nowUS-tick<=100_000,
                  pts>=dropPTS,contextValid,contextRate.isFinite,abs(contextRate-rate)<=0.01,
                  clockID==self.clockID,reference>=self.reference,
                  deltaMS.isFinite,thresholdMS.isFinite,abs(thresholdMS-self.thresholdMS)<=0.001,
                  -deltaMS>=max(minimumLateMS,severityMultiplier*thresholdMS) else{return false}
            let shift=Double(tick-dropTick)/1000 + deltaMS-self.deltaMS - Double(pts-dropPTS)/(1000*rate)
            return shift.isFinite && abs(shift)<=VLCClockResyncPolicy.earlyMaximumMappingErrorMS
        }
    }
    private(set) var earlyDispatchEvidence: EarlyDispatchEvidence?
    private(set) var triggerPath: TriggerPath = .none
    private(set) var earlyEvidence = EarlyEvidence()
    private var earlyLastReportedSampleUS: Int64 = 0
    var earlyEvidenceSampleUS: Int64? { earlyPrevious?.sampleUS }
    /// Read-only accepted evidence timestamp; scheduling never changes policy gates.
    var evidenceSampleUS: Int64? { previous?.sampleUS }
    private var healthStart: Double?
    private var healthLast: Double?
    private var healthPTS: Double?
    private var healthCount = 0

    mutating func automaticDrop(now: Double, authorizedRate:Double=2) {
        guard now.isFinite, now>=0, !spent, Self.validRecoveryRate(authorizedRate) else{return}
        if armed {
            if recoveryRate != authorizedRate {
                recoveryRate=authorizedRate;armedAt=now;previous=nil;earlyPrevious=nil;earlyTooSoonCache=nil;earlyDispatchEvidence=nil
            }
            return
        }
        recoveryRate=authorizedRate
        costGuard.beginChain()
        armed = true
        armedAt = now
        triggerPath = .none
        earlyDispatchEvidence = nil
        earlyEvidence = EarlyEvidence()
        earlyLastReportedSampleUS = 0
        oldContextRetrySampleUS = nil
        previous = nil
        earlyPrevious = nil
        earlyTooSoonCache = nil
        clearHealth()
    }

    /// An interruption cancels eligibility, not the spent allowance. Only a
    /// sustained run of newly published frames can release that allowance.
    mutating func interrupt() {
        costGuard.interrupt()
        oldContextRetrySampleUS = nil
        armed = false
        armedAt = nil
        previous = nil
        earlyPrevious = nil
        earlyTooSoonCache = nil
        clearHealth()
    }

    private mutating func clearHealth() {
        healthStart = nil
        healthLast = nil
        healthPTS = nil
        healthCount = 0
    }

    /// Call only for an actually published frame, never a repeated native
    /// display or mailbox receipt. A gap over 250 ms is not sustained recovery.
    mutating func observedFrame(now: Double, pts: Double, eligible: Bool) {
        oldContextRetrySampleUS = nil
        previous = nil
        earlyPrevious = nil
        earlyTooSoonCache = nil
        guard eligible, now.isFinite, pts.isFinite, now >= 0, pts >= 0 else {
            clearHealth()
            return
        }
        costGuard.publicationProgress()
        if let last = healthLast, let lastPTS = healthPTS,
           now > last, now - last <= 0.25, pts > lastPTS {
            healthCount = min(healthCount + 1, 1_000_000)
        } else {
            healthStart = now
            healthCount = 1
        }
        healthLast = now
        healthPTS = pts
        if let start = healthStart, healthCount >= 6, now - start >= 0.5 {
            spent = false
            armed = false
            armedAt = nil
            clearHealth()
        }
    }

    mutating func observe(_ value: Input) -> Bool {
        oldContextRetrySampleUS = nil
        guard armed, !spent, let armedAt else { return false }
        costGuard.observe(value)
        let early=observeEarly(value, armedAt: armedAt)
        let legacy=early ? false:observeLegacy(value, armedAt: armedAt)
        guard early || legacy else { return false }
        guard !costGuard.shouldDefer(value) else { return false }
        if early {earlyDispatchEvidence=EarlyDispatchEvidence(value)}
        else if recoveryRate>2 {earlyDispatchEvidence=EarlyDispatchEvidence(value,minimumLateMS:50,severityMultiplier:1)}
        return spend(early ? .earlySevere:.legacy)
    }

    private mutating func observeEarly(_ value: Input, armedAt: Double) -> Bool {
        // Repeated cached snapshots do not create new evidence or log entries.
        let freshReport = value.sampleUS > earlyLastReportedSampleUS
        if freshReport {
            earlyTooSoonCache=nil
            earlyLastReportedSampleUS = value.sampleUS
            var report = EarlyEvidence()
            report.sequence = earlyEvidence.sequence &+ 1
            report.secondSampleUS = value.sampleUS
            report.secondDropPTS = value.dropPTS
            report.secondLateMS = -value.dropDeltaMS
            report.contextRate = value.dropContextRate
            report.secondReference = value.dropReference
            if let old=earlyPrevious {
                report.firstSampleUS=old.sampleUS;report.firstDropPTS=old.dropPTS
                report.firstLateMS = -old.dropDeltaMS;report.firstReference=old.dropReference
            }
            earlyEvidence=report
        }
        func validCounterOrder(_ x:Input)->Bool {
            x.queueCount>=x.queueValid && x.queueCount>=x.admitted && x.admitted>=x.pop && x.pop>=x.lateDrop
        }
        func severeness(_ x:Input)->Bool {
            x.dropDeltaMS.isFinite && x.dropThresholdMS.isFinite && x.dropThresholdMS>0 &&
            -x.dropDeltaMS >= max(Self.earlyMinimumLateMS,6*x.dropThresholdMS)
        }
        guard value.now.isFinite,value.lastFrameAt.isFinite,value.now>=armedAt,
              value.lastFrameAt>=0,value.now-value.lastFrameAt>=Self.earlyNoFrameSeconds,
              value.eligible,value.rateConfirmed,value.selectedRate.isFinite,value.effectiveRate.isFinite,
              abs(value.selectedRate-recoveryRate)<=0.001,abs(value.effectiveRate-recoveryRate)<=0.01 else {
            earlyPrevious=nil;if freshReport {earlyEvidence.reason = .ineligible};return false
        }
        // The existing poll revisits a cached first sample while waiting for
        // the bounded second read. It is not new evidence, but must not erase
        // that baseline merely because its age crossed the new-sample 100 ms gate.
        if let old=earlyPrevious,value.sampleUS==old.sampleUS {
            if value.nowUS<value.sampleUS || value.nowUS-value.sampleUS>Self.earlyMaximumSpacingUS {earlyPrevious=nil}
            return false
        }
        // An ordinary snapshot may arrive between the two extra reads. If
        // it was fresh, fully non-contradictory and only too soon to pair,
        // revisiting that exact cache must not erase the older baseline.
        // Compare every input field except observation time; actual new/stale
        // data still takes the normal freshness and contradiction path below.
        if !freshReport,let old=earlyPrevious,let cached=earlyTooSoonCache,
           cached.baselineUS==old.sampleUS {
            var repeated=value
            repeated.now=cached.input.now;repeated.nowUS=cached.input.nowUS
            if repeated==cached.input {
                if value.now<cached.input.now || value.nowUS<cached.input.nowUS ||
                   value.nowUS<old.sampleUS || value.nowUS-old.sampleUS>Self.earlyMaximumSpacingUS {
                    earlyPrevious=nil;earlyTooSoonCache=nil
                }
                return false
            }
        }
        guard value.nowUS>0,value.sampleUS>0,value.sampleUS<=value.nowUS,
              value.nowUS-value.sampleUS<=100_000,
              value.now-Double(value.nowUS-value.sampleUS)/1e6>=armedAt,
              value.dropTick>0,value.dropTick<=value.sampleUS,value.sampleUS-value.dropTick<=100_000,
              value.queueTick>0,value.queueTick<=value.sampleUS,value.sampleUS-value.queueTick<=100_000 else {
            earlyPrevious=nil;if freshReport {earlyEvidence.reason = .stale};return false
        }
        guard value.dropContextValid,value.dropContextRate.isFinite,abs(value.dropContextRate-recoveryRate)<=0.01,
              value.dropRate.isFinite,abs(value.dropRate-recoveryRate)<=0.01,value.dropReference>0 else {
            // 143: a new 2x watch can precede the next vout drop by a few
            // milliseconds. Keep this rejected sample out of both early
            // evidence slots; permit only one already-budgeted fresh retry.
            if freshReport,value.dropContextValid,value.dropContextRate.isFinite,
               value.dropContextRate>recoveryRate+0.01,value.dropRate.isFinite,abs(value.dropRate-recoveryRate)<=0.01,
               value.dropReference>0,value.dropPTS>=0,value.queuePTS>=0,value.queueValid>0,
               validCounterOrder(value),severeness(value) {
                oldContextRetrySampleUS=value.sampleUS
            }
            earlyPrevious=nil;if freshReport {earlyEvidence.reason = .context};return false
        }
        guard value.dropPTS>=0,value.queuePTS>=0,value.queueValid>0,validCounterOrder(value) else {
            earlyPrevious=nil;if freshReport {earlyEvidence.reason = .counterReset};return false
        }
        guard severeness(value) else {
            earlyPrevious=nil;if freshReport {earlyEvidence.reason = .notSevere};return false
        }
        guard let old=earlyPrevious else {
            earlyPrevious=value;if freshReport {earlyEvidence.reason = .baseline};return false
        }
        if value.sampleUS==old.sampleUS {return false}
        guard value.sampleUS>old.sampleUS,value.now>=old.now else {
            earlyPrevious=nil;if freshReport {earlyEvidence.reason = .stale};return false
        }
        let elapsed=value.sampleUS-old.sampleUS
        guard elapsed>=Self.earlySpacingUS else {
            // Only a truly fresh, progressing, same-mapping intermediate can
            // receive cache-only protection. A fresh contradiction must never
            // gain it merely because the two observations are close together.
            let mappingError=Double(value.dropTick-old.dropTick)/1000 + value.dropDeltaMS-old.dropDeltaMS - Double(value.dropPTS-old.dropPTS)/(1000*recoveryRate)
            if freshReport,value.dropPTS>old.dropPTS,value.dropTick>old.dropTick,
               value.dropClockID==old.dropClockID,value.dropReference>=old.dropReference,
               abs(value.dropThresholdMS-old.dropThresholdMS)<=0.001,
               mappingError.isFinite,abs(mappingError)<=Self.earlyMaximumMappingErrorMS,
               value.queuePTS>=old.queuePTS,value.queueTick>=old.queueTick,
               value.queueCount>=old.queueCount,value.queueValid>=old.queueValid,
               value.admitted>=old.admitted,value.pop>=old.pop,value.lateDrop>=old.lateDrop,
               value.queueInvalid==old.queueInvalid,value.queueRepeat==old.queueRepeat,
               value.queueBackward==old.queueBackward,value.errors==old.errors,
               value.renderNormal==old.renderNormal {
                earlyTooSoonCache=(old.sampleUS,value)
            }
            if freshReport {earlyEvidence.reason = .tooSoon};return false
        }
        guard elapsed<=Self.earlyMaximumSpacingUS else {
            earlyPrevious=value;if freshReport {earlyEvidence.reason = .tooFar};return false
        }
        guard value.dropPTS>old.dropPTS,value.dropTick>old.dropTick else {
            earlyPrevious=nil;if freshReport {earlyEvidence.reason = .repeatedPTS};return false
        }
        // Reference generations normally advance with audio reports. Check that
        // the PTS->deadline mapping stayed continuous instead of demanding equality.
        let mappingError=Double(value.dropTick-old.dropTick)/1000 + value.dropDeltaMS-old.dropDeltaMS - Double(value.dropPTS-old.dropPTS)/(1000*recoveryRate)
        if freshReport {earlyEvidence.mappingErrorMS=mappingError}
        guard value.dropClockID==old.dropClockID,value.dropReference>=old.dropReference,
              abs(value.dropThresholdMS-old.dropThresholdMS)<=0.001,
              mappingError.isFinite,abs(mappingError)<=Self.earlyMaximumMappingErrorMS else {
            earlyPrevious=value;if freshReport {earlyEvidence.reason = .mappingChanged};return false
        }
        guard value.queueCount>=old.queueCount,value.queueValid>=old.queueValid,
              value.admitted>=old.admitted,value.pop>=old.pop,value.lateDrop>=old.lateDrop,
              value.queueInvalid>=old.queueInvalid,value.queueRepeat>=old.queueRepeat,
              value.queueBackward>=old.queueBackward,value.errors>=old.errors,value.renderNormal>=old.renderNormal else {
            earlyPrevious=nil;if freshReport {earlyEvidence.reason = .counterReset};return false
        }
        guard value.queueInvalid==old.queueInvalid,value.queueRepeat==old.queueRepeat,
              value.queueBackward==old.queueBackward,value.errors==old.errors,
              value.renderNormal==old.renderNormal else {
            earlyPrevious=nil;if freshReport {earlyEvidence.reason = .outputProgress};return false
        }
        let dropped=value.lateDrop-old.lateDrop
        if freshReport {earlyEvidence.dropsAdvanced=dropped}
        guard value.queueCount>old.queueCount,value.queueValid>old.queueValid,
              value.queuePTS>old.queuePTS,value.queueTick>old.queueTick,
              value.admitted>old.admitted,value.pop-old.pop>=6,dropped>=6 else {
            earlyPrevious=value;if freshReport {earlyEvidence.reason = .insufficientProgress};return false
        }
        let improvement=(-old.dropDeltaMS)-(-value.dropDeltaMS)
        // Only a bounded diagnostic estimate: worsening/no progress uses 60 s.
        let remaining=improvement>0 ? min(60_000,(-value.dropDeltaMS-value.dropThresholdMS)*Double(elapsed)/1000/improvement):60_000
        if freshReport {earlyEvidence.estimatedRemainingMS=remaining}
        earlyPrevious=value
        guard remaining>=Self.earlyMinimumRemainingMS else {
            if freshReport {earlyEvidence.reason = .catchingUp};return false
        }
        if freshReport {earlyEvidence.reason = .accepted}
        return true
    }

    private mutating func spend(_ path:TriggerPath)->Bool {
        spent=true;armed=false;previous=nil;earlyPrevious=nil;earlyTooSoonCache=nil;clearHealth()
        triggerPath=path
        if path == .legacy && recoveryRate==2 {earlyDispatchEvidence=nil}
        if triggerCount<UInt64.max {triggerCount += 1}
        return true
    }

    private mutating func observeLegacy(_ value: Input, armedAt: Double) -> Bool {
        guard value.now.isFinite, value.lastFrameAt.isFinite,
              value.now >= armedAt, value.lastFrameAt >= 0,
              value.now - value.lastFrameAt >= 1,
              value.eligible, value.rateConfirmed,
              value.selectedRate.isFinite, value.effectiveRate.isFinite,
              abs(value.selectedRate - recoveryRate) <= 0.001,
              abs(value.effectiveRate - recoveryRate) <= 0.01,
              value.nowUS > 0, value.sampleUS > 0,
              value.sampleUS <= value.nowUS,
              value.nowUS - value.sampleUS <= 1_250_000,
              value.queuePTS >= 0,
              value.queueTick > 0, value.queueTick <= value.sampleUS,
              value.sampleUS - value.queueTick <= 250_000,
              value.dropTick > 0, value.dropTick <= value.sampleUS,
              value.sampleUS - value.dropTick <= 250_000,
              value.queueValid > 0, value.queueCount >= value.queueValid,
              value.queueCount >= value.admitted, value.admitted >= value.pop,
              value.pop >= value.lateDrop,
              value.dropDeltaMS.isFinite, value.dropThresholdMS.isFinite,
              value.dropThresholdMS > 0,
              value.dropDeltaMS < -max(50, value.dropThresholdMS),
              value.dropRate.isFinite, abs(value.dropRate - recoveryRate) <= 0.01,
              (recoveryRate==2 || (value.dropContextValid && value.dropContextRate.isFinite &&
                abs(value.dropContextRate-recoveryRate)<=0.01 && value.dropPTS>=0 && value.dropReference>0)),
              value.now - Double(value.nowUS - value.sampleUS) / 1e6 >= armedAt
        else {
            previous = nil
            return false
        }
        guard let old = previous else {
            previous = value
            return false
        }
        // Re-reading the same 1 Hz cached snapshot is never extra evidence.
        if value.sampleUS == old.sampleUS { return false }
        guard value.sampleUS > old.sampleUS, value.now >= old.now else {
            previous = nil
            return false
        }
        let elapsed = value.sampleUS - old.sampleUS
        if elapsed < 750_000 {
            // Early supplemental reads may arrive between the legacy pair.
            // Keep its deadline when the intervening evidence is consistent;
            // reset on counter/timeline regressions or any normal output/error.
            let consistent = value.queueCount>=old.queueCount && value.queueValid>=old.queueValid &&
                value.queuePTS>=old.queuePTS && value.queueTick>=old.queueTick &&
                value.admitted>=old.admitted && value.pop>=old.pop && value.lateDrop>=old.lateDrop &&
                value.dropTick>=old.dropTick && value.queueInvalid==old.queueInvalid &&
                value.queueRepeat==old.queueRepeat && value.queueBackward==old.queueBackward &&
                value.errors==old.errors && value.renderNormal==old.renderNormal
            if !consistent {previous=value}
            return false
        }
        guard elapsed <= 1_500_000 else {previous=value;return false}
        if recoveryRate>2 {
            let mapping=Double(value.dropTick-old.dropTick)/1000+value.dropDeltaMS-old.dropDeltaMS-Double(value.dropPTS-old.dropPTS)/(1000*recoveryRate)
            guard value.dropPTS>old.dropPTS,value.dropClockID==old.dropClockID,value.dropReference>=old.dropReference,
                  mapping.isFinite,abs(mapping)<=Self.earlyMaximumMappingErrorMS else {previous=value;return false}
        }
        let progress = value.queueCount > old.queueCount &&
            value.queueValid > old.queueValid && value.queuePTS > old.queuePTS &&
            value.queueTick > old.queueTick && value.admitted > old.admitted &&
            value.pop > old.pop && value.lateDrop > old.lateDrop &&
            value.dropTick > old.dropTick
        let clean = value.queueInvalid == old.queueInvalid &&
            value.queueRepeat == old.queueRepeat && value.queueBackward == old.queueBackward &&
            value.errors == old.errors && value.renderNormal == old.renderNormal
        // Rejected evidence never restores an allowance or opens a new chain.
        previous = value
        guard progress, clean else { return false }
        return true
    }
}

/// Passive, allocation-free low-frequency journal selection. It does not alter
/// either policy baseline. Repeated cached polls with identical eligibility do
/// not produce records; cached eligibility changes do, even with no new sample.
struct VLCResyncBaselineJournal {
    struct Qualification: Equatable {
        let sampleUS:Int64, flags:Int
        let selected:Double, effective:Double
        init(_ x:VLCClockResyncPolicy.Input) {
            sampleUS=x.sampleUS;flags=(x.eligible ? 1:0)|(x.rateConfirmed ? 2:0)|(x.dropContextValid ? 4:0)
            // Invalid rates are one stable diagnostic state, not a NaN flood.
            selected=x.selectedRate.isFinite ? x.selectedRate : -1
            effective=x.effectiveRate.isFinite ? x.effectiveRate : -1
        }
    }
    struct Event {
        let sequence:UInt64, reason:Int
        let before:VLCClockResyncPolicy.Baselines, after:VLCClockResyncPolicy.Baselines
        let oldFlags:Int, newFlags:Int, cachedQualificationChanged:Bool
        let sampleUS:Int64, nowUS:Int64
        // 0 absent/unchanged; 1 adopt; 2 replace; 3 retain; 4 reset.
        static func operation(_ old:Int64?,_ new:Int64?)->Int {
            if old==nil {return new==nil ? 0:1}
            if new==nil {return 4}
            return old==new ? 3:2
        }
        var legacyOperation:Int {Self.operation(before.legacy,after.legacy)}
        var earlyOperation:Int {Self.operation(before.early,after.early)}
    }
    private(set) var sequence:UInt64=0
    private var last:Qualification?
    mutating func newChain(){last=nil}
    mutating func record(before:VLCClockResyncPolicy.Baselines,after:VLCClockResyncPolicy.Baselines,
                         input:VLCClockResyncPolicy.Input?,reason:Int)->Event? {
        let old=last, next=input.map(Qualification.init)
        let changed=next.map{old != $0} ?? false
        let cached=next.map{old?.sampleUS==$0.sampleUS && changed} ?? false
        let fresh=next.map{old?.sampleUS != $0.sampleUS} ?? false
        if let next {last=next}
        let retained=fresh && (after.legacy != nil || after.early != nil)
        guard before != after || cached || retained else{return nil}
        sequence &+= 1
        return .init(sequence:sequence,reason:reason,before:before,after:after,
                     oldFlags:old?.flags ?? -1,newFlags:next?.flags ?? -1,
                     cachedQualificationChanged:cached,sampleUS:next?.sampleUS ?? 0,nowUS:input?.nowUS ?? 0)
    }
}


/// 146: same-player/source software-publication cost, never physical display latency.
/// No native reads. Caller clears scope on engine/source changes and interrupts
/// unfinished captures on user intents. All thresholds are conservative candidates.
struct VLCResyncCostGuard {
    struct Cost {
        let nonce:UInt64, commandUS:Int64, adoptedUS:Int64, durationUS:Int64
        var rate:Double=2
    }
    struct Capture {
        let nonce:UInt64, commandUS:Int64
        var rate:Double=2
        var firstPTS:Double?, lastPTS:Double?, lastUS:Int64?, runUS:Int64?, count=0
    }
    enum Reason:Int {
        case none=0, capture=1, adopted=2, interrupted=3, scope=4, expiredHistory=5
        case granted=6, deadline=7, worsening=8, context=9, progress=10, captureTimeout=11
        case cheaperSeek=12, awaitingConfirmation=13, confirmation=14
    }
    private(set) var history:[Cost]=[]
    private(set) var capture:Capture?
    private(set) var sequence:UInt64=0
    private(set) var reason:Reason = .none
    private(set) var source:Cost?
    private(set) var evictedNonce:UInt64=0
    private(set) var deadlineUS:Int64=0
    private(set) var remainingMS:Double = -1
    struct Observation {
        var nowUS:Int64=0,invalidMask:Int64=0,transportMask:Int64=0,nativeRate:Double=0
        var expectedNonce:UInt64=0,observedNonce:UInt64=0
        var expectedEpoch:Int64=Int64.min,observedEpoch:Int64=Int64.min
    }
    private(set) var observation=Observation()
    mutating func recordObservation(_ value:Observation){observation=value}
    /// Scope/intent validation is independent from temporary native transport state.
    mutating func expireCapture(nowUS:Int64) {
        guard let c=capture else{return}
        if nowUS<c.commandUS || nowUS-c.commandUS>15_000_000 {
            capture=nil;awaitingConfirmation=false;changed(.captureTimeout)
        }
    }
    mutating func awaitConfirmation(resetRun:Bool) {
        guard var c=capture else{return}
        if resetRun {c.lastPTS=nil;c.lastUS=nil;c.runUS=nil;c.count=0;capture=c}
        if !awaitingConfirmation {awaitingConfirmation=true;changed(.awaitingConfirmation)}
    }
    private(set) var awaitingConfirmation=false
    private(set) var adoptedCount:UInt64=0
    private(set) var used=false
    private var previous:VLCClockResyncPolicy.Input?
    private var lastSampleUS:Int64=0
    private var estimateSampleUS:Int64=0
    private var initialLateMS:Double=0
    private var selectedCostUS:Int64=0
    private mutating func changed(_ why:Reason) { reason=why;sequence &+= 1 }
    mutating func beginChain() {
        deadlineUS=0;used=false;previous=nil;lastSampleUS=0;estimateSampleUS=0;remainingMS = -1
    }
    mutating func interrupt() {
        if capture != nil || deadlineUS != 0 { changed(.interrupted) }
        capture=nil;awaitingConfirmation=false;deadlineUS=0;previous=nil;estimateSampleUS=0
    }
    mutating func clearScope() {
        interrupt();evictedNonce=history.last?.nonce ?? 0;history.removeAll(keepingCapacity:true)
        source=nil;changed(.scope)
    }
    mutating func dispatched(nonce:UInt64, commandUS:Int64, rate:Double=2) {
        guard commandUS>0,VLCClockResyncPolicy.validRecoveryRate(rate) else{return}
        awaitingConfirmation=false
        capture=Capture(nonce:nonce,commandUS:commandUS,rate:rate)
        source=Cost(nonce:nonce,commandUS:commandUS,adoptedUS:0,durationUS:0,rate:rate);changed(.capture)
    }
    mutating func firstPublication(nonce:UInt64, pts:Double) {
        guard capture?.nonce==nonce,pts.isFinite,pts>=0 else{return}
        capture?.firstPTS=pts
    }
    mutating func published(nowUS:Int64, pts:Double, eligible:Bool, rateConfirmed:Bool=true) {
        expireCapture(nowUS:nowUS)
        guard var c=capture else{return}
        guard eligible,pts.isFinite,pts>=0 else {interrupt();return}
        if awaitingConfirmation == rateConfirmed {
            awaitingConfirmation = !rateConfirmed
            changed(rateConfirmed ? .confirmation:.awaitingConfirmation)
        }
        guard let first=c.firstPTS else{return}
        if pts<=first {
            // A repeated forced first frame is not recovery; a regression after
            // progress also breaks the run used to validate a completed cost.
            c.lastPTS=nil;c.lastUS=nil;c.runUS=nil;c.count=0;capture=c;return
        }
        if let last=c.lastPTS,pts==last {return}
        if let last=c.lastPTS,let tick=c.lastUS,pts>last,nowUS>tick,nowUS-tick<=250_000 {
            c.count += 1
        } else {c.runUS=nowUS;c.count=1}
        c.lastPTS=pts;c.lastUS=nowUS;capture=c
        // Internal seekSequence acknowledgement can temporarily close the
        // adapter gate. Preserve actual publication times; only adoption waits.
        guard rateConfirmed,let start=c.runUS,c.count>=6,nowUS-start>=500_000 else{return}
        let cost=Cost(nonce:c.nonce,commandUS:c.commandUS,adoptedUS:nowUS,durationUS:start-c.commandUS,rate:c.rate)
        guard cost.durationUS>0 else{return}
        expire(nowUS)
        if history.count==3 {evictedNonce=history.removeFirst().nonce}
        history.append(cost);source=cost;capture=nil;adoptedCount &+= 1;changed(.adopted)
    }
    /// Only actual publication clears a pending deferral; eligibility-only polls do not.
    mutating func publicationProgress() {
        previous=nil;estimateSampleUS=0
        if deadlineUS != 0 {deadlineUS=0;changed(.progress)}
    }
    private mutating func expire(_ nowUS:Int64) {
        let expired=history.filter { nowUS<$0.adoptedUS || nowUS-$0.adoptedUS>60_000_000 }
        if let last=expired.last {
            evictedNonce=last.nonce;history.removeAll { nowUS<$0.adoptedUS || nowUS-$0.adoptedUS>60_000_000 }
            changed(.expiredHistory)
        }
    }
    private func fresh(_ x:VLCClockResyncPolicy.Input)->Bool {
        x.nowUS>0 && x.sampleUS>0 && x.nowUS>=x.sampleUS && x.nowUS-x.sampleUS<=100_000 &&
        x.dropTick>0 && x.dropTick<=x.sampleUS && x.sampleUS-x.dropTick<=100_000 &&
        x.queueTick>0 && x.queueTick<=x.sampleUS && x.sampleUS-x.queueTick<=100_000
    }
    private func valid(_ x:VLCClockResyncPolicy.Input)->Bool {
        x.eligible && x.rateConfirmed && x.selectedRate.isFinite && x.effectiveRate.isFinite &&
        VLCClockResyncPolicy.validRecoveryRate(x.selectedRate) && abs(x.effectiveRate-x.selectedRate)<=0.01 &&
        x.dropContextValid && x.dropContextRate.isFinite && abs(x.dropContextRate-x.selectedRate)<=0.01 &&
        x.dropRate.isFinite && abs(x.dropRate-x.selectedRate)<=0.01 && x.dropReference>0 && x.dropPTS>=0 &&
        x.queuePTS>=0 && x.queueValid>0 && x.queueCount>=x.queueValid && x.queueCount>=x.admitted &&
        x.admitted>=x.pop && x.pop>=x.lateDrop && x.dropDeltaMS.isFinite &&
        x.dropThresholdMS.isFinite && x.dropThresholdMS>0
    }
    mutating func observe(_ x:VLCClockResyncPolicy.Input) {
        expire(x.nowUS)
        if deadlineUS>0 && x.nowUS>=deadlineUS {deadlineUS=0;changed(.deadline)}
        guard x.eligible,x.rateConfirmed,VLCClockResyncPolicy.validRecoveryRate(x.selectedRate),abs(x.effectiveRate-x.selectedRate)<=0.01 else {
            if deadlineUS>0 {deadlineUS=0;changed(.context)}
            previous=nil;estimateSampleUS=0;return
        }
        // A 1Hz cached sample becoming stale cannot revoke a finite grant.
        guard x.sampleUS != lastSampleUS else{return}
        lastSampleUS=x.sampleUS;estimateSampleUS=0;remainingMS = -1
        guard fresh(x) else{return}
        guard valid(x) else {
            previous=nil
            if deadlineUS>0 {deadlineUS=0;changed(.context)}
            return
        }
        guard let old=previous else {previous=x;return}
        let elapsed=x.sampleUS-old.sampleUS
        if elapsed>0 && elapsed<150_000 {return}
        previous=x
        let mapping=Double(x.dropTick-old.dropTick)/1000+x.dropDeltaMS-old.dropDeltaMS-Double(x.dropPTS-old.dropPTS)/(1000*x.selectedRate)
        guard elapsed>=150_000,elapsed<=1_250_000,x.dropPTS>old.dropPTS,x.dropTick>old.dropTick,
              x.selectedRate==old.selectedRate,x.dropClockID==old.dropClockID,x.dropReference>=old.dropReference,
              abs(x.dropThresholdMS-old.dropThresholdMS)<=0.001,mapping.isFinite,abs(mapping)<=10,
              x.queueCount>old.queueCount,x.queueValid>old.queueValid,x.queuePTS>old.queuePTS,
              x.queueTick>old.queueTick,x.admitted>old.admitted,x.pop>=old.pop,x.lateDrop>=old.lateDrop,
              x.pop-old.pop>=6,x.lateDrop-old.lateDrop>=6,
              x.queueInvalid==old.queueInvalid,x.queueRepeat==old.queueRepeat,
              x.queueBackward==old.queueBackward,x.errors==old.errors,x.renderNormal==old.renderNormal else {
            if deadlineUS>0 {deadlineUS=0;changed(.context)}
            return
        }
        let improvement=x.dropDeltaMS-old.dropDeltaMS
        // Late deltas belong to dropTick, not snapshot collection time. Taking
        // the longer span prevents differential sample age making catchup optimistic.
        let estimateElapsed=max(elapsed,x.dropTick-old.dropTick)
        remainingMS=improvement>0 ? max(0,(-x.dropDeltaMS-x.dropThresholdMS)*Double(estimateElapsed)/1000/improvement):60_000
        estimateSampleUS=x.sampleUS
        if deadlineUS>0 && (improvement<=0 || -x.dropDeltaMS>initialLateMS ||
           remainingMS*1.05+25>=Double(selectedCostUS)/1000) {
            deadlineUS=0;changed(.worsening)
        }
    }
    mutating func shouldDefer(_ x:VLCClockResyncPolicy.Input)->Bool {
        if deadlineUS>x.nowUS {return true}
        guard !used,estimateSampleUS==x.sampleUS,fresh(x),valid(x),remainingMS.isFinite,remainingMS>0,
              let cost=history.filter({abs($0.rate-x.selectedRate)<=0.001}).min(by:{$0.durationUS<$1.durationUS}) else{return false}
        source=cost
        guard remainingMS*1.05+25<Double(cost.durationUS)/1000 else {changed(.cheaperSeek);return false}
        used=true;initialLateMS = -x.dropDeltaMS;selectedCostUS=cost.durationUS
        deadlineUS=x.nowUS+Int64(min(2000,remainingMS+250)*1000)
        changed(.granted);return true
    }
}


/// VLC-only 147 candidate. Scope resets are owned by the driver. Native proof
/// uses existing ordinary snapshots; a fresh drop is not required when healthy.
struct VLCKnownHealthyRecovery {
    struct Proof {
        let rate:Double, atUS:Int64, firstSampleUS:Int64, lastSampleUS:Int64
        let firstNormal:UInt64, lastNormal:UInt64, late:UInt64, errors:UInt64
        let runStartUS:Int64, frames:Int
    }
    enum Reason:Int {case none=0, certified=1, holding=2, recovered=3, timeout=4, interrupted=5, rejected=6, contradicted=7}
    private(set) var proof:Proof?
    private(set) var holdingRate:Double=0
    private(set) var deadlineUS:Int64=0
    private(set) var sequence:UInt64=0
    private(set) var reason:Reason = .none
    private(set) var consumed:Proof?
    private var runRate:Double=0,runStartUS:Int64=0,lastUS:Int64=0,lastPTS:Double = -1
    private var frames=0
    private var nativeBaseline:VLCClockResyncPolicy.Input?
    private var nativeLastUS:Int64=0
    static let certificateFreshnessUS:Int64=100_000
    private var needsFreshCertificate=false, freshnessReported=false
    private(set) var freshnessSequence:UInt64=0
    struct SamplingState:Equatable,Sendable {
        let rate:Double,runStartUS:Int64,lastUS:Int64,frames:Int
        let firstNativeUS:Int64,lastNativeUS:Int64
        let certified:Bool
        var needsFreshCertificate:Bool=false
    }
    var samplingState:SamplingState {
        .init(rate:runRate,runStartUS:runStartUS,lastUS:lastUS,frames:frames,
              firstNativeUS:nativeBaseline?.sampleUS ?? 0,lastNativeUS:nativeLastUS,
              certified:proof?.runStartUS==runStartUS,needsFreshCertificate:needsFreshCertificate)
    }
    private var recoveryStartUS:Int64=0,recoveryLastUS:Int64=0,recoveryPTS:Double = -1,recoveryFrames=0
    var holding:Bool {deadlineUS>0}
    private mutating func change(_ r:Reason){reason=r;sequence &+= 1}
    private mutating func contradict(_ rate:Double) {
        if let p=proof,abs(p.rate-rate)<=0.001 {consumed=p;proof=nil;change(.contradicted)}
    }
    private mutating func resetRun(){runRate=0;runStartUS=0;lastUS=0;lastPTS = -1;frames=0;nativeBaseline=nil;nativeLastUS=0;needsFreshCertificate=false;freshnessReported=false}
    mutating func interrupt(preserveProof:Bool=false) {
        if proof != nil || holding {change(.interrupted)}
        if !preserveProof {proof=nil;consumed=nil}
        holdingRate=0;deadlineUS=0;resetRun();recoveryStartUS=0;recoveryLastUS=0;recoveryFrames=0;recoveryPTS = -1
    }
    @discardableResult mutating func beginReturn(nowUS:Int64, rate:Double)->Bool {
        guard !holding,let p=proof,rate>2,abs(p.rate-rate)<=0.001,
              nowUS>=p.atUS,nowUS-p.atUS<=10_000_000 else{return false}
        consumed=p;proof=nil;holdingRate=rate;deadlineUS=nowUS+4_000_000
        resetRun();recoveryStartUS=0;recoveryLastUS=0;recoveryFrames=0;recoveryPTS = -1
        change(.holding);return true
    }
    @discardableResult mutating func suppression(nowUS:Int64)->Bool {
        if holding,nowUS>=deadlineUS {deadlineUS=0;holdingRate=0;change(.timeout)}
        return holding
    }
    mutating func dispatchRejected() {
        if holding {deadlineUS=0;holdingRate=0;change(.rejected)}
    }
    /// Counter evidence can invalidate an old certificate without a publication
    /// in the same uninterrupted run. After a rate/run interruption cumulative
    /// counters cannot attribute intervening overload to the certificate rate.
    private mutating func invalidateContradictedProof(_ x:VLCClockResyncPolicy.Input) {
        guard let p=proof,runStartUS==p.runStartUS,runRate==p.rate,
              abs(x.selectedRate-p.rate)<=0.001,
              x.sampleUS>=p.lastSampleUS,x.sampleUS<=x.nowUS,
              x.nowUS-x.sampleUS<=Self.certificateFreshnessUS else{return}
        if x.renderNormal<p.lastNormal || x.lateDrop != p.late || x.errors != p.errors {
            contradict(p.rate)
        }
    }
    mutating func observe(_ x:VLCClockResyncPolicy.Input, publishedPTS:Double?) {
        _=suppression(nowUS:x.nowUS)
        if let p=proof,x.nowUS<p.atUS || x.nowUS-p.atUS>10_000_000 {proof=nil}
        let eligible=x.eligible && x.rateConfirmed && x.selectedRate>=2.5 &&
            VLCClockResyncPolicy.validRecoveryRate(x.selectedRate) &&
            x.effectiveRate.isFinite && abs(x.effectiveRate-x.selectedRate)<=0.01
        guard eligible else{resetRun();return}
        invalidateContradictedProof(x)
        guard let pts=publishedPTS else {
            if lastUS>0,x.nowUS-lastUS>250_000 {contradict(x.selectedRate);resetRun()}
            return
        }
        guard pts.isFinite,pts>=0 else{contradict(x.selectedRate);resetRun();return}
        if holding,abs(x.selectedRate-holdingRate)<=0.001 {
            if recoveryLastUS>0,pts>recoveryPTS,x.nowUS>recoveryLastUS,x.nowUS-recoveryLastUS<=250_000 {
                recoveryFrames += 1
            } else if pts != recoveryPTS {recoveryStartUS=x.nowUS;recoveryFrames=1}
            if pts != recoveryPTS {recoveryLastUS=x.nowUS;recoveryPTS=pts}
            if recoveryFrames>=6,x.nowUS-recoveryStartUS>=500_000 {
                deadlineUS=0;holdingRate=0;change(.recovered)
            }
        }
        if runRate==x.selectedRate,lastUS>0,(x.nowUS-lastUS>250_000 || pts<lastPTS) {contradict(x.selectedRate)}
        if runRate != x.selectedRate || lastUS==0 || x.nowUS<=lastUS || x.nowUS-lastUS>250_000 || pts<lastPTS {
            resetRun();runRate=x.selectedRate;runStartUS=x.nowUS;frames=1
        } else if pts>lastPTS {frames += 1}
        else {return}
        lastUS=x.nowUS;lastPTS=pts
        guard x.sampleUS>=runStartUS,x.sampleUS<=x.nowUS,x.nowUS-x.sampleUS<=1_250_000 else{return}
        guard let old=nativeBaseline else {nativeBaseline=x;nativeLastUS=x.sampleUS;return}
        guard x.sampleUS>=old.sampleUS,x.renderNormal>=old.renderNormal,
              x.lateDrop==old.lateDrop,x.errors==old.errors else {
            // Contrary evidence at the same rate invalidates its certificate;
            // overload at a higher rate does not erase an earlier healthy rate.
            contradict(x.selectedRate);resetRun();return
        }
        nativeLastUS=max(nativeLastUS,x.sampleUS)
        // Publication duration and native separation remain independent evidence.
        guard x.nowUS-runStartUS>=1_500_000,frames>=40,
              x.sampleUS-old.sampleUS>=1_000_000,x.renderNormal>old.renderNormal,
              proof?.lastSampleUS != x.sampleUS else{return}
        // Old snapshots may still contradict counters above, but cannot certify
        // current health. Age alone never revokes an existing certificate.
        guard x.nowUS-x.sampleUS<=Self.certificateFreshnessUS else {
            needsFreshCertificate=true
            if !freshnessReported {freshnessReported=true;freshnessSequence &+= 1}
            return
        }
        needsFreshCertificate=false
        proof=Proof(rate:x.selectedRate,atUS:x.nowUS,firstSampleUS:old.sampleUS,lastSampleUS:x.sampleUS,
                    firstNormal:old.renderNormal,lastNormal:x.renderNormal,late:x.lateDrop,errors:x.errors,runStartUS:runStartUS,frames:frames)
        change(.certified)
    }
}

/// Two evidence-preparation reads plus at most one final freshness read per
/// identity. Broken runs and failed reads never refill either allowance.
struct VLCHealthSampleBudget {
    struct Identity:Equatable,Sendable {
        let engine:ObjectIdentifier,source:UInt64?,revision:UInt64,presentation:UInt64
        let rate:Double
    }
    struct Request:Equatable,Sendable {
        let identity:Identity,runStartUS:Int64,sequence:Int,purpose:Int,dueUS:Int64
    }
    private(set) var identity:Identity?
    private(set) var issued=0
    private var preparationIssued=0
    private(set) var finalIssued=false
    private var pending:Request?
    mutating func request(identity next:Identity,state:VLCKnownHealthyRecovery.SamplingState,
                          nowUS:Int64,eligible:Bool,cachedUS:Int64=0)->Request? {
        if identity != next {identity=next;issued=0;preparationIssued=0;finalIssued=false;pending=nil}
        guard eligible,pending==nil,!state.certified,state.runStartUS>0,
              state.rate==next.rate,state.lastUS>=state.runStartUS,nowUS>=state.lastUS,
              nowUS-state.lastUS<=250_000,cachedUS<=state.lastNativeUS else{return nil}
        let purpose:Int,dueUS:Int64
        if state.needsFreshCertificate {
            guard !finalIssued,state.lastUS-state.runStartUS>=1_500_000,state.frames>=40,
                  state.firstNativeUS>0,state.lastNativeUS-state.firstNativeUS>=1_000_000,
                  nowUS>=state.lastNativeUS,nowUS-state.lastNativeUS>VLCKnownHealthyRecovery.certificateFreshnessUS else{return nil}
            purpose=3;dueUS=state.lastUS;finalIssued=true
        } else if state.firstNativeUS==0 {
            guard preparationIssued<2,state.lastUS-state.runStartUS>=250_000 else{return nil}
            purpose=1;dueUS=state.runStartUS+250_000
        } else {
            guard preparationIssued<2,state.frames>=40,state.lastNativeUS-state.firstNativeUS<1_000_000 else{return nil}
            purpose=2;dueUS=state.firstNativeUS+1_000_000
            guard nowUS>=dueUS else{return nil}
        }
        if purpose != 3 {preparationIssued += 1}
        issued += 1
        let request=Request(identity:next,runStartUS:state.runStartUS,sequence:issued,purpose:purpose,dueUS:dueUS)
        pending=request;return request
    }
    mutating func complete(_ request:Request,current:Identity?,state:VLCKnownHealthyRecovery.SamplingState)->Bool {
        guard pending==request else{return false}
        pending=nil
        return identity==request.identity && current==request.identity &&
            state.runStartUS==request.runStartUS && state.rate==request.identity.rate
    }
}


/// A not-severe sample is only a reason to consider another bounded read.
/// It never counts as either of the two severe samples required for recovery.
struct VLCNotSevereRetryWitness {
    static func valid(_ x:VLCClockResyncPolicy.Input)->Bool {
        x.eligible && x.rateConfirmed && x.now.isFinite && x.lastFrameAt.isFinite &&
        x.now>=x.lastFrameAt && x.now-x.lastFrameAt>=VLCClockResyncPolicy.earlyNoFrameSeconds &&
        x.selectedRate>2 && VLCClockResyncPolicy.validRecoveryRate(x.selectedRate) &&
        x.effectiveRate.isFinite && abs(x.effectiveRate-x.selectedRate)<=0.01 &&
        x.nowUS>0 && x.sampleUS>0 && x.sampleUS<=x.nowUS && x.nowUS-x.sampleUS<=100_000 &&
        x.dropTick>0 && x.dropTick<=x.sampleUS && x.sampleUS-x.dropTick<=100_000 &&
        x.queueTick>0 && x.queueTick<=x.sampleUS && x.sampleUS-x.queueTick<=100_000 &&
        x.dropContextValid && x.dropContextRate.isFinite && abs(x.dropContextRate-x.selectedRate)<=0.01 &&
        x.dropRate.isFinite && abs(x.dropRate-x.selectedRate)<=0.01 && x.dropReference>0 &&
        x.dropPTS>=0 && x.queuePTS>=0 && x.queueValid>0 &&
        x.queueCount>=x.queueValid && x.queueCount>=x.admitted && x.admitted>=x.pop && x.pop>=x.lateDrop &&
        x.dropDeltaMS.isFinite && x.dropThresholdMS.isFinite && x.dropThresholdMS>0
    }
    static func seed(_ x:VLCClockResyncPolicy.Input)->Bool {
        valid(x) && -x.dropDeltaMS>x.dropThresholdMS &&
        -x.dropDeltaMS<max(VLCClockResyncPolicy.earlyMinimumLateMS,6*x.dropThresholdMS)
    }
    static func follows(_ x:VLCClockResyncPolicy.Input,_ old:VLCClockResyncPolicy.Input)->Bool {
        guard valid(x),x.sampleUS>old.sampleUS,x.selectedRate==old.selectedRate,
              x.lastFrameAt==old.lastFrameAt,x.dropPTS>old.dropPTS,x.dropTick>old.dropTick,
              x.queuePTS>old.queuePTS,x.queueTick>old.queueTick,x.dropClockID==old.dropClockID,
              x.dropReference>=old.dropReference,abs(x.dropThresholdMS-old.dropThresholdMS)<=0.001,
              x.queueCount>old.queueCount,x.queueValid>old.queueValid,x.admitted>old.admitted,
              x.pop>old.pop,x.lateDrop>old.lateDrop,x.queueInvalid==old.queueInvalid,
              x.queueRepeat==old.queueRepeat,x.queueBackward==old.queueBackward,
              x.errors==old.errors,x.renderNormal==old.renderNormal else{return false}
        let error=Double(x.dropTick-old.dropTick)/1000+x.dropDeltaMS-old.dropDeltaMS -
            Double(x.dropPTS-old.dropPTS)/(1000*x.selectedRate)
        return error.isFinite && abs(error)<=VLCClockResyncPolicy.earlyMaximumMappingErrorMS
    }
}
