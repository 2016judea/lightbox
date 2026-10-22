import Foundation

/// Tells colour negative, B&W negative and slide apart from the preview alone.
///
/// Cues, in order:
/// 1. The film base. A colour negative's orange mask passes far more red than blue
///    (measured on the 8200i, 2026-10-22: R 0.348, G 0.153, B 0.085, so R/B = 4.1).
///    B&W film and slide film have a near-neutral base.
/// 2. Colour in the picture. With the base divided out, a B&W negative's three channels
///    carry the same density at every pixel; a slide's do not.
/// 3. The gap between frames. On a negative it is bare base, the brightest thing in the scan;
///    on slide film it is black. Used as a tiebreaker.
struct FilmGuess: Equatable {
    var type: FilmType
    var reason: String
    var baseRB: Float
    var chroma: Float
}

enum FilmDetect {
    static let orangeMaskRB: Float = 1.8     // colour negative above this
    static let neutralChroma: Float = 0.05   // B&W below this (density units)

    static func guess(_ raw: RawImage) -> FilmGuess {
        let w = raw.width, h = raw.height, px = raw.pixels
        let step = max(1, Int(sqrt(Double(raw.pixelCount) / 200_000)))
        var lums: [Float] = []
        for y in stride(from: 0, to: h, by: step) { for x in stride(from: 0, to: w, by: step) {
            let o = (y * w + x) * 3; lums.append((px[o] + px[o + 1] + px[o + 2]) / 3)
        } }
        lums.sort()
        let p99 = lums[min(lums.count - 1, Int(Double(lums.count) * 0.99))]
        let filmCut = 0.012 * p99
        var ch: [[Float]] = [[], [], []]
        for y in stride(from: 0, to: h, by: step) { for x in stride(from: 0, to: w, by: step) {
            let o = (y * w + x) * 3
            if (px[o] + px[o + 1] + px[o + 2]) / 3 > filmCut { for c in 0..<3 { ch[c].append(px[o + c]) } }
        } }
        var base: [Float] = [1, 1, 1]
        for c in 0..<3 { ch[c].sort(); base[c] = max(1e-4, ch[c][min(ch[c].count - 1, Int(Double(ch[c].count) * 0.995))]) }
        let rb = base[0] / base[2]

        // chroma: spread of the three densities per pixel, median over the middle of the frame
        var spreads: [Float] = []
        for y in stride(from: h / 5, to: 4 * h / 5, by: step) { for x in stride(from: w / 5, to: 4 * w / 5, by: step) {
            let o = (y * w + x) * 3
            if (px[o] + px[o + 1] + px[o + 2]) / 3 <= filmCut { continue }
            let d = (0..<3).map { -log10f(max(px[o + $0] / base[$0], 1e-4)) }
            let mean = (d[0] + d[1] + d[2]) / 3
            if mean < 0.05 || mean > 2.5 { continue }      // skip bare base and opaque bits
            spreads.append(d.max()! - d.min()!)
        } }
        spreads.sort()
        let chroma = spreads.isEmpty ? 0 : spreads[spreads.count / 2]

        // gap between frames: is there a band near base brightness at the left or right edge?
        let baseLum = (base[0] + base[1] + base[2]) / 3
        func bandBright(_ x0: Int, _ x1: Int) -> Bool {
            var n = 0, b = 0
            for y in stride(from: h / 4, to: 3 * h / 4, by: step) { for x in x0..<x1 {
                let o = (y * w + x) * 3; n += 1
                if (px[o] + px[o + 1] + px[o + 2]) / 3 > 0.85 * baseLum { b += 1 }
            } }
            return n > 0 && Double(b) / Double(n) > 0.6
        }
        let edge = max(2, w / 40)
        let rebate = bandBright(0, edge) || bandBright(w - edge, w)

        if rb > orangeMaskRB {
            return FilmGuess(type: .colorNegative, reason: "orange film base", baseRB: rb, chroma: chroma)
        }
        if chroma < neutralChroma {
            return FilmGuess(type: .bwNegative, reason: "neutral base, no colour in the picture", baseRB: rb, chroma: chroma)
        }
        if rebate {
            return FilmGuess(type: .bwNegative, reason: "neutral base with a clear gap between frames", baseRB: rb, chroma: chroma)
        }
        return FilmGuess(type: .slide, reason: "clear base, colour in the picture, black between frames", baseRB: rb, chroma: chroma)
    }
}
