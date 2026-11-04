import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Lightbox

/// His real rolls, downsampled once into samples/roll/ (gitignored) from ~/Pictures/Lightbox.
/// Skips when neither is on the machine.
enum Roll {
    static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("samples")
    static let dir = samples.appendingPathComponent("roll")

    struct Frame { var name: String; var stock: String; var raw: RawImage }

    /// Every "<date> <stock>/frame-NN-raw.pnm" under ~/Pictures/Lightbox, at 1200 px on the long side.
    static func frames() throws -> [Frame] {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let pics = fm.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Lightbox")
        var out: [Frame] = []
        if let rolls = try? fm.contentsOfDirectory(atPath: pics.path) {
            for r in rolls.sorted() {
                let folder = pics.appendingPathComponent(r)
                for f in ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() where f.hasSuffix("-raw.pnm") {
                    let name = "\(r) \(f.replacingOccurrences(of: "-raw.pnm", with: ""))"
                    let cached = dir.appendingPathComponent(name + ".tif")
                    if !fm.fileExists(atPath: cached.path) {
                        try RawImage.loadPNM(folder.appendingPathComponent(f)).downsampled(maxSide: 1200).writeRawTIFF(cached)
                    }
                    let stock = String(r.dropFirst(11))
                    out.append(Frame(name: name, stock: stock, raw: try RawImage.load(cached)))
                }
            }
        }
        if out.isEmpty, let cached = try? fm.contentsOfDirectory(atPath: dir.path) {
            for f in cached.sorted() where f.hasSuffix(".tif") {
                let stock = String(f.dropFirst(11).split(separator: " frame").first ?? "")
                out.append(Frame(name: f, stock: stock, raw: try RawImage.load(dir.appendingPathComponent(f))))
            }
        }
        try XCTSkipIf(out.isEmpty, "no real roll on this machine")
        return out
    }

    static func writeJPEG(_ img: CGImage, _ url: URL) {
        let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
    }
}

final class BenchTests: XCTestCase {

    /// The spec's rule: a flag on more than about one frame in five of a normal roll means its
    /// threshold is wrong. Prints every frame's measurements so thresholds can be set from data.
    func testTriggersStayQuietOnANormalRoll() throws {
        let frames = try Roll.frames()
        var fired: [Ambiguity.Kind: [String]] = [:]
        for f in frames {
            let look = FilmStock.named(f.stock)?.look ?? .standard
            let a = Develop.analyse(f.raw, filmType: .colorNegative)
            let (s, amb) = try XCTUnwrap(Bench.analyse(f.raw, a, edit: Edit(), look: look, stock: f.stock, labConfidence: nil))
            print(String(format: "%@ | neg %.2f–%.2f key %.2f | cast Y%+.1f M%+.1f neutral %.2f | sh Y%+.1f M%+.1f hl Y%+.1f M%+.1f | faces %d skin %@ | -> %@",
                         f.name, s.negMin, s.negMax, s.key, s.cast.y, s.cast.m, s.neutralFraction,
                         s.shadows.y, s.shadows.m, s.highlights.y, s.highlights.m,
                         s.faceCount, s.skin.map { String(format: "Y%+.0f M%+.0f", $0.y, $0.m) } ?? "-",
                         amb.map(\.kind.rawValue).joined(separator: ",")))
            for k in amb { fired[k.kind, default: []].append(f.name) }
        }
        let n = frames.count
        for (k, names) in fired { print("fired \(k.rawValue): \(names.count)/\(n)", names) }
        for (k, names) in fired {
            // one in five, rounded up: on 10 frames, 2 may fire
            XCTAssertLessThanOrEqual(names.count, Int((Double(n) / 5).rounded(.up)), "\(k.rawValue) fires on \(names.count) of \(n) normal frames")
        }
    }

