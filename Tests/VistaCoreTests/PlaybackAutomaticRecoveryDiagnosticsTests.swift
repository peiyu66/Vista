import Foundation
import Testing
@testable import VistaMedia
@testable import VistaCore

struct PlaybackAutomaticRecoveryDiagnosticsTests {
 typealias Observer=PlaybackAutomaticRecoveryDiagnostics
 private func started(reference:Double=24)->Observer {
  var observer=Observer()
  #expect(observer.begin(sequence:41,now:10,previousSpeed:2.5,targetSpeed:2,
   decisionClock:100,lastFramePTS:99,healthyReferenceFPS:reference)==nil)
  return observer
 }
 @discardableResult private func step(_ observer:inout Observer,_ time:Double,pts:Double?=nil,
  clock:Double?=nil,rate:Double=2,waiting:Bool=false,polled:Bool=true)->Observer.Record? {
  observer.observe(now:10+time,effectiveRate:rate,playing:true,waiting:waiting,
   clock:clock ?? 100+time*2,outputPolled:polled,copiedFramePTS:pts)
 }
 @Test func exactDecisionCorrelationRequiresTwoFreshForwardSamplesAndLaterAdvancingPTS() throws {
  var observer=started()
  #expect(step(&observer,0,pts:100)==nil) // decision callback is not a confirmation
  #expect(step(&observer,0.01,pts:100)==nil)
  #expect(step(&observer,0.02,pts:101,clock:100.02)==nil) // repeated clock resets pair
  #expect(step(&observer,0.03,pts:102)==nil)
  #expect(step(&observer,0.04,pts:103)==nil) // confirmation callback is not a post-rate frame
  #expect(step(&observer,0.05,pts:102)==nil) // old tail
  #expect(step(&observer,0.06,pts:103)==nil) // repeated PTS
  #expect(step(&observer,0.07,pts:103.1)==nil) // a copy alone is not sustained recovery
  let result=observer.interrupt(.stopped,now:10.08)
  let record=try #require(result)
  #expect(record.sequence==41 && record.previousSpeed==2.5 && record.targetSpeed==2)
  #expect(record.rateConfirmedAt==10.04 && record.firstFrameAt==10.07)
  #expect(record.sustainedAt==nil && record.reason == .stopped)
  #expect(record.baselineMask==3 && record.milestoneMask==23)
 }
 @Test func sustainedWitnessNeedsFullRollingCadenceAndTwoSeparatedChecksAtFloorTwo() throws {
  var observer=started()
  var terminal:Observer.Record?
  for index in 1...40 {
   let time=Double(index)/100
   let record=step(&observer,time,pts:index%4==0 ? 100+time*2:nil)
   if index<38 {#expect(record==nil)}
   if let record {terminal=record;break}
  }
  let record=try #require(terminal)
  #expect(record.reason == .recovered && record.targetSpeed==2 && record.cadenceApplicable)
  #expect(record.rateConfirmedAt==10.02 && record.firstFrameAt==10.04)
  #expect(try #require(record.sustainedAt)>=10.38)
  #expect(!observer.isObserving)
  #expect(step(&observer,0.41,pts:101)==nil)
 }
 @Test func normalWaitingResetsEvidenceWithoutTerminatingOrBankingOldCadence() throws {
  var observer=started()
  for index in 1...20 {#expect(step(&observer,Double(index)/100,pts:100+Double(index)/50)==nil)}
  #expect(step(&observer,0.21,pts:105,rate:0,waiting:true)==nil)
  #expect(observer.isObserving)
  var result:Observer.Record?
  for index in 22...65 {
   let value=step(&observer,Double(index)/100,pts:105+Double(index)/50)
   if index<59 {#expect(value==nil)}
   if let value {result=value;break}
  }
  let record=try #require(result)
  #expect(record.reason == .recovered && record.resets>0)
  #expect(try #require(record.sustainedAt)>=10.59)
 }
 @Test func lowReferenceIsNotCalledUnrecoveredAndUnknownPTSNeedsAnAdvancingPair() throws {
  var observer=started(reference:12)
  #expect(step(&observer,0.01)==nil)
  #expect(step(&observer,0.02)==nil)
  let result=step(&observer,0.03,pts:99.1)
  let record=try #require(result)
  #expect(record.reason == .firstFrameOnly && !record.cadenceApplicable && record.sustainedAt==nil)
  var unknown=Observer()
  unknown.begin(sequence:9,now:10,previousSpeed:2.5,targetSpeed:2,decisionClock:nil,lastFramePTS:nil,healthyReferenceFPS:12)
  #expect(step(&unknown,0.01)==nil) // establishes unknown clock, not a confirmation
  #expect(step(&unknown,0.02)==nil)
  #expect(step(&unknown,0.03)==nil)
  #expect(step(&unknown,0.04,pts:1)==nil) // unknown PTS baseline, not an advance
  #expect(step(&unknown,0.05,pts:1)==nil)
  let unknownResult=step(&unknown,0.06,pts:1.1)
  #expect(try #require(unknownResult).firstFrameAt==10.06)
 }
 @Test func lifecycleAndNewAutomaticStepsCannotReuseLaterFrames() throws {
  let interruptions:[Observer.EndReason]=[.manualRate,.seek,.pause,.background,.sourceFailure,.stopped,.ended]
  for reason in interruptions {
   var observer=started()
   #expect(step(&observer,0.01)==nil)
   let result=observer.interrupt(reason,now:10.02)
   let record=try #require(result)
   #expect(record.reason==reason && record.rateConfirmedAt==nil)
   #expect(step(&observer,0.03,pts:110)==nil)
   #expect(!observer.isObserving)
  }
  var observer=started()
  #expect(step(&observer,0.01)==nil)
  #expect(step(&observer,0.02)==nil)
  let prior=observer.begin(sequence:42,now:10.03,previousSpeed:2,targetSpeed:1.5,
   decisionClock:100.06,lastFramePTS:101,healthyReferenceFPS:12)
  let old=try #require(prior)
  #expect(old.sequence==41 && old.reason == .superseded)
  #expect(step(&observer,0.04,pts:102,rate:2)==nil) // previous target does not confirm new episode
  #expect(step(&observer,0.05,pts:103,rate:1.5)==nil)
  #expect(step(&observer,0.06,pts:104,rate:1.5)==nil)
  #expect(step(&observer,0.07,pts:104,rate:1.5)==nil)
  let next=step(&observer,0.08,pts:105,rate:1.5)
  let new=try #require(next)
  #expect(new.sequence==42 && new.rateConfirmedAt==10.06 && new.firstFrameAt==10.08)
 }
 @Test func sourceEpochInterruptRejectsLaterFramesWithoutAnObservedRecoveryFlag() throws {
  var observer=started()
  #expect(step(&observer,0.01)==nil)
  #expect(step(&observer,0.02)==nil)
  // Native detects a changed source epoch before processing the next loop.
  // There need not have been a waiting or recovering=true observation.
  let terminal=observer.interrupt(.sourceEpoch,now:10.03)
  let record=try #require(terminal)
  #expect(record.sequence==41 && record.reason == .sourceEpoch && record.reason.rawValue==12)
  #expect(record.rateConfirmedAt==10.02 && record.firstFrameAt==nil && record.sustainedAt==nil)
  #expect(step(&observer,0.04,pts:110)==nil)
  #expect(step(&observer,0.05,pts:111)==nil)
  #expect(!observer.isObserving)
  let completed=observer.finish(now:10.06)
  #expect(try #require(completed).summary.incomplete==1)
 }
 @Test func boundedBudgetAndOneSummaryMakeSuppressionAndIncompleteEpisodesExplicit() throws {
  var observer=Observer()
  for index in 0..<19 {
   #expect(observer.begin(sequence:UInt64(index+1),now:Double(index),previousSpeed:2.5,targetSpeed:2,
    decisionClock:Double(index),lastFramePTS:Double(index),healthyReferenceFPS:24)==nil)
   let record=observer.interrupt(.seek,now:Double(index)+0.1)
   #expect((record != nil)==(index<16))
  }
  let result=observer.finish(now:20)
  let complete=try #require(result)
  #expect(complete.terminal==nil)
  #expect(complete.summary.seen==19 && complete.summary.emitted==16 && complete.summary.suppressed==3)
  #expect(complete.summary.incomplete==16 && complete.summary.recovered==0)
  #expect(observer.finish(now:21)==nil)
  var pending=started()
  let pendingResult=pending.finish(now:10.1)
  let unfinished=try #require(pendingResult)
  #expect(unfinished.terminal?.reason == .stopped && unfinished.summary.incomplete==1)
  #expect(!pending.isObserving)
 }
 @Test func invalidNumbersAndLongSamplingGapsCannotFabricateMilestones() throws {
  var observer=started()
  #expect(step(&observer,0.01)==nil)
  #expect(step(&observer,0.5,pts:100)==nil) // stale first confirmation
  #expect(step(&observer,0.51,pts:.nan,clock:.nan)==nil)
  #expect(step(&observer,0.52,pts:101)==nil) // establishes unknown clock
  #expect(step(&observer,0.53,pts:102)==nil)
  #expect(step(&observer,0.54,pts:103)==nil)
  #expect(step(&observer,0.55,pts:103)==nil)
  let result=observer.interrupt(.stopped,now:.nan)
  let record=try #require(result)
  #expect(record.rateConfirmedAt==10.54 && record.firstFrameAt==nil && record.endedAt==nil)
  #expect(record.invalidObservations>=1)
  #expect(record.milestoneMask==3)
 }
 @Test func recentClockAndPollEvidenceCannotBeBankedAcrossStallsOrDiscontinuities() throws {
  var observer=started()
  #expect(step(&observer,0.01)==nil)
  #expect(step(&observer,0.02)==nil)
  // Dense copies and matching rate alone are insufficient if the recent
  // media-clock movement is almost zero, even though each increment is positive.
  for index in 3...90 {
   let time=Double(index)/100
   #expect(step(&observer,time,pts:200+time,clock:100.04+(time-0.02)*0.01)==nil)
  }
  #expect(step(&observer,0.91,pts:201,clock:150)==nil) // discontinuity
  let result=observer.interrupt(.stopped,now:10.92)
  let record=try #require(result)
  #expect(record.sustainedAt==nil && record.invalidObservations>0)
  var polls=started()
  for index in 1...20 {#expect(step(&polls,Double(index)/100,pts:100+Double(index)/100)==nil)}
  for index in 21...29 {#expect(step(&polls,Double(index)/100,polled:false)==nil)}
  // The new poll cannot erase the preceding >0.1s polling gap.
  #expect(step(&polls,0.31,pts:101)==nil)
  let pending=polls.interrupt(.stopped,now:10.32)
  #expect(try #require(pending).resets>0)
 }
 @Test func boundedStateAndNumericRecordSchemasStayBelowOrdinaryLimit() throws {
  var observer=started()
  #expect(step(&observer,0.01)==nil)
  #expect(step(&observer,0.02)==nil)
  for index in 21...110 { // dense short burst, too short to complete a cadence window
   #expect(step(&observer,Double(index)/1000,pts:100+Double(index)/1000)==nil)
   #expect(observer.retainedFrameTimes<=Observer.frameCapacity && observer.retainedPollTimes<=Observer.pollCapacity && observer.retainedClockSamples<=Observer.clockCapacity)
  }
  let result=observer.finish(now:10.12)
  let completion=try #require(result)
  let terminal=PlaybackLogRecord(automaticRecovery:try #require(completion.terminal),session:9,build:"97")
   .withRecoveryLogLosses(dropped:7,failures:3)
  let summary=PlaybackLogRecord(automaticRecoverySummary:completion.summary,session:9,build:"97")
  for record in [terminal,summary] {
   let bytes=try JSONEncoder().encode(record)
   #expect(bytes.count<PlaybackLogStore.ordinaryRecordLimit)
   #expect(record.values.keys.allSatisfy{PlaybackLogField(rawValue:$0) != nil})
   #expect(record.waitEpisode==nil)
  }
  #expect(terminal.values["logDropped"]==7 && terminal.values["logFailures"]==3)
  #expect(terminal.values["autoRecoverySustainedMS"]==nil)
  #expect(terminal.values["autoSpeedSession"]==9 && terminal.values["autoSpeedSequence"]==41)
  let ordinary=PlaybackLogRecord(event:.sample,values:[.frames:9],build:"97")
  #expect(ordinary.values==["frames":9] && ordinary.waitEpisode==nil)
  var decision=PlaybackAutomaticSpeedPolicy.Decision(nextSpeed:2,reason:.sparseOutput,sequence:8,
   observedSeconds:0.35,advancingFrames:4,outputPolls:12,clockAdvance:0.7,maximumFrameGap:0.2)
  decision.sparseTrigger = .lowCadence;decision.healthyReferenceFPS=24;decision.recentAdvancingFrames=4;decision.lowCadenceChecks=2
  let automatic=PlaybackLogRecord(automaticSpeed:decision,session:9,previous:2.5)
  #expect(automatic.values["autoSpeedSparseTrigger"]==2 && automatic.values["autoSpeedLowCadenceFPS"]==20)
  #expect(automatic.values["autoSpeedLowCadenceFrameCount"]==6 && automatic.values["autoSpeedRequiredLowCadenceChecks"]==2)
  #expect(automatic.values["autoSpeedHealthyReferenceFPS"]==24 && automatic.values["autoSpeedRecentAdvancingFrames"]==4)
  #expect(automatic.values["autoSpeedMaximumObservationGap"]==0.1 && automatic.values["autoSpeedMinimumSparseSpeed"]==2.5)
  #expect(try JSONEncoder().encode(automatic).count<PlaybackLogStore.ordinaryRecordLimit)
 }
}
