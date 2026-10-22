import Foundation
import CoreGraphics

/// Comparing our render with his lab scan, and pulling our colour toward it.
enum LabCompare {
    static let qs: [Double] = [0.05, 0.25, 0.5, 0.75, 0.95]

    /// RGB pixels (0...255) of the central 80% of an image, at most ~250 px on the long side.
    static func pixels(_ img: CGImage) -> [[Double]] {
        let s = min(1, 250 / Double(max(img.width, img.height)))
        let w = max(1, Int(Double(img.width) * s)), h = max(1, Int(Double(img.height) * s))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var out: [[Double]] = [[], [], []]
        for y in (h / 10)..<(h - h / 10) { for x in (w / 10)..<(w - w / 10) {
            let o = (y * w + x) * 4
            for c in 0..<3 { out[c].append(Double(p[o + c])) }
        } }
        return out
    }

    /// Quantiles per channel; colour and tone, without needing the two crops to line up exactly.
    static func quantiles(_ img: CGImage) -> [[Double]] {
        pixels(img).map { ch in
            let s = ch.sorted()
            return qs.map { s[min(s.count - 1, Int(Double(s.count - 1) * $0))] }
        }
    }

    static func distance(_ a: [[Double]], _ b: [[Double]]) -> Double {
        var d = 0.0
        for c in 0..<3 { for i in qs.indices { d += pow(a[c][i] - b[c][i], 2) } }
        return sqrt(d / Double(3 * qs.count))
    }

    struct Stats: CustomStringConvertible {
        var mean: [Double], median: [Double], black: [Double], white: [Double]
        var description: String {
            func f(_ v: [Double]) -> String { v.map { String(format: "%.1f", $0) }.joined(separator: "/") }
            return "mean \(f(mean)) median \(f(median)) black(0.5%) \(f(black)) white(99.5%) \(f(white))"
        }
    }

    static func stats(_ img: CGImage) -> Stats {
        let px = pixels(img)
        func q(_ ch: [Double], _ p: Double) -> Double { let s = ch.sorted(); return s[Int(Double(s.count - 1) * p)] }
        return Stats(mean: px.map { $0.reduce(0, +) / Double($0.count) }, median: px.map { q($0, 0.5) },
                     black: px.map { q($0, 0.005) }, white: px.map { q($0, 0.995) })
    }

    /// Sets exposure, warmth and tint so our render's tone and colour land on the lab scan's.
    /// Coordinate descent on a ~250 px render; a starting point he can still move.
    static func fit(_ raw: RawImage, _ a: Analysis, _ start: Edit, look: FilmStock.Look, lab: CGImage) -> (Edit, Double, Double) {
        let small = raw.downsampled(maxSide: 400)
        let target = quantiles(lab)
        func cost(_ e: Edit) -> Double {
            guard let img = Develop.render(small, a, e, look: look) else { return .infinity }
            return distance(quantiles(img), target)
        }
        var e = start
        let before = cost(e)
        var best = before
        for step in [0.25, 0.1, 0.04, 0.015] {
            var improved = true
            while improved {
                improved = false
                for k in 0..<3 {
                    for dir in [-1.0, 1.0] {
                        var t = e
                        switch k {
                        case 0: t.exposure = max(-1, min(1, t.exposure + dir * step))
                        case 1: t.warmth = max(-1, min(1, t.warmth + dir * step))
                        default: t.tint = max(-1, min(1, t.tint + dir * step))
                        }
                        let c = cost(t)
                        if c < best - 1e-3 { best = c; e = t; improved = true }
                    }
                }
            }
        }
        return (e, before, best)
    }

    /// Variance of the Laplacian of luminance: higher = more fine detail. Compare only at the same scale.
    static func sharpness(_ img: CGImage, side: Int) -> Double {
        let s = Double(side) / Double(max(img.width, img.height))
        let w = Int(Double(img.width) * s), h = Int(Double(img.height) * s)
        var g = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &g, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, sum2 = 0.0, n = 0.0
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let i = y * w + x
            let l = Double(g[i - 1]) + Double(g[i + 1]) + Double(g[i - w]) + Double(g[i + w]) - 4 * Double(g[i])
            sum += l; sum2 += l * l; n += 1
        } }
        let m = sum / n
        return sum2 / n - m * m
    }
}
