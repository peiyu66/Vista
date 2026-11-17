import Foundation

@main @MainActor struct Test {
 static var checks=0
 static func check(_ condition: @autoclosure ()->Bool,_ label:String) {
  checks += 1
  if !condition() {fatalError("FAILED: \(label)")}
 }
 static func sample(_ t:Double=2,_ late:Double=120,_ pts:Int64=4_000_000,_ count:UInt64=100)->VLCClockResyncPolicy.Input {
  .init(now:t,lastFrameAt:0,eligible:true,rateConfirmed:true,effectiveRate:2,selectedRate:2,
   nowUS:Int64(t*1e6),sampleUS:Int64(t*1e6),queuePTS:pts+10_000,queueTick:Int64(t*1e6),dropTick:Int64(t*1e6),
   queueCount:count+20,queueValid:count+20,queueInvalid:0,queueRepeat:0,queueBackward:0,
   admitted:count+10,pop:count,lateDrop:count,renderNormal:20,errors:0,
   dropDeltaMS: -late,dropThresholdMS:16.683,dropRate:2,
   dropPTS:pts,dropClockID:1,dropContextValid:true,dropContextRate:2,dropReference:10)
 }
 static func policy()->VLCClockResyncPolicy {var p=VLCClockResyncPolicy();p.automaticDrop(now:1);return p}
 static func second()->VLCClockResyncPolicy.Input {var x=sample(2.15,110,4_320_000,120);x.dropReference=11;return x}
 static func rejects(_ mutate:(inout VLCClockResyncPolicy.Input)->Void,_ label:String) {
  var p=policy();check(!p.observe(sample()),"baseline \(label)");var s=second();mutate(&s)
  check(!p.observe(s),label);check(!p.spent,"allowance unspent \(label)")
 }
 static func main()throws {
  var w=VLCCatchupRecovery189();check(!w.observe(sample(),revision:1,published:false),"ordinary baseline no experiment never seeks")
  w.arm(now:0,revision:1);check(!w.observe(sample(0.8),revision:1,published:false),"subsecond ignored")
  check(!w.observe(sample(),revision:1,published:false),"one proof insufficient")
  check(w.observe(second(),revision:1,published:false),"two severe proofs fallback")
  check(w.consumed && !w.active,"allowance consumed")
  w.arm(now:3,revision:1);check(!w.active,"cannot rearm after consumption")
  func reject(_ f:(inout VLCClockResyncPolicy.Input)->Void,_ label:String){var q=VLCCatchupRecovery189();q.arm(now:0,revision:1);_ = q.observe(sample(),revision:1,published:false);var x=second();f(&x);check(!q.observe(x,revision:1,published:false),label)}
  reject({$0.eligible=false},"pause source inactive")
  reject({$0.rateConfirmed=false},"unconfirmed")
  reject({$0.lastFrameAt=2.1},"fresh publication")
  reject({$0.nowUS+=300000},"stale capture")
  reject({$0.sampleUS=$0.nowUS+1},"future capture")
  reject({$0.dropTick-=300000},"stale drop")
  reject({$0.queueTick-=300000},"stale queue")
  reject({$0.dropContextValid=false},"missing clock context")
  reject({$0.dropContextRate=3},"old rate")
  reject({$0.dropClockID=9},"clock identity switch")
  reject({$0.dropReference=0},"clock reference reset")
  reject({$0.dropPTS=1},"backward PTS")
  reject({$0.renderNormal+=1},"native rendering progressed")
  reject({$0.errors+=1},"delivery error")
  reject({$0.queueBackward+=1},"queue backward")
  reject({$0.lateDrop=105},"too few drops")
  reject({$0.pop=105},"too few dequeues")
  reject({$0.dropDeltaMS = -60},"rapid natural catchup under one second")
  var q=VLCCatchupRecovery189();q.arm(now:0,revision:1);_ = q.observe(sample(),revision:1,published:false)
  check(!q.observe(second(),revision:2,published:false),"revision cancels old proof")
  check(!q.observe(sample(3.3,200,6_000_000,300),revision:2,published:false),"new revision needs new first proof")
  check(q.observe(sample(3.5,210,6_200_000,320),revision:2,published:false),"fresh pair after new revision")
  var paused=VLCCatchupRecovery189();paused.arm(now:0,revision:1);var x=sample(10);x.eligible=false
  _=paused.observe(x,revision:1,published:false)
  check(!paused.observe(sample(10.5),revision:1,published:false),"resume grants fresh full second")
  var healthy=VLCCatchupRecovery189();healthy.arm(now:0,revision:1)
  for n in 0..<12 {_=healthy.observe(sample(Double(n)/20),revision:1,published:true)}
  check(healthy.healthy && healthy.active,"sustained progress recorded without removing safety net")
  _=healthy.observe(sample(3,200,8_000_000,300),revision:1,published:false)
  check(healthy.observe(sample(3.2,210,8_200_000,320),revision:1,published:false),"late stall after healthy first return still covered")
  var cancelled=VLCCatchupRecovery189();cancelled.arm(now:0,revision:1);_ = cancelled.observe(sample(),revision:1,published:false);cancelled.cancel()
  check(!cancelled.observe(second(),revision:1,published:false),"manual seek or source cancels monitor")
  for rate in [1.0,2,3,3.5,5] {var a=VLCCatchupRecovery189();a.arm(now:0,revision:1)
   var first=sample(2,1500),next=sample(2.2,1600,5_000_000,120)
   for k in [0,1] {if k==0 {first.selectedRate=rate;first.effectiveRate=rate;first.dropRate=rate;first.dropContextRate=rate} else {next.selectedRate=rate;next.effectiveRate=rate;next.dropRate=rate;next.dropContextRate=rate}}
   check(!a.observe(first,revision:1,published:false),"one proof rate \(rate)");check(a.observe(next,revision:1,published:false),"fallback keeps rate \(rate)")
  }
  print("PASS \(checks) post-hold progress assertions")
 }
}
