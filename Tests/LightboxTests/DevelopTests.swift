import XCTest
import ImageIO
import UniformTypeIdentifiers
import UniformTypeIdentifiers
@testable import Lightbox

final class DevelopTests: XCTestCase {
    let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("samples")

    func testCropMappingRoundTrips() {
        let r = NRect(x: 0.1, y: 0.2, w: 0.5, h: 0.3)
        for rot in 0..<4 { for m in [false, true] {
            let back = Develop.toRaw(Develop.toDisplay(r, rotation: rot, mirrored: m), rotation: rot, mirrored: m)
            XCTAssertEqual(back.x, r.x, accuracy: 1e-9); XCTAssertEqual(back.y, r.y, accuracy: 1e-9)
            XCTAssertEqual(back.w, r.w, accuracy: 1e-9); XCTAssertEqual(back.h, r.h, accuracy: 1e-9)
        } }
    }

    /// The real frame off the scanner: auto result must be neither clipped nor colour-cast.
    func testRealColourNegativeInvertsNeutral() throws {
        let url = samples.appendingPathComponent("full_3600_irclean.pnm")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "no sample scan")
        let t0 = Date()
        let full = try RawImage.loadPNM(url)
        let w = full.downsampled(maxSide: 2000)
        let a = Develop.analyse(w, filmType: .colorNegative)
        print("load+analyse", Date().timeIntervalSince(t0), "base", a.base, "box", a.box)
        XCTAssertGreaterThan(a.base[0], a.base[2], "orange mask: red base should exceed blue")
        XCTAssertGreaterThan(a.box.w, 0.6); XCTAssertGreaterThan(a.box.h, 0.6)
        var e = Edit(); e.rotation = 1
        let t1 = Date()
        let img = try XCTUnwrap(Develop.render(w, a, e))
        print("preview render", Date().timeIntervalSince(t1), img.width, img.height)
        let t2 = Date()
        let big = try XCTUnwrap(Develop.render(full, a, e))
        print("full render", Date().timeIntervalSince(t2), big.width, big.height)
        let out = samples.appendingPathComponent("test_auto.jpg")
        let d = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, nil); XCTAssertTrue(CGImageDestinationFinalize(d))
        // channel means of the output should be close to each other (no strong cast)
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: 64 * 64 * 4)
        var m = [0.0, 0.0, 0.0]
        for i in 0..<(64 * 64) { for c in 0..<3 { m[c] += Double(p[i * 4 + c]) / 4096 } }
        print("output channel means", m)
        XCTAssertLessThan(m.max()! - m.min()!, 25)
    }
}

final class PreviewBoxTests: XCTestCase {
    func testPreviewAndFullAgreeOnTheBox() throws {
        let s = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("samples")
        let p = s.appendingPathComponent("preview_app.pnm"), f = s.appendingPathComponent("full_3600_irclean.pnm")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: p.path) && FileManager.default.fileExists(atPath: f.path))
        let pa = Develop.analyse(try RawImage.loadPNM(p), filmType: .colorNegative)
        let fa = Develop.analyse(try RawImage.loadPNM(f).downsampled(maxSide: 2000), filmType: .colorNegative)
        print("preview", pa); print("full", fa)
        XCTAssertEqual(pa.box.x, fa.box.x, accuracy: 0.03); XCTAssertEqual(pa.box.w, fa.box.w, accuracy: 0.04)
        XCTAssertEqual(pa.box.y, fa.box.y, accuracy: 0.03); XCTAssertEqual(pa.box.h, fa.box.h, accuracy: 0.04)
    }
}

