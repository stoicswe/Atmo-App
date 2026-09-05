import Foundation
import CoreGraphics
import SwiftUI
import AtmoCore

// MARK: - Image Luminance
/// Mean brightness of an image's top and bottom bands, 0 (black) … 1
/// (white), from a tiny decode of its thumbnail — enough for viewer chrome
/// to pick glyph colors that stay legible over the picture.
enum ImageLuminance {
    struct Sample: Equatable {
        let top: Double
        let bottom: Double
    }

    /// Fraction of the height each band covers.
    private static let band = 0.2

    static func sample(_ url: URL) async -> Sample? {
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        guard let (data, _) = try? await URLSession.cachedSession.data(for: request) else { return nil }
        return await Task.detached(priority: .utility) {
            guard let image = AsyncCachedImage<EmptyView>.decode(data, maxPixelSize: 96) else { return nil }
            #if canImport(UIKit)
            guard let cg = image.cgImage else { return nil }
            #else
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            #endif
            return sample(cg)
        }.value
    }

    /// Pure luminance over an RGBA8 render of the image.
    nonisolated static func sample(_ image: CGImage) -> Sample? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func mean(rows: Range<Int>) -> Double {
            var total = 0.0
            var count = 0
            for y in rows {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
                    total += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
                    count += 1
                }
            }
            return count == 0 ? 0 : total / Double(count)
        }
        let bandRows = max(1, Int(Double(height) * band))
        return Sample(top: mean(rows: 0..<bandRows), bottom: mean(rows: (height - bandRows)..<height))
    }
}
