import CoreGraphics
import XCTest
@testable import Harness

/// R18.10: the pixel path must find a fragment at a known place, refuse an ambiguous
/// fragment, and hand the model points instead of pixels.
final class PixelMatchTests: XCTestCase {
    private func grayImage(width: Int, height: Int, _ bytes: [UInt8]) -> CGImage {
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    /// Deterministic noise: a fragment like this correlates with one place only, which
    /// is exactly what the matcher must reward.
    private func noise(width: Int, height: Int, seed: UInt64) -> [UInt8] {
        var state = seed
        var out = [UInt8](repeating: 0, count: width * height)
        for index in out.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            out[index] = UInt8((state >> 33) % 256)
        }
        return out
    }

    private func paste(_ fragment: [UInt8], into canvas: inout [UInt8],
                       canvasWidth: Int, x: Int, y: Int, width: Int, height: Int) {
        for row in 0..<height {
            for column in 0..<width {
                canvas[(y + row) * canvasWidth + x + column] = fragment[row * width + column]
            }
        }
    }

    func testFindsFragmentAtKnownPlace() throws {
        let canvasWidth = 240
        let canvasHeight = 180
        var canvas = [UInt8](repeating: 210, count: canvasWidth * canvasHeight)
        let fragment = noise(width: 40, height: 40, seed: 7)
        paste(fragment, into: &canvas, canvasWidth: canvasWidth,
              x: 100, y: 60, width: 40, height: 40)
        let source = grayImage(width: canvasWidth, height: canvasHeight, canvas)
        let template = try XCTUnwrap(source.cropping(to: CGRect(x: 100, y: 60, width: 40, height: 40)))

        let matches = TemplateMatcher.matches(in: source, template: template)

        let best = try XCTUnwrap(matches.first)
        XCTAssertEqual(matches.count, 1, "\(matches)")
        XCTAssertEqual(best.x, 100)
        XCTAssertEqual(best.y, 60)
        XCTAssertGreaterThan(best.score, 0.95)
        XCTAssertFalse(PixelMatchPolicy.isAmbiguous(matches))
    }

    func testTwoIdenticalFragmentsAreAmbiguous() throws {
        let canvasWidth = 260
        let canvasHeight = 200
        var canvas = [UInt8](repeating: 210, count: canvasWidth * canvasHeight)
        let fragment = noise(width: 32, height: 32, seed: 11)
        paste(fragment, into: &canvas, canvasWidth: canvasWidth,
              x: 20, y: 20, width: 32, height: 32)
        paste(fragment, into: &canvas, canvasWidth: canvasWidth,
              x: 180, y: 140, width: 32, height: 32)
        let source = grayImage(width: canvasWidth, height: canvasHeight, canvas)
        let template = try XCTUnwrap(source.cropping(to: CGRect(x: 20, y: 20, width: 32, height: 32)))

        let matches = TemplateMatcher.matches(in: source, template: template)

        XCTAssertEqual(matches.count, 2, "\(matches)")
        XCTAssertTrue(PixelMatchPolicy.isAmbiguous(matches))
    }

    func testMissingFragmentIsEmpty() throws {
        let source = grayImage(width: 120, height: 90, [UInt8](repeating: 128, count: 120 * 90))
        let template = grayImage(width: 16, height: 16, noise(width: 16, height: 16, seed: 3))

        XCTAssertTrue(TemplateMatcher.matches(in: source, template: template).isEmpty)
    }

    func testAmbiguityNeedsCloseScores() {
        let first = PixelMatch(x: 0, y: 0, width: 10, height: 10, score: 0.97)
        let close = PixelMatch(x: 100, y: 100, width: 10, height: 10, score: 0.96)
        let far = PixelMatch(x: 100, y: 100, width: 10, height: 10, score: 0.80)

        XCTAssertTrue(PixelMatchPolicy.isAmbiguous([first, close]))
        XCTAssertFalse(PixelMatchPolicy.isAmbiguous([first, far]))
        XCTAssertFalse(PixelMatchPolicy.isAmbiguous([first]))
    }

    func testPixelCentreBecomesScreenPoint() {
        let point = ScreenGeometry.point(
            fromRegionPixels: CGPoint(x: 200, y: 100),
            origin: CGPoint(x: -1808, y: 137),
            scale: 2
        )

        XCTAssertEqual(point.x, -1708)
        XCTAssertEqual(point.y, 187)
    }

    func testDisplayIsInferredFromPixelSize() {
        let screens = [
            DisplaySpace(origin: .zero, size: CGSize(width: 1512, height: 982), scale: 2),
            DisplaySpace(origin: CGPoint(x: -1808, y: 137),
                         size: CGSize(width: 1920, height: 1080), scale: 1)
        ]

        XCTAssertEqual(
            ScreenGeometry.displayIndex(
                forPixelSize: CGSize(width: 3024, height: 1964), screens: screens
            ),
            0
        )
        XCTAssertEqual(
            ScreenGeometry.displayIndex(
                forPixelSize: CGSize(width: 1920, height: 1080), screens: screens
            ),
            1
        )
        XCTAssertNil(
            ScreenGeometry.displayIndex(
                forPixelSize: CGSize(width: 800, height: 600), screens: screens
            )
        )
    }
}
