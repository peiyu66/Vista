import Foundation
import Testing
@testable import VistaCore
@testable import VistaMedia

private actor SeekWaitBytes:MediaByteSource {
 let data:Data
 init()throws {data=try Data(contentsOf:Bundle.module.url(forResource:"OpenGOPHEVC",withExtension:"mp4")!)}
 func fileSize(for file:MediaFile)async throws->UInt64 {try await Task.sleep(for:.milliseconds(150));return UInt64(data.count)}
 func read(_ file:MediaFile,range:Range<UInt64>)async throws->Data {
  try await Task.sleep(for:.milliseconds(15));try Task.checkCancellation()
  return data.subdata(in:Int(range.lowerBound)..<Int(range.upperBound))
 }
}
struct SeekWaitTests {
 @Test @MainActor func retainedFrameAndFreshTimingDuringSeekThenStop()async throws {
  let player=PlaybackController(engine:HardwarePlayback(muteAudioForTesting:true))
  let source=try SeekWaitBytes();player.play(file:try MediaFile(components:["fixture.mp4"]),source:source,sourceKind:.synthetic)
  try await ready(player);player.togglePause()
  let before=try #require(player.frame)
  player.seek(to:4.1)
  #expect(player.isPreparing && player.isSeeking)
  #expect(player.frame?.image === before.image)
  try await Task.sleep(for:.milliseconds(50))
  #expect(player.frame?.image === before.image)
  try await ready(player)
  #expect(player.isPaused)
  #expect(player.preparationText.contains("舊播放清理"))
  #expect(player.preparationText.contains("來源就緒"))
  #expect(player.preparationText.contains("軌道就緒"))
  #expect(player.preparationText.contains("解碼器就緒"))
  #expect(player.preparationText.contains("首幀交付"))
  #expect(player.preparationText.contains("音訊與時鐘就緒"))
  print("SEEK_WAIT_TIMING",player.preparationText)
  player.seek(to:8.1);player.stop()
  try await Task.sleep(for:.milliseconds(300))
  #expect(player.frame == nil && player.pixelFrame == nil && !player.isPreparing && !player.isPlaying)
 }
 @MainActor private func ready(_ player:PlaybackController)async throws {
  let until=ContinuousClock.now.advanced(by:.seconds(15))
  while player.isPreparing,ContinuousClock.now<until {try await Task.sleep(for:.milliseconds(10))}
  #expect(!player.isPreparing && player.isPlaying)
 }
}
