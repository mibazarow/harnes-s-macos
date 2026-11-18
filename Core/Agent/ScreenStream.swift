import CoreGraphics
import Foundation

/// R25.7: a short watch instead of "take a screenshot, wait, take another". Frames are
/// compared on a coarse grid; only the blocks that moved are reported, so a progress bar
/// or a loading spinner is visible without shipping a 3840×2160 image every second.
///
/// Opt-in on purpose: each frame is a full ScreenCaptureKit capture, and `ui wait` plus
/// `verify` covers most cases. It exists for "ждём, пока догрузится" and animations.
enum ScreenStream {
    struct Result: Equatable, Sendable {
        let frames: Int
        let changedFrames: Int
        /// Changed blocks as fractions of the frame: x, y, w, h in 0...1.
        let regions: [CGRect]
    }

    /// Coarse grid: 16 columns and 10 rows is enough to say "the top-left corner
    /// changed" without listing individual pixels.
    static let gridWidth = 16
    static let gridHeight = 10
    /// A block counts as changed when this share of its pixels differs.
    static let blockThreshold = 0.02

    static func grayscale(_ image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        guard let context = bytes.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(
                data: buffer.baseAddress, width: gridWidth, height: gridHeight,
                bitsPerComponent: 8, bytesPerRow: gridWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight))
        return bytes
    }

    /// Blocks whose pixels differ by more than `tolerance` on the 0...255 scale.
    static func changedBlocks(
        _ previous: [UInt8], _ current: [UInt8], tolerance: Int = 8
    ) -> [CGRect] {
        guard previous.count == current.count,
              previous.count == gridWidth * gridHeight else { return [] }
        var regions: [CGRect] = []
        for row in 0..<gridHeight {
            for column in 0..<gridWidth {
                let index = row * gridWidth + column
                let delta = abs(Int(previous[index]) - Int(current[index]))
                guard delta > tolerance else { continue }
                regions.append(CGRect(
                    x: Double(column) / Double(gridWidth),
                    y: Double(row) / Double(gridHeight),
                    width: 1 / Double(gridWidth),
                    height: 1 / Double(gridHeight)
                ))
            }
        }
        return regions
    }

    /// Collects frames for `duration` and returns how many changed. `onFrame` receives
    /// the last changed frame so the caller can save it once.
    static func watch(
        windowID: CGWindowID,
        duration: TimeInterval,
        interval: TimeInterval
    ) async -> (result: Result, lastChanged: CGImage?)? {
        guard WindowCapture.isAvailable else { return nil }
        let boundedDuration = min(max(duration, 0.5), 15)
        let boundedInterval = min(max(interval, 0.2), 5)
        let started = ContinuousClock.now
        var frames = 0
        var changedFrames = 0
        var previous: [UInt8]?
        var lastChanged: CGImage?
        var regions: [CGRect] = []

        while ContinuousClock.now - started < .seconds(boundedDuration) {
            guard let image = await WindowCapture.frame(windowID: windowID),
                  let gray = grayscale(image) else {
                return nil
            }
            frames += 1
            if let previous {
                let blocks = changedBlocks(previous, gray)
                if !blocks.isEmpty {
                    changedFrames += 1
                    regions = blocks
                    lastChanged = image
                }
            }
            previous = gray
            try? await Task.sleep(for: .seconds(boundedInterval))
        }
        return (
            Result(frames: frames, changedFrames: changedFrames, regions: regions),
            lastChanged
        )
    }
}
