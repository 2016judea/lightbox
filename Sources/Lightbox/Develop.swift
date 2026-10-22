import Foundation
import CoreGraphics
import Accelerate
import CoreImage

enum FilmType: String, Codable, CaseIterable, Identifiable {
    case colorNegative, bwNegative, slide
    var id: String { rawValue }
    var label: String {
        switch self {
        case .colorNegative: return "Colour negative"
        case .bwNegative: return "B&W negative"
        case .slide: return "Slide"
        }
    }
    var short: String {
        switch self {
        case .colorNegative: return "Colour"
        case .bwNegative: return "B&W"
        case .slide: return "Slide"
        }
    }
}

/// Normalised rectangle, 0...1, in raw-scan coordinates (origin top-left).
struct NRect: Codable, Equatable {
    var x: Double, y: Double, w: Double, h: Double
    static let full = NRect(x: 0, y: 0, w: 1, h: 1)
}

/// The user's adjustments. All sliders are -1...1 with 0 meaning "the auto result".
struct Edit: Codable, Equatable {
    init(filmType: FilmType = .colorNegative) { self.filmType = filmType }
    var filmType: FilmType = .colorNegative
    var exposure: Double = 0
    var warmth: Double = 0
    var tint: Double = 0
    var contrast: Double = 0
    var rotation: Int = 0          // quarter turns clockwise
    var mirrored = false
    var crop: NRect? = nil         // nil = the auto-detected picture area
    var sharpen: Double = 0        // -1 (none) ... 1 (crunchy); 0 = lab-like default
    var dust = true                // remove dust from the infrared plane, when the frame has one

    enum CodingKeys: String, CodingKey { case filmType, exposure, warmth, tint, contrast, rotation, mirrored, crop, sharpen, dust }
    /// Every field optional on the way in, so sidecars written by older versions still open.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        filmType = try c.decodeIfPresent(FilmType.self, forKey: .filmType) ?? .colorNegative
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        mirrored = try c.decodeIfPresent(Bool.self, forKey: .mirrored) ?? false
        crop = try c.decodeIfPresent(NRect.self, forKey: .crop)
        sharpen = try c.decodeIfPresent(Double.self, forKey: .sharpen) ?? 0
        dust = try c.decodeIfPresent(Bool.self, forKey: .dust) ?? true
    }
}

/// What the scan itself says: film base, where the picture is, and each channel's density range.
struct Analysis: Equatable {
    var base: [Float]      // film-base transmittance per channel
    var box: NRect         // detected picture area
    var lo: [Float]        // density at the 0.1th percentile, per channel (index 3 = luminance)
    var hi: [Float]        // density at the 99.9th percentile
    var med: [Float]       // median of each channel after normalisation (for neutral balance)
}

enum Develop {

    static func percentile(_ v: inout [Float], _ q: Double) -> Float {
        guard !v.isEmpty else { return 0 }
        let k = min(v.count - 1, max(0, Int(Double(v.count - 1) * q)))
        // nth_element via partial sort is overkill; the sample is <= 250k so a full sort is fine
        return v[k]
    }

    static func density(_ t: Float) -> Float { -log10f(max(t, 1e-4)) }

