import Foundation
import CoreGraphics

/// Project-generated ideal equidistant calibration chart, not captured camera footage.
public enum VRFisheyeCalibration {
    public static func image(layout: VRLayout) -> CGImage? {
        let side = 512
        // Mono deliberately uses a wide canvas to exercise the inscribed-circle rule.
        let eyeWidth = layout == .mono ? side * 2 : side
        let width = layout == .overUnder ? side : side * 2
        let height = layout == .overUnder ? side * 2 : side
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let localX = x % eyeWidth, localY = y % side
            let dx = (Double(localX) + 0.5 - Double(eyeWidth) / 2) / (Double(side) / 2)
            let dy = (Double(side) / 2 - Double(localY) - 0.5) / (Double(side) / 2)
            let radius = hypot(dx, dy)
            let second = layout == .sideBySide ? x >= side : (layout == .overUnder && y >= side)
            var color: (UInt8, UInt8, UInt8) = (0, 0, 0)
            if radius <= 1 {
                if abs(dx) > abs(dy) { color = dx > 0 ? (175, 30, 30) : (180, 140, 25) }
                else { color = dy > 0 ? (25, 155, 45) : (30, 60, 180) }
                // Rings independently encode 30/60/90 degrees as 1/3, 2/3, 1 radius.
                let ring = [1.0 / 3, 2.0 / 3, 1.0].contains { abs(radius - $0) < 0.006 }
                if ring || abs(dx) < 0.004 || abs(dy) < 0.004 { color = (240, 240, 240) }
                if radius < 0.035 { color = second ? (240, 50, 220) : (240, 240, 240) }
            }
            let offset = (y * width + x) * 4
            pixels[offset] = color.0; pixels[offset + 1] = color.1; pixels[offset + 2] = color.2; pixels[offset + 3] = 255
        } }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
