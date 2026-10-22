import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Lightbox

/// Dust removal from the real Color+IR capture of the Gold 200 frame (samples/, not in git).
final class DustTests: XCTestCase {
    var samples: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("samples") }

    func testCleansOnlyTheDust() throws {
        let rgbU = samples.appendingPathComponent("gold200-cir.ppm"), irU = samples.appendingPathComponent("gold200-cir-ir.pgm")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: irU.path))
        let raw = try RawImage.loadPNM(rgbU)
        let ir = try Dust.loadPGM(irU)
        XCTAssertEqual(ir.width, raw.width); XCTAssertEqual(ir.height, raw.height)
        let t0 = Date()
        let (clean, frac) = Dust.clean(raw, ir: ir)
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "dust: %.3f%% of the frame, cleaned in %.2fs", frac * 100, dt))
        XCTAssertGreaterThan(frac, 0.0001, "the frame has visible dust; some must be found")
        XCTAssertLessThan(frac, 0.005, "but nowhere near the whole picture (the holder edge must not count)")
        // pixels outside the mask are untouched
        let (m, _) = Dust.mask(ir)
        var changedOutside = 0, changedInside = 0
        for i in stride(from: 0, to: raw.pixelCount, by: 7) {
            let d = abs(clean.pixels[i * 3 + 1] - raw.pixels[i * 3 + 1])
            if m[i] == 0 && d > 0 { changedOutside += 1 }
            if m[i] == 1 && d > 0.001 { changedInside += 1 }
        }
        XCTAssertEqual(changedOutside, 0)
        XCTAssertGreaterThan(changedInside, 0)
        // a side-by-side crop around the largest defect for the eye
        var best = 0, bestCount = 0
        let w = raw.width
        for y in stride(from: 200, to: raw.height - 200, by: 100) { for x in stride(from: 200, to: w - 200, by: 100) {
            var c = 0; for dy in 0..<100 { for dx in 0..<100 { c += Int(m[(y + dy) * w + x + dx]) } }
            if c > bestCount { bestCount = c; best = y * w + x }
        } }
        let a = Develop.analyse(raw.downsampled(maxSide: 1000), filmType: .colorNegative)
        let cx = Double(best % w) / Double(w), cy = Double(best / w) / Double(raw.height)
        let box = NRect(x: max(0, cx - 0.03), y: max(0, cy - 0.04), w: 0.08, h: 0.1)
        var e = Edit(); e.sharpen = -1
        let before = Develop.render(raw, a, e, crop: box)!, after = Develop.render(clean, a, e, crop: box)!
        let ctx = CGContext(data: nil, width: before.width * 2 + 10, height: before.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.draw(before, in: CGRect(x: 0, y: 0, width: before.width, height: before.height))
        ctx.draw(after, in: CGRect(x: before.width + 10, y: 0, width: after.width, height: after.height))
        let d = CGImageDestinationCreateWithURL(samples.appendingPathComponent("dust_before_after.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
    }

    func testOldSidecarWithoutDustStillOpens() throws {
        let old = #"{"edit":{"sharpen":0,"mirrored":false,"rotation":1,"warmth":0,"tint":0,"contrast":0,"filmType":"colorNegative","exposure":0},"stock":"Kodak Gold 200","dpi":3600,"dust":true,"scannedAt":814404706}"#
        let s = try JSONDecoder().decode(Store.Sidecar.self, from: Data(old.utf8))
        XCTAssertEqual(s.edit.rotation, 1); XCTAssertTrue(s.edit.dust)
    }
}

/// The Sharpness slider must change the picture visibly at 100% (the loupe scale).
final class SharpnessTests: XCTestCase {
    func testSliderMovesSharpnessAtLoupeScale() throws {
        let s = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("samples")
        let u = s.appendingPathComponent("full_3600_irclean.pnm")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: u.path))
        let full = try RawImage.loadPNM(u)
        let a = Develop.analyse(full.downsampled(maxSide: 1000), filmType: .colorNegative)
        let crop = NRect(x: 0.35, y: 0.3, w: 420 / 5184, h: 420 / 3877)
        var v: [Double] = []
        for sv in [-1.0, 0.0, 1.0] {
            var e = Edit(); e.sharpen = sv
            v.append(LabCompare.sharpness(Develop.render(full, a, e, crop: crop)!, side: 420))
        }
        print("loupe sharpness min/default/max", v)
        XCTAssertLessThan(v[0], v[1] * 0.8)
        XCTAssertGreaterThan(v[2], v[1] * 2)
    }
}
