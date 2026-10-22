import XCTest
import ImageIO
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
