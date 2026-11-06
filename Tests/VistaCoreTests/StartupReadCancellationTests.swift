import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

private actor DelayedStartupBytes:MediaByteSource {
    let bytes:Data
    init()throws {bytes=try Data(contentsOf:Bundle.module.url(forResource:"SyntheticHEVC",withExtension:"mp4")!)}
    func fileSize(for file:MediaFile)async throws->UInt64 {UInt64(bytes.count)}
    func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data {
        try await Task.sleep(for:.milliseconds(20))
        try Task.checkCancellation()
        return bytes.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))
    }
}
struct StartupReadCancellationTests {
    @Test @MainActor func normalOpenCanCancelSpeculativeReadsWithoutTransportFailure()async throws {
        let metrics=PlaybackMetrics(source:.synthetic)
        let report=try await HardwarePlayback(muteAudioForTesting:true).play(file:MediaFile(components:["synthetic.mp4"]),source:DelayedStartupBytes(),metrics:metrics,onInfo:{_ in},onFrame:{_ in})
        let snapshot=metrics.snapshot()
        #expect(report.hardwareVerified && report.decodedFrames>0)
        #expect(snapshot.events[.readFailure,default:0]==snapshot.events[.readCancelled,default:0])
        print("STARTUP_READ_CLASSIFICATION reads",snapshot.stages[.read]?.count ?? 0,"cancelled",snapshot.events[.readCancelled,default:0],"other",snapshot.events[.readFailure,default:0]-snapshot.events[.readCancelled,default:0])
    }
}