/// Detection on the real colour negative, plus a B&W negative and a slide SYNTHESISED from it
/// (no real B&W or slide frame was in the holder on 2026-10-22).
final class FilmDetectTests: XCTestCase {
    func realRaw() throws -> RawImage {
        let s = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("samples")
        let p = s.appendingPathComponent("preview_app.pnm")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: p.path))
        return try RawImage.loadPNM(p)
    }

    func testRealColourNegative() throws {
        let g = FilmDetect.guess(try realRaw()); print("colour neg:", g)
        XCTAssertEqual(g.type, .colorNegative)
    }

    func testSyntheticBWNegative() throws {
        var r = try realRaw()
        let a = Develop.analyse(r, filmType: .colorNegative)
        for i in 0..<r.pixelCount {
            var d: Float = 0
            for c in 0..<3 { d += Develop.density(r.pixels[i * 3 + c] / a.base[c]) / 3 }
            let t = 0.8 * powf(10, -d)
            for c in 0..<3 { r.pixels[i * 3 + c] = t }
        }
        let g = FilmDetect.guess(r); print("synthetic B&W:", g)
        XCTAssertEqual(g.type, .bwNegative)
    }

    func testSyntheticSlide() throws {
        var r = try realRaw()
        let a = Develop.analyse(r, filmType: .colorNegative)
        let holder = (0..<r.pixelCount).map { (r.pixels[$0 * 3] + r.pixels[$0 * 3 + 1] + r.pixels[$0 * 3 + 2]) / 3 < 0.004 }
        let img = Develop.render(r, a, Edit(), crop: .full)!
        let ctx = CGContext(data: nil, width: r.width, height: r.height, bitsPerComponent: 8, bytesPerRow: r.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: r.pixelCount * 4)
        for i in 0..<r.pixelCount {
            // positive film: transmittance follows the picture; rebate and holder are black
            let rebate = (r.pixels[i * 3] / a.base[0]) > 0.85
            for c in 0..<3 {
                r.pixels[i * 3 + c] = (holder[i] || rebate) ? 0.001 : 0.9 * powf(Float(p[i * 4 + c]) / 255, 2.2) + 0.002
            }
        }
        let g = FilmDetect.guess(r); print("synthetic slide:", g)
        XCTAssertEqual(g.type, .slide)
    }
}

