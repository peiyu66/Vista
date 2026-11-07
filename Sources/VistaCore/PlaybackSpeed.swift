import Foundation

/// Capability and requested rate are distinct from AVPlayer's current transport rate.
public struct PlaybackSpeedStatus:Equatable,Sendable {
 public var selected:Int,effectiveRate:Double,ready:Bool,supportsFastForward:Bool,paused:Bool,waiting:Bool
 public init(selected:Int=1,effectiveRate:Double=0,ready:Bool=false,supportsFastForward:Bool=false,paused:Bool=false,waiting:Bool=false) {
  self.selected=selected;self.effectiveRate=effectiveRate;self.ready=ready;self.supportsFastForward=supportsFastForward;self.paused=paused;self.waiting=waiting
 }
 // Ready AVPlayerItems support 1...2 even when canPlayFastForward is false (Apple QA1772).
 public var maximum:Int {ready ? (supportsFastForward ? 3:2):1}
 public func accepts(_ rate:Int)->Bool {ready && (1...maximum).contains(rate)}
 public var canIncrease:Bool {accepts(selected+1)}
 public var canReset:Bool {ready && selected>1}
 public var text:String {
  let value="\(selected)×"
  if !ready {return value}
  if paused {return "\(value) · 暫停"}
  if waiting {return "設定 \(value) · 緩衝中"}
  if !effectiveRate.isFinite || abs(effectiveRate-Double(selected))>0.05 {return "設定 \(value) · 等待播放"}
  return value
 }
}
