import XCTest
@testable import Lightbox

/// Each setting's reset puts that one setting back to its default and leaves the rest alone.
final class ResetTests: XCTestCase {
    func testEachResetRestoresItsDefault() {
        var base = Edit(filmType: .colorNegative)
        base.exposure = 0.3; base.warmth = 0.1; base.tint = -0.05     // e.g. lab-matched starting point
        var e = Edit(filmType: .bwNegative)
        e.exposure = -0.7; e.contrast = 0.4; e.sharpen = 0.9; e.warmth = -0.6; e.tint = 0.5
        e.rotation = 3; e.mirrored = true; e.crop = NRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5); e.dust = false
        for s in Setting.allCases where s != .stock && s != .dpi {
            XCTAssertTrue(Setting.differs(s, e, base), "\(s) should start changed")
            let r = Setting.reset(s, e, to: base)
            XCTAssertFalse(Setting.differs(s, r, base), "\(s) should be back at its default")
            // and only that one moved
            for other in Setting.allCases where other != s && other != .stock && other != .dpi {
                XCTAssertEqual(Setting.differs(other, r, base), Setting.differs(other, e, base), "\(s) reset touched \(other)")
            }
        }
        XCTAssertEqual(Setting.reset(.exposure, e, to: base).exposure, 0.3, "resets to the lab-matched value, not zero")
    }

    @MainActor
    func testStoreResetsAndUndo() {
        Store.labSearchEnabled = false
        let st = Store()
        st.edit.exposure = 0.8
        st.recordUndo(); st.reset(.exposure)
        XCTAssertEqual(st.edit.exposure, 0)
        st.undo()
        XCTAssertEqual(st.edit.exposure, 0.8, "⌘Z brings the value back")
        st.dpi = 7200; st.reset(.dpi); XCTAssertEqual(st.dpi, 3600)
        st.stock = "Kodak Portra 400"; st.reset(.stock); XCTAssertEqual(st.stock, FilmStock.defaultName)
    }
}

final class BackToLoadTests: XCTestCase {
    /// Going back from Keep keeps the roll (stock, type, orientation) and moves to the next frame;
    /// from Load itself it does nothing.
    @MainActor
    func testBackToLoadKeepsTheRoll() async throws {
        let s = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("samples")
        let src = s.appendingPathComponent("full_3600_irclean.pnm")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path))
        Store.labSearchEnabled = false
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lb-back-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = dir.appendingPathComponent("frame-01-raw.tif")
        try RawImage.loadPNM(src).downsampled(maxSide: 600).writeRawTIFF(raw)
        let st = Store()
        st.backToLoad()                                     // nothing to go back from
        await st.open(raw)
        st.stock = "Candido 400"; st.edit.rotation = 1
        XCTAssertTrue(st.canGoBackToLoad)
        let frame = st.frameNumber
        st.backToLoad()
        XCTAssertEqual(st.phase, .ready)
        XCTAssertEqual(st.stock, "Candido 400")
        XCTAssertEqual(st.edit.rotation, 1)
        XCTAssertEqual(st.frameNumber, frame + 1)
        XCTAssertNil(st.image)
    }
}
