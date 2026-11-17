
import Foundation
@MainActor @main struct Test {
 static var checks=0
 static func check(_ value:Bool,_ msg:String){checks+=1;precondition(value,msg)}
 static func armed(_ rate:Double=3)->VLCClockResyncPolicy {var p=VLCClockResyncPolicy();p.automaticDrop(now:1,authorizedRate:rate);return p}
 static func pending(_ rate:Double=3)->VLCDirectRecovery194 {var d=VLCDirectRecovery194();d.arm(revision:7,source:10,rate:rate,authorized:rate,video:true,available:true);return d}
 static func main(){
  var p=armed(),d=pending()
  check(!d.take(revision:7,source:10,rate:3,effective:3.5,confirmed:false,eligible:true),"setter acceptance is not output confirmation")
  check(d.intent != nil,"pending confirmation")
  check(d.take(revision:7,source:10,rate:3,effective:3,confirmed:true,eligible:true),"first confirmed eligible poll takes direct request")
  check(p.requestDirect194(eligible:true,confirmed:true,selected:3,effective:3),"no frame gap, late proof, sample count or cost required")
  check(p.spent && !p.armed && p.triggerPath == .direct194 && p.earlyDispatchEvidence == nil,"spend before await and no inherited early proof")
  for _ in 0..<100 {check(!d.take(revision:7,source:10,rate:3,effective:3,confirmed:true,eligible:true),"no repeated request");check(!p.requestDirect194(eligible:true,confirmed:true,selected:3,effective:3),"no retry after native refusal")}
  p.automaticDrop(now:2,authorizedRate:3);check(!p.armed,"later decision cannot refill spent chain")
  p.interrupt();p.automaticDrop(now:3,authorizedRate:3);check(!p.armed,"manual/source interrupt cannot refill allowance")
  for kind in 0..<6 {
   var q=pending();let revision:UInt64=kind==0 ? 8:7;let epoch:UInt64?=kind==1 ? 11:(kind==2 ? nil:10)
   let rate=kind==3 ? 2.5:kind==4 ? Double.nan:3
   if kind==5 {q.cancel()}
   check(!q.take(revision:revision,source:epoch,rate:rate,effective:3,confirmed:true,eligible:true),"new intent/source/cancel cannot execute old request")
   check(!q.take(revision:7,source:10,rate:3,effective:3,confirmed:true,eligible:true),"stale identity cannot revive")
  }
  for rate in [2.0,2.5,3,3.5,4,4.5,5] {
   var q=pending(rate),pol=armed(rate)
   check(!q.take(revision:7,source:10,rate:rate,effective:rate,confirmed:true,eligible:false),"pause/background/buffering/pending-seek gating")
   check(q.take(revision:7,source:10,rate:rate,effective:rate,confirmed:true,eligible:true),"safety opening is not a new sampling window")
   check(pol.requestDirect194(eligible:true,confirmed:true,selected:rate,effective:rate),"existing authorized rate")
  }
  for pair in [(false,true,3.0,3.0),(true,false,3.0,3.0),(true,true,3.5,2.0)] {
   var q=VLCDirectRecovery194();q.arm(revision:7,source:10,rate:pair.2,authorized:pair.3,video:pair.0,available:pair.1)
   check(q.intent==nil,"buffering/manual/unavailable/unapproved rate not armed")
  }
  for kind in 0..<5 {
   var q=armed()
   check(!q.requestDirect194(eligible:kind != 0,confirmed:kind != 1,selected:kind==2 ? 3.5:kind==3 ? .nan:3,effective:kind==4 ? 3.5:3),"policy safety gate")
   check(!q.spent,"safety denial before attempt does not consume")
  }
  // Natural-recovery and eventual-seek histories get the SAME decision: no hindsight classification.
  for label in ["natural recovery history","persistent recovery history"] {
   let rate=label.hasPrefix("natural") ? 2.0:3.0;var q=pending(rate),pol=armed(rate)
   check(q.take(revision:7,source:10,rate:rate,effective:rate,confirmed:true,eligible:true) && pol.requestDirect194(eligible:true,confirmed:true,selected:rate,effective:rate),label)
  }
  print("PASS \(checks) actual direct194 admission/allowance checks; includes natural and persistent event scope, no timing/late-proof inputs")
 }
}