    /// Reads the film base, the picture area and each channel's density range off the scan.
    /// This is what lets any stock invert well with no profile: the frame carries its own calibration.
    static func analyse(_ raw: RawImage, filmType: FilmType) -> Analysis {
        let w = raw.width, h = raw.height, n = raw.pixelCount
        let step = max(1, Int(sqrt(Double(n) / 250_000)))
        let px = raw.pixels

        // 1. Holder is opaque (reads near zero). Film is everything well above it.
        var lums: [Float] = []
        lums.reserveCapacity(n / (step * step) + 1)
        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) {
                let o = (y * w + x) * 3
                lums.append((px[o] + px[o + 1] + px[o + 2]) / 3)
            }
        }
        lums.sort()
        let p99 = percentile(&lums, 0.99)
        // Measured on the 8200i (2026-10-22): the holder reads < 0.002, the film base ~0.19 and the
        // densest negative (a bright sky) ~0.024. So the cut sits at 2% of the brightest film; at 25%
        // it cropped the sky off. Slides go denser in the shadows, so their cut is lower.
        let filmThresh = (filmType == .slide ? 0.012 : 0.02) * p99

        // 2. Film base = the brightest film (the unexposed rebate) for a negative; clear white for a slide.
        var chans: [[Float]] = [[], [], []]
        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) {
                let o = (y * w + x) * 3
                let l = (px[o] + px[o + 1] + px[o + 2]) / 3
                if l > filmThresh { for c in 0..<3 { chans[c].append(px[o + c]) } }
            }
        }
        var base: [Float] = [1, 1, 1]
        for c in 0..<3 {
            chans[c].sort()
            base[c] = max(1e-3, percentile(&chans[c], filmType == .slide ? 0.999 : 0.995))
        }
        let baseMean = (base[0] + base[1] + base[2]) / 3

        // 3. Picture area: rows and columns that are mostly film but not bare base.
        //    For a slide the mount is the holder, so "film" is the picture.
        let rebateCut: Float = filmType == .slide ? .greatestFiniteMagnitude : 0.9 * baseMean
        var rowHits = [Int](repeating: 0, count: h), colHits = [Int](repeating: 0, count: w)
        var rowN = [Int](repeating: 0, count: h), colN = [Int](repeating: 0, count: w)
        let s2 = max(1, step / 2)
        for y in stride(from: 0, to: h, by: s2) {
            for x in stride(from: 0, to: w, by: s2) {
                let o = (y * w + x) * 3
                let l = (px[o] + px[o + 1] + px[o + 2]) / 3
                let isImg = l > filmThresh && l < rebateCut
                rowN[y] += 1; colN[x] += 1
                if isImg { rowHits[y] += 1; colHits[x] += 1 }
            }
        }
        func span(_ hits: [Int], _ cnt: [Int]) -> (Int, Int)? {
            var first = -1, last = -1
            for i in 0..<hits.count where cnt[i] > 0 && Double(hits[i]) / Double(cnt[i]) > 0.5 {
                if first < 0 { first = i }; last = i
            }
            return first < 0 ? nil : (first, last)
        }
        var box = NRect.full
        if let (r0, r1) = span(rowHits, rowN), let (c0, c1) = span(colHits, colN),
           (r1 - r0) > h / 3, (c1 - c0) > w / 3 {
            // pull in 1% so the frame edge never shows
            let ix = Double(c1 - c0) * 0.01, iy = Double(r1 - r0) * 0.01
            box = NRect(x: (Double(c0) + ix) / Double(w), y: (Double(r0) + iy) / Double(h),
                        w: (Double(c1 - c0) - 2 * ix) / Double(w), h: (Double(r1 - r0) - 2 * iy) / Double(h))
        }

        // 4. Density range of each channel inside the picture. Normalising each channel to its own
        //    range is what removes the orange mask and the stock's colour crossover.
        let bx0 = Int(box.x * Double(w)), by0 = Int(box.y * Double(h))
        let bx1 = Int((box.x + box.w) * Double(w)), by1 = Int((box.y + box.h) * Double(h))
        var ds: [[Float]] = [[], [], [], []]
        let s3 = max(1, Int(sqrt(Double((bx1 - bx0) * (by1 - by0)) / 250_000)))
        for y in stride(from: by0, to: by1, by: s3) {
            for x in stride(from: bx0, to: bx1, by: s3) {
                let o = (y * w + x) * 3
                var sum: Float = 0
                for c in 0..<3 {
                    let d = density(px[o + c] / base[c]); ds[c].append(d); sum += d
                }
                ds[3].append(sum / 3)
            }
        }
        var lo: [Float] = [0, 0, 0, 0], hi: [Float] = [1, 1, 1, 1]
        for c in 0..<4 {
            ds[c].sort()
            lo[c] = percentile(&ds[c], 0.001)
            hi[c] = max(lo[c] + 0.05, percentile(&ds[c], 0.999))
        }
        // 5. Median of each normalised channel, for a gentle neutral balance.
        var med: [Float] = [0.5, 0.5, 0.5]
        for c in 0..<3 {
            var m = percentile(&ds[c], 0.5)
            m = (m - lo[c]) / (hi[c] - lo[c])
            med[c] = filmType == .slide ? 1 - m : m
        }
        return Analysis(base: base, box: box, lo: lo, hi: hi, med: med)
    }

    /// Print curve: a sigmoid with a soft toe and shoulder, like paper. `k` is its steepness.
    static func curveLUT(k: Float, black: Float = 0, size: Int = 4096) -> [Float] {
        let f: (Float) -> Float = { 1 / (1 + expf(-k * ($0 - 0.5))) }
        let f0 = f(0), f1 = f(1)
        return (0..<size).map { i in
            let x = -0.25 + 1.5 * Float(i) / Float(size - 1)
            let y = (f(x) - f0) / (f1 - f0)
            return black + (1 - black) * powf(max(0, min(1, y)), 1 / 1.1)
        }
    }

    /// Turns the raw scan into a positive, cropped and oriented, as 8-bit or 16-bit RGB.
    static func render(_ raw: RawImage, _ a: Analysis, _ e: Edit, crop overrideCrop: NRect? = nil,
                       sixteenBit: Bool = false, look: FilmStock.Look = .standard) -> CGImage? {
        let crop = overrideCrop ?? e.crop ?? a.box
        let W = raw.width, H = raw.height
        let x0 = max(0, min(W - 1, Int(crop.x * Double(W)))), y0 = max(0, min(H - 1, Int(crop.y * Double(H))))
        let cw = max(1, min(W - x0, Int(crop.w * Double(W)))), ch = max(1, min(H - y0, Int(crop.h * Double(H))))

        let k = Float(5.0 * (1 + 0.5 * e.contrast))
        let lut = curveLUT(k: k, black: look.outputBlack)
        let lutScale = Float(lut.count - 1) / 1.5
        let expo = Float(e.exposure) * 0.3 + look.exposureBias
        let warm = Float(e.warmth) * 0.08 + look.warmBias
        let tint = Float(e.tint) * 0.06 + look.tintBias
        let neutralW: Float = e.filmType == .colorNegative ? look.neutral : (e.filmType == .slide ? 0.3 : 0)
        // one shared density range keeps the film's own colour (redscale); per-channel removes the mask
        let shared = !look.perChannelLevels && e.filmType != .bwNegative
        let lo: [Float] = look.anchorToBase ? [0, 0, 0, 0] : (shared ? [a.lo[3], a.lo[3], a.lo[3], a.lo[3]] : a.lo)
        let hi: [Float] = shared ? [a.hi[3], a.hi[3], a.hi[3], a.hi[3]] : a.hi
        // medians re-expressed in whatever range is in use
        let med: [Float] = a.med.indices.map { c in
            let dmed = a.lo[c] + a.med[c] * (a.hi[c] - a.lo[c])     // back to density
            return (dmed - lo[c]) / (hi[c] - lo[c])
        }
        let mm = (med[0] + med[1] + med[2]) / 3
        let offs: [Float] = [neutralW * (mm - med[0]) + expo + warm,
                             neutralW * (mm - med[1]) + expo - tint,
                             neutralW * (mm - med[2]) + expo - warm]
        let bp = look.blackPoint, bpScale = 1 / (1 - look.blackPoint), sat = look.saturation
        let invBase: [Float] = [1 / a.base[0], 1 / a.base[1], 1 / a.base[2]]
        let scale: [Float] = (0..<4).map { 1 / (hi[$0] - lo[$0]) }

        // output buffer in crop orientation first
        var out8 = sixteenBit ? [] : [UInt8](repeating: 0, count: cw * ch * 3)
        var out16 = sixteenBit ? [UInt16](repeating: 0, count: cw * ch * 3) : []
        let ft = e.filmType
        raw.pixels.withUnsafeBufferPointer { src in
            lut.withUnsafeBufferPointer { L in
                var row = [Float](repeating: 0, count: cw * 3)
                var lg = [Float](repeating: 0, count: cw * 3)
                for yy in 0..<ch {
                    let so = ((y0 + yy) * W + x0) * 3
                    for i in 0..<(cw * 3) { row[i] = max(src[so + i] * invBase[i % 3], 1e-4) }
                    var cnt = Int32(cw * 3)
                    vvlog10f(&lg, row, &cnt)                       // lg = log10(t) = -D
                    for xx in 0..<cw {
                        let o = xx * 3
                        var v: (Float, Float, Float)
                        switch ft {
                        case .colorNegative:
                            v = ((-lg[o] - lo[0]) * scale[0], (-lg[o + 1] - lo[1]) * scale[1], (-lg[o + 2] - lo[2]) * scale[2])
                        case .bwNegative:
                            let d = -(lg[o] + lg[o + 1] + lg[o + 2]) / 3
                            let n = (d - lo[3]) * scale[3]
                            v = (n, n, n)
                        case .slide:
                            v = (1 - (-lg[o] - lo[0]) * scale[0], 1 - (-lg[o + 1] - lo[1]) * scale[1], 1 - (-lg[o + 2] - lo[2]) * scale[2])
                        }
                        var vs = [v.0 + offs[0], v.1 + offs[1], v.2 + offs[2]]
                        if bp > 0 { for c in 0..<3 { vs[c] = (vs[c] - bp) * bpScale } }
                        if sat != 1 {
                            let m = (vs[0] + vs[1] + vs[2]) / 3
                            for c in 0..<3 { vs[c] = m + sat * (vs[c] - m) }
                        }
                        let d = (yy * cw + xx) * 3
                        for c in 0..<3 {
                            let idx = Int(max(0, min(Float(L.count - 1), (vs[c] + 0.25) * lutScale)))
                            let y = L[idx]
                            if sixteenBit { out16[d + c] = UInt16(y * 65535) } else { out8[d + c] = UInt8(y * 255 + 0.5) }
                        }
                    }
                }
            }
        }
        let bpc = sixteenBit ? 16 : 8
        let data: Data = sixteenBit ? out16.withUnsafeBytes { Data($0) } : out8.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = sixteenBit ? CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue) : CGBitmapInfo()
        guard let img = CGImage(width: cw, height: ch, bitsPerComponent: bpc, bitsPerPixel: bpc * 3,
                                bytesPerRow: cw * 3 * bpc / 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: info, provider: provider, decode: nil,
                                shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let oriented = orient(img, rotation: e.rotation, mirrored: e.mirrored)
        // Output sharpening, as every lab scanner applies. Radius is set for a 3600 dpi frame and
        // scaled to the size being rendered, so the preview and the export look alike.
        let (amount, radius1) = sharpening(e.sharpen)
        guard amount > 0.01, let o = oriented else { return oriented }
        let radius = max(0.3, radius1 * Double(cw) / Double(max(1, Int(crop.w * 5184))))
        return sharpen(o, radius: radius, amount: amount)
    }

    /// Slider -1...1 to unsharp-mask amount and radius at 3600 dpi. Left = none, 0 = lab-like,
    /// right = clearly crunchy at 100%.
    static func sharpening(_ s: Double) -> (amount: Double, radius: Double) {
        s <= 0 ? (0.6 * (1 + s), 1.4) : (0.6 + 1.9 * s, 1.4 + 0.8 * s)
    }

    static let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    static func sharpen(_ img: CGImage, radius: Double, amount: Double) -> CGImage? {
        let ci = CIImage(cgImage: img)
        guard let f = CIFilter(name: "CIUnsharpMask") else { return img }
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(radius, forKey: kCIInputRadiusKey)
        f.setValue(amount, forKey: kCIInputIntensityKey)
        guard let out = f.outputImage else { return img }
        let fmt: CIFormat = img.bitsPerComponent == 16 ? .RGBA16 : .RGBA8
        return ciContext.createCGImage(out, from: ci.extent, format: fmt, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? img
    }

    /// Rotates by quarter turns clockwise and optionally mirrors.
    static func orient(_ img: CGImage, rotation: Int, mirrored: Bool) -> CGImage? {
        let r = ((rotation % 4) + 4) % 4
        if r == 0 && !mirrored { return img }
        let w = img.width, h = img.height
        let (ow, oh) = r % 2 == 0 ? (w, h) : (h, w)
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: img.bitsPerComponent,
                                  bytesPerRow: 0, space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                                    | (img.bitsPerComponent == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0))
        else { return nil }
        ctx.translateBy(x: CGFloat(ow) / 2, y: CGFloat(oh) / 2)
        ctx.rotate(by: -CGFloat(r) * .pi / 2)       // CG is y-up, so negative = clockwise on screen
        if mirrored { ctx.scaleBy(x: -1, y: 1) }
        ctx.draw(img, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    // MARK: crop <-> display mapping (for the crop overlay, which works on the oriented, uncropped picture)

    /// Maps a rect in oriented display space (0...1) back to raw-scan space.
    static func toRaw(_ r: NRect, rotation: Int, mirrored: Bool) -> NRect {
        var q = r
        let rot = ((rotation % 4) + 4) % 4
        // undo rotation (clockwise quarter turns) first, then mirror
        for _ in 0..<rot { q = NRect(x: q.y, y: 1 - q.x - q.w, w: q.h, h: q.w) }
        if mirrored { q.x = 1 - q.x - q.w }
        return q
    }

    static func toDisplay(_ r: NRect, rotation: Int, mirrored: Bool) -> NRect {
        var q = r
        if mirrored { q.x = 1 - q.x - q.w }
        let rot = ((rotation % 4) + 4) % 4
        for _ in 0..<rot { q = NRect(x: 1 - q.y - q.h, y: q.x, w: q.h, h: q.w) }
        return q
    }
}
