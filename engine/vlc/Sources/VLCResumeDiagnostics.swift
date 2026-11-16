#if VISTA_VLC_CANDIDATE
import Foundation

/// Private ABI1 scalar slots. Presence, lifetime and native clock stay explicit.
/// This record is never read by playback policy. No media path or pointer enters it.
struct VLCResumeRecord:Codable,Sendable {
    enum Outcome:Int,Codable,Sendable {case window=1,superseded,pause,seek,source,stopped,ended,failed,unavailable,rejected}
    struct Slot:Codable,Sendable {
        let slot:Int,sequence:UInt64,present:UInt64,tickUS:Int64
        let role,reason:UInt32?
        let referenceGeneration:UInt64?
        let values:[Int64?]
        let rate,contextRate:Double?
        init(index:Int,event:vista_resume_event) {
            slot=index;sequence=event.sequence;present=event.present;tickUS=event.tick_us
            role=present & (1<<12) != 0 ? event.role:nil
            reason=present & (1<<13) != 0 ? event.reason:nil
            referenceGeneration=present & (1<<14) != 0 ? event.reference_generation:nil
            var scalars=event.value
            values=withUnsafeBytes(of:&scalars){bytes in
                bytes.bindMemory(to:Int64.self).enumerated().map {i,value in event.present & (1<<i) != 0 ? value:nil}
            }
            rate=present & (1<<10) != 0 && event.rate.isFinite ? event.rate:nil
            contextRate=present & (1<<11) != 0 && event.context_rate.isFinite ? event.context_rate:nil
        }
    }
    struct Native:Codable,Sendable {
        let snapshotUS,armedUS:Int64,resumeUS,endUS:Int64?
        let endReason,streamClosed:UInt32
        let validSlots,globalLost,registrationFailures:UInt64
        let reports,rejects,accepts,drops:UInt64
        let decoderLifetime,controlRequest,controlAck:UInt64
        let decodeSequence:UInt64?
        let decodeEntryUS,decodeExitUS,decodePTS:Int64?
        let decodeValid,controlSuperseded:UInt32
        let decodeActive:UInt32?
        init(_ s:vista_resume_snapshot_data) {
            snapshotUS=s.snapshot_us;armedUS=s.armed_us
            resumeUS=s.resume_us>0 ? s.resume_us:nil;endUS=s.end_reason != 0 && s.end_us>0 ? s.end_us:nil
            endReason=s.end_reason;streamClosed=s.stream_closed;validSlots=s.valid_slots
            globalLost=s.global_lost;registrationFailures=s.registration_failures
            reports=s.report_count;rejects=s.reject_count;accepts=s.accept_count;drops=s.drop_count
            decoderLifetime=s.decoder_lifetime;controlRequest=s.control_request_seq;controlAck=s.control_ack_seq;decodeSequence=s.decode_valid != 0 ? s.decode_seq:nil
            decodeEntryUS=s.decode_valid != 0 && s.decode_entry_us>0 ? s.decode_entry_us:nil
            decodeExitUS=s.decode_valid != 0 && s.decode_exit_us>0 ? s.decode_exit_us:nil
            decodePTS=s.decode_valid != 0 && s.decode_pts != 0 ? s.decode_pts:nil
            decodeValid=s.decode_valid;decodeActive=s.decode_valid != 0 ? s.decode_active:nil;controlSuperseded=s.control_superseded
        }
    }
    let schema:Int,group:Int,groups:Int
    let clockDomain:String,mediaDomain:String,watchDomain:String
    let session,command,revision:UInt64,seekNonce,sourceEpoch:UInt64?
    let requestedRate:Double,outcome:Outcome
    let markABI,markStatus:UInt32,instance,episode:UInt64?
    let setterStatus:Int32,resumeReturnUS:Int64?
    let snapshotABI,snapshotStatus:UInt32?
    let nativeFinishStatus:Int32?,nativeEndConfirmed:Bool?
    let native:Native?,slots:[Slot]
    let emittedEpisodes,suppressedEpisodes,coalescedArms:UInt64
}

