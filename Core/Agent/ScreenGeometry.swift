import CoreGraphics

/// One display as the UI tools need it: where it sits in the global point space and
/// how many pixels its backing store has per point.
struct DisplaySpace: Equatable, Sendable {
    let origin: CGPoint
    let size: CGSize
    let scale: CGFloat

    var frame: CGRect { CGRect(origin: origin, size: size) }
}

/// Three coordinate spaces meet here: screenshot pixels, global screen points (the
/// origin is the main display's top-left corner, other displays can be negative) and
/// AX element positions. Mixing them moves clicks to the wrong display on Retina and
/// multi-monitor setups (R18.1).
enum ScreenGeometry {
    static func pixels(fromPoint point: CGPoint, in display: DisplaySpace) -> CGPoint {
        CGPoint(
            x: (point.x - display.origin.x) * display.scale,
            y: (point.y - display.origin.y) * display.scale
        )
    }

    static func point(fromPixels pixel: CGPoint, in display: DisplaySpace) -> CGPoint {
        CGPoint(
            x: pixel.x / display.scale + display.origin.x,
            y: pixel.y / display.scale + display.origin.y
        )
    }

    /// Index of the display that owns the point; `nil` when it is outside every frame.
    static func displayIndex(for point: CGPoint, screens: [DisplaySpace]) -> Int? {
        screens.firstIndex { $0.frame.contains(point) }
    }

    /// R18.10: a capture is a rectangle in points (a window, a display, a clip), and the
    /// OCR or template hit is a pixel inside it. This is the conversion that makes a
    /// found word clickable without the model doing arithmetic.
    static func point(fromRegionPixels pixel: CGPoint, origin: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: pixel.x / scale + origin.x, y: pixel.y / scale + origin.y)
    }

    /// Which display produced a capture of this pixel size. Used when `ocr` gets only a
    /// file path and the scale is not stated: the backing size identifies the screen.
    static func displayIndex(forPixelSize size: CGSize, screens: [DisplaySpace]) -> Int? {
        screens.firstIndex {
            abs($0.size.width * $0.scale - size.width) < 2
                && abs($0.size.height * $0.scale - size.height) < 2
        }
    }
}
