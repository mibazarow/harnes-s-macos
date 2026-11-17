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
}
