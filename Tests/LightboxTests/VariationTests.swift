import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Lightbox

final class VariationTests: XCTestCase {

    func testProposalIsClampedAndCropMapsIntoTheShownPicture() {
        let p = VariationAI.Proposal(name: "x", why: "y", exposure: 3, contrast: -4, warmth: 0.2, tint: .nan,
                                     sharpen: 0.5, crop: .init(x: 0.9, y: -0.2, w: 0.3, h: 0.7))
        let shown = NRect(x: 0.1, y: 0.1, w: 0.8, h: 0.8)
        let e = VariationAI.edit(from: p, base: Edit(), shownCrop: shown)
        XCTAssertEqual(e.exposure, 1); XCTAssertEqual(e.contrast, -1); XCTAssertEqual(e.tint, 0)
        XCTAssertEqual(e.warmth, 0.2, accuracy: 1e-9)
        // width raised to the 60% floor, then pushed back inside the picture
        let c = try! XCTUnwrap(e.crop)
        XCTAssertEqual(c.w, 0.6 * 0.8, accuracy: 1e-9)
        XCTAssertEqual(c.x + c.w, shown.x + shown.w, accuracy: 1e-9)
        XCTAssertEqual(c.y, shown.y, accuracy: 1e-9)
    }

    func testNoCropLeavesTheFrameAlone() {
        let p = VariationAI.Proposal(name: "x", why: "y", exposure: 0, contrast: 0, warmth: 0, tint: 0, sharpen: 0, crop: nil)
        XCTAssertNil(VariationAI.edit(from: p, base: Edit(), shownCrop: .full).crop)
    }

    /// Live: sends his real Gold 200 frame to Claude and writes the six tiles as one sheet.
    /// Runs only with LIGHTBOX_LIVE=1 (it costs an API call).
    func testLiveFiveAlternativesOnTheRealFrame() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIGHTBOX_LIVE"] == "1")
        let fx = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lightbox/fixtures/gold200-frame.pnm")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fx.path))
        let w = try RawImage.loadPNM(fx).downsampled(maxSide: 2000)
        let a = Develop.analyse(w, filmType: .colorNegative)
        let look = FilmStock.named("Kodak Gold 200")!.look
        let base = Edit()
        let pic = try XCTUnwrap(Develop.render(w, a, base, look: look))
        let t0 = Date()
        let props = try await VariationAI.propose(picture: pic, current: base, stock: "Kodak Gold 200",
                                                  note: FilmStock.named("Kodak Gold 200")?.note)
        print("claude took", Date().timeIntervalSince(t0), "s")
        XCTAssertEqual(props.count, 5)
        let shown = Develop.toDisplay(a.box, rotation: 0, mirrored: false)
        let small = w.downsampled(maxSide: 600)
        var tiles: [CGImage] = []
        var alts: [CGImage] = []
        for p in props {
            print(p.name, "|", p.why, "| exp", p.exposure, "con", p.contrast, "warm", p.warmth, "tint", p.tint,
                  "sharp", p.sharpen, "crop", p.crop.map { "\($0.x),\($0.y),\($0.w),\($0.h)" } ?? "none")
            alts.append(try XCTUnwrap(Develop.render(small, a, VariationAI.edit(from: p, base: base, shownCrop: shown), look: look)))
        }
        let def = try XCTUnwrap(Develop.render(small, a, base, look: look))
        tiles = [alts[0], alts[1], def, alts[2], alts[3], alts[4]]
        // 3 x 2 sheet, each tile fitted into a 600 x 600 cell
        let cell = 600, W = cell * 3, H = cell * 2
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        for (i, t) in tiles.enumerated() {
            let s = min(Double(cell - 20) / Double(t.width), Double(cell - 20) / Double(t.height))
            let tw = Double(t.width) * s, th = Double(t.height) * s
            let cx = Double((i % 3) * cell), cy = Double(H - (i / 3 + 1) * cell)
            ctx.draw(t, in: CGRect(x: cx + (Double(cell) - tw) / 2, y: cy + (Double(cell) - th) / 2, width: tw, height: th))
        }
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("samples/variations_live.jpg")
        let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        print("sheet", out.path)
    }

    /// Picking a tile on Preview takes its settings, closes the grid and names the pick for Scan.
    @MainActor
    func testChoosingATileCarriesItsSettings() {
        Store.variationsEnabled = false
        let st = Store()
        st.phase = .previewed
        var e = Edit(); e.warmth = 0.35; e.exposure = 0.05
        let v = Variation(name: "Golden evening", why: "Warmer.", edit: e)
        st.variations = [Variation(name: "As scanned", why: "No changes.", edit: Edit(), isDefault: true), v]
        st.showingVariations = true
        st.chooseVariation(v)
        XCTAssertEqual(st.edit.warmth, 0.35, accuracy: 1e-9)
        XCTAssertFalse(st.showingVariations)
        XCTAssertEqual(st.chosenName, "Golden evening")
        st.undo()
        XCTAssertEqual(st.edit.warmth, 0, accuracy: 1e-9)
    }
}
