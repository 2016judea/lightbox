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

    static func differs(_ s: Setting, _ e: Edit, _ b: Edit) -> Bool {
        reset(s, e, to: b) != e
    }
}
