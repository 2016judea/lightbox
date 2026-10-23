import XCTest
import ImageIO
@testable import Lightbox

/// "If I save, edit, and save again, it sends the same one to Photos": every changed edit is a new
/// version on disk and the import uses that new file; an unchanged edit is neither rewritten nor re-imported.
@MainActor
final class ExportVersionTests: XCTestCase {
    func mean(_ u: URL) -> Double {
        let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(u as CFURL, nil)!, 0, nil)!
        let s = LabCompare.stats(img); return (s.mean[0] + s.mean[1] + s.mean[2]) / 3
    }

    func testEditThenSaveMakesANewVersion() async throws {
        let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("samples")
        let src = samples.appendingPathComponent("full_3600_irclean.pnm")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path))
        Store.labSearchEnabled = false; Store.variationsEnabled = false
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lb-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = dir.appendingPathComponent("frame-01-raw.tif")
        try RawImage.loadPNM(src).downsampled(maxSide: 1200).writeRawTIFF(raw)

        let store = Store()
        var imported: [URL] = []
        store.photosImporter = { imported.append($0); return nil }
        await store.open(raw)
        await store.addToPhotos()
        store.edit.exposure = 0.5
        await store.addToPhotos()
        await store.addToPhotos()                 // nothing changed: no new file, no second import

        let v1 = dir.appendingPathComponent("frame-01.jpg"), v2 = dir.appendingPathComponent("frame-01 v2.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: v1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: v2.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("frame-01 v3.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("frame-01 v2.json").path))
        let m1 = mean(v1), m2 = mean(v2)
        print("v1 mean \(m1) v2 mean \(m2) imported \(imported.map(\.lastPathComponent))")
        XCTAssertGreaterThan(m2, m1 + 5, "the second file carries the brighter edit")
        XCTAssertEqual(imported, [v1, v2])
        XCTAssertEqual(store.toast, "Already in Photos")
    }
}