/// A completed real seek nonce, never a presentation generation. Nil source is
/// valid for local media but still bound to the exact engine object lifetime.
struct VLCResumeSeekIdentity {
    private var value:(nonce:UInt64,engine:ObjectIdentifier,epoch:UInt64?)?
    mutating func clear() {value=nil}
    mutating func completed(nonce:UInt64,engine:ObjectIdentifier,epoch:UInt64?) {
        value=nonce>0 ? (nonce,engine,epoch):nil
    }
    mutating func source(epoch:UInt64?,recovering:Bool) {
        if recovering || value?.epoch != epoch {clear()}
    }
    func nonce(engine:ObjectIdentifier,epoch:UInt64?)->UInt64 {
        guard let value,value.engine==engine,value.epoch==epoch else{return 0}
        return value.nonce
    }
}

/// One active episode; three bounded records only at closure, never per frame.
/// Eight episode summaries per rolling minute renew, rather than first-N lifetime
/// exhaustion. Paused-rate supersedes before resume coalesce into the latest arm.
struct VLCResumeObserver {
    struct Command {
        let session,id,revision,seekNonce:UInt64,sourceEpoch:UInt64?
        let rate:Double,paused:Bool
    }
    private struct Active {
        let command:Command,mark:vista_resume_mark,setterStatus:Int32
        var snapshot:vista_resume_snapshot_data?
        var lastABI:UInt32?,lastStatus:UInt32?,resumeReturnUS:Int64?
        var finishStatus:Int32?
    }
    private var active:Active?
    private var windowStartUS:Int64?,windowEmitted=0
    private(set) var emitted:UInt64=0,suppressed:UInt64=0,coalesced:UInt64=0
    var hasActive:Bool {active != nil}
    static func reason(_ outcome:VLCResumeRecord.Outcome)->UInt32 {
        switch outcome {case .superseded:return 1;case .pause:return 2;case .seek:return 3;case .source:return 4;case .ended:return 6;default:return 5}
    }
    mutating func begin(_ command:Command,mark:vista_resume_mark,setterStatus:Int32,
                        previous:vista_resume_snapshot_data,previousFinishStatus:Int32?=nil,nowUS:Int64)->[VLCResumeRecord] {
        var result:[VLCResumeRecord]=[]
        if active != nil {
            update(previous)
            if active?.resumeReturnUS==nil,(active?.snapshot?.resume_us ?? 0)<=0 {
                active=nil;coalesced &+= 1
            } else {result=finish(.superseded,nativeFinishStatus:previousFinishStatus,nowUS:nowUS)}
        }
        guard command.paused else{return result}
        active=Active(command:command,mark:mark,setterStatus:setterStatus)
        if setterStatus != 0 {result += finish(.rejected,nowUS:nowUS)}
        return result
    }
    mutating func resumed(returnUS:Int64) {
        guard returnUS>0 else{return}
        active?.resumeReturnUS=returnUS
    }
    private func matches(_ s:vista_resume_snapshot_data,_ a:Active)->Bool {
        s.abi_version==1 && s.status==0 && a.mark.abi_version==1 && a.mark.status==0 &&
        s.instance_id==a.mark.instance_id && s.episode_id==a.mark.episode_id &&
        s.session_id==a.command.session && s.command_id==a.command.id &&
        s.revision==a.command.revision && s.seek_nonce==a.command.seekNonce
    }
    private mutating func update(_ snapshot:vista_resume_snapshot_data) {
        guard var a=active else{return}
        a.lastABI=snapshot.abi_version;a.lastStatus=snapshot.status
        if matches(snapshot,a) {a.snapshot=snapshot}
        active=a
    }
    mutating func observe(_ snapshot:vista_resume_snapshot_data,nowUS:Int64)->[VLCResumeRecord] {
        update(snapshot)
        guard let a=active else{return []}
        if matches(snapshot,a),snapshot.end_reason != 0 {
            let outcome:VLCResumeRecord.Outcome
            switch snapshot.end_reason {
            case 1:outcome = .superseded;case 2:outcome = .pause;case 3:outcome = .seek
            case 4:outcome = .source;case 5:outcome = .stopped;case 6:outcome = .ended
            case 7:outcome = .window;default:outcome = .unavailable
            }
            return finish(outcome,nowUS:nowUS)
        }
        // No timer. At an existing ordinary poll, stop waiting for a missing or
        // persistently busy native record after the bounded observation window.
        if let resumed=a.resumeReturnUS,nowUS>=resumed,nowUS-resumed>=4_000_000 {
            return finish(.unavailable,nowUS:nowUS)
        }
        return []
    }
    mutating func finish(_ outcome:VLCResumeRecord.Outcome,snapshot:vista_resume_snapshot_data?=nil,nativeFinishStatus:Int32?=nil,nowUS:Int64)->[VLCResumeRecord] {
        if let snapshot {update(snapshot)}
        if let nativeFinishStatus {active?.finishStatus=nativeFinishStatus}
        guard let a=active else{return []};active=nil
        if windowStartUS==nil || nowUS < windowStartUS! || nowUS-windowStartUS!>=60_000_000 {
            windowStartUS=nowUS;windowEmitted=0
        }
        guard windowEmitted<8 else{suppressed &+= 1;return []}
        windowEmitted += 1;emitted &+= 1
        var slots:[VLCResumeRecord.Slot]=[]
        if let s=a.snapshot {
            var raw=s.slots
            slots=withUnsafeBytes(of:&raw){bytes in
                bytes.bindMemory(to:vista_resume_event.self).enumerated().compactMap {index,event in
                    s.valid_slots & (1<<index) != 0 ? .init(index:index,event:event):nil
                }
            }
        }
        // Keep fixed ranges so missing slots/groups never look like zeros.
        let groups=slots.isEmpty ? 1:3
        return (0..<groups).map {group in
            .init(schema:1,group:group,groups:groups,clockDomain:"vlc_monotonic_us",mediaDomain:"vlc_native_ticks",watchDomain:"player_normalized_us",
                session:a.command.session,command:a.command.id,revision:a.command.revision,seekNonce:a.command.seekNonce>0 ? a.command.seekNonce:nil,sourceEpoch:a.command.sourceEpoch,
                requestedRate:a.command.rate,outcome:outcome,markABI:a.mark.abi_version,markStatus:a.mark.status,
                instance:a.mark.status==0 ? a.mark.instance_id:nil,episode:a.mark.status==0 ? a.mark.episode_id:nil,
                setterStatus:a.setterStatus,resumeReturnUS:a.resumeReturnUS,snapshotABI:a.lastABI,snapshotStatus:a.lastStatus,nativeFinishStatus:a.finishStatus,nativeEndConfirmed:a.snapshot.map{$0.end_reason != 0},
                native:a.snapshot.map(VLCResumeRecord.Native.init),slots:slots.filter{$0.slot/8==group},
                emittedEpisodes:emitted,suppressedEpisodes:suppressed,coalescedArms:coalesced)
        }
    }
}
#endif

