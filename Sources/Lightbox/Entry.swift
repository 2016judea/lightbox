import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Photos
import CoreImage

func PHAssetFetch(_ id: String) -> PHAsset? { PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject }

/// `Lightbox --lab-match <raw.pnm> <out-dir>` runs the Photos matcher headless (for calibration and
/// the regression fixture) and writes candidates.json + lab.jpg + ours.jpg into out-dir.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--lab-bench"), args.count > i + 2 {
            let raw = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            Task { await runBench(raw: raw, out: out); exit(0) }
            RunLoop.main.run()
        } else if let i = args.firstIndex(of: "--lab-match"), args.count > i + 2 {
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

    /// Times the thumbnail paths, a cold build, a warm sync and a query; checks both thumbnail
    /// paths keep the true lab scan close.
    static func runBench(raw: URL, out: URL) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out.appendingPathComponent("log.txt"))
        let st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        log("authorization before asking: \(st.rawValue) (3 = authorized)", out)
        guard await LabIndex.authorize() else { log("denied", out); return }
        let full = try! RawImage.load(raw)
        let w = full.downsampled(maxSide: 1200)
        let a = Develop.analyse(w, filmType: .colorNegative)
        let pos = Develop.render(w, a, Edit(), crop: .full, look: FilmStock.named("Kodak Gold 200")!.look)!
        let q = LabIndex.featurePrint(Develop.orient(pos, rotation: 1, mirrored: false)!)!
        let trueId = "0AB1A3F2-2E29-45EC-9836-2EAA7C2F8BA8/L0/001"
        if let asset = PHAssetFetch(trueId) {
            for (name, img) in [("imageio-360", LabIndex.thumbnail(asset)), ("photokit-300", LabIndex.fastThumbnail(asset))] {
                if let img, let v = LabIndex.featurePrint(img) {
                    log(String(format: "true pair via %@ (%dx%d): d=%.4f", name, img.width, img.height, LabIndex.cosineDistance(q, v)), out)
                }
            }
        }
        // per-asset cost of each path over 300 photos, 8-way parallel
        let o = PHFetchOptions(); o.fetchLimit = 300
        o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let f = PHAsset.fetchAssets(with: o); var assets: [PHAsset] = []
        f.enumerateObjects { x, _, _ in assets.append(x) }
        for (name, fn) in [("imageio-360", LabIndex.thumbnail as (PHAsset, CGFloat) -> CGImage?), ("photokit-300", LabIndex.fastThumbnail)] {
            let t = Date(); var ok = 0; let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: assets.count) { i in
                if let img = fn(assets[i], name == "imageio-360" ? 360 : 300), LabIndex.featurePrint(img) != nil { lock.lock(); ok += 1; lock.unlock() }
            }
            log(String(format: "%@: %d/%d ok, %.1f ms/photo (thumb+print, parallel)", name, ok, assets.count, Date().timeIntervalSince(t) * 1000 / Double(assets.count)), out)
        }
        // cold build
        let idx = LabIndex.shared
        for p in [idx.indexPath, idx.dbPath, idx.dbPath + "-wal", idx.dbPath + "-shm"] { try? FileManager.default.removeItem(atPath: p) }
        var t = Date()
        var firstPriority = 0.0
        let s1 = try! await idx.sync(progress: nil, onPriority: { firstPriority = Date().timeIntervalSince(t) })
        log(String(format: "COLD build: %d photos, +%d skipped %d in %.1fs (Film album done at %.1fs) %@", s1.total, s1.added, s1.skipped, s1.seconds, firstPriority, s1.phases.description), out)
        t = Date()
        let s2 = try! await idx.sync()
        log(String(format: "WARM sync (%@): %d to read in %.3fs", s2.incremental ? "change token" : "full diff", s2.total, s2.seconds), out)
        t = Date()
        let (m, _) = try! idx.query(pos)
        log(String(format: "query+re-rank: %.0f ms -> %@ conf %.2f", Date().timeIntervalSince(t) * 1000, m?.assetId ?? "none", m?.confidence ?? 0), out)
        let sz = (try? FileManager.default.attributesOfItem(atPath: idx.indexPath)[.size] as? Int) ?? 0
        log("index \(idx.count) vectors, usearch \(sz / 1024) KB", out)
        falsePositives(out)
    }

    /// 30 Film-album photos, each degraded the way a lab scan differs from ours (8% crop, a quarter
    /// turn, a colour cast), queried twice: with itself in the library (should match) and with
    /// itself removed (the best impostor must be rejected).
    static func falsePositives(_ out: URL) {
        let idx = LabIndex.shared
        let cols = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var film: PHAssetCollection?
        cols.enumerateObjects { c, _, stop in if c.localizedTitle == "Film" { film = c; stop.pointee = true } }
        guard let film else { log("no Film album", out); return }
        let assets = PHAsset.fetchAssets(in: film, options: nil)
        var hits = 0, fp = 0, n = 0
        var impostorD: [Double] = [], selfD: [Double] = []
        for i in stride(from: 0, to: assets.count, by: max(1, assets.count / 30)) {
            let a = assets.object(at: i)
            guard let big = LabIndex.thumbnail(a, side: 900) else { continue }
            let w = big.width, h = big.height
            guard let cropped = big.cropping(to: CGRect(x: w / 25, y: h / 25, width: w * 23 / 25, height: h * 23 / 25)),
                  let turned = Develop.orient(cropped, rotation: 1, mirrored: false) else { continue }
            let ci = CIImage(cgImage: turned).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.08, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0.9, w: 0)])
            guard let q = Develop.ciContext.createCGImage(ci, from: ci.extent) else { continue }
            n += 1
            idx.excluded = []
            if let (m, r) = try? idx.query(q) {
                if m?.assetId == a.localIdentifier { hits += 1 }
                if let d = r.first(where: { $0.id == a.localIdentifier })?.distance { selfD.append(d) }
            }
            idx.excluded = [a.localIdentifier]
            if let (m, r) = try? idx.query(q) {
                if m != nil { fp += 1; log("FALSE POSITIVE for \(a.localIdentifier): \(m!.assetId) d=\(m!.distance) s=\(m!.structure)", out) }
                if let d = r.first?.distance { impostorD.append(d) }
            }
        }
        idx.excluded = []
        func q(_ v: [Double], _ p: Double) -> Double { let s = v.sorted(); return s.isEmpty ? .nan : s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
        log(String(format: "false-positive check, %d film frames: found itself %d/%d; impostor accepted %d/%d", n, hits, n, fp, n), out)
        log(String(format: "  self distance median %.3f max %.3f; best impostor min %.3f median %.3f (gate %.2f)",
                    q(selfD, 0.5), q(selfD, 1), q(impostorD, 0), q(impostorD, 0.5), LabIndex.maxDistance), out)
    }

    static func runLabMatch(raw: URL, out: URL) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out.appendingPathComponent("log.txt"))
        guard await LabIndex.authorize() else { log("Photos access denied", out); return }
        let idx = LabIndex.shared
        do {
            let t0 = Date()
            let st = try await idx.sync()
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
