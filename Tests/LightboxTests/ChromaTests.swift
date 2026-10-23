import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Lightbox

/// Writes full-size renders for measuring colour noise against the lab (LIGHTBOX_LIVE=1 only).
final class ChromaTests: XCTestCase {
    func testWriteRendersForNoiseCheck() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIGHTBOX_LIVE"] == "1")
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIGHTBOX_OUT"] ?? NSTemporaryDirectory())
        let jobs: [(String, String, Edit)] = {
            var v3 = Edit(); v3.exposure = 0.2; v3.contrast = -0.35; v3.sharpen = -0.3; v3.tint = 0.05; v3.warmth = 0.05
            let sup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return [(sup.appendingPathComponent("Lightbox/fixtures/gold200-frame.pnm").path, "montana", Edit()),
                    (NSHomeDirectory() + "/Pictures/Lightbox/2026-10-23 Kodak Gold 200/frame-01-raw.pnm", "alex", v3)]
        }()
        for (path, name, e) in jobs where FileManager.default.fileExists(atPath: path) {
            let full = try RawImage.load(URL(fileURLWithPath: path))
            let a = Develop.analyse(full.downsampled(maxSide: 2000), filmType: .colorNegative)
            let img = try XCTUnwrap(Develop.render(full, a, e, look: FilmStock.named("Kodak Gold 200")!.look))
            let u = out.appendingPathComponent("\(name).png")
            let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(d, img, nil); XCTAssertTrue(CGImageDestinationFinalize(d))
        }
    }
}
