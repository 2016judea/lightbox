import Foundation

/// One adjustable setting in the edit pane, for its own reset button.
enum Setting: String, CaseIterable {
    case exposure, contrast, sharpen, warmth, tint, cropRotate, filmType, stock, dust, dpi

    /// Edit-scoped settings put back to the frame's baseline (the stock's starting point, or the
    /// lab-matched values if "Match lab colour" was used).
    static func reset(_ s: Setting, _ e: Edit, to b: Edit) -> Edit {
        var e = e
        switch s {
        case .exposure: e.exposure = b.exposure
        case .contrast: e.contrast = b.contrast
        case .sharpen: e.sharpen = b.sharpen
        case .warmth: e.warmth = b.warmth
        case .tint: e.tint = b.tint
        case .cropRotate: e.crop = b.crop; e.rotation = b.rotation; e.mirrored = b.mirrored
        case .filmType: e.filmType = b.filmType
        case .dust: e.dust = b.dust
        case .stock, .dpi: break
        }
        return e
    }

    /// Slider settings count as changed only past half a displayed step, matching what the label shows.
    static func differs(_ s: Setting, _ e: Edit, _ b: Edit) -> Bool {
        func off(_ x: Double, _ y: Double) -> Bool { abs(x - y) >= 0.005 }
        switch s {
        case .exposure: return off(e.exposure, b.exposure)
        case .contrast: return off(e.contrast, b.contrast)
        case .sharpen: return off(e.sharpen, b.sharpen)
        case .warmth: return off(e.warmth, b.warmth)
        case .tint: return off(e.tint, b.tint)
        default: return reset(s, e, to: b) != e
        }
    }
}
