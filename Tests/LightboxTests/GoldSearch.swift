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
        func cost(_ l: FilmStock.Look) -> Double {
            let q = LabCompare.quantiles(Develop.render(w, a, e, look: l)!)
            return LabCompare.distance(q, t)
        }
        // coordinate descent over seven values (a grid this wide would be 10^6 renders)
        var l = FilmStock.named("Kodak Gold 200")!.look
        var c = cost(l)
        let steps: [(WritableKeyPath<FilmStock.Look, Float>, Float, ClosedRange<Float>)] = [
            (\.exposureBias, 0.02, -0.1...0.3), (\.blackPoint, 0.01, 0...0.15), (\.contrastBias, 0.04, 0.7...1.5),
            (\.warmBias, 0.005, -0.05...0.06), (\.tintBias, 0.004, -0.04...0.04), (\.outputWhite, 0.005, 0.9...1), (\.neutral, 0.05, 0.2...0.9)]
        for _ in 0..<6 {
            for (kp, st, rg) in steps {
                for dir: Float in [-1, 1] {
                    while true {
                        var t2 = l; t2[keyPath: kp] = min(rg.upperBound, max(rg.lowerBound, t2[keyPath: kp] + dir * st))
                        let c2 = cost(t2)
                        if c2 < c - 0.01 { l = t2; c = c2 } else { break }
                    }
                }
            }
        }
        best = (c, l)
        print("GOLD BEST", c, "exposureBias", l.exposureBias, "blackPoint", l.blackPoint, "contrastBias", l.contrastBias, "warmBias", l.warmBias, "tintBias", l.tintBias, "outputWhite", l.outputWhite, "neutral", l.neutral)

    }
}
