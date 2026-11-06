import Foundation
import Testing
@testable import VistaMedia
@testable import VistaCore
struct PlaybackMetricsTests {
    @Test func tenSecondWindowFreezesAndRejectsInvalidNumbers() {
        let m=PlaybackMetrics(source:.smb,now:100)
        m.record(.read,seconds:0.2,bytes:1024,now:101)
        m.record(.read,seconds:.nan,bytes:99,now:102)
        m.mark(.decoded,now:109.9);m.mark(.decoded,now:110)
        m.record(.texture,seconds:1,now:111)
        m.setHardware(verified:true,softwareTest:false,now:102)
        m.setFormat(codec:"private-secret-name",width:3840,height:2160,now:102)
        let s=m.snapshot(now:120)
        #expect(s.elapsed==10 && s.complete)
        #expect(s.readBytes==1024 && s.stages[.read]?.count==1)
        #expect(s.events[.decoded]==1 && s.stages[.texture]==nil)
        #expect(s.hardware=="已查核硬解" && !s.text.contains("private-secret"))
    }
    @Test func finishAndNewSessionDoNotMixLateResults() {
        let a=PlaybackMetrics(now:0);a.mark(.submitted,now:1);a.finish(now:2)
        a.mark(.uploaded,now:3)
        let b=PlaybackMetrics(now:3);b.setHardware(verified:false,softwareTest:true,now:4)
        #expect(a.snapshot(now:9).elapsed==2 && a.snapshot(now:9).events[.uploaded]==nil)
        #expect(b.snapshot(now:4).events.isEmpty && b.snapshot(now:4).hardware=="模擬器軟解測試")
    }
    @Test func sourceReadsCountBytesFailuresAndPreserveCancellation() async throws {
        let metric=PlaybackMetrics(source:.smb)
        let source=MeasuredMediaSource(base:MetricFixtureSource(),metrics:metric)
        let file=try MediaFile(components:["private-fixture.mp4"])
        #expect(try await source.fileSize(for:file)==4)
        #expect(try await source.read(file,range:0..<4)==Data([0,0,0,0]))
        await #expect(throws:CancellationError.self) {try await source.read(file,range:4..<5)}
        let snapshot=metric.snapshot()
        #expect(snapshot.readBytes==4 && snapshot.stages[.read]?.count==2)
        #expect(snapshot.events[.readFailure]==1 && snapshot.events[.readCancelled]==1 && !snapshot.text.contains("private-fixture"))
        #expect(snapshot.text.contains("取消 1／其他 0"))
    }
    @Test func transportErrorIsNotCancellationAndEmptyReadIsSuccess()async throws {
        let metrics=PlaybackMetrics(),source=MeasuredMediaSource(base:MetricFixtureSource(),metrics:metrics)
        let file=try MediaFile(components:["synthetic.mp4"])
        #expect(try await source.read(file,range:4..<4).isEmpty)
        await #expect(throws:MediaInspectionError.unavailable) {try await source.read(file,range:99..<100)}
        let s=metrics.snapshot()
        #expect(s.stages[.read]?.count==2 && s.readBytes==0)
        #expect(s.events[.readFailure]==1 && s.events[.readCancelled]==nil)
        #expect(s.text.contains("取消 0／其他 1"))
    }
    @Test func failureClassificationFreezesAtomicallyAtWindowEnd() {
        let metrics=PlaybackMetrics(now:100)
        metrics.recordReadFailure(seconds:0.1,cancelled:true,now:109.99)
        metrics.recordReadFailure(seconds:0.1,cancelled:false,now:110)
        let s=metrics.snapshot(now:111)
        #expect(s.stages[.read]?.count==1 && s.events[.readFailure]==1 && s.events[.readCancelled]==1)
    }
    @Test func progressFormattingAndUnknownDuration() {
        #expect(PlaybackProgress.time(65)=="01:05")
        #expect(PlaybackProgress.time(3601)=="1:00:01")
        #expect(PlaybackProgress.time(nil)=="—" && PlaybackProgress.time(.infinity)=="—")
        #expect(PlaybackProgress.duration(0)==nil && PlaybackProgress.duration(.nan)==nil)
        #expect(PlaybackProgress.clamp(120,duration:30)==30)
        #expect(PlaybackProgress.clamp(-5,duration:30)==0)
    }
    @Test func concurrentCountersStayBoundedAndReportCost() async {
        let m=PlaybackMetrics(now:0)
        let start=ProcessInfo.processInfo.systemUptime
        await withTaskGroup(of:Void.self) {group in
            for _ in 0..<4 {group.addTask {for _ in 0..<10000 {m.mark(.decoded,now:1);m.record(.decode,seconds:0.001,now:1)}}}
        }
        let s=m.snapshot(now:2)
        #expect(s.events[.decoded]==40000 && s.stages[.decode]?.count==40000)
        #expect(s.events.count==1 && s.stages.count==1)
        print("METRIC_80000_UPDATES_MS",(ProcessInfo.processInfo.systemUptime-start)*1000)
    }
}

private struct MetricFixtureSource:MediaByteSource {
    func fileSize(for file:MediaFile) async throws -> UInt64 {4}
    func read(_ file:MediaFile,range:Range<UInt64>) async throws -> Data {
        if range.lowerBound==99 {throw MediaInspectionError.unavailable}
        if range.upperBound>4 {throw CancellationError()}
        return Data(repeating:0,count:Int(range.count))
    }
}
