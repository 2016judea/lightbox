import Foundation
import CoreGraphics
import Vision

// Where a negative is genuinely ambiguous, measured, and the printer's moves that answer it.
// Spec: docs/ALTERNATIVES.md, "Where a negative is genuinely ambiguous" and "The alternatives
// Lightbox offers". Each trigger fires only on its own ambiguity; on a normal roll no trigger may
// fire on more than about one frame in five (BenchTests checks this on his real rolls).

/// What the frame measures as, in printer's units. Colour is print density x 100 (CC):
/// yellowness = B density - mean(R, G); magentaness = G density - mean(R, B).
struct FrameStats {
    var negMax: Double          // luminance density above base at the 99.9th percentile (the highlights' density)
    var negMin: Double          // ... at the 0.1th percentile (the shadows' density)
    var key: Double             // median of the normalised negative, 0 (dark scene) ... 1 (bright scene)
    var cast: (y: Double, m: Double)            // midtones
    var neutralFraction: Double                 // midtone pixels within 6 CC of grey
    var shadows: (y: Double, m: Double)
    var highlights: (y: Double, m: Double)
    var mids: (y: Double, m: Double)
    var skin: (y: Double, m: Double)?           // mean over detected faces
    var faceCount = 0
}

struct RingTile: Identifiable, Equatable {
    let id = UUID()
    var label: String
    var edit: Edit
    static func == (a: RingTile, b: RingTile) -> Bool { a.id == b.id }
}

struct Ambiguity: Identifiable, Equatable {
    enum Kind: String { case density, colour, skin, tone }
    var id: Kind { kind }
    var kind: Kind
    var flag: String            // the one plain line shown under the picture
    var tiles: [RingTile]
}

enum Bench {

    // Thresholds. Set 2026-11-03 against his own rolls (2026-10-22/23 Gold 200, 2026-10-23
    // Portra 400; BenchTests prints the numbers): each fires on at most one frame in five there.
    static let thinNeg = 0.55           // highlights under this density: thin
    static let denseShadows = 0.30      // shadows over this density: dense
    static let lowKey = 0.12, highKey = 0.65
    static let castCC = 20.0            // the frame's grey sits this far from the stock's own balance
    static let minNeutral = 0.12        // less than this share of near-grey midtones: no reliable neutral
    static let skinOffCC = 15.0         // skin this far from its reference
    static let labConfidenceLow = 0.5

    /// Reference skin in the same units, from the ColorChecker light and dark skin patches
    /// (sRGB 194/150/130 and 115/82/68): yellowness 26 and 32, magentaness 5.6 and 6.9.
    static let skinTarget = (y: 29.0, m: 6.0)

    // MARK: measuring

    /// Print densities x 100 for an 8-bit sRGB value.
    static let densityLUT: [Double] = (0..<256).map { i in
        let v = Double(i) / 255
        let lin = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        return -log10(max(lin, 1e-4)) * 100
    }

    struct Pixels { var w: Int; var h: Int; var rgba: [UInt8] }

    static func pixels(_ img: CGImage, maxSide: Int = 400) -> Pixels {
        let s = min(1, Double(maxSide) / Double(max(img.width, img.height)))
        let w = max(1, Int(Double(img.width) * s)), h = max(1, Int(Double(img.height) * s))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Pixels(w: w, h: h, rgba: buf)
    }