/// Each special stock's profile, applied to film SYNTHESISED from the real Gold 200 preview
/// (no redscale, CineStill or expired Portra frame was in the scanner on 2026-10-22).
final class StockProfileTests: XCTestCase {
    func realRaw() throws -> RawImage {
        let s = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("samples")
        let p = s.appendingPathComponent("preview_app.pnm")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: p.path))
        return try RawImage.loadPNM(p)
    }
    /// Re-expose the real frame into a new negative. `mono` uses the frame's mean density for every
    /// channel (times `gains`); otherwise each channel keeps its own density, so the picture keeps its
    /// colour. `cast` is density added in proportion to exposure (none at the bare base, full from
    /// density 0.2 up), as a coloured light does; `fog` is added everywhere, base included.
    func synth(_ r: RawImage, mono: Bool = false, gains: [Float] = [1, 1, 1], base: [Float],
               fog: Float = 0, cast: [Float] = [0, 0, 0]) -> RawImage {
        let a = Develop.analyse(r, filmType: .colorNegative)
        var o = r
        for i in 0..<r.pixelCount {
            let dc = (0..<3).map { Develop.density(r.pixels[i * 3 + $0] / a.base[$0]) }
            let dm = (dc[0] + dc[1] + dc[2]) / 3
            let ramp = min(1, max(0, dm / 0.2))
            let holder = r.pixels[i * 3] < 0.004
            for c in 0..<3 {
                let d = (mono ? dm : dc[c]) * gains[c] + fog + cast[c] * ramp
                o.pixels[i * 3 + c] = holder ? 0.0005 : base[c] * powf(10, -d)
            }
        }
        return o
    }
    func means(_ img: CGImage, where keep: ((Float, Float, Float) -> Bool)? = nil) -> [Double] {
        let w = img.width, h = img.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var m = [0.0, 0.0, 0.0]; var n = 0.0
        for i in 0..<(w * h) {
            let r = Float(p[i * 4]), g = Float(p[i * 4 + 1]), b = Float(p[i * 4 + 2])
            if let keep, !keep(r, g, b) { continue }
            m[0] += Double(r); m[1] += Double(g); m[2] += Double(b); n += 1
        }
        return m.map { $0 / max(n, 1) }
    }
    func render(_ r: RawImage, _ stock: String?) -> CGImage {
        let a = Develop.analyse(r, filmType: .colorNegative)
        let look = stock.flatMap { FilmStock.named($0)?.look } ?? .standard
        return Develop.render(r, a, Edit(), look: look)!
    }

    func testRedscaleKeepsItsRed() throws {
        // red-sensitive layer took most of the light: red density dominates; orange base
        let r = synth(try realRaw(), mono: true, gains: [1.0, 0.55, 0.25], base: [0.34, 0.15, 0.085])
        let std = means(render(r, nil)), red = means(render(r, "Redscale"))
        print("redscale R/B standard", std[0] / std[2], "profile", red[0] / red[2])
        XCTAssertLessThan(std[0] / std[2], 1.15, "the standard path neutralises it")
        XCTAssertGreaterThan(red[0] / red[2], 1.5, "the profile keeps the red/amber")
    }

    func testCineStillKeepsTungstenAndHalation() throws {
        // tungsten-lit scene: the picture leans amber (less blue density); add a red glow ring round the
        // brightest highlights, as remjet-free film does
        var r = synth(try realRaw(), base: [0.34, 0.15, 0.085], cast: [0.12, 0.04, -0.05])
        let a = Develop.analyse(r, filmType: .colorNegative)
        var ring = [Bool](repeating: false, count: r.pixelCount)
        let w = r.width, h = r.height
        var hot: [Int] = []
        for i in 0..<r.pixelCount where Develop.density(r.pixels[i * 3 + 1] / a.base[1]) > 0.9 * a.hi[1] { hot.append(i) }
        for i in hot.prefix(400) {
            let x = i % w, y = i / w
            for dy in -3...3 { for dx in -3...3 where abs(dx) + abs(dy) >= 3 {
                let xx = x + dx, yy = y + dy
                guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                let j = yy * w + xx
                ring[j] = true
                r.pixels[j * 3] *= 0.55          // more red density = red glow in the positive
            } }
        }
        let img = render(r, "CineStill 800T"), std = render(r, nil)
        let warmC = means(img), warmS = means(std)
        print("cinestill R/B profile", warmC[0] / warmC[2], "standard", warmS[0] / warmS[2])
        XCTAssertGreaterThan(warmC[0] / warmC[2], 1.12, "tungsten colour kept")
        XCTAssertGreaterThan(warmC[0] / warmC[2], warmS[0] / warmS[2] + 0.05, "and warmer than the auto-neutral path")
        // halation: the glow pixels are redder than their neighbourhood in the output
        let ringM = means(img) { r, g, _ in r > g * 1.15 }
        print("cinestill glow R/G", ringM[0] / max(ringM[1], 1))
        XCTAssertGreaterThan(ringM[0] / max(ringM[1], 1), 1.15)
    }

    func testPortra160VCCorrectsFogAndAddsPop() throws {
        // expired: +0.15 density of fog everywhere and a magenta drift
        let r = synth(try realRaw(), gains: [0.8, 0.8, 0.8], base: [0.34, 0.15, 0.085], fog: 0.15, cast: [0, 0.06, 0])
        let a = Develop.analyse(r, filmType: .colorNegative)
        let std = Develop.render(r, a, Edit())!, vc = render(r, "Kodak Portra 160VC")
        func darkest(_ img: CGImage) -> Double {
            let s = means(img) { r, g, b in (r + g + b) / 3 < 40 }
            return (s[0] + s[1] + s[2]) / 3
        }
        func satOf(_ img: CGImage) -> Double { let m = means(img); return m.max()! - m.min()! }
        let mStd = means(std), mVC = means(vc)
        print("160VC shadows std", darkest(std), "vc", darkest(vc), "cast std", satOf(std), "vc", satOf(vc), mStd, mVC)
        XCTAssertLessThan(darkest(vc), darkest(std), "blacks go deeper once the fog is clipped")
        XCTAssertLessThan(satOf(vc), satOf(std) + 2, "drift pulled back at least as far as standard")
        // saturation: per-pixel colourfulness higher than the standard path
        func chroma(_ img: CGImage) -> Double {
            let w = img.width, h = img.height
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
            var s = 0.0
            for i in 0..<(w * h) { let v = [p[i*4], p[i*4+1], p[i*4+2]].map(Double.init); s += v.max()! - v.min()! }
            return s / Double(w * h)
        }
        print("160VC chroma std", chroma(std), "vc", chroma(vc))
        XCTAssertGreaterThan(chroma(vc), chroma(std) * 1.05)
    }

    func testGoldKeepsSomeWarmth() throws {
        let r = try realRaw()
        let std = means(render(r, nil)), gold = means(render(r, "Kodak Gold 200"))
        print("gold R/B std", std[0] / std[2], "gold", gold[0] / gold[2])
        XCTAssertGreaterThan(gold[0] / gold[2], std[0] / std[2])
    }

    func testStockListIsHisInOrder() {
        XCTAssertEqual(FilmStock.all.first?.name, "Kodak Gold 200")
        XCTAssertEqual(FilmStock.all.count, 12)
        XCTAssertEqual(FilmStock.all.last?.name, "Other colour negative")
        XCTAssertEqual(FilmStock.named("Kodak Ultramax 400")?.note, "Gold’s faster, slightly rowdier cousin. More grain, punchier color")
    }
}

