import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Photos

func PHAssetFetch(_ id: String) -> PHAsset? { PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject }

/// `Lightbox --lab-match <raw.pnm> <out-dir>` runs the Photos matcher headless (for calibration and
/// the regression fixture) and writes candidates.json + lab.jpg + ours.jpg into out-dir.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--lab-match"), args.count > i + 2 {
            let raw = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            Task {
                await runLabMatch(raw: raw, out: out)
                exit(0)
            }
            RunLoop.main.run()
        } else {
            LightboxApp.main()
        }
    }

    static func log(_ s: String, _ out: URL) {
        print(s)
        let f = out.appendingPathComponent("log.txt")
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); try? h.close() }
        else { try? (s + "\n").write(to: f, atomically: true, encoding: .utf8) }
    }

    static func writeJPEG(_ img: CGImage, _ url: URL) {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        CGImageDestinationFinalize(d)
    }

    static func runLabMatch(raw: URL, out: URL) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out.appendingPathComponent("log.txt"))
        guard await LabIndex.authorize() else { log("Photos access denied", out); return }
        let idx = LabIndex.shared
        do {
            let t0 = Date()
            let st = try await idx.sync { n, total in log("  indexed \(n)/\(total)", out) }
            log("sync: total \(st.total) added \(st.added) removed \(st.removed) skipped \(st.skipped) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s; index count \(idx.count)", out)
            let full = try RawImage.load(raw)
            let w = full.downsampled(maxSide: 1200)
            let a = Develop.analyse(w, filmType: .colorNegative)
            guard let pos = Develop.render(w, a, Edit(), look: FilmStock.named("Kodak Gold 200")!.look) else { return }
            writeJPEG(pos, out.appendingPathComponent("ours.jpg"))
            let tq = Date()
            let (m, ranked) = try idx.query(pos)
            log(String(format: "query: %.0f ms", Date().timeIntervalSince(tq) * 1000), out)
            for c in ranked.prefix(10) {
                log(String(format: "  d=%.4f rot=%d %@ %@", c.distance, c.rotation, c.id, c.albums ?? ""), out)
            }
            // structure score for the top 5, so the threshold can be set from data
            if let top = ranked.first, let a = PHAssetFetch(top.id), let th = LabIndex.thumbnail(a) {
                writeJPEG(th, out.appendingPathComponent("top_thumb.jpg"))
                log("top thumb \(th.width)x\(th.height)", out)
            }
            for c in ranked.prefix(5) {
                if let th = LabIndex.fullImage(c.id, side: 512), let ours = Develop.orient(pos, rotation: c.rotation, mirrored: false) {
                    log(String(format: "  structure %.3f for %@", LabIndex.structure(ours, th), c.id), out)
                }
            }
            if let m {
                log("MATCH \(m.assetId) conf \(String(format: "%.3f", m.confidence)) d \(String(format: "%.4f", m.distance)) s \(String(format: "%.3f", m.structure)) rot \(m.rotation) album \(m.album ?? "-")", out)
                if let lab = LabIndex.fullImage(m.assetId, side: 4000) { writeJPEG(lab, out.appendingPathComponent("lab.jpg")) }
                if let d = try? JSONEncoder().encode(m) { try? d.write(to: out.appendingPathComponent("match.json")) }
            } else { log("NO MATCH", out) }
            let sz = (try? FileManager.default.attributesOfItem(atPath: idx.indexPath)[.size] as? Int) ?? 0
            let dsz = (try? FileManager.default.attributesOfItem(atPath: idx.dbPath)[.size] as? Int) ?? 0
            log("store: usearch \(sz / 1024) KB, sqlite \(dsz / 1024) KB", out)
        } catch { log("error: \(error)", out) }
    }
}
