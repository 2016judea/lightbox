import XCTest
import ImageIO
@testable import Lightbox

/// One-off grid search used to set Gold 200's exposureBias / outputBlack / tint against the lab scan.
/// Skipped unless LIGHTBOX_GOLD_SEARCH=1.
final class GoldSearch: XCTestCase {
    func testSearch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIGHTBOX_GOLD_SEARCH"] == "1")
        let s = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("samples")
        let lab = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(s.appendingPathComponent("lab_IMG_7810.jpg") as CFURL, nil)!, 0, nil)!
        let w = try RawImage.loadPNM(s.appendingPathComponent("full_3600_irclean.pnm")).downsampled(maxSide: 500)
        let a = Develop.analyse(w, filmType: .colorNegative)
        var e = Edit(); e.rotation = 1
        let t = LabCompare.quantiles(lab)
        var best = (1e9, FilmStock.Look())
        for ex in stride(from: 0.0, through: 0.16, by: 0.02) { for ob in stride(from: 0.0, through: 0.06, by: 0.01) {
            for tb in stride(from: -0.012, through: 0.012, by: 0.006) { for wb in stride(from: 0.0, through: 0.03, by: 0.01) {
                var l = FilmStock.named("Kodak Gold 200")!.look
                l.exposureBias = Float(ex); l.outputBlack = Float(ob); l.tintBias = Float(tb); l.warmBias = Float(wb)
                let d = LabCompare.distance(LabCompare.quantiles(Develop.render(w, a, e, look: l)!), t)
                if d < best.0 { best = (d, l) }
            } }
        } }
        print("GOLD BEST", best.0, "exposureBias", best.1.exposureBias, "outputBlack", best.1.outputBlack, "tintBias", best.1.tintBias, "warmBias", best.1.warmBias)
    }
}
