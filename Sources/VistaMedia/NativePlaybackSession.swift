import Foundation
@preconcurrency import AVFoundation
import CoreVideo
#if os(visionOS)
import UIKit

/// Latest display deadline only; never accumulate a queue of refresh callbacks.
@MainActor private final class NativeDisplayClock:NSObject {
 private var link:CADisplayLink?
 private var pending:CFTimeInterval?
 func start(){let value=CADisplayLink(target:self,selector:#selector(tick));link=value;value.add(to:.main,forMode:.common)}
 @objc private func tick(_ link:CADisplayLink){pending=link.targetTimestamp}
 func take()->CFTimeInterval?{defer{pending=nil};return pending}
 func stop(){link?.invalidate();link=nil;pending=nil}
}
#endif
#if SWIFT_PACKAGE
import VistaCore
#endif

/// One bounded aggregate per request. Overlapping read durations are not wall time.
struct NativeStageSnapshot:Equatable {
 let at:Double,reads:Int,bytes:Int,readSeconds:Double,interrupted:Int,waitingSeconds:Double
 let reason:String
}
struct NativeRequestMetrics {
 var epoch=0,reads=0,bytes=0,interrupted=0
 var started=0.0,readSeconds=0.0,waitingSeconds=0.0
 var waitingSince:Double?,seekCompleted:Double?,firstFrame:Double?,firstPTS:Double?
 var reason="無",kind="開片"
 var target:Double?,targetBuffered:Bool?
 var seekSnapshot:NativeStageSnapshot?,firstSnapshot:NativeStageSnapshot?,presentationSnapshot:NativeStageSnapshot?
 func snapshot(now:Double)->NativeStageSnapshot {
  .init(at:now,reads:reads,bytes:bytes,readSeconds:readSeconds,interrupted:interrupted,
        waitingSeconds:waitingSeconds+(waitingSince.map{max(0,now-$0)} ?? 0),reason:reason)
 }
 mutating func completeSeek(now:Double){guard seekSnapshot==nil else{return};seekCompleted=now;seekSnapshot=snapshot(now:now)}
 mutating func deliverFirst(now:Double,pts:Double){guard firstSnapshot==nil else{return};firstFrame=now;firstPTS=pts;firstSnapshot=snapshot(now:now)}
 mutating func present(now:Double){guard presentationSnapshot==nil else{return};presentationSnapshot=snapshot(now:now)}
 static func isBuffered(_ target:Double,ranges:[Range<Double>])->Bool {
  guard target.isFinite else{return false}
  return ranges.contains{$0.lowerBound.isFinite && $0.upperBound.isFinite && $0.contains(target)}
 }
 mutating func begin(_ kind:String,now:Double){let next=epoch+1;self=Self();epoch=next;started=now;self.kind=kind}
 mutating func endRead(epoch:Int,bytes:Int,seconds:Double,interrupted:Bool){
  guard epoch==self.epoch else{return};reads += 1;self.bytes += bytes;readSeconds += seconds
  if interrupted {self.interrupted += 1}
 }
 mutating func waiting(_ value:Bool,reason:String,now:Double){
  if value {if waitingSince==nil {waitingSince=now};self.reason=reason}
  else if let start=waitingSince {waitingSeconds += max(0,now-start);waitingSince=nil}
 }
 func text(now:Double)->String {
  func stage(_ name:String,_ value:NativeStageSnapshot?)->String {
   guard let v=value else{return "\(name)：—"}
   return "\(name) \(Int((v.at-started)*1000)) ms／讀\(v.reads)、\(v.bytes) B、Σ\(Int(v.readSeconds*1000)) ms／中止\(v.interrupted)／等\(Int(v.waitingSeconds*1000)) ms（\(v.reason)）"
  }
  let targetText=target.map{String(format:"%.2f",$0)} ?? "—"
  let buffered=targetBuffered.map{$0 ? "是":"未報告涵蓋"} ?? "不適用"
  return "請求 \(epoch) \(kind)／目標 \(targetText) s／已緩衝：\(buffered)\n" +
   [stage("seek",seekSnapshot),stage("首幀",firstSnapshot),stage("呈現通知",presentationSnapshot)].joined(separator:"\n")
 }

}

#if VISTA_ANON_IO_EXPERIMENT
struct AnonymousIOSnapshot:Equatable {
 let started:Int,finished:Int,cancelled:Int,failed:Int,inFlight:Int,oldAtStart:Int,oldRemaining:Int,peak:Int,bytes:Int,overflow:Int
 let maxTotalMS:Double,lastOldMS:Double
 var text:String {"I/O 起\(started) 完\(finished) 取消\(cancelled) 錯\(failed) 在途\(inFlight) 峰\(peak) B\(bytes) 溢\(overflow) 舊\(oldAtStart)/\(oldRemaining) 舊尾\(Int(lastOldMS))ms 最長總等待\(Int(maxTotalMS))ms"}
}
@MainActor final class AnonymousIOAggregate {
 private struct Slot {let epoch:Int,start:Double}
 private var slots:[UInt64:Slot]=[:],serial:UInt64=0,epoch=0
 private var epochStart=0.0,started=0,finished=0,cancelled=0,failed=0,oldAtStart=0,peak=0,bytes=0
 private var maxTotalMS=0.0,lastOldMS=0.0
 private(set) var overflow=0
 func beginEpoch(now:Double) {epoch += 1;epochStart=now;started=0;finished=0;cancelled=0;failed=0;oldAtStart=slots.count;peak=slots.count;bytes=0;maxTotalMS=0;lastOldMS=0}
 func begin(now:Double)->UInt64? {
  guard slots.count<8 else{overflow += 1;return nil}
  serial &+= 1;slots[serial]=Slot(epoch:epoch,start:now);started += 1;peak=max(peak,slots.count);return serial
 }
 func end(_ id:UInt64?,now:Double,bytes count:Int,cancelled wasCancelled:Bool,failed wasFailed:Bool) {
  guard let id,let slot=slots.removeValue(forKey:id) else{return}
  if slot.epoch != epoch {lastOldMS=max(lastOldMS,max(0,now-epochStart)*1000);return}
  finished += 1;bytes += max(0,count);if wasCancelled {cancelled += 1};if wasFailed {failed += 1}
  maxTotalMS=max(maxTotalMS,max(0,now-slot.start)*1000)
 }
 func snapshot()->AnonymousIOSnapshot {.init(started:started,finished:finished,cancelled:cancelled,failed:failed,inFlight:slots.count,oldAtStart:oldAtStart,oldRemaining:slots.values.filter{$0.epoch != epoch}.count,peak:peak,bytes:bytes,overflow:overflow,maxTotalMS:maxTotalMS,lastOldMS:lastOldMS)}
}
#endif

/// Controlled AVPlayer candidate. No claim about the internal decoder identity.
@MainActor public final class NativePlaybackSession {
 public enum State:Equatable,Sendable {case preparing,playing,waiting,paused,seeking,ended}
 public enum Failure:Error,Equatable {case source,stalled,player,unsupported}
 public let decoderDescription="解碼方式：系統管理（未知）"
 #if os(visionOS)
 private var displayClock:NativeDisplayClock?
 #endif
 var experimentPlayerTime:Double?{player?.currentTime().seconds}
 private var player:AVPlayer?
 private var item:AVPlayerItem?
 private var asset:AVURLAsset?
 private var bridge:ResourceBridge?
 private var running=false,prepared=false
 private var active=false,sourceFailed=false,paused=false,seeking=false
 private var seekGeneration=UUID(),frameSession=UUID()
 private var lastProgress=0.0
 private let stallLimit:Double
 private let muted:Bool
 private var frames=0,waits=0
 private var maxClockDifference=0.0
 public private(set) var diagnosticsText="AVPlayer 候選／解碼方式：系統管理（未知）"
 private var diagnosticUpdate=0.0
 #if VISTA_ANON_IO_EXPERIMENT
 var experimentItem:AVPlayerItem?{item}
 private var anonymousIO=AnonymousIOAggregate()
 private var anonymousStages:[String:AnonymousIOSnapshot]=[:]
 #endif
 private(set) var requestMetrics=NativeRequestMetrics()
 public init(stallLimit:Double=15,muted:Bool=false) {self.stallLimit=max(0.1,stallLimit);self.muted=muted}
 public func anonymousLogValues()->[PlaybackLogField:Double] {
  let m=requestMetrics;var v:[PlaybackLogField:Double]=[.frames:Double(frames),.waits:Double(waits),.clockDeltaMS:maxClockDifference*1000,.epoch:Double(m.epoch),.reads:Double(m.reads),.bytes:Double(m.bytes),.readMS:m.readSeconds*1000,.interrupted:Double(m.interrupted),.waitMS:m.waitingSeconds*1000]
  if let target=m.target {v[.target]=target};if let buffered=m.targetBuffered {v[.targetBuffered]=buffered ? 1:0}
  for (stage,at,reads,bytes) in [(m.seekSnapshot,PlaybackLogField.seekMS,PlaybackLogField.seekReads,PlaybackLogField.seekBytes),(m.firstSnapshot,PlaybackLogField.firstFrameMS,PlaybackLogField.firstReads,PlaybackLogField.firstBytes),(m.presentationSnapshot,PlaybackLogField.presentMS,PlaybackLogField.presentReads,PlaybackLogField.presentBytes)] {
   if let stage {v[at]=max(0,stage.at-m.started)*1000;v[reads]=Double(stage.reads);v[bytes]=Double(stage.bytes)}
  }
  let detail:[(NativeStageSnapshot?,PlaybackLogField,PlaybackLogField,PlaybackLogField)]=[(m.seekSnapshot,.seekReadMS,.seekWaitMS,.seekInterrupted),(m.firstSnapshot,.firstReadMS,.firstWaitMS,.firstInterrupted),(m.presentationSnapshot,.presentReadMS,.presentWaitMS,.presentInterrupted)]
  for(stage,read,wait,cancel) in detail {if let stage {v[read]=stage.readSeconds*1000;v[wait]=stage.waitingSeconds*1000;v[cancel]=Double(stage.interrupted)}}
  #if VISTA_ANON_IO_EXPERIMENT
  let io=anonymousIO.snapshot()
  v[.ioStarted]=Double(io.started);v[.ioFinished]=Double(io.finished);v[.ioCancelled]=Double(io.cancelled);v[.ioFailed]=Double(io.failed);v[.ioInFlight]=Double(io.inFlight);v[.ioPeak]=Double(io.peak);v[.ioOld]=Double(io.oldAtStart);v[.ioOldRemaining]=Double(io.oldRemaining);v[.ioOldMS]=io.lastOldMS;v[.ioMaxMS]=io.maxTotalMS
  #endif
  return v
 }
 public private(set) var selectedSpeed=1
 public var speedStatus:PlaybackSpeedStatus {
  let effectiveRate=item?.timebase.map {CMTimebaseGetEffectiveRate($0)} ?? 0
  return PlaybackSpeedStatus(selected:selectedSpeed,effectiveRate:effectiveRate,ready:active && item?.status == .readyToPlay,
   supportsFastForward:item?.canPlayFastForward ?? false,paused:paused,waiting:player?.timeControlStatus == .waitingToPlayAtSpecifiedRate)
 }
 public var isPlaybackPaused:Bool {paused}
 @discardableResult public func setSpeed(_ requested:Int)->Bool {
  guard active,let player,speedStatus.accepts(requested) else{return false}
  selectedSpeed=requested;player.defaultRate=Float(requested)
  if !paused && !seeking {player.play()}
  return true
 }
 public func pause(){paused=true;player?.pause()}
 public func resume(){paused=false;lastProgress=ProcessInfo.processInfo.systemUptime;if !seeking {player?.play()}}
 public func seek(to target:Double,maximumBackward:Double=1,maximumForward:Double=0)async throws {
  guard target.isFinite,target>=0,let player,let item,active else{throw Failure.unsupported}
  let ranges=item.loadedTimeRanges.map(\.timeRangeValue).compactMap { range -> Range<Double>? in
   let start=range.start.seconds,end=CMTimeRangeGetEnd(range).seconds
   guard start.isFinite,end.isFinite,end>start else{return nil};return start..<end
  }
  let id=UUID();seekGeneration=id;seeking=true;player.pause();item.cancelPendingSeeks()
  requestMetrics.begin("跳轉",now:ProcessInfo.processInfo.systemUptime)
  #if VISTA_ANON_IO_EXPERIMENT
  anonymousIO.beginEpoch(now:ProcessInfo.processInfo.systemUptime);anonymousStages=[:]
  #endif
  requestMetrics.target=target;requestMetrics.targetBuffered=NativeRequestMetrics.isBuffered(target,ranges:ranges)
  maxClockDifference=0;diagnosticUpdate=0
  let finished=await player.seek(to:CMTime(seconds:target,preferredTimescale:60000),toleranceBefore:CMTime(seconds:min(1,max(0,maximumBackward)),preferredTimescale:60000),toleranceAfter:CMTime(seconds:min(1,max(0,maximumForward)),preferredTimescale:60000))
  guard active,seekGeneration==id else{throw CancellationError()}
  seeking=false;lastProgress=ProcessInfo.processInfo.systemUptime
  guard finished else{throw CancellationError()}
  requestMetrics.completeSeek(now:ProcessInfo.processInfo.systemUptime)
  #if VISTA_ANON_IO_EXPERIMENT
  anonymousStages["seek"]=anonymousIO.snapshot()
  #endif
  frameSession=UUID()
  if !paused {player.play()}
 }
 public func recordPresentation(session:UUID) {
  guard active,session==frameSession else{return}
  requestMetrics.present(now:ProcessInfo.processInfo.systemUptime)
  #if VISTA_ANON_IO_EXPERIMENT
  if anonymousStages["呈現"]==nil {anonymousStages["呈現"]=anonymousIO.snapshot()}
  // Presentation can arrive while paused, without another video frame to refresh the text.
  if let divider=diagnosticsText.range(of:"\nAVPlayer 候選") {
   let suffix=String(diagnosticsText[divider.lowerBound...]).components(separatedBy:"\n").filter{!$0.contains(" I/O 起")}.joined(separator:"\n")
   let lines=["seek","首幀","呈現"].compactMap {key in anonymousStages[key].map{key+" "+$0.text}}
   diagnosticsText=requestMetrics.text(now:ProcessInfo.processInfo.systemUptime)+suffix+"\n"+lines.joined(separator:"\n")
  }
  #endif
 }
 public func stop(){active=false;seekGeneration=UUID();item?.cancelPendingSeeks();player?.pause();asset?.cancelLoading()}
 private func check()throws {
  try Task.checkCancellation()
  guard active else{throw CancellationError()}
  if sourceFailed {throw Failure.source}
  if item?.status == .failed {throw Failure.player}
  if (!paused || !prepared) && ProcessInfo.processInfo.systemUptime-lastProgress>stallLimit {throw Failure.stalled}
 }
 public func play(file:MediaFile,source:any MediaByteSource,startAt:Double=0,startPaused:Bool=false,
  onInfo:@escaping @MainActor (VideoTrackInfo)->Void,
  onState:@escaping @MainActor (State)->Void,
  onFrame:@escaping @MainActor (DecodedVideoFrame)->Void,
  onSpeed:@escaping @MainActor (PlaybackSpeedStatus)->Void = {_ in})async throws {
  guard !running else{throw Failure.unsupported}
  let ext=(file.components.last! as NSString).pathExtension.lowercased()
  guard ["mp4","m4v","mov"].contains(ext) else{throw Failure.unsupported}
  running=true;prepared=false;active=true;sourceFailed=false;paused=startPaused;seeking=false;selectedSpeed=1;frameSession=UUID()
  lastProgress=ProcessInfo.processInfo.systemUptime;frames=0;waits=0;maxClockDifference=0;diagnosticUpdate=0;onState(.preparing)
  do {
   requestMetrics.begin("開片",now:ProcessInfo.processInfo.systemUptime)
   let size:UInt64
   do {size=try await source.fileSize(for:file)}
   catch is CancellationError {throw CancellationError()}
   catch {throw Failure.source}
   try check()
   guard size>0,size<=Int64.max else{throw Failure.source}
   let loader=ResourceBridge(source:source,file:file,size:size,contentType:ext=="mov" ? "com.apple.quicktime-movie":"public.mpeg-4",chunkBytes:262144)
   bridge=loader
   #if VISTA_ANON_IO_EXPERIMENT
   anonymousIO=AnonymousIOAggregate();anonymousIO.beginEpoch(now:ProcessInfo.processInfo.systemUptime);anonymousStages=[:]
   let aggregate=anonymousIO
   loader.onAnonymousBegin={aggregate.begin(now:ProcessInfo.processInfo.systemUptime)}
   loader.onAnonymousEnd={id,bytes,cancelled,failed in aggregate.end(id,now:ProcessInfo.processInfo.systemUptime,bytes:bytes,cancelled:cancelled,failed:failed)}
   #endif
   loader.onRangeBegin={ [weak self] in self?.requestMetrics.epoch ?? -1 }
   loader.onRangeEnd={ [weak self] epoch,bytes,seconds,interrupted in
    self?.requestMetrics.endRead(epoch:epoch,bytes:bytes,seconds:seconds,interrupted:interrupted)
   }
   loader.onReadFailure={ [weak self] in self?.sourceFailed=true }
   loader.onReadProgress={ [weak self] in self?.lastProgress=ProcessInfo.processInfo.systemUptime }
   let urlAsset=AVURLAsset(url:URL(string:"vista-media://native/\(UUID().uuidString).\(ext)")!)
   asset=urlAsset;urlAsset.resourceLoader.setDelegate(loader,queue:.main)
   let media=AVPlayerItem(asset:urlAsset);item=media
   let output=AVPlayerItemVideoOutput(pixelBufferAttributes:nil)
   media.add(output)
   let native=AVPlayer(playerItem:media);player=native;native.isMuted=muted;native.defaultRate=1
   while media.status == .unknown {try check();try await Task.sleep(for:.milliseconds(10))}
   try check()
   let tracks=try await urlAsset.loadTracks(withMediaType:.video)
   guard tracks.count==1,try await !urlAsset.load(.hasProtectedContent) else{throw Failure.unsupported}
   let (formats,transform)=try await tracks[0].load(.formatDescriptions,.preferredTransform)
   let duration=try await urlAsset.load(.duration).seconds
   guard let format=formats.first,duration.isFinite,duration>0 else{throw Failure.unsupported}
   let dimensions=CMVideoFormatDescriptionGetDimensions(format),code=CMFormatDescriptionGetMediaSubType(format)
   let codec=String(bytes:[24,16,8,0].map{UInt8((code >> $0)&255)},encoding:.ascii) ?? "unknown"
   onInfo(VideoTrackInfo(codec:codec,width:dimensions.width,height:dimensions.height,duration:duration,hasAudio:try await !urlAsset.loadTracks(withMediaType:.audio).isEmpty))
   try check()
   #if os(visionOS)
   let clock=NativeDisplayClock();displayClock=clock;clock.start()
   #endif
   if startAt>0 {try await seek(to:min(startAt,duration))}
   prepared=true
   if paused {native.pause()}else{native.play()}
   var state:State = .preparing
   var reportedSpeed:PlaybackSpeedStatus?
   while true {
    try check()
    let speed=speedStatus
    if reportedSpeed != speed {reportedSpeed=speed;onSpeed(speed)}
    let next:State=seeking ? .seeking:paused ? .paused:native.timeControlStatus == .waitingToPlayAtSpecifiedRate ? .waiting:.playing
    if next != state {if next == .waiting {waits += 1};state=next;onState(next)}
    let now=ProcessInfo.processInfo.systemUptime
    let reason:String
    switch native.reasonForWaitingToPlay {
     case .toMinimizeStalls:reason="避免停滯"
     case .evaluatingBufferingRate:reason="評估緩衝"
     case .noItemToPlay:reason="無項目"
     default:reason="其他／無"
    }
    requestMetrics.waiting(!seeking && !paused && native.timeControlStatus == .waitingToPlayAtSpecifiedRate,reason:reason,now:now)
    let time=native.currentTime()
    #if os(visionOS)
    let outputTime=displayClock?.take().map{output.itemTime(forHostTime:$0)}
    #else
    let outputTime:CMTime?=time
    #endif
    if !seeking,let outputTime,output.hasNewPixelBuffer(forItemTime:outputTime) {
     var display=CMTime.invalid
     if let pixel=output.copyPixelBuffer(forItemTime:outputTime,itemTimeForDisplay:&display),display.seconds.isFinite {
      lastProgress=ProcessInfo.processInfo.systemUptime
      frames += 1
      requestMetrics.deliverFirst(now:lastProgress,pts:display.seconds)
      #if VISTA_ANON_IO_EXPERIMENT
      if anonymousStages["首幀"]==nil {anonymousStages["首幀"]=anonymousIO.snapshot()}
      #endif
      maxClockDifference=max(maxClockDifference,abs(display.seconds-native.currentTime().seconds))
      if lastProgress-diagnosticUpdate>=1 {
       diagnosticUpdate=lastProgress
       diagnosticsText=requestMetrics.text(now:lastProgress)+"\nAVPlayer 候選／解碼方式：系統管理（未知）\n影格 \(frames)／等待 \(waits)／影格與播放器時鐘差最大 \(Int(maxClockDifference*1000)) ms／\(CVPixelBufferGetWidth(pixel))×\(CVPixelBufferGetHeight(pixel))"
       #if VISTA_ANON_IO_EXPERIMENT
       let aggregateLines=["seek","首幀","呈現"].compactMap {key in anonymousStages[key].map{key+" "+$0.text}}
       diagnosticsText += "\n"+aggregateLines.joined(separator:"\n")
       #endif
      }
      onFrame(DecodedVideoFrame(pixel:pixel,time:display.seconds,transform:transform,session:frameSession))
     }
    }
    if !seeking,!paused,time.seconds>=duration,native.rate==0 {onState(.ended);break}
    try await Task.sleep(for:.milliseconds(8))
   }
   await cleanup()
  }catch {await cleanup();throw error}
 }
 private func cleanup()async {
  stop()
  #if os(visionOS)
  displayClock?.stop();displayClock=nil
  #endif
  player?.replaceCurrentItem(with:nil)
  let old=bridge;bridge=nil;old?.onReadFailure=nil;old?.onReadProgress=nil;old?.onRangeBegin=nil;old?.onRangeEnd=nil
  await old?.stop()
  item=nil;player=nil;asset=nil;seeking=false;running=false
 }
}