    /// Mean yellowness/magentaness over pixels whose luma (0...1) is in the band.
    static func cast(_ p: Pixels, luma lo: Double, _ hi: Double, rect: (Int, Int, Int, Int)? = nil,
                     neutralWithin: Double? = nil) -> (y: Double, m: Double, n: Int, neutral: Int) {
        let (x0, y0, x1, y1) = rect ?? (0, 0, p.w, p.h)
        var sy = 0.0, sm = 0.0, n = 0, neu = 0
        for yy in y0..<y1 { for xx in x0..<x1 {
            let o = (yy * p.w + xx) * 4
            let r = Int(p.rgba[o]), g = Int(p.rgba[o + 1]), b = Int(p.rgba[o + 2])
            let l = (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255
            guard l >= lo && l <= hi else { continue }
            let dr = densityLUT[r], dg = densityLUT[g], db = densityLUT[b]
            let cy = db - (dr + dg) / 2, cm = dg - (dr + db) / 2
            sy += cy; sm += cm; n += 1
            if let t = neutralWithin, abs(cy) < t && abs(cm) < t { neu += 1 }
        } }
        return n == 0 ? (0, 0, 0, 0) : (sy / Double(n), sm / Double(n), n, neu)
    }

    /// The frame's probable grey: mean-shift toward the densest cluster of low-colour pixels, from
    /// the stock's own intended balance. Returns its colour and the share of band pixels inside it.
    static func grey(_ p: Pixels, luma lo: Double, _ hi: Double, from start: (y: Double, m: Double),
                     rect: (Int, Int, Int, Int)? = nil, radius: Double = 15) -> (y: Double, m: Double, share: Double, n: Int) {
        let (x0, y0, x1, y1) = rect ?? (0, 0, p.w, p.h)
        var pts: [(Double, Double)] = []
        for yy in y0..<y1 { for xx in x0..<x1 {
            let o = (yy * p.w + xx) * 4
            let r = Int(p.rgba[o]), g = Int(p.rgba[o + 1]), b = Int(p.rgba[o + 2])
            let l = (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255
            guard l >= lo && l <= hi else { continue }
            let dr = densityLUT[r], dg = densityLUT[g], db = densityLUT[b]
            pts.append((db - (dr + dg) / 2, dg - (dr + db) / 2))
        } }
        guard !pts.isEmpty else { return (start.y, start.m, 0, 0) }
        var c = start, inside = 0
        for _ in 0..<8 {
            var sy = 0.0, sm = 0.0; inside = 0
            for q in pts where (q.0 - c.y) * (q.0 - c.y) + (q.1 - c.m) * (q.1 - c.m) < radius * radius { sy += q.0; sm += q.1; inside += 1 }
            guard inside > 0 else { break }
            c = (sy / Double(inside), sm / Double(inside))
        }
        return (c.y, c.m, Double(inside) / Double(pts.count), inside)
    }

    /// Faces (Vision), and the mean colour of the middle of each face.
    static func skin(_ img: CGImage, _ p: Pixels) -> (y: Double, m: Double, count: Int)? {
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        let faces = (req.results ?? []).filter { $0.confidence > 0.6 && $0.boundingBox.width > 0.03 }
        guard !faces.isEmpty else { return nil }
        var sy = 0.0, sm = 0.0, n = 0
        for f in faces {
            let bb = f.boundingBox     // normalised, origin bottom-left
            let cx = bb.midX, cy = 1 - bb.midY, hw = bb.width / 4, hh = bb.height / 4
            let r = (Int((cx - hw) * Double(p.w)), Int((cy - hh) * Double(p.h)), Int((cx + hw) * Double(p.w)), Int((cy + hh) * Double(p.h)))
            let c = cast(p, luma: 0.12, 0.95, rect: (max(0, r.0), max(0, r.1), min(p.w, r.2), min(p.h, r.3)))
            if c.n > 0 { sy += c.y * Double(c.n); sm += c.m * Double(c.n); n += c.n }
        }
        return n == 0 ? nil : (sy / Double(n), sm / Double(n), faces.count)
    }

    /// Everything the triggers read, off the negative (analysis) and the frame as it renders now.
    static func measure(_ a: Analysis, rendered img: CGImage, bias: (y: Double, m: Double) = (0, 0), faces: Bool = true) -> FrameStats {
        let p = pixels(img)
        let mid = grey(p, luma: 0.15, 0.85, from: bias)
        let sh = grey(p, luma: 0.06, 0.3, from: (mid.y, mid.m)), hl = grey(p, luma: 0.65, 0.94, from: (mid.y, mid.m))
        let md = grey(p, luma: 0.35, 0.65, from: (mid.y, mid.m))
        var s = FrameStats(negMax: Double(a.hi[3]), negMin: Double(a.lo[3]),
                           key: Double(a.med[0] + a.med[1] + a.med[2]) / 3,
                           cast: (mid.y - bias.y, mid.m - bias.m), neutralFraction: mid.share,
                           shadows: (sh.y, sh.m), highlights: (hl.y, hl.m), mids: (md.y, md.m))
        if faces, let k = skin(img, p) { s.skin = (k.y, k.m); s.faceCount = k.count }
        return s
    }

    /// The colour a stock's profile prints on purpose (Gold's warmth), which is not a cast.
    static func bias(_ look: FilmStock.Look) -> (y: Double, m: Double) {
        (Double(look.warmBias) * 1.5 / PrinterUnits.ccOffset, Double(look.tintBias) / PrinterUnits.ccOffset)
    }

    // MARK: deciding

    /// The six print directions as Y/M moves, cyan held at zero as in a ring-around:
    /// +5 R = +5 Y +5 M, +5 C = −5 Y −5 M, +5 B = −5 Y, +5 G = −5 M.
    static let directions: [(name: String, y: Double, m: Double)] = [
        ("Y", 1, 0), ("R", 1, 1), ("M", 0, 1), ("B", -1, 0), ("C", -1, -1), ("G", 0, -1),
    ]

    /// The direction nearest a colour vector (by angle), and its index.
    static func nearestDirection(y: Double, m: Double) -> Int {
        var best = 0, bestDot = -Double.infinity
        let n = max(1e-9, (y * y + m * m).squareRoot())
        for (i, d) in directions.enumerated() {
            let dn = (d.y * d.y + d.m * d.m).squareRoot()
            let dot = (y * d.y + m * d.m) / (n * dn)
            if dot > bestDot { bestDot = dot; best = i }
        }
        return best
    }

    static func ccLabel(y: Double, m: Double) -> String {
        [PrinterUnits.ccText(y, "Y"), PrinterUnits.ccText(m, "M")].compactMap { $0 }.joined(separator: " ")
    }

    /// The edit moved so that a measured colour lands on a target (by default, grey).
    static func neutralise(_ e: Edit, from c: (y: Double, m: Double), to t: (y: Double, m: Double) = (0, 0)) -> (Edit, String) {
        let dy = ((t.y - c.y) / 5).rounded() * 5, dm = ((t.m - c.m) / 5).rounded() * 5   // in CC 5 steps, as a printer would
        return (PrinterUnits.moved(e, y: dy, m: dm), ccLabel(y: dy, m: dm))
    }

    static func detect(_ s: FrameStats, edit e: Edit, stock: String, labConfidence: Double?) -> [Ambiguity] {
        let steps = StockStepSizes.steps(for: stock)
        let expired = FilmStock.named(stock)?.expired ?? false
        let isColour = e.filmType == .colorNegative
        let neutralKeeper = (FilmStock.named(stock)?.look.neutral ?? 0.6) < 0.3   // Redscale, 800T: the cast is the point
        var out: [Ambiguity] = []

        // 1. Density ring: unusual key, or a thin or dense negative.
        var why: String?
        if s.negMax < thinNeg { why = "Thin negative — print for the shadows or the highlights?" }
        else if s.negMin > denseShadows { why = "Dense negative — print for the highlights or the shadows?" }
        else if s.key > highKey { why = "Bright scene — where should middle grey sit?" }
        else if s.key < lowKey { why = "Dark scene — where should middle grey sit?" }
        if let why {
            let ds = steps.densityStops
            let tiles = [-ds[1], -ds[0], ds[0], ds[1]].map { st in
                RingTile(label: PrinterUnits.stopsText(st) ?? "", edit: PrinterUnits.moved(e, stops: st))
            }
            out.append(Ambiguity(kind: .density, flag: why, tiles: tiles))
        }
        guard isColour, !neutralKeeper else { return out }

        // 2. Colour ring: a cast the default balance left, no reliable neutral, or a weak lab match.
        let castMag = (s.cast.y * s.cast.y + s.cast.m * s.cast.m).squareRoot()
        let lowLab = labConfidence.map { $0 < labConfidenceLow } ?? false
        if castMag > castCC || s.neutralFraction < minNeutral || lowLab {
            let flag = castMag > castCC ? "A colour cast the scan can't settle — which way is neutral?"
                : (lowLab ? "No sure lab scan to judge the colour by — which way is neutral?"
                   : "Nothing in the frame is surely grey — which way is neutral?")
            // the 2-3 directions it is ambiguous along: away from the cast, and that direction's two neighbours
            let away = castMag > 1 ? (nearestDirection(y: -s.cast.y, m: -s.cast.m)) : 3   // no cast: the amber-blue axis
            var tiles: [RingTile] = []
            for (i, step) in [(away, steps.cc[1]), (away, steps.cc[0]), ((away + 5) % 6, steps.cc[0]), ((away + 1) % 6, steps.cc[0])] {
                let d = directions[i]
                let dy = d.y * step, dm = d.m * step
                tiles.append(RingTile(label: "+\(Int(step)) \(d.name)", edit: PrinterUnits.moved(e, y: dy, m: dm)))
            }
            if castMag <= castCC {        // no cast to move away from: offer both ends of the axis
                let d = directions[(away + 3) % 6]
                tiles.append(RingTile(label: "+\(Int(steps.cc[0])) \(d.name)", edit: PrinterUnits.moved(e, y: d.y * steps.cc[0], m: d.m * steps.cc[0])))
            }
            out.append(Ambiguity(kind: .colour, flag: flag, tiles: tiles))
        }

        // 4. Balance on skin: faces, and skin wants different filtration from the scene's greys.
        if let k = s.skin {
            let off = ((skinTarget.y - k.y) * (skinTarget.y - k.y) + (skinTarget.m - k.m) * (skinTarget.m - k.m)).squareRoot()
            if off > skinOffCC {
                let (es, ls) = neutralise(e, from: k, to: skinTarget)
                if !ls.isEmpty {
                    out.append(Ambiguity(kind: .skin, flag: "Skin and greys want different colour — balance on which?", tiles: [
                        RingTile(label: "balance on skin · \(ls)", edit: es),
                    ]))
                }
            }
        }

        // 5. Balance by tone: expired stock only. Measuring crossover off the picture (shadow grey vs
        //    highlight grey) was tried on his rolls 2026-11-03 and read scene colour instead: dark hair
        //    and coats are "warm shadows", so it fired on 5 of 10 normal frames. A real channel-slope
        //    test needs the calibration fit's per-channel curves; until then, expired stock is the trigger.
        if expired {
            var tiles: [RingTile] = []
            for (name, c) in [("neutral shadows", s.shadows), ("neutral midtones", s.mids), ("neutral highlights", s.highlights)] {
                let (en, l) = neutralise(e, from: c)
                tiles.append(RingTile(label: l.isEmpty ? name : "\(name) · \(l)", edit: en))
            }
            out.append(Ambiguity(kind: .tone, flag: "Expired film — which tones should be neutral?", tiles: tiles))
        }
        return out
    }

    /// Measures and decides in one go: renders the frame small with the current edit.
    static func analyse(_ raw: RawImage, _ a: Analysis, edit e: Edit, look: FilmStock.Look, stock: String,
                        labConfidence: Double?) -> (FrameStats, [Ambiguity])? {
        guard let img = Develop.render(raw.width > 900 ? raw.downsampled(maxSide: 900) : raw, a, e, look: look) else { return nil }
        let s = measure(a, rendered: img, bias: bias(look))
        return (s, detect(s, edit: e, stock: stock, labConfidence: labConfidence))
    }
}