/// Baseline: his lab-developed, lab-scanned print of the same Gold 200 frame (Photos, Film + Big Sky 2025,
/// IMG_7810, 1228x1818). Files live in samples/ and are not in git.
final class LabBaselineTests: XCTestCase {
    var samples: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("samples") }

    func load(_ name: String) throws -> CGImage {
        let u = samples.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: u.path), "no \(name)")
        let src = CGImageSourceCreateWithURL(u as CFURL, nil)!
        return CGImageSourceCreateImageAtIndex(src, 0, nil)!
    }

    func save(_ img: CGImage, _ name: String) {
        let d = CGImageDestinationCreateWithURL(samples.appendingPathComponent(name) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary); CGImageDestinationFinalize(d)
    }

    func testGoldAgainstLab() throws {
        let lab = try load("lab_IMG_7810.jpg")
        let f = samples.appendingPathComponent("full_3600_irclean.pnm")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: f.path))
        let full = try RawImage.loadPNM(f)
        let w = full.downsampled(maxSide: 2000)
        let a = Develop.analyse(w, filmType: .colorNegative)
        var e = Edit(); e.rotation = 1
        let gold = FilmStock.named("Kodak Gold 200")!.look
        let ours = Develop.render(w, a, e, look: gold)!
        let ourFull = Develop.render(full, a, e, look: gold)!
        save(ourFull, "ours_gold_full.jpg")
        print("LAB  ", LabCompare.stats(lab))
        print("OURS ", LabCompare.stats(ours))
        let d0 = LabCompare.distance(LabCompare.quantiles(ours), LabCompare.quantiles(lab))
        print("quantile distance ours->lab", d0)
        let side = 1818
        print("sharpness at \(side)px: lab", LabCompare.sharpness(lab, side: side), "ours", LabCompare.sharpness(ourFull, side: side))
        print("sharpness at 900px: lab", LabCompare.sharpness(lab, side: 900), "ours", LabCompare.sharpness(ourFull, side: 900))
        print("ours native \(ourFull.width)x\(ourFull.height) lab native \(lab.width)x\(lab.height)")
        let (fit, before, after) = LabCompare.fit(w, a, e, look: gold, lab: lab)
        print(String(format: "fit: exposure %.3f warmth %.3f tint %.3f  cost %.2f -> %.2f", fit.exposure, fit.warmth, fit.tint, before, after))
        let fitted = Develop.render(full, a, fit, look: gold)!
        save(fitted, "ours_gold_fitted.jpg")
        print("FIT  ", LabCompare.stats(Develop.render(w, a, fit, look: gold)!))
        XCTAssertLessThanOrEqual(after, before)
        XCTAssertLessThan(d0, 7, "Gold 200 out of the box lands within 7/255 of his lab scan's tone and colour")
    }
}
