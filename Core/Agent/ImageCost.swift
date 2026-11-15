import Foundation
import ImageIO

/// What a provider charges for one image.
///
/// A flat price per image made a 32×32 icon and a 2560×1440 screenshot cost the same,
/// and the breakdown line could not be trusted on requests that carried one. Providers
/// tile: a small base price plus a per-512px tile, after the longest side is capped.
/// The exact constants differ per vendor; these are the middle of the common scheme and
/// are checked against `prompt_tokens` on live sessions (R15.5), not treated as truth.
enum ImageCost {
    static let tileSide = 512
    static let tokensPerTile = 170
    static let baseTokens = 85
    static let longestSideCap = 2_048
    /// A cap after downscaling: 16 tiles is 2 805 tokens, close to what a full-screen
    /// screenshot costs on the providers we use.
    static let maxTiles = 16

    static func tokens(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return baseTokens }
        let scale = min(1, Double(longestSideCap) / Double(max(width, height)))
        let width = max(1, Int((Double(width) * scale).rounded(.up)))
        let height = max(1, Int((Double(height) * scale).rounded(.up)))
        let columns = (width + tileSide - 1) / tileSide
        let rows = (height + tileSide - 1) / tileSide
        return baseTokens + min(max(columns * rows, 1), maxTiles) * tokensPerTile
    }

    /// Reads only the pixel dimensions, not the pixels. Falls back to the old flat price
    /// when the data is not an image the system can parse.
    static func tokens(in data: Data) -> Int {
        let key = cacheKey(data)
        if let cached = cache.object(forKey: key) { return cached.intValue }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return Tuning.imageTokenEstimate
        }
        let value = tokens(width: width, height: height)
        cache.setObject(NSNumber(value: value), forKey: key)
        return value
    }

    /// The token pass runs once per step, and a long run can have hundreds of steps over
    /// the same attachment: parsing the header again every time is pure waste.
    /// `NSCache` is documented as thread-safe; the compiler cannot see that.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSNumber>()

    private static func cacheKey(_ data: Data) -> NSString {
        let head = data.prefix(32).base64EncodedString()
        let tail = data.suffix(32).base64EncodedString()
        return "\(data.count):\(head):\(tail)" as NSString
    }
}
