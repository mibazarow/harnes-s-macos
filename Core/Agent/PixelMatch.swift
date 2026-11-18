import Accelerate
import CoreGraphics
import Foundation

/// One template hit: the top-left corner and the size in pixels of the searched image.
struct PixelMatch: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let score: Double

    var center: CGPoint {
        CGPoint(x: Double(x) + Double(width) / 2, y: Double(y) + Double(height) / 2)
    }
}

/// R18.10: the pixel path is a fallback, so its rules are strict on purpose. Two hits
/// with nearly the same score mean the fragment is not distinctive enough to click.
enum PixelMatchPolicy {
    static let threshold = 0.85
    static let maxCandidates = 5
    /// A second hit this close to the first is a coin flip, not a match.
    static let ambiguousDelta = 0.02

    static func isAmbiguous(_ matches: [PixelMatch]) -> Bool {
        guard matches.count >= 2 else { return false }
        return matches[0].score - matches[1].score < ambiguousDelta
    }
}

/// Template search through Accelerate.
///
/// A 3840×2160 screen against a 200-pixel fragment is ~10^11 multiply-adds at full
/// resolution, so the search runs coarse-to-fine: both images are box-downsampled until
/// the fragment is about 24 pixels wide, the reduced grid is scanned, and only the best
/// few positions are refined at full resolution.
enum TemplateMatcher {
    struct Plane {
        let width: Int
        let height: Int
        var pixels: [Float]
    }

