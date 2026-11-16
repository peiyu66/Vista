import Foundation

/// Pure, fixed-size control boundary for the existing automatic-speed policy.
/// Native get_rate/set_rate report requests, not output-rate confirmation. Only
/// a post-command watch point, interpolated by LibVLC, can open the sparse gate.
/// An unchanged watch sequence is valid across polls (native updates may be 10s
/// apart); repeated PTS and bridge take counts never stand in for new output.
struct VLCAutomaticSpeedAdapter {
    struct Command:Equatable {let revision:UInt64,rate:Double}
    struct Timing {
        var sequence:UInt64,seekSequence:UInt64
        var rate:Double,clock:Double
        var valid:Bool,paused:Bool,seeking:Bool,buffering:Bool
    }
    private(set) var selectedSpeed=1.0,effectiveRate=0.0
    private(set) var revision:UInt64=0
    private(set) var staleCompletions:UInt64=0
    private(set) var rateConfirmed=false
    private(set) var policy=PlaybackAutomaticSpeedPolicy()
    private var submittedSpeed:Double?=1
    private var watchFloor:UInt64=0,lastWatch:UInt64=0,lastSeek:UInt64=0
    private var sourceEpoch:UInt64?,sourceObserved=false,wasRecovering=false
    private(set) var timing:Timing?
    var needsRateCommand:Bool{submittedSpeed != selectedSpeed}
    var diagnostics:PlaybackAutomaticSpeedPolicy.DiagnosticSnapshot{policy.diagnostics}

    mutating func interrupt(reason:PlaybackAutomaticSpeedPolicy.ResetReason = .interruption) {
        revision &+= 1;watchFloor=lastWatch;effectiveRate=0;rateConfirmed=false
        policy.interruptObservation(reason:reason)
    }
    mutating func manualRate(_ rate:Double,now:Double) {
        revision &+= 1;selectedSpeed=rate;submittedSpeed=nil
        watchFloor=lastWatch;effectiveRate=0;rateConfirmed=false
        policy.manualSpeedDidChange(now:now)
    }
    /// Capture immediately before the one serialized engine setter. No returned
    /// receipt may overwrite intent that changed during that actor suspension.
    mutating func beginCommand()->Command {
        submittedSpeed=nil
        return Command(revision:revision,rate:selectedSpeed)
    }
    @discardableResult mutating func complete(_ command:Command,accepted:Bool,watchFloor:UInt64)->Bool {
        guard command.revision==revision,command.rate==selectedSpeed else {
            staleCompletions=min(9_007_199_254_740_991,staleCompletions+1);return false
        }
        guard accepted else{return false}
        submittedSpeed=command.rate;self.watchFloor=max(self.watchFloor,watchFloor)
        effectiveRate=0;rateConfirmed=false;return true
    }
    /// Source recovery/epoch is read-only context, never a new recovery strategy.
    @discardableResult mutating func observeSource(epoch:UInt64?,recovering:Bool)->Bool {
        let changed=sourceObserved && sourceEpoch != epoch
        let entered=recovering && !wasRecovering
        sourceObserved=true;sourceEpoch=epoch;wasRecovering=recovering
        if changed || entered {interrupt(reason:.recovery)}
        return changed || entered
    }
    mutating func discardTiming(through sequence:UInt64) {
        lastWatch=max(lastWatch,sequence);watchFloor=max(watchFloor,sequence)
        effectiveRate=0;rateConfirmed=false
    }
    mutating func observeTiming(_ value:Timing) {
        if value.seekSequence != lastSeek {interrupt();lastSeek=value.seekSequence;watchFloor=max(watchFloor,value.sequence)}
        lastWatch=value.sequence;timing=value
        // A frozen/zero native clock is not user pause. It closes only the
        // sparse-rate gate; independent native buffering still enters waiting.
        guard submittedSpeed==selectedSpeed,value.sequence>watchFloor,value.valid,
              !value.paused,!value.seeking,value.clock.isFinite,value.clock>=0,
              value.rate.isFinite else {effectiveRate=0;rateConfirmed=false;return}
        effectiveRate=value.rate
        rateConfirmed=value.rate>0 && abs(value.rate-selectedSpeed)<=PlaybackAutomaticSpeedPolicy.effectiveRateTolerance
    }
    mutating func update(now:Double,ready:Bool,eligible:Bool,paused:Bool,
                         outputPolled:Bool,publishedPTS:Double?,queueSample:PlaybackQueuePressureSample?=nil,deferReductions:Bool=false)->PlaybackAutomaticSpeedPolicy.Decision? {
        guard let timing else{return nil}
        let status=PlaybackSpeedStatus(selected:selectedSpeed,effectiveRate:effectiveRate,ready:ready,
            supportsFastForward:true,paused:paused,waiting:timing.buffering)
        // UI "no publish for .5s" is deliberately absent. Native buffering is
        // independent of rate acknowledgement and is not proof of SMB I/O wait.
        let decision=policy.update(now:now,status:status,eligible:eligible && !timing.seeking,
            playing:!timing.paused && !timing.seeking && !timing.buffering,
            clock:timing.clock,outputPolled:outputPolled,copiedFramePTS:publishedPTS,queueSample:queueSample,deferReductions:deferReductions)
        if let decision {
            revision &+= 1;selectedSpeed=decision.nextSpeed;submittedSpeed=nil
            watchFloor=lastWatch;effectiveRate=0;rateConfirmed=false
        }
        return decision
    }
}
