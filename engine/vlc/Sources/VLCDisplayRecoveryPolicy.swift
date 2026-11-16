/// Presentation-only alternative to the second clock check. Native Display is
/// already scheduled by VLC, but is NOT a seek-flush fence. A bounded timeline
/// anchored by the original clock/seek gate is still required for recovery.
struct VLCDisplayRecoveryPolicy {
    struct Frame {
        let rawPTS:Int64,tickZero:Int64,ticksPerSecond:Int64,displayUS:Int64
        let producer:UInt64
        var ptsUS:Int64? {
            // This bundled VLC uses CLOCK_FREQ=1e6. Reject sentinels/overflow
            // before subtraction, conversion or any seek-policy arithmetic.
            guard ticksPerSecond==1_000_000,rawPTS != Int64.max,
                  rawPTS != Int64.min,tickZero==1 else{return nil}
            let (pts,overflow)=rawPTS.subtractingReportingOverflow(tickZero)
            return !overflow && pts>=0 ? pts:nil
        }
    }
    struct Context {
        var eligible:Bool,userPaused:Bool,nativePlaying:Bool
        var timerValid:Bool,timerPaused:Bool,seeking:Bool,buffering:Bool
        var clockUS:Int64,nowUS:Int64,rate:Double
    }
    enum Result:Int {
        case invalid=1,intent,producer,display,nonadvancing,clock,timeline
        case clockAccepted=10,recovered
        var accepted:Bool{self == .clockAccepted || self == .recovered}
    }
    private(set) var lastAccepted:Frame?
    private var anchorPTS:Int64?,anchorDisplay:Int64=0
    private var commandFloor:Int64=0,lastDisplay:Int64=0
    private(set) var recoveryCount:UInt64=0,nonadvancingCount:UInt64=0
    private(set) var timelineRejected:UInt64=0
    private(set) var lastResult:Result = .intent
    private(set) var lastAgeMS = -1.0,lastUpperPTS = -1.0

    static func validClock(_ value:Int64)->Bool{value>0 && value<Int64.max}
    mutating func invalidateTimeline(){anchorPTS=nil}
    /// Resume excludes all paused wall time. Rate commands cannot borrow any
    /// pre-command frame/blank time: only a subsequent normal-clock acceptance
    /// may establish their new-rate anchor. No delay or timeout is introduced.
    mutating func command(at clock:Int64,preserveTimeline:Bool) {
        guard Self.validClock(clock) else{commandFloor=Int64.max;anchorPTS=nil;return}
        commandFloor=max(commandFloor,clock)
        anchorPTS=preserveTimeline ? lastAccepted?.ptsUS:nil
        anchorDisplay=clock
    }
    /// Called ONLY after the unchanged target/clock/watch seek gate accepts the
    /// latest request. It intentionally permits a backward target as a new anchor.
    mutating func acceptSeek(_ frame:Frame) {
        lastAccepted=frame;anchorPTS=frame.ptsUS
        // The original seek gate verifies the media target, not a native flush.
        // Even a matching target snapshot from before the command cannot grant
        // elapsed-time credit from the previous presentation timeline.
        anchorDisplay=max(frame.displayUS,commandFloor)
        lastDisplay=frame.displayUS
    }
    mutating func evaluate(_ frame:Frame,_ c:Context)->Result {
        let result=decide(frame,c);lastResult=result
        if result == .recovered{recoveryCount=min(9_007_199_254_740_991,recoveryCount+1)}
        if result == .nonadvancing{nonadvancingCount=min(9_007_199_254_740_991,nonadvancingCount+1)}
        if result == .timeline{timelineRejected=min(9_007_199_254_740_991,timelineRejected+1)}
        return result
    }
    private mutating func decide(_ frame:Frame,_ c:Context)->Result {
        lastAgeMS = -1;lastUpperPTS = -1
        guard let pts=frame.ptsUS else{return .invalid}
        guard c.eligible else{return .intent}
        if let previous=lastAccepted,previous.producer != frame.producer{return .producer}
        let validDisplay=Self.validClock(frame.displayUS) && Self.validClock(c.nowUS) && frame.displayUS<=c.nowUS
        if validDisplay{lastAgeMS=Double(c.nowUS-frame.displayUS)/1_000}
        let seconds=Double(pts)/1e6,clock=Double(c.clockUS)/1e6
        if c.clockUS>=0,c.clockUS<Int64.max,abs(seconds-clock)<=0.25 {
            // Original normal-clock publication semantics, including redisplay,
            // are preserved. Only a NEW post-command frame can seed recovery.
            if validDisplay,frame.displayUS>commandFloor,frame.displayUS>lastDisplay,
               lastAccepted?.ptsUS.map({pts>$0}) ?? true {
                lastAccepted=frame;anchorPTS=pts;anchorDisplay=frame.displayUS
                lastDisplay=frame.displayUS
            }
            return .clockAccepted
        }
        // Only the observed paused/provisional-clock failure has an alternative.
        // Native buffering and an already scheduled advancing Display coexist
        // in the observed 119 failures. Buffering is diagnostic, not a veto of
        // this independent display evidence. Do not change the waiting policy.
        guard c.timerValid,c.timerPaused,!c.userPaused,c.nativePlaying,!c.seeking,
              c.rate.isFinite,c.rate>0 else{return .clock}
        guard validDisplay else{return .invalid}
        guard frame.displayUS>commandFloor,frame.displayUS>lastDisplay else{return .display}
        lastDisplay=frame.displayUS
        guard let previous=lastAccepted?.ptsUS,pts>previous else{return .nonadvancing}
        guard let anchorPTS,frame.displayUS>=anchorDisplay else{return .timeline}
        let upper=Double(anchorPTS)/1e6 + Double(frame.displayUS-anchorDisplay)/1e6*c.rate + 0.25
        lastUpperPTS=upper.isFinite ? upper:-1
        guard upper.isFinite,seconds<=upper else{return .timeline}
        // Keep the fixed clock/seek/resume anchor during recovery. Moving it on
        // each fallback frame would incorrectly accumulate 250ms of extra slack.
        lastAccepted=frame
        return .recovered
    }
}
