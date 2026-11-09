import Foundation
import Testing
@testable import VistaMedia

struct PlaybackControllerUIDiagnosticsTests {
 private func state(_ mask:Int=0)->PlaybackControllerUIState {
  .init(stopping:mask & 1 != 0,scrubbing:mask & 2 != 0,preparing:mask & 4 != 0,advancing:mask & 8 != 0,
        requiresFormatConfirmation:mask & 16 != 0,canResetSpeed:mask & 32 == 0,canIncreaseSpeed:mask & 64 == 0,
        canGoBack:mask & 128 == 0,canAdvance:mask & 256 == 0,hasDuration:mask & 512 == 0)
 }
 @Test func allMasksMatchIndependentDisabledConditions() {
  for bits in 0..<1024 {
   var d=PlaybackControllerUIDiagnostics()
   let s=state(bits), v=d.update(state:s,now:10)!
   #expect(v[.uiStateMask] == Double(bits))
   let row=(s.stopping ? 1:0)+(s.scrubbing ? 2:0)
   #expect(v[.uiRowDisabledMask] == Double(row))
   #expect(v[.uiPreviousDisabledMask] == Double(row+(s.advancing ? 8:0)+(s.canGoBack ? 0:128)))
   #expect(v[.uiNextDisabledMask] == Double(row+(s.advancing ? 8:0)+(s.canAdvance ? 0:256)))
   #expect(v[.uiPauseDisabledMask] == Double(row+(s.preparing ? 4:0)+(s.advancing ? 8:0)+(s.requiresFormatConfirmation ? 16:0)))
   #expect(v[.uiIncreaseDisabledMask] == Double(row+(s.advancing ? 8:0)+(s.requiresFormatConfirmation ? 16:0)+(s.canIncreaseSpeed ? 0:64)))
   #expect(v[.uiResetSpeedDisabledMask] == Double(row+(s.advancing ? 8:0)+(s.requiresFormatConfirmation ? 16:0)+(s.canResetSpeed ? 0:32)))
   let seekParts:[Int]=[s.stopping ? 1:0,s.preparing ? 4:0,s.advancing ? 8:0,s.requiresFormatConfirmation ? 16:0,s.hasDuration ? 0:512]
   let seekExpected=Double(seekParts.reduce(0,+))
   #expect(v[.uiSeekDisabledMask] == seekExpected)
  }
 }
 @Test func normalScrubbingDoesNotDisableSeek() {
  var d=PlaybackControllerUIDiagnostics()
  let v=d.update(state:state(2),action:.sliderValueBegan,now:20)!
  #expect(v[.uiRowDisabledMask] == 2 && v[.uiSeekDisabledMask] == 0)
 }
 @Test func sameStatePollsDoNotEmitOrSuppressOrRewriteLastEdge() {
  var d=PlaybackControllerUIDiagnostics()
  #expect(d.update(state:state(2),action:.sliderValueBegan,now:1) != nil)
  for n in 2...20 {#expect(d.update(state:state(2),now:Double(n)) == nil)}
  #expect(d.update(state:state(2),action:.sliderValueBegan,now:21) == nil)
  let v=d.snapshot(now:22)
  #expect(v[.uiEventSequence] == 1 && v[.uiEventSuppressed] == 0)
  #expect(v[.uiLastAction] == 1 && v[.uiLastActionUptime] == 1)
  #expect(v[.uiStateAgeMS] == 21000)
 }
 @Test func otherFlagsNeverResetIndependentLockOrigins() {
  var d=PlaybackControllerUIDiagnostics()
  _=d.update(state:state(2),now:10)
  _=d.update(state:state(3),action:.stopBegan,now:12)
  _=d.update(state:state(3|4|32),now:15)
  var v=d.snapshot(now:20)
  #expect(v[.uiObservationStartedUptime] == 10 && v[.uiStateSinceUptime] == 15)
  #expect(v[.uiScrubbingSinceUptime] == 10 && v[.uiStoppingSinceUptime] == 12)
  #expect(v[.uiScrubbingAgeMS] == 10000 && v[.uiStoppingAgeMS] == 8000)
  _=d.update(state:state(1),action:.sliderEnded,now:21)
  v=d.snapshot(now:22)
  #expect(v[.uiScrubbingSinceUptime] == 0 && v[.uiScrubbingAgeMS] == 0)
  #expect(v[.uiStoppingSinceUptime] == 12)
  _=d.update(state:state(3),action:.sliderValueBegan,now:23)
  #expect(d.snapshot(now:24)[.uiScrubbingSinceUptime] == 23)
 }
 @Test func completeSliderStopAndViewEdgesAreRecorded() {
  var d=PlaybackControllerUIDiagnostics()
  let edges:[(Int,PlaybackControllerUIDiagnostics.Action)]=[(0,.viewAppeared),(2,.sliderValueBegan),(2,.sliderEditingBegan),(0,.sliderEnded),(1,.stopBegan),(0,.stopCompleted),(0,.viewDisappeared)]
  for (index,pair) in edges.enumerated() {
   let v=d.update(state:state(pair.0),action:pair.1,now:Double(index+1))!
   #expect(v[.uiLastAction] == Double(pair.1.rawValue))
   #expect(v[.uiEventSequence] == Double(index+1))
  }
  let v=d.snapshot(now:100)
  #expect(v[.uiLastAction] == 6 && v[.uiLastActionUptime] == 7)
  #expect(v[.uiStateSequence] == 5)
 }
 @Test func ordinaryExhaustionPreservesThreeTerminalEventsAndLatestState() {
  var d=PlaybackControllerUIDiagnostics()
  var emitted=0
  for n in 0..<200 {
   if d.update(state:state(n % 2 == 0 ? 2:0),now:Double(n)) != nil {emitted += 1}
  }
  #expect(emitted == 125)
  #expect(d.snapshot(now:200)[.uiEventSuppressed] == 75)
  for (n,pair) in [(1,PlaybackControllerUIDiagnostics.Action.stopBegan),(0,.stopCompleted),(0,.viewDisappeared)].enumerated() {
   #expect(d.update(state:state(pair.0),action:pair.1,now:Double(201+n)) != nil)
   emitted += 1
  }
  #expect(emitted == 128)
  #expect(d.update(state:state(1023),action:.sliderEditingBegan,now:204) == nil)
  let v=d.snapshot(now:205)
  #expect(v[.uiStateMask] == 1023 && v[.uiEventSequence] == 204 && v[.uiEventSuppressed] == 76)
  #expect(v[.uiLastAction] == 2 && v[.uiLastActionUptime] == 204)
  #expect(v[.uiStateAgeMS] == 1000 && v[.uiScrubbingAgeMS] == 1000)
 }
 @Test func smallBudgetAndZeroBudgetStillTrackObservations() {
  var d=PlaybackControllerUIDiagnostics(eventLimit:4)
  #expect(d.update(state:state(),now:1) != nil)
  #expect(d.update(state:state(2),now:2) == nil)
  #expect(d.update(state:state(1),action:.stopBegan,now:3) != nil)
  #expect(d.update(state:state(),action:.stopCompleted,now:4) != nil)
  #expect(d.update(state:state(),action:.viewDisappeared,now:5) != nil)
  #expect(d.update(state:state(),action:.viewAppeared,now:6) == nil)
  #expect(d.snapshot(now:7)[.uiEventSuppressed] == 2)
  var zero=PlaybackControllerUIDiagnostics(eventLimit:-1)
  #expect(zero.update(state:state(2),now:10) == nil)
  #expect(zero.snapshot(now:11)[.uiScrubbingAgeMS] == 1000)
  #expect(zero.update(state:state(2),now:12) == nil)
  #expect(zero.snapshot(now:13)[.uiEventSuppressed] == 1)
 }
 @Test func clockAnomaliesStayFiniteAndNeverBackdateObservation() throws {
  var d=PlaybackControllerUIDiagnostics()
  #expect(d.snapshot(now:.infinity).values.allSatisfy {$0 == 0})
  _=d.update(state:state(2),now:10)
  _=d.update(state:state(3),action:.stopBegan,now:2)
  #expect(d.snapshot(now:0)[.uiStoppingSinceUptime] == 10)
  for t in [Double.nan,Double.infinity,-Double.infinity,-1,Double.greatestFiniteMagnitude] {
   _=d.update(state:state(3|4),now:t)
   let v=d.snapshot(now:t)
   #expect(v.values.allSatisfy {$0.isFinite && $0 >= 0})
   _=try JSONEncoder().encode(PlaybackLogRecord(event:.controllerUI,values:v,build:"96"))
  }
 }
 @Test func stateChangesPreserveLastCallbackButIdentifyEventCause() {
  var d=PlaybackControllerUIDiagnostics()
  _=d.update(state:state(2),action:.sliderEditingBegan,now:10)
  let v=d.update(state:state(2|4),now:11)!
  #expect(v[.uiLastAction] == 2 && v[.uiLastActionUptime] == 10)
  #expect(v[.uiEventAction] == 0 && v[.uiStateSinceUptime] == 11)
 }
 @Test func unknownClockDoesNotInventOrBackfillLockStart() {
  for invalid in [Double.nan,Double.infinity,-Double.infinity,-10] {
   var d=PlaybackControllerUIDiagnostics()
   _=d.update(state:state(3),action:.stopBegan,now:invalid)
   var v=d.snapshot(now:100)
   #expect(v[.uiStateSinceUptime] == 0 && v[.uiStateAgeMS] == 0)
   #expect(v[.uiScrubbingAgeMS] == 0 && v[.uiStoppingAgeMS] == 0)
   #expect(v[.uiLastActionUptime] == 0 && v[.uiObservationStartedUptime] == 0)
   #expect(d.update(state:state(3),now:101) == nil)
   v=d.snapshot(now:102)
   #expect(v[.uiObservationStartedUptime] == 101)
   #expect(v[.uiStateAgeMS] == 0 && v[.uiScrubbingAgeMS] == 0 && v[.uiStoppingAgeMS] == 0)
  }
 }
 @Test func fixedNumericSchemaEncodesAsControllerEventAndSample() throws {
  var d=PlaybackControllerUIDiagnostics()
  let v=d.update(state:state(1023),action:.viewAppeared,now:10)!
  #expect(v.count == 21)
  #expect(PlaybackLogEvent.controllerUI.isCritical)
  for event in [PlaybackLogEvent.controllerUI,.sample] {
   let data=try JSONEncoder().encode(PlaybackLogRecord(event:event,values:v,build:"96"))
   let decoded=try JSONDecoder().decode(PlaybackLogRecord.self,from:data)
   #expect(decoded.event == event && decoded.values.count == 21 && data.count < 4096)
   #expect(Set(decoded.values.keys) == Set(v.keys.map(\.rawValue)))
   #expect(decoded.values.values.allSatisfy {$0.isFinite})
  }
 }
}
