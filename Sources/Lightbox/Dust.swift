import Foundation

/// Dust and scratch removal from the infrared plane, done in Lightbox so it can be switched on
/// and off after the scan. Dye is close to transparent in infrared while dust, hair and scratches
/// block it, so a defect is where the IR plane dips well below its own local level. Those pixels
/// (grown by a couple of pixels) are filled from their clean neighbours, outside in.
enum Dust {
    struct Plane { let width: Int; let height: Int; var v: [Float] }

    /// Reads the 16-bit PGM that lb-scan writes.
    static func loadPGM(_ url: URL) throws -> Plane {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try data.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Plane in
            let p = b.bindMemory(to: UInt8.self)
            var i = 0, toks: [String] = []
            while toks.count < 4 && i < p.count {
                while i < p.count, p[i] == 32 || p[i] == 10 || p[i] == 13 || p[i] == 9 { i += 1 }
                if p[i] == UInt8(ascii: "#") { while i < p.count && p[i] != 10 { i += 1 }; continue }
                var t = ""; while i < p.count, !(p[i] == 32 || p[i] == 10 || p[i] == 13 || p[i] == 9) { t.append(Character(UnicodeScalar(p[i]))); i += 1 }
                toks.append(t)
            }
            i += 1
            guard toks.first == "P5", let w = Int(toks[1]), let h = Int(toks[2]), let mx = Int(toks[3]) else { throw RawImage.LoadError.notPNM }
            let bps = mx > 255 ? 2 : 1
            guard p.count - i >= w * h * bps else { throw RawImage.LoadError.truncated }
            var v = [Float](repeating: 0, count: w * h)
            let s = 1 / Float(mx)
            for k in 0..<(w * h) {
                let o = i + k * bps
                v[k] = (bps == 2 ? Float(UInt16(p[o]) << 8 | UInt16(p[o + 1])) : Float(p[o])) * s
            }
            return Plane(width: w, height: h, v: v)
        }
    }

    /// Defect mask (1 = dust). `fraction` is how much of the frame it covers.
    static func mask(_ ir: Plane, threshold: Float = 0.86) -> (mask: [UInt8], fraction: Double) {
        let w = ir.width, h = ir.height
        let r = max(6, w / 200)                       // local level over ~0.5 mm at 3600 dpi
        // integral image for a box mean
        var integ = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w { row += Double(ir.v[y * w + x]); integ[(y + 1) * (w + 1) + x + 1] = integ[y * (w + 1) + x + 1] + row }
        }
        // the film's own IR level; holder plastic reads ~0
        var sample: [Float] = []
        for i in stride(from: 0, to: w * h, by: 97) where ir.v[i] > 0.1 { sample.append(ir.v[i]) }
        sample.sort()
        let film = sample.isEmpty ? 1 : sample[sample.count / 2]
        var m = [UInt8](repeating: 0, count: w * h)
        var n = 0
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h, y + r + 1)
            for x in 0..<w {
                let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                let sum = integ[y1 * (w + 1) + x1] - integ[y0 * (w + 1) + x1] - integ[y1 * (w + 1) + x0] + integ[y0 * (w + 1) + x0]
                let mean = Float(sum / Double((y1 - y0) * (x1 - x0)))
                // Only where the local level is the film's own: within ~r of the holder's edge the
                // mean straddles opaque plastic and every pixel there would look like dust
                // (that band was 98% of the first mask on the Gold 200 frame, 2026-10-22).
                if mean > 0.85 * film, ir.v[y * w + x] < threshold * mean { m[y * w + x] = 1; n += 1 }
            }
        }
        // grow by ~2 px at 3600 dpi so the dust's soft edge goes too
        let g = max(1, w / 1700)        // 3 px at 3600 dpi
        var grown = m
        for y in 0..<h { for x in 0..<w where m[y * w + x] == 1 {
            for dy in -g...g { for dx in -g...g {
                let yy = y + dy, xx = x + dx
                if yy >= 0, yy < h, xx >= 0, xx < w { grown[yy * w + xx] = 1 }
            } }
        } }
        let total = grown.reduce(0) { $0 + Int($1) }
        _ = n
        return (grown, Double(total) / Double(w * h))
    }

    /// Fills masked pixels from their unmasked neighbours, one ring at a time.
    static func inpaint(_ raw: inout RawImage, _ maskIn: [UInt8]) {
        let w = raw.width, h = raw.height
        var m = maskIn
        var frontier: [Int] = []
        for i in 0..<(w * h) where m[i] == 1 { frontier.append(i) }
        raw.pixels.withUnsafeMutableBufferPointer { px in
            while !frontier.isEmpty {
                var filled: [(Int, Float, Float, Float)] = []
                var rest: [Int] = []
                for i in frontier {
                    let x = i % w, y = i / w
                    var r: Float = 0, g: Float = 0, b: Float = 0, c: Float = 0
                    for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                        let j = yy * w + xx
                        if m[j] == 0 { r += px[j * 3]; g += px[j * 3 + 1]; b += px[j * 3 + 2]; c += 1 }
                    } }
                    if c > 0 { filled.append((i, r / c, g / c, b / c)) } else { rest.append(i) }
                }
                if filled.isEmpty { break }
                for (i, r, g, b) in filled { px[i * 3] = r; px[i * 3 + 1] = g; px[i * 3 + 2] = b; m[i] = 0 }
                frontier = rest
            }
        }
    }

    static func clean(_ raw: RawImage, ir: Plane) -> (RawImage, Double) {
        guard ir.width == raw.width, ir.height == raw.height else { return (raw, 0) }
        let (m, f) = mask(ir)
        var out = raw
        inpaint(&out, m)
        return (out, f)
    }

    static func irURL(for raw: URL) -> URL {
        let stem = raw.deletingPathExtension().lastPathComponent
        let base = stem.hasSuffix("-raw") ? String(stem.dropLast(4)) : stem
        return raw.deletingLastPathComponent().appendingPathComponent(base + "-ir.pgm")
    }
}
