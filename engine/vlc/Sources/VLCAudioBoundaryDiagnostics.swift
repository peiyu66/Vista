#if VISTA_VLC_CANDIDATE
import Foundation

/// Typed anonymous data only. This observer is not consulted by playback policy.
struct VLCAudioBoundaryRecord:Codable,Sendable {
    enum Outcome:Int,Codable,Sendable {case observed=1,superseded,pause,seek,source,stopped,failed,ended,unavailable,rejected,evicted}
    enum Origin:Int,Codable,Sendable {case manual=1,automatic}
    struct Video:Codable,Sendable {
        let appUptime:Double
        let nativeNowUS:Int64
        let values:[String:Double]
        init(_ input:[PlaybackLogField:Double],at:Double,nativeNowUS:Int64) {
            appUptime=at;self.nativeNowUS=nativeNowUS
            let pairs:[(String,PlaybackLogField)]=[
                ("vtSubmit",.vlcVTSubmit),("vtCallback",.vlcVTCallback),
                ("queue",.vlcNativeQueueCount),("lateDrop",.vlcNativeLateDrop),("normal",.vlcNativeRenderNormal),
                ("published",.vlcFramesPublished),("clockRejected",.vlcClockRejected),
                ("nativeSampleSeconds",.vlcNativeDiagSampleClock),("nativeAgeMS",.vlcNativeDiagAgeMS),
                ("watch",.vlcWatchUpdates),("publishedPTS",.vlcPublishedPTS),
                ("resyncAttempt",.vlcResyncAttempts),("resyncOutcome",.vlcResyncOutcome),
                ("resyncTriggerSeconds",.vlcResyncTriggerClock),("resyncDispatchSeconds",.vlcResyncCommandClock),
                ("resyncAcceptedMS",.vlcResyncObservedMS)]
            var mapped:[String:Double]=[:]
            for (name,key) in pairs {if let value=input[key],value.isFinite {mapped[name]=value}}
            if let sample=mapped["nativeSampleSeconds"] {mapped["nativeAgeMS"]=max(0,Double(nativeNowUS)/1000-sample*1000)}
            values=mapped
        }
    }
    struct Native:Codable,Sendable {
        let nativePTSDomain,watchPTSDomain:String
        let instance,episode:UInt64
        let valid,endReason:UInt32
        let requestedRate:Double?,audioRate:Double?
        let reports,rejected,accepted:UInt64
        let command_us:Int64?
        let change_us:Int64?
        let block_us,boundary_system_us,boundary_audio_us:Int64?
        let enqueue_us,enqueue_date_us,fifo_after_enqueue_us,block_length_us:Int64?
        let first_report_us,first_report_system_us,first_report_audio_us,last_report_us,last_report_system_us,last_report_audio_us:Int64?
        let first_reject_us,first_reject_system_us,last_reject_us,last_reject_system_us:Int64?
        let accept_us,accept_system_us,accept_audio_us,accept_clock_audio_us:Int64?
        let watch_us,watch_system_us,watch_audio_us,watch_accept_us:Int64?
        let watch_native_audio_us,watch_pts_offset_us:Int64?
        let end_us:Int64?
        init(_ e:vista_audio_boundary_episode) {
            nativePTSDomain="vlc_audio_ticks";watchPTSDomain="player_normalized_us"
            instance=e.instance_id;episode=e.episode_id;valid=e.valid;endReason=e.end_reason
            requestedRate=e.requested_rate.isFinite ? e.requested_rate:nil
            audioRate=e.valid & 2 != 0 && e.audio_rate.isFinite ? e.audio_rate:nil
            reports=e.report_count;rejected=e.reject_count;accepted=e.accept_count
            command_us=e.valid & 1 != 0 ? e.command_us:nil
            change_us=e.valid & 2 != 0 ? e.change_us:nil
            block_us=e.valid & 4 != 0 ? e.block_us:nil
            boundary_system_us=e.valid & 4 != 0 ? e.boundary_system_us:nil
            boundary_audio_us=e.valid & 4 != 0 ? e.boundary_audio_us:nil
            enqueue_us=e.valid & 8 != 0 ? e.enqueue_us:nil
            enqueue_date_us=e.valid & 8 != 0 ? e.enqueue_date_us:nil
            fifo_after_enqueue_us=e.valid & 8 != 0 ? e.fifo_after_enqueue_us:nil
            block_length_us=e.valid & 8 != 0 ? e.block_length_us:nil
            first_report_us=e.valid & 16 != 0 ? e.first_report_us:nil
            first_report_system_us=e.valid & 16 != 0 ? e.first_report_system_us:nil
            first_report_audio_us=e.valid & 16 != 0 ? e.first_report_audio_us:nil
            last_report_us=e.valid & 16 != 0 ? e.last_report_us:nil
            last_report_system_us=e.valid & 16 != 0 ? e.last_report_system_us:nil
            last_report_audio_us=e.valid & 16 != 0 ? e.last_report_audio_us:nil
            first_reject_us=e.valid & 32 != 0 ? e.first_reject_us:nil
            first_reject_system_us=e.valid & 32 != 0 ? e.first_reject_system_us:nil
            last_reject_us=e.valid & 32 != 0 ? e.last_reject_us:nil
            last_reject_system_us=e.valid & 32 != 0 ? e.last_reject_system_us:nil
            accept_us=e.valid & 64 != 0 ? e.accept_us:nil
            accept_system_us=e.valid & 64 != 0 ? e.accept_system_us:nil
            accept_audio_us=e.valid & 64 != 0 ? e.accept_audio_us:nil
            accept_clock_audio_us=e.valid & 64 != 0 ? e.accept_clock_audio_us:nil
            watch_native_audio_us=e.valid & 128 != 0 ? e.watch_native_audio_us:nil
            watch_pts_offset_us=e.valid & 256 != 0 ? e.watch_pts_offset_us:nil
            watch_accept_us=e.valid & 128 != 0 ? e.watch_accept_us:nil
            watch_us=e.valid & 128 != 0 ? e.watch_us:nil
            watch_system_us=e.valid & 128 != 0 ? e.watch_system_us:nil
            watch_audio_us=e.valid & 128 != 0 ? e.watch_audio_us:nil
            end_us=e.end_reason != 0 ? e.end_us:nil
        }
    }
    let schema:Int
    let clockDomain:String
    let markABI,snapshotABI:UInt32?
    let session,command,revision:UInt64
    let sourceEpoch:UInt64?
    let origin:Origin,outcome:Outcome
    let requestedRate:Double
    let commandIntentNativeUS:Int64
    let setterStatus:Int32?,setterReturnUS:Int64?,watchFloor:UInt64?
    let markStatus:UInt32?,markInstance:UInt64?,markEpisode:UInt64?
    let snapshotStatus:UInt32?,snapshotNativeUS:Int64?,finishStatus:Int32?
    let overwritten,dropped,globalDropped,registrationFailures:UInt64?
    let native:Native?
    let before,after:Video
    let summariesEmitted,summariesSuppressed:UInt64
}

