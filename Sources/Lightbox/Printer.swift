import Foundation

// The printer's bench: corrections in the units a colour printer or a scan-station operator uses
// (print density in stops, colour filtration in CC, paper grade), mapped onto Lightbox's own
// sliders. Spec: docs/ALTERNATIVES.md (Aidan, 2026-11-03).
//
// Convention: every unit describes the PRINT, not the filter pack. "+10 Y" means the print moves
// 10 CC toward yellow; "+⅓ stop" means the print gets a third of a stop lighter. A darkroom filter
// pack runs the other way (more Y filtration makes the print bluer); a ring-around is labelled by
// what you see, and so is this.

enum PrinterUnits {
    // How the units were derived (2026-11-03): the print curve (Develop.curveLUT, k = 5) was read as
    // print density, -log10 of linear sRGB. At middle grey (output 0.46, input 0.45) one unit of
    // normalised input moves print density by 2.88. So:
    //   1 CC  = 0.01 print density  = 0.01 / 2.88 = 0.00347 normalised offset
    //   1 stop = 0.301 print density = 0.301 / 2.88 = 0.1046 normalised offset
    // Stock profiles that change the curve's steepness (contrastBias) make these approximate.
    static let ccOffset = 0.00347
    static let stopOffset = 0.1046

    // Develop.render's slider scales (offsets per slider unit): exposure 0.3, warmth 0.08 (red up,
    // blue down), tint 0.06 (green down). Yellowness is B density minus the mean of R and G, so a
    // warmth offset w reads as 1.5 w; magentaness is G density minus the mean of R and B, so a tint
    // offset t reads as t.
    static let stopsPerExposure = 0.3 / stopOffset          // ≈ 2.87 stops across the half slider
    static let ccYPerWarmth = 1.5 * 0.08 / ccOffset          // ≈ 34.6 CC
    static let ccMPerTint = 0.06 / ccOffset                  // ≈ 17.3 CC
    /// Paper grade: one grade steepens the print curve by 20% (contrast slider 0.4).
    static let gradesPerContrast = 2.5

    static func stops(_ e: Edit) -> Double { e.exposure * stopsPerExposure }
    static func y(_ e: Edit) -> Double { e.warmth * ccYPerWarmth }
    static func m(_ e: Edit) -> Double { e.tint * ccMPerTint }
    static func grade(_ e: Edit) -> Double { e.contrast * gradesPerContrast }

    // MARK: readouts

    /// "+⅓ stop", "−⅔ stop", "+1 stop", "+1⅓ stops"; off a third, one decimal ("+0.4 stop").
    static func stopsText(_ s: Double) -> String? {
        if abs(s) < 0.05 { return nil }
        let sign = s > 0 ? "+" : "−"
        let a = abs(s), thirds = (a * 3).rounded()
        if abs(a * 3 - thirds) < 0.06 {
            let whole = Int(thirds) / 3, frac = Int(thirds) % 3
            let f = frac == 1 ? "⅓" : (frac == 2 ? "⅔" : "")
            let n = (whole == 0 ? "" : "\(whole)") + f
            return "\(sign)\(n) stop" + (thirds > 3 ? "s" : "")
        }
        return String(format: "%@%.1f stop%@", sign, a, a > 1 ? "s" : "")
    }

    /// "+10 Y", "−5 M"; nil under half a CC.
    static func ccText(_ v: Double, _ dye: String) -> String? {
        let r = Int(v.rounded())
        if r == 0 { return nil }
        return (r > 0 ? "+" : "−") + "\(abs(r)) \(dye)"
    }

    /// "+½ grade", "−1 grade"; nil under a twentieth.
    static func gradeText(_ g: Double) -> String? {
        if abs(g) < 0.05 { return nil }
        let sign = g > 0 ? "+" : "−", a = abs(g), halves = (a * 2).rounded()
        if abs(a * 2 - halves) < 0.1 {
            let whole = Int(halves) / 2, half = Int(halves) % 2 == 1
            return "\(sign)\(whole == 0 ? "" : "\(whole)")\(half ? "½" : "") grade"
        }
        return String(format: "%@%.1f grade", sign, a)
    }

