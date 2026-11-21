import AppKit
import Foundation

public enum QAImages {
    public struct Comparison: Sendable {
        public var changedFraction: Double
        public var png: Data
    }

    public static func normalize(_ data: Data) throws -> (data: Data, width: Int, height: Int) {
        guard data.count <= 25_000_000, let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
              bitmap.pixelsWide * bitmap.pixelsHigh <= 16_000_000,
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw QAError("Choose an image under 25 MB and 16 million pixels.")
        }
        return (png, bitmap.pixelsWide, bitmap.pixelsHigh)
    }

    /// Exact-size comparison. Never resize one capture to hide a viewport or layout change.
    public static func compare(baseline: Data, actual: Data, channelTolerance: Int = 12) throws -> Comparison {
        guard let left = NSBitmapImageRep(data: baseline), let right = NSBitmapImageRep(data: actual),
              left.pixelsWide == right.pixelsWide, left.pixelsHigh == right.pixelsHigh,
              left.pixelsWide * left.pixelsHigh <= 16_000_000 else {
            throw QAError("The screenshots have different dimensions. Capture the same viewport and zoom as the baseline.")
        }
        let width = left.pixelsWide, height = left.pixelsHigh
        let a = try rgba(left), b = try rgba(right)
        guard let diff = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32), let out = diff.bitmapData else {
            throw QAError("Couldn't create the image comparison.")
        }
        var changed = 0
        for pixel in 0..<(width * height) {
            let i = pixel * 4
            let different = (0..<4).contains { abs(Int(a[i + $0]) - Int(b[i + $0])) > channelTolerance }
            if different { changed += 1; out[i] = 232; out[i + 1] = 55; out[i + 2] = 82 }
            else { for channel in 0..<3 { out[i + channel] = UInt8((Int(b[i + channel]) + 255 * 3) / 4) } }
            out[i + 3] = 255
        }
        guard let png = diff.representation(using: .png, properties: [:]) else { throw QAError("Couldn't encode the comparison.") }
        return Comparison(changedFraction: Double(changed) / Double(width * height), png: png)
    }

    private static func rgba(_ bitmap: NSBitmapImageRep) throws -> [UInt8] {
        guard let image = bitmap.cgImage else { throw QAError("Couldn't read screenshot pixels.") }
        var pixels = [UInt8](repeating: 0, count: bitmap.pixelsWide * bitmap.pixelsHigh * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                bitsPerComponent: 8, bytesPerRow: bitmap.pixelsWide * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            return true
        }
        guard rendered else { throw QAError("Couldn't decode screenshot pixels.") }
        return pixels
    }
}
