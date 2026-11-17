import Foundation
@main struct Runtime {
 static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1])
  #if VISTA_DIAGNOSTICS
  await PlaybackFlowTrace.testDestination(root)
  #endif
  let started=PlaybackFlowTrace.start(session:1)
  for i in 0..<64 {PlaybackFlowTrace.mark(.decoderCall,a:Int64(i));PlaybackFlowTrace.anchor()}
  let result=await PlaybackFlowTrace.finish(session:1)
  #if VISTA_DIAGNOSTICS
  precondition(started && result["records",default:0]>0)
  #else
  precondition(!started && result["status"]==2)
  #endif
  print("PASS actual Flow writer started=\(started), result=\(result)")
 }
}