    /// Each trigger does fire when its ambiguity is put into a real frame.
    func testTriggersFireOnTheirOwnAmbiguity() throws {
        let f = try XCTUnwrap(try Roll.frames().first { $0.stock == "Kodak Gold 200" })
        let look = FilmStock.named(f.stock)!.look
        let a = Develop.analyse(f.raw, filmType: .colorNegative)
        let kinds = { (a: Analysis, e: Edit, stock: String) -> Set<Ambiguity.Kind> in
            Set(Bench.analyse(f.raw, a, edit: e, look: look, stock: stock, labConfidence: nil)!.1.map(\.kind))
        }
        // a thin negative: the same frame with its density squashed toward the base
        var thin = a; thin.hi[3] = 0.4
        XCTAssertTrue(kinds(thin, Edit(), f.stock).contains(.density))
        // a strong cast left in the print
        var cast = Edit(); cast.warmth = 0.9
        XCTAssertTrue(kinds(a, cast, f.stock).contains(.colour))
        // expired stock always offers balance by tone
        XCTAssertTrue(kinds(a, Edit(), "Kodak Portra 160VC").contains(.tone))
        // a weak lab match asks about colour
        let lowLab = Bench.analyse(f.raw, a, edit: Edit(), look: look, stock: f.stock, labConfidence: 0.2)!.1
        XCTAssertTrue(lowLab.contains { $0.kind == .colour })
    }

    /// Skin far off its reference reads as a skin question. Synthetic numbers through the rules.
    func testSkinRule() {
        var s = FrameStats(negMax: 1, negMin: 0.05, key: 0.4, cast: (0, 0), neutralFraction: 0.5,
                           shadows: (0, 0), highlights: (0, 0), mids: (0, 0))
        XCTAssertTrue(Bench.detect(s, edit: Edit(), stock: "Kodak Gold 200", labConfidence: nil).isEmpty, "a plain frame raises nothing")
        s.skin = (y: 8, m: 6); s.faceCount = 1
        let skin = Bench.detect(s, edit: Edit(), stock: "Kodak Gold 200", labConfidence: nil)
        XCTAssertEqual(skin.map(\.kind), [.skin])
        XCTAssertGreaterThan(skin[0].tiles[0].edit.warmth, 0, "skin too blue: balancing on skin warms the print")
        XCTAssertTrue(skin[0].tiles[0].label.contains("+20 Y"), skin[0].tiles[0].label)
        // Redscale and 800T keep their cast: no colour or skin questions
        XCTAssertTrue(Bench.detect(s, edit: Edit(), stock: "Redscale", labConfidence: 0.1).isEmpty)
    }
}

final class RollSheetTests: XCTestCase {
    /// samples/roll/sheet.jpg: every frame of the roll at its default, for eyeballing the triggers.
    func testWriteRollSheet() throws {
        let frames = try Roll.frames()
        let cell = 420, cols = 5, rows = (frames.count + cols - 1) / cols
        let W = cell * cols, H = cell * rows
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.46, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        for (i, f) in frames.enumerated() {
            let look = FilmStock.named(f.stock)?.look ?? .standard
            let a = Develop.analyse(f.raw, filmType: .colorNegative)
            let t = try XCTUnwrap(Develop.render(f.raw, a, Edit(), look: look))
            let s = min(Double(cell - 16) / Double(t.width), Double(cell - 16) / Double(t.height))
            let tw = Double(t.width) * s, th = Double(t.height) * s
            let cx = Double((i % cols) * cell), cy = Double(H - (i / cols + 1) * cell)
            ctx.draw(t, in: CGRect(x: cx + (Double(cell) - tw) / 2, y: cy + (Double(cell) - th) / 2, width: tw, height: th))
        }
        Roll.writeJPEG(ctx.makeImage()!, Roll.dir.appendingPathComponent("sheet.jpg"))
    }
}

final class PrinterUnitTests: XCTestCase {
    func testReadoutsSpeakPrinterUnits() {
        XCTAssertEqual(PrinterUnits.stopsText(1.0 / 3), "+⅓ stop")
        XCTAssertEqual(PrinterUnits.stopsText(-2.0 / 3), "−⅔ stop")
        XCTAssertEqual(PrinterUnits.stopsText(4.0 / 3), "+1⅓ stops")
        XCTAssertNil(PrinterUnits.stopsText(0.01))
        XCTAssertEqual(PrinterUnits.ccText(10.2, "Y"), "+10 Y")
        XCTAssertEqual(PrinterUnits.gradeText(0.5), "+½ grade")
        let e = PrinterUnits.moved(Edit(), stops: 1.0 / 3, y: 5, m: -5)
        XCTAssertEqual(PrinterUnits.summary(e), "+5 Y −5 M, +⅓ stop")
        XCTAssertNil(PrinterUnits.summary(Edit()))
        XCTAssertEqual(frameList([1, 2, 3, 5, 7, 8]), "1–3, 5, 7, 8")
    }