    /// The whole correction in one line: "+5 Y −5 M, +⅓ stop". Nil when there is none.
    static func summary(_ e: Edit) -> String? {
        let colour = [ccText(y(e), "Y"), ccText(m(e), "M")].compactMap { $0 }.joined(separator: " ")
        let parts = [colour.isEmpty ? nil : colour, stopsText(stops(e)), gradeText(grade(e))].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: moves

    /// The edit moved by a correction in printer's units, clamped to the sliders' range.
    static func moved(_ e: Edit, stops ds: Double = 0, y dy: Double = 0, m dm: Double = 0, grade dg: Double = 0) -> Edit {
        var o = e
        func c(_ v: Double) -> Double { max(-1, min(1, v)) }
        o.exposure = c(e.exposure + ds / stopsPerExposure)
        o.warmth = c(e.warmth + dy / ccYPerWarmth)
        o.tint = c(e.tint + dm / ccMPerTint)
        o.contrast = c(e.contrast + dg / gradesPerContrast)
        return o
    }
}

/// The correction a frame carries: the four sliders a printer's notebook would write down.
struct Correction: Codable, Equatable {
    var exposure = 0.0, warmth = 0.0, tint = 0.0, contrast = 0.0
    init() {}
    init(_ e: Edit) { exposure = e.exposure; warmth = e.warmth; tint = e.tint; contrast = e.contrast }
    func applied(to e: Edit) -> Edit {
        var o = e; o.exposure = exposure; o.warmth = warmth; o.tint = tint; o.contrast = contrast; return o
    }
    var edit: Edit { applied(to: Edit()) }
    var isNeutral: Bool { PrinterUnits.summary(edit) == nil }
    var summary: String { PrinterUnits.summary(edit) ?? "none" }
    /// Same correction as far as the readouts can tell.
    func same(_ o: Correction) -> Bool { summary == o.summary }
}

/// Ring step sizes for a stock.
struct RingSteps: Equatable {
    var densityStops: [Double]   // e.g. [1/3, 2/3]
    var cc: [Double]             // e.g. [5, 10]

    /// The darkroom ring-around defaults the spec cites: density ±⅓ and ±⅔ stop, filtration CC 5 and 10.
    static let darkroom = RingSteps(densityStops: [1.0 / 3, 2.0 / 3], cc: [5, 10])
}

/// CALIBRATION SEAM. The spec sets each stock's ring steps from how far the lab's per-frame
/// corrections spread for that stock ("a step means one typical lab correction for that film").
/// That fit against his lab scans does not exist yet (2026-11-03), so every stock gets the darkroom
/// defaults. When the calibration lands, it replaces `provider`; nothing else changes.
enum StockStepSizes {
    nonisolated(unsafe) static var provider: (String) -> RingSteps = { _ in .darkroom }
    static func steps(for stock: String) -> RingSteps { provider(stock) }
}

/// Paper and machine character, chosen once per roll (spec: "not per frame").
enum PrintCharacter: String, Codable, CaseIterable, Identifiable {
    case soft, normal, hard
    var id: String { rawValue }
    var label: String {
        switch self { case .soft: return "Soft"; case .normal: return "Normal"; case .hard: return "Hard" }
    }
    /// Short notebook name: what each one is modelled on.
    var notebookName: String {
        switch self { case .soft: return "Noritsu-soft"; case .normal: return "normal"; case .hard: return "Frontier-hard" }
    }

    /// Soft: a flatter curve with lifted shadows and a gentle highlight roll-off (Noritsu-like).
    /// Hard: a steeper curve, deeper blacks, highlights pushed toward clipping (Frontier-like).
    /// Normal is the stock profile untouched.
    func apply(_ l: FilmStock.Look) -> FilmStock.Look {
        var o = l
        switch self {
        case .normal: break
        case .soft:
            o.contrastBias *= 0.85
            o.outputBlack = max(o.outputBlack, 0.03)
            o.outputWhite = min(o.outputWhite, 0.97)
        case .hard:
            o.contrastBias *= 1.18
            o.outputBlack = 0
            o.outputWhite = 1
            o.blackPoint = max(o.blackPoint, 0.02)
        }
        return o
    }
}

/// The roll's notebook: its character, the correction the next frame starts from, and which frames
/// used which correction. Saved next to the roll's raws as notebook.json.
struct RollNotebook: Codable, Equatable {
    var character: PrintCharacter = .normal
    /// What the next frame starts from: the last correction he kept on this roll.
    var carried = Correction()
    /// Frame number -> the correction that frame was kept with.
    var frames: [Int: Correction] = [:]

    /// Frames kept with the given correction, in order.
    func frames(using c: Correction) -> [Int] { frames.filter { $0.value.same(c) }.map(\.key).sorted() }

    /// Writes a frame's correction down; the next frame starts from it.
    mutating func keep(frame: Int, _ c: Correction) {
        frames[frame] = c
        carried = c
    }

    static func url(in folder: URL) -> URL { folder.appendingPathComponent("notebook.json") }
    static func load(from folder: URL) -> RollNotebook? {
        guard let d = try? Data(contentsOf: url(in: folder)) else { return nil }
        return try? JSONDecoder().decode(RollNotebook.self, from: d)
    }
    func save(to folder: URL) {
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: Self.url(in: folder)) }
    }
}

/// "1, 3–5, 7"
func frameList(_ ns: [Int]) -> String {
    var out: [String] = [], i = 0
    while i < ns.count {
        var j = i
        while j + 1 < ns.count && ns[j + 1] == ns[j] + 1 { j += 1 }
        out.append(j - i >= 2 ? "\(ns[i])–\(ns[j])" : (i == j ? "\(ns[i])" : "\(ns[i]), \(ns[j])"))
        i = j + 1
    }
    return out.joined(separator: ", ")
}
