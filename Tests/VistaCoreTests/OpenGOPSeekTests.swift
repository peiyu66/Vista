import Foundation
import Testing
import CoreImage
import CryptoKit
@testable import VistaCore
@testable import VistaMedia
private actor OpenGOPSource:MediaByteSource {
 let bytes:Data
 init()throws {bytes=try Data(contentsOf:Bundle.module.url(forResource:"OpenGOPHEVC",withExtension:"mp4")!)}
 func fileSize(for file:MediaFile)async throws->UInt64 {UInt64(bytes.count)}
 func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data {bytes.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))}
}
struct OpenGOPSeekTests {
 @Test(arguments:[0.0,2.1,4.1,6.1]) @MainActor func openGOPRandomAccess(target:Double)async throws {
  let result=try await HardwarePlayback(muteAudioForTesting:true).play(file:MediaFile(components:["synthetic.mp4"]),source:OpenGOPSource(),startAt:target,onInfo:{_ in},onFrame:{_ in},onPixelFrame:{_ in})
  #expect(result.hardwareVerified && result.decodedFrames>0)
 }
}

struct OpenGOPRegressionTests {
 @Test @MainActor func seekPixelsMatchContinuousAndSkipTenResumes()async throws {
  let source=try OpenGOPSource(),engine=HardwarePlayback(muteAudioForTesting:true),context=CIContext()
  let file=try MediaFile(components:["synthetic.mp4"])
  var reference=[Int:Data](),compared=0
  _ = try await engine.play(file:file,source:source,onInfo:{_ in},onFrame:{_ in},onPixelFrame:{frame in
   if frame.time>=10.1,let image=frame.makeImage(context:context),let bytes=image.dataProvider?.data as Data? {
    reference[Int((frame.time*60000).rounded())]=Data(SHA256.hash(data:bytes))
   }
  })
  _ = try await engine.play(file:file,source:source,startAt:10.1,onInfo:{_ in},onFrame:{_ in},onPixelFrame:{frame in
   if let image=frame.makeImage(context:context),let bytes=image.dataProvider?.data as Data? {
    #expect(reference[Int((frame.time*60000).rounded())]==Data(SHA256.hash(data:bytes)));compared += 1
   }
  })
  #expect(compared>100)
  let controller=PlaybackController(engine:HardwarePlayback(muteAudioForTesting:true))
  controller.play(file:file,source:source);defer {controller.stop()}
  try await ready(controller)
  controller.togglePause();controller.skip(by:10)
  try await ready(controller)
  #expect(controller.isPlaying && controller.isPaused && controller.position>=10)
  controller.seek(to:2.1);controller.seek(to:4.1);controller.seek(to:6.1)
  try await ready(controller)
  #expect(controller.isPlaying && controller.isPaused && controller.position>=6.1 && controller.position<6.3)
  controller.togglePause();try await Task.sleep(for:.milliseconds(200))
  #expect(controller.isPlaying && controller.position>6.1)
  controller.stop();try await Task.sleep(for:.milliseconds(100))
  #expect(!controller.isPlaying && controller.frame==nil && controller.pixelFrame==nil)
 }
 @MainActor private func ready(_ controller:PlaybackController)async throws {
  let deadline=ContinuousClock.now.advanced(by:.seconds(10))
  while controller.isPreparing {
   if ContinuousClock.now>deadline {throw PlaybackFailure.seekUnavailable}
   try await Task.sleep(for:.milliseconds(10))
  }
 }
 @Test func gateOnlyDropsInitialCRALeadingRASL()throws {
  var gate=HEVCRandomAccess()
  #expect(try !gate.shouldSkip(types:[21],pts:2))
  #expect(try gate.shouldSkip(types:[9],pts:1.9))
  #expect(try gate.shouldSkip(types:[8],pts:1.8))
  #expect(try !gate.shouldSkip(types:[6],pts:1.95))
  #expect(try !gate.shouldSkip(types:[1],pts:2.1))
  #expect(try !gate.shouldSkip(types:[9],pts:3.9))
  var closed=HEVCRandomAccess();#expect(try !closed.shouldSkip(types:[19],pts:0));#expect(try !closed.shouldSkip(types:[9],pts:1))
  var invalid=HEVCRandomAccess();_ = try invalid.shouldSkip(types:[21],pts:2)
  #expect(throws:PlaybackFailure.seekUnavailable) {try invalid.shouldSkip(types:[8],pts:2.1)}
 }
 @Test func malformedAndAmbiguousNALsFailClosed()throws {
  func scan(_ bytes:[UInt8])throws->Set<Int> {try HEVCRandomAccess.vclTypes(byteCount:bytes.count,lengthSize:4){o,n in Array(bytes[o..<o+n])}}
  #expect(try scan([0,0,0,2,42,1])==[21])
  for bytes:[UInt8] in [[0,0,0,9,42,1],[0,0,0,1,42],[0,0,0,2,42,0],[0,0,0,2,43,1],[0,0,0,2,42,1,0,0,0,2,16,1]] {
   #expect(throws:PlaybackFailure.seekUnavailable) {try scan(bytes)}
  }
 }
}