#if VISTA_VLC_CANDIDATE
/// Passive same-frame timings. No diagnostic value feeds a playback decision.
struct VLCFrameStageRecord:Codable,Sendable {
    enum Outcome:Int,Codable,Sendable {case window=1,superseded,pause,seek,source,stopped,ended,failed,unavailable,rejected,pausedNotArmed}
    struct Sample:Codable,Sendable {
        let slot:Int,frameID,decoderGeneration,stageMask:UInt64
        let pts:Int64,outputPTS:Int64?,ticks:[Int64?]
        let outcome,metadataMask:UInt32
        let deadlineUS,thresholdUS,processingUS:Int64?
        let submitStatus,callbackStatus:Int32?
        let callbackFlags,contextID:UInt32?
        let videoRate:Double?,referenceGeneration:UInt64?
        let contextRate:Double?,queueMask:UInt32,queueID,queueEpoch,queueLost:UInt64
        let queueDepthBytes:[UInt64?],inputLoop:[Int64]?
        init(slot:Int,s:vista_frame_stage_sample) {
            self.slot=slot;frameID=s.frame_id;decoderGeneration=s.decoder_generation;stageMask=s.stage_mask
            pts=s.pts;outputPTS=s.metadata_mask & 128 != 0 ? s.output_pts:nil;outcome=s.outcome;metadataMask=s.metadata_mask
            contextRate=s.metadata_mask & 256 != 0 && s.context_rate.isFinite ? s.context_rate:nil
            queueMask=s.queue.mask;queueID=s.queue.id;queueEpoch=s.queue.epoch;queueLost=s.queue.lost
            queueDepthBytes=[s.queue.mask & 1 != 0 ? s.queue.enqueue_depth:nil,
                s.queue.mask & 2 != 0 ? s.queue.dequeue_depth:nil,
                s.queue.mask & 1 != 0 ? s.queue.enqueue_bytes:nil,
                s.queue.mask & 2 != 0 ? s.queue.dequeue_bytes:nil]
            inputLoop=s.queue.mask & 4 != 0 ? [s.queue.loop.0,s.queue.loop.1,s.queue.loop.2,s.queue.loop.3]:nil
            var raw=s.ticks
            ticks=withUnsafeBytes(of:&raw) { bytes in
                bytes.bindMemory(to:Int64.self).enumerated().map {i,t in s.stage_mask & (1<<i) != 0 ? t:nil}
            }
            // Metadata bit meanings are fixed by native ABI2, not inferred from zero.
            deadlineUS=s.metadata_mask & 1 != 0 ? s.deadline_us:nil
            thresholdUS=s.metadata_mask & 2 != 0 ? s.threshold_us:nil
            processingUS=s.metadata_mask & 2 != 0 ? s.processing_us:nil
            contextID=s.metadata_mask & 16 != 0 ? s.context_id:nil
            referenceGeneration=s.metadata_mask & 64 != 0 ? s.reference_generation:nil
            videoRate=s.metadata_mask & 32 != 0 && s.video_rate.isFinite ? s.video_rate:nil
            submitStatus=s.metadata_mask & 4 != 0 ? s.submit_status:nil
            callbackStatus=s.metadata_mask & 8 != 0 ? s.callback_status:nil
            callbackFlags=s.metadata_mask & 8 != 0 ? s.callback_flags:nil
        }
    }
    struct Native:Codable,Sendable {
        let armedUS,snapshotUS:Int64,endUS:Int64?
        let endReason,sampleMask:UInt32
        let framesStarted,framesPrepared,framesDropped,capacityLost,contentionLost,staleEvents:UInt64
        init(_ s:vista_frame_stage_snapshot_data) {
            armedUS=s.armed_us;snapshotUS=s.snapshot_us;endUS=s.end_reason != 0 && s.end_us>0 ? s.end_us:nil
            endReason=s.end_reason;sampleMask=s.sample_mask
            framesStarted=s.frames_started;framesPrepared=s.frames_prepared;framesDropped=s.frames_dropped
            capacityLost=s.capacity_lost;contentionLost=s.contention_lost;staleEvents=s.stale_events
        }
    }
    let schema:Int,clockDomain:String,mediaDomain:String
    let session,command,revision:UInt64,seekNonce,sourceEpoch:UInt64?
    let requestedRate:Double,pausedAtCommand:Bool,origin:Int,outcome:Outcome
    let markABI,markStatus:UInt32,instance,episode:UInt64?
    let setterStatus:Int32,snapshotABI,snapshotStatus:UInt32?
    let nativeFinishStatus:Int32?,nativeEndConfirmed:Bool?
    let native:Native?,samples:[Sample]
    let emittedEpisodes,suppressedEpisodes:UInt64
    let suppressedManualEpisodes,suppressedAutomaticEpisodes:UInt64
}