    /// The calibration seam: whatever the provider says is what the ring steps by.
    func testStepSizesComeFromTheSeam() {
        let saved = StockStepSizes.provider
        defer { StockStepSizes.provider = saved }
        XCTAssertEqual(StockStepSizes.steps(for: "Kodak Gold 200"), .darkroom)
        StockStepSizes.provider = { _ in RingSteps(densityStops: [0.5, 1], cc: [7, 14]) }
        let s = FrameStats(negMax: 0.3, negMin: 0, key: 0.4, cast: (0, 0), neutralFraction: 0.5,
                           shadows: (0, 0), highlights: (0, 0), mids: (0, 0))
        let d = Bench.detect(s, edit: Edit(), stock: "Kodak Gold 200", labConfidence: nil)
        XCTAssertEqual(d.first?.tiles.map(\.label), ["−1 stop", "−0.5 stop", "+0.5 stop", "+1 stop"])
    }

    func testCharacterChangesThePrintCurve() {
        let l = FilmStock.named("Kodak Gold 200")!.look
        XCTAssertEqual(PrintCharacter.normal.apply(l), l)
        XCTAssertLessThan(PrintCharacter.soft.apply(l).contrastBias, l.contrastBias)
        XCTAssertGreaterThan(PrintCharacter.hard.apply(l).contrastBias, l.contrastBias)
    }
}

/// The printer's notebook: a correction kept on one frame is where the next frame of the roll starts.
final class CarryForwardTests: XCTestCase {
    @MainActor
    func testAcceptedCorrectionCarriesToTheNextFrame() async throws {
        let src = Roll.samples.appendingPathComponent("full_3600_irclean.pnm")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path))
        Store.labSearchEnabled = false; Store.variationsEnabled = false; Store.benchEnabled = false
        defer { Store.benchEnabled = true }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lb-carry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = dir.appendingPathComponent("frame-01-raw.tif")
        try RawImage.loadPNM(src).downsampled(maxSide: 600).writeRawTIFF(raw)

        let st = Store()
        await st.open(raw)
        XCTAssertEqual(st.frameNumber, 1)
        let tile = RingTile(label: "+10 Y", edit: PrinterUnits.moved(st.edit, stops: 1.0 / 3, y: 10))
        st.accept(tile, from: .colour)
        XCTAssertEqual(PrinterUnits.summary(st.edit), "+10 Y, +⅓ stop")
        XCTAssertTrue(st.settled.contains(.colour), "an answered question drops its flag")
        st.setCharacter(.soft)

        st.nextFrame()
        XCTAssertEqual(st.frameNumber, 2)
        XCTAssertEqual(PrinterUnits.summary(st.edit), "+10 Y, +⅓ stop", "frame 2 starts from frame 1's correction")
        XCTAssertEqual(st.frameStart.summary, "+10 Y, +⅓ stop")
        XCTAssertEqual(st.notebook.frames(using: Correction(st.edit)), [1])
        XCTAssertEqual(st.notebook.character, .soft, "character is per roll")
        XCTAssertTrue(st.settled.isEmpty, "a new frame asks its own questions")
        // written next to the roll's raws
        XCTAssertEqual(RollNotebook.load(from: dir)?.carried.summary, "+10 Y, +⅓ stop")

        st.resetFrame()
        XCTAssertNil(PrinterUnits.summary(st.edit), "reset frame: no correction on this frame")
        XCTAssertEqual(st.notebook.carried.summary, "+10 Y, +⅓ stop", "...the roll still remembers")
        st.resetRoll()
        XCTAssertTrue(st.notebook.carried.isNeutral)
        XCTAssertTrue(st.notebook.frames.isEmpty)
        XCTAssertEqual(st.notebook.character, .soft)
    }
}
