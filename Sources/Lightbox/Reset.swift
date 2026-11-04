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

    /// Slider settings count as changed only when the readout (in printer's units) shows a change.
    static func differs(_ s: Setting, _ e: Edit, _ b: Edit) -> Bool {
        typealias P = PrinterUnits
        switch s {
        case .exposure: return P.stopsText((e.exposure - b.exposure) * P.stopsPerExposure) != nil
        case .contrast: return P.gradeText((e.contrast - b.contrast) * P.gradesPerContrast) != nil
        case .sharpen: return abs(e.sharpen - b.sharpen) >= 0.005
        case .warmth: return P.ccText((e.warmth - b.warmth) * P.ccYPerWarmth, "Y") != nil
        case .tint: return P.ccText((e.tint - b.tint) * P.ccMPerTint, "M") != nil
        default: return reset(s, e, to: b) != e
        }
    }
}
