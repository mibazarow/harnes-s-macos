import CoreGraphics

/// R19.5: a full-screen Retina shot is 3840×2160; a model rarely needs that. The target
/// size is computed once, then `sips` resamples the file in place.
enum ScreenshotScale {
    static func target(size: CGSize, scaleDown: Double?, maxHeight: Int?) -> CGSize? {
        var width = size.width
        var height = size.height
        if let scaleDown, scaleDown > 0, scaleDown < 1 {
            width *= scaleDown
            height *= scaleDown
        }
        if let maxHeight, maxHeight > 0, height > Double(maxHeight) {
            let scale = Double(maxHeight) / height
            width *= scale
            height = Double(maxHeight)
        }
        guard width < size.width || height < size.height else { return nil }
        return CGSize(width: max(width.rounded(), 1), height: max(height.rounded(), 1))
    }
}