/// Independent from AudioBoundary completion. One bounded closure record,
/// Renewed quota: 8/minute, at most 2 manual, leaving room for a complete
/// six-step automatic 5x -> 2x chain. Existing ordinary 1Hz snapshots only.
/// Multiple chains can still exhaust the fixed budget; report both loss classes.
struct VLCFrameStageObserver {
    private struct Active {
        let command:VLCResumeObserver.Command,origin:Int,mark:vista_frame_stage_mark,setterStatus:Int32,startedUS:Int64
        var snapshot:vista_frame_stage_snapshot_data?
        var lastABI:UInt32?,lastStatus:UInt32?,finishStatus:Int32?
    }
    private var active:Active?,windowStartUS:Int64?,windowEmitted=0,windowManualEmitted=0
    private(set) var emitted:UInt64=0,suppressed:UInt64=0
    private(set) var suppressedManual:UInt64=0,suppressedAutomatic:UInt64=0
    var hasActive:Bool {active != nil}
    private func matches(_ s:vista_frame_stage_snapshot_data,_ a:Active)->Bool {
        s.abi_version==2 && s.status==0 && a.mark.abi_version==2 && a.mark.status==0 &&
        s.instance_id==a.mark.instance_id && s.episode_id==a.mark.episode_id &&
        s.session_id==a.command.session && s.command_id==a.command.id &&
        s.revision==a.command.revision && s.seek_nonce==a.command.seekNonce
    }
    private mutating func update(_ s:vista_frame_stage_snapshot_data) {
        guard var a=active else{return}
        a.lastABI=s.abi_version;a.lastStatus=s.status
        if matches(s,a){a.snapshot=s};active=a
    }
    mutating func begin(_ command:VLCResumeObserver.Command,origin:Int=1,mark:vista_frame_stage_mark,setterStatus:Int32,
                        previous:vista_frame_stage_snapshot_data,previousFinishStatus:Int32?,nowUS:Int64)->[VLCFrameStageRecord] {
        var records=finish(.superseded,snapshot:previous,nativeFinishStatus:previousFinishStatus,nowUS:nowUS)
        active=Active(command:command,origin:origin,mark:mark,setterStatus:setterStatus,startedUS:nowUS)
        if command.paused {records += finish(.pausedNotArmed,nowUS:nowUS)}
        else if setterStatus != 0 {records += finish(.rejected,nowUS:nowUS)}
        else if mark.abi_version != 2 || mark.status != 0 {records += finish(.unavailable,nowUS:nowUS)}
        return records
    }
    mutating func observe(_ s:vista_frame_stage_snapshot_data,nowUS:Int64)->[VLCFrameStageRecord] {
        update(s)
        guard let a=active else{return []}
        if matches(s,a),s.end_reason != 0 {
            let outcome:VLCFrameStageRecord.Outcome
            switch s.end_reason {case 1:outcome = .superseded;case 2:outcome = .pause;case 3:outcome = .seek;case 4:outcome = .source;case 5:outcome = .stopped;case 6:outcome = .ended;case 7:outcome = .window;default:outcome = .unavailable}
            return finish(outcome,nowUS:nowUS)
        }
        if nowUS>=a.startedUS,nowUS-a.startedUS>=4_500_000 {return finish(.unavailable,nowUS:nowUS)}
        return []
    }
    mutating func finish(_ outcome:VLCFrameStageRecord.Outcome,snapshot:vista_frame_stage_snapshot_data?=nil,
                         nativeFinishStatus:Int32?=nil,nowUS:Int64)->[VLCFrameStageRecord] {
        if let snapshot {update(snapshot)}
        if let nativeFinishStatus {active?.finishStatus=nativeFinishStatus}
        guard let a=active else{return []};active=nil
        if windowStartUS==nil || nowUS<windowStartUS! || nowUS-windowStartUS!>=60_000_000 {windowStartUS=nowUS;windowEmitted=0;windowManualEmitted=0}
        guard windowEmitted<8, a.origin==2 || windowManualEmitted<2 else {
            suppressed &+= 1
            if a.origin==2 {suppressedAutomatic &+= 1} else {suppressedManual &+= 1}
            return []
        }
        windowEmitted += 1;if a.origin != 2 {windowManualEmitted += 1};emitted &+= 1
        var samples:[VLCFrameStageRecord.Sample]=[]
        if let s=a.snapshot {
            var raw=s.samples
            samples=withUnsafeBytes(of:&raw) {bytes in
                bytes.bindMemory(to:vista_frame_stage_sample.self).enumerated().compactMap {i,v in
                    s.sample_mask & (1<<i) != 0 ? .init(slot:i,s:v):nil
                }
            }
        }
        return [.init(schema:2,clockDomain:"vlc_monotonic_us",mediaDomain:"vlc_native_ticks",
            session:a.command.session,command:a.command.id,revision:a.command.revision,
            seekNonce:a.command.seekNonce>0 ? a.command.seekNonce:nil,sourceEpoch:a.command.sourceEpoch,
            requestedRate:a.command.rate,pausedAtCommand:a.command.paused,origin:a.origin,outcome:outcome,
            markABI:a.mark.abi_version,markStatus:a.mark.status,instance:a.mark.status==0 ? a.mark.instance_id:nil,
            episode:a.mark.status==0 ? a.mark.episode_id:nil,setterStatus:a.setterStatus,snapshotABI:a.lastABI,snapshotStatus:a.lastStatus,
            nativeFinishStatus:a.finishStatus,nativeEndConfirmed:a.snapshot.map{$0.end_reason != 0},native:a.snapshot.map(VLCFrameStageRecord.Native.init),
            samples:samples,emittedEpisodes:emitted,suppressedEpisodes:suppressed,
            suppressedManualEpisodes:suppressedManual,suppressedAutomaticEpisodes:suppressedAutomatic)]
    }
}
#endif