/// One pending command, bounded per-session output. Native ring losses remain
/// explicit; old source/engine IDs cannot be reassigned to the latest command.
struct VLCAudioBoundaryObserver {
    static let maximumSummaries:UInt64=64
    struct Command {
        let session,id,revision:UInt64,sourceEpoch:UInt64?
        let origin:VLCAudioBoundaryRecord.Origin,rate:Double,intentUS:Int64
        let video:VLCAudioBoundaryRecord.Video
    }
    private struct Active {
        let command:Command,receipt:VLCVistaAudioRateReceipt
        var snapshot:vista_audio_boundary_snapshot_data?
    }
    private var active:Active?
    private(set) var emitted:UInt64=0,suppressed:UInt64=0
    var hasActive:Bool {active != nil}
    mutating func begin(_ command:Command,receipt:VLCVistaAudioRateReceipt,after:VLCAudioBoundaryRecord.Video)->[VLCAudioBoundaryRecord] {
        var output:[VLCAudioBoundaryRecord]=[]
        if let record=finish(.superseded,snapshot:receipt.previous,finishStatus:receipt.finish_status,after:after){output.append(record)}
        active=Active(command:command,receipt:receipt)
        if receipt.rate.status != 0 {
            if let record=finish(.rejected,after:after){output.append(record)}
        } else if receipt.mark.status != 0 || receipt.mark.abi_version != 2 {
            if let record=finish(.unavailable,after:after){output.append(record)}
        }
        return output
    }
    mutating func observe(_ snapshot:vista_audio_boundary_snapshot_data,after:VLCAudioBoundaryRecord.Video)->VLCAudioBoundaryRecord? {
        guard var value=active else{return nil}
        if snapshot.abi_version==2,snapshot.status==0,snapshot.instance_id==value.receipt.mark.instance_id {value.snapshot=snapshot;active=value}
        guard let episode=matching(snapshot,command:value.command,mark:value.receipt.mark) else {
            if snapshot.status==0,snapshot.instance_id==value.receipt.mark.instance_id,snapshot.overwritten_episodes>0 {
                return finish(.evicted,snapshot:snapshot,after:after)
            }
            return nil
        }
        if episode.valid & 128 != 0 {return finish(.observed,snapshot:snapshot,after:after)}
        if episode.end_reason != 0 {
            let outcome:VLCAudioBoundaryRecord.Outcome
            switch episode.end_reason {case 1:outcome = .superseded;case 2:outcome = .pause;case 3:outcome = .seek;case 4:outcome = .source;case 5:outcome = .stopped;default:outcome = .ended}
            return finish(outcome,snapshot:snapshot,after:after)
        }
        return nil
    }
    mutating func finish(_ outcome:VLCAudioBoundaryRecord.Outcome,snapshot:vista_audio_boundary_snapshot_data?=nil,
                         finishStatus:Int32?=nil,after:VLCAudioBoundaryRecord.Video)->VLCAudioBoundaryRecord? {
        guard let value=active else{return nil};active=nil
        guard emitted<Self.maximumSummaries else{suppressed=min(9_007_199_254_740_991,suppressed+1);return nil}
        emitted += 1
        let candidate=snapshot ?? value.snapshot
        // An unavailable terminal snapshot never masquerades as a current zero.
        let episode=candidate.flatMap{matching($0,command:value.command,mark:value.receipt.mark)}
        let validSnapshot=candidate.flatMap{$0.abi_version==2 && $0.status==0 && $0.instance_id==value.receipt.mark.instance_id ? $0:nil}
        let c=value.command,r=value.receipt
        return .init(schema:1,clockDomain:"vlc_monotonic_us",markABI:r.mark.abi_version,snapshotABI:candidate?.abi_version,session:c.session,command:c.id,revision:c.revision,sourceEpoch:c.sourceEpoch,
            origin:c.origin,outcome:outcome,requestedRate:c.rate,commandIntentNativeUS:c.intentUS,
            setterStatus:r.rate.status,setterReturnUS:r.rate.command_clock_us,watchFloor:r.rate.watch_floor,
            markStatus:r.mark.status,markInstance:r.mark.status==0 ? r.mark.instance_id:nil,
            markEpisode:r.mark.status==0 ? r.mark.episode_id:nil,snapshotStatus:candidate?.status,
            snapshotNativeUS:validSnapshot?.snapshot_us,finishStatus:finishStatus,
            overwritten:validSnapshot?.overwritten_episodes,dropped:validSnapshot.flatMap{$0.dropped_events==UInt64.max ? nil:$0.dropped_events},
            globalDropped:candidate?.global_dropped_events,registrationFailures:candidate?.registration_failures,
            native:episode.map(VLCAudioBoundaryRecord.Native.init),before:c.video,after:after,
            summariesEmitted:emitted,summariesSuppressed:suppressed)
    }
    private func matching(_ snapshot:vista_audio_boundary_snapshot_data,command:Command,mark:vista_audio_boundary_mark)->vista_audio_boundary_episode? {
        guard mark.abi_version==2,snapshot.abi_version==2,snapshot.status==0,snapshot.instance_id==mark.instance_id else{return nil}
        var episodes=snapshot.episodes
        return withUnsafeBytes(of:&episodes){bytes in
            let rows=bytes.bindMemory(to:vista_audio_boundary_episode.self)
            for row in rows.prefix(min(Int(snapshot.count),8)) {
                if row.session_id==command.session,row.command_id==command.id,row.episode_id==mark.episode_id,
                   row.instance_id==mark.instance_id {return row}
            }
            return nil
        }
    }
}
#endif