    static func plane(_ image: CGImage) -> Plane? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        let space = CGColorSpaceCreateDeviceGray()
        guard let context = bytes.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }) else { return nil }
        context.interpolationQuality = .none
        // Row 0 of the plane is row 0 of the image: no flip, so a match's y is the same
        // y the caller sees when it crops or reads the capture.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var pixels = [Float](repeating: 0, count: width * height)
        vDSP_vfltu8(bytes, 1, &pixels, 1, vDSP_Length(width * height))
        return Plane(width: width, height: height, pixels: pixels)
    }

    /// Box filter by an integer factor: keeps thin lines from aliasing away.
    static func reduce(_ plane: Plane, step: Int) -> Plane {
        guard step > 1 else { return plane }
        let width = plane.width / step
        let height = plane.height / step
        guard width > 0, height > 0 else { return plane }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let rowBase = y * step * plane.width
            for x in 0..<width {
                var sum: Float = 0
                let column = x * step
                for dy in 0..<step {
                    let base = rowBase + dy * plane.width + column
                    sum += plane.pixels.withUnsafeBufferPointer { buffer in
                        var partial: Float = 0
                        vDSP_sve(buffer.baseAddress! + base, 1, &partial, vDSP_Length(step))
                        return partial
                    }
                }
                out[y * width + x] = sum / Float(step * step)
            }
        }
        return Plane(width: width, height: height, pixels: out)
    }

    /// Normalised cross-correlation of one window against a zero-mean template.
    private static func score(
        image: Plane, template: Plane, templateCentered: [Float], templateEnergy: Float,
        at x: Int, y: Int, scratch: inout [Float]
    ) -> Double {
        let tw = template.width
        let th = template.height
        let count = vDSP_Length(tw * th)
        for row in 0..<th {
            let source = (y + row) * image.width + x
            let target = row * tw
            image.pixels.withUnsafeBufferPointer { buffer in
                scratch.withUnsafeMutableBufferPointer { out in
                    out.baseAddress!.advanced(by: target)
                        .update(from: buffer.baseAddress!.advanced(by: source), count: tw)
                }
            }
        }
        var mean: Float = 0
        vDSP_meanv(scratch, 1, &mean, count)
        var energy: Float = 0
        vDSP_svesq(scratch, 1, &energy, count)
        energy -= Float(tw * th) * mean * mean
        guard energy > 1, templateEnergy > 1 else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(scratch, 1, templateCentered, 1, &dot, count)
        return Double(max(0, min(1, dot / (energy * templateEnergy).squareRoot())))
    }

    static func matches(
        in source: CGImage, template: CGImage,
        threshold: Double = PixelMatchPolicy.threshold,
        limit: Int = PixelMatchPolicy.maxCandidates
    ) -> [PixelMatch] {
        guard let sourcePlane = plane(source), let templatePlane = plane(template) else { return [] }
        guard templatePlane.width <= sourcePlane.width,
              templatePlane.height <= sourcePlane.height else { return [] }

        var templateCentered = templatePlane.pixels
        var templateMean: Float = 0
        vDSP_meanv(templatePlane.pixels, 1, &templateMean,
                   vDSP_Length(templatePlane.pixels.count))
        var negative = -templateMean
        vDSP_vsadd(templateCentered, 1, &negative, &templateCentered, 1,
                   vDSP_Length(templateCentered.count))
        var templateEnergy: Float = 0
        vDSP_svesq(templateCentered, 1, &templateEnergy, vDSP_Length(templateCentered.count))
        guard templateEnergy > 1 else { return [] }

        let step = max(1, templatePlane.width / 24)
        let coarseSource = reduce(sourcePlane, step: step)
        let coarseTemplate = reduce(templatePlane, step: step)
        guard coarseTemplate.width > 1, coarseTemplate.height > 1,
              coarseTemplate.width <= coarseSource.width,
              coarseTemplate.height <= coarseSource.height else { return [] }

        var coarseCentered = coarseTemplate.pixels
        var coarseMean: Float = 0
        vDSP_meanv(coarseTemplate.pixels, 1, &coarseMean,
                   vDSP_Length(coarseTemplate.pixels.count))
        var coarseNegative = -coarseMean
        vDSP_vsadd(coarseCentered, 1, &coarseNegative, &coarseCentered, 1,
                   vDSP_Length(coarseCentered.count))
        var coarseEnergy: Float = 0
        vDSP_svesq(coarseCentered, 1, &coarseEnergy, vDSP_Length(coarseCentered.count))
        guard coarseEnergy > 1 else { return [] }

        var scratch = [Float](repeating: 0, count: coarseTemplate.width * coarseTemplate.height)
        var candidates: [(x: Int, y: Int, score: Double)] = []
        let maxY = coarseSource.height - coarseTemplate.height
        let maxX = coarseSource.width - coarseTemplate.width
        if maxX >= 0 && maxY >= 0 {
            for y in 0...maxY {
                for x in 0...maxX {
                    let value = score(
                        image: coarseSource, template: coarseTemplate,
                        templateCentered: coarseCentered, templateEnergy: coarseEnergy,
                        at: x, y: y, scratch: &scratch
                    )
                    if value >= threshold {
                        candidates.append((x * step, y * step, value))
                    }
                }
            }
        }
        guard !candidates.isEmpty else { return [] }

        // Refine only the best few coarse positions, then de-duplicate them at full
        // resolution: neighbours of one hit are not a second candidate.
        candidates.sort { $0.score > $1.score }
        var refined: [PixelMatch] = []
        var fullScratch = [Float](repeating: 0, count: templatePlane.width * templatePlane.height)
        let radius = step
        let fullMaxX = sourcePlane.width - templatePlane.width
        let fullMaxY = sourcePlane.height - templatePlane.height
        for candidate in candidates.prefix(limit * 4) {
            var best: (x: Int, y: Int, score: Double) = (candidate.x, candidate.y, 0)
            let xRange = max(0, candidate.x - radius)...min(fullMaxX, candidate.x + radius)
            let yRange = max(0, candidate.y - radius)...min(fullMaxY, candidate.y + radius)
            for y in yRange {
                for x in xRange {
                    let value = score(
                        image: sourcePlane, template: templatePlane,
                        templateCentered: templateCentered, templateEnergy: templateEnergy,
                        at: x, y: y, scratch: &fullScratch
                    )
                    if value > best.score { best = (x, y, value) }
                }
            }
            guard best.score >= threshold else { continue }
            let tooClose = refined.contains {
                abs($0.x - best.x) < templatePlane.width / 2
                    && abs($0.y - best.y) < templatePlane.height / 2
            }
            guard !tooClose else { continue }
            refined.append(PixelMatch(
                x: best.x, y: best.y,
                width: templatePlane.width, height: templatePlane.height,
                score: best.score
            ))
        }
        return refined.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }
}
