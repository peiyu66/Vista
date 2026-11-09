import Foundation
import Testing
@testable import VistaMedia

struct PlaybackMemoryDiagnosticsTests {
 @Test func unavailableMeasurementsAreOmittedRatherThanReportedAsZero() {
  var diagnostics=PlaybackMemoryDiagnostics()
  let unknown=diagnostics.values(sampling:.init())
  #expect(unknown.isEmpty)
  let availableOnly=diagnostics.values(sampling:.init(availableBytes:4096))
  #expect(availableOnly == [.memoryAvailableBytes:4096])
  // An actual zero is kept distinct from an unavailable/failed measurement.
  let zero=diagnostics.values(sampling:.init(footprintBytes:0,availableBytes:0))
  #expect(zero[.memoryFootprintBytes]==0 && zero[.memoryAvailableBytes]==0)
  #expect(zero[.memoryProcessPeakBytes]==nil)
 }

 @Test func sampledPeakIsPerPlaybackAndDistinctFromTheProcessLifetimePeak() {
  var diagnostics=PlaybackMemoryDiagnostics()
  let first=diagnostics.values(sampling:.init(footprintBytes:100,processPeakBytes:900,availableBytes:400))
  #expect(first[.memoryObservedPeakBytes]==100 && first[.memoryProcessPeakBytes]==900)
  let higher=diagnostics.values(sampling:.init(footprintBytes:250,processPeakBytes:900,availableBytes:300))
  #expect(higher[.memoryObservedPeakBytes]==250)
  let lower=diagnostics.values(sampling:.init(footprintBytes:125,processPeakBytes:900,availableBytes:500))
  #expect(lower[.memoryFootprintBytes]==125 && lower[.memoryObservedPeakBytes]==250)
  #expect(lower[.memoryAvailableBytes]==500)
  // A failed probe must not invent a fresh current footprint/budget or erase a known peak.
  let failed=diagnostics.values(sampling:.init())
  #expect(failed == [.memoryObservedPeakBytes:250])
  diagnostics=PlaybackMemoryDiagnostics()
  let newPlayback=diagnostics.values(sampling:.init(footprintBytes:80,processPeakBytes:900))
  #expect(newPlayback[.memoryObservedPeakBytes]==80 && newPlayback[.memoryProcessPeakBytes]==900)
 }

 @Test func pressureCountersTrackDeliveredFlagsOnlyAndSaturate() {
  var diagnostics=PlaybackMemoryDiagnostics()
  diagnostics.recordPressure(warning:true,critical:true)
  #expect(diagnostics.values(sampling:.init()).isEmpty)
  diagnostics.pressureMonitored=true
  #expect(diagnostics.values(sampling:.init()) == [.memoryWarningEvents:0,.memoryCriticalEvents:0])
  diagnostics.recordPressure(warning:true,critical:false)
  diagnostics.recordPressure(warning:false,critical:false)
  diagnostics.recordPressure(warning:true,critical:true)
  let values=diagnostics.values(sampling:.init())
  #expect(values[.memoryWarningEvents]==2 && values[.memoryCriticalEvents]==1)
  diagnostics.warningEvents=UInt32.max;diagnostics.criticalEvents=UInt32.max
  diagnostics.recordPressure(warning:true,critical:true)
  #expect(diagnostics.warningEvents==UInt32.max && diagnostics.criticalEvents==UInt32.max)
 }

 @Test func serializedMemoryEvidenceIsFixedNumericAndBounded()throws {
  var diagnostics=PlaybackMemoryDiagnostics(pressureMonitored:true,warningEvents:UInt32.max,criticalEvents:UInt32.max)
  var values=diagnostics.values(sampling:.init(footprintBytes:UInt64.max,processPeakBytes:UInt64.max,availableBytes:UInt64.max))
  values[.cacheStorageAllocatedBytes]=32*1024*1024
  values[.cacheStoragePeakAllocatedBytes]=32*1024*1024
  let expected:Set<String>=["memoryFootprintBytes","memoryObservedPeakBytes","memoryProcessPeakBytes","memoryAvailableBytes","memoryWarningEvents","memoryCriticalEvents","cacheStorageAllocatedBytes","cacheStoragePeakAllocatedBytes"]
  let encoded=try JSONEncoder().encode(PlaybackLogRecord(event:.sample,values:values,build:"84"))
  let decoded=try JSONDecoder().decode(PlaybackLogRecord.self,from:encoded)
  #expect(Set(decoded.values.keys)==expected && decoded.values.values.allSatisfy(\.isFinite))
  #expect(encoded.count<512)
  #expect(decoded.values["cacheStorageAllocatedBytes"]==33_554_432)
 }
}
