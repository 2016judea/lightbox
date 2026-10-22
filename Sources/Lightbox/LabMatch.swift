import Foundation
import Photos
import Vision
import CoreGraphics
import CoreImage
import SQLite3
import ImageIO
import USearch

/// Finds the lab scan of the frame in the scanner among his Photos.
///
/// Store (~/Library/Application Support/Lightbox/):
///   labindex.usearch  HNSW graph over L2-normalised Vision feature prints, cosine metric (USearch)
///   labindex.sqlite   one row per asset: localIdentifier, dates, albums, film flag, the exact vector
///   meta in SQLite    dimension + Vision request revision; a mismatch rebuilds from scratch
///
/// Query: the scan's positive at 0/90/180/270 degrees, top 10 from the ANN graph for each, then a
/// re-rank on exact cosine distance plus a structural check (luminance correlation of the two images
/// at the matched rotation). A wrong match is worse than none, so both must clear a threshold.
struct LabMatch: Codable, Equatable {
    var assetId: String
    var confidence: Double
    var distance: Double
    var structure: Double
    var rotation: Int          // quarter turns clockwise applied to OUR image to line up with the lab scan
    var album: String?
    var created: Date?
}

final class LabIndex: @unchecked Sendable {
    static let shared = LabIndex()

    let dir: URL
    private var db: OpaquePointer?
    private var index: USearchIndex?
    private var dim = 0
    private let lock = NSLock()
    private(set) var count = 0
    private var reserved = 0

    // Thresholds from his library, 2026-10-22: the true lab scan of the Gold 200 frame scored
    // distance 0.084 / structure 0.97; the nearest wrong frames (same river, same evening) 0.148+ and
    // structure <= 0.27. A wrong match is worse than none, so both gates sit well inside that gap.
    static var maxDistance = 0.12
    static var minStructure = 0.60

    init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lightbox")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    var indexPath: String { dir.appendingPathComponent("labindex.usearch").path }
    var dbPath: String { dir.appendingPathComponent("labindex.sqlite").path }

    static var visionRevision: Int { VNGenerateImageFeaturePrintRequest.currentRevision }
    static let thumbMethod = "imageio-360"

    // MARK: feature prints

    static func featurePrint(_ img: CGImage, orientation: CGImagePropertyOrientation = .up) -> [Float]? {
        let req = VNGenerateImageFeaturePrintRequest()
        req.imageCropAndScaleOption = .scaleFit
        let h = VNImageRequestHandler(cgImage: img, orientation: orientation)
        guard (try? h.perform([req])) != nil, let obs = req.results?.first as? VNFeaturePrintObservation,
              obs.elementType == .float else { return nil }
        var v = obs.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(obs.elementCount)) }
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if n > 0 { for i in v.indices { v[i] /= n } }
        return v
    }

    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
        var d: Float = 0
        for i in 0..<min(a.count, b.count) { d += a[i] * b[i] }
        return Double(1 - d)
    }

    // MARK: store

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func metaGet(_ k: String) -> String? {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key=?", -1, &st, nil)
        sqlite3_bind_text(st, 1, k, -1, SQLITE_TRANSIENT)
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? String(cString: sqlite3_column_text(st, 0)) : nil
    }

    private func metaSet(_ k: String, _ v: String) {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", -1, &st, nil)
        sqlite3_bind_text(st, 1, k, -1, SQLITE_TRANSIENT); sqlite3_bind_text(st, 2, v, -1, SQLITE_TRANSIENT)
        sqlite3_step(st); sqlite3_finalize(st)
    }

    /// Opens the store, rebuilding it if the vector dimension or Vision revision changed.
    func open(dimension: Int) throws {
        lock.lock(); defer { lock.unlock() }
        if db == nil {
            sqlite3_open(dbPath, &db)
            exec("PRAGMA journal_mode=WAL")
            exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")
            exec("""
                CREATE TABLE IF NOT EXISTS assets(key INTEGER PRIMARY KEY AUTOINCREMENT, local_id TEXT UNIQUE,
                  created REAL, modified REAL, albums TEXT, is_film INTEGER, vector BLOB)
                """)
        }
        let stale = metaGet("dimension") != String(dimension) || metaGet("vision_revision") != String(Self.visionRevision)
            || metaGet("thumb_method") != Self.thumbMethod
        if stale {
            exec("DELETE FROM assets")
            try? FileManager.default.removeItem(atPath: indexPath)
            metaSet("dimension", String(dimension)); metaSet("vision_revision", String(Self.visionRevision))
            metaSet("thumb_method", Self.thumbMethod)
        }
        dim = dimension
        let idx = try USearchIndex.make(metric: .cos, dimensions: UInt32(dimension), connectivity: 16, quantization: .f32)
        if !stale, FileManager.default.fileExists(atPath: indexPath) { try idx.load(path: indexPath) }
        index = idx
        count = try idx.count
        reserved = max(1024, count * 2)
        try idx.reserve(UInt32(reserved))
    }

    private func known() -> [String: (Int64, Double)] {
        var out: [String: (Int64, Double)] = [:]
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT local_id, key, modified FROM assets", -1, &st, nil)
        while sqlite3_step(st) == SQLITE_ROW {
            out[String(cString: sqlite3_column_text(st, 0))] = (sqlite3_column_int64(st, 1), sqlite3_column_double(st, 2))
        }
        sqlite3_finalize(st)
        return out
    }

    private func vector(key: Int64) -> (String, [Float], String?, Double)? {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT local_id, vector, albums, created FROM assets WHERE key=?", -1, &st, nil)
        sqlite3_bind_int64(st, 1, key)
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        let id = String(cString: sqlite3_column_text(st, 0))
        let n = Int(sqlite3_column_bytes(st, 1)) / 4
        let p = sqlite3_column_blob(st, 1)!.bindMemory(to: Float.self, capacity: n)
        let albums = sqlite3_column_text(st, 2).map { String(cString: $0) }
        return (id, Array(UnsafeBufferPointer(start: p, count: n)), albums, sqlite3_column_double(st, 3))
    }

    private func upsert(_ a: PHAsset, albums: [String], film: Bool, vector v: [Float], replacing old: Int64?) throws {
        if let old { try? index?.remove(key: USearchKey(old)); exec("DELETE FROM assets WHERE key=\(old)") }
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO assets(local_id,created,modified,albums,is_film,vector) VALUES(?,?,?,?,?,?)", -1, &st, nil)
        sqlite3_bind_text(st, 1, a.localIdentifier, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(st, 2, a.creationDate?.timeIntervalSince1970 ?? 0)
        sqlite3_bind_double(st, 3, a.modificationDate?.timeIntervalSince1970 ?? 0)
        sqlite3_bind_text(st, 4, albums.joined(separator: "|"), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(st, 5, film ? 1 : 0)
        v.withUnsafeBytes { _ = sqlite3_bind_blob(st, 6, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
        sqlite3_step(st); sqlite3_finalize(st)
        let key = sqlite3_last_insert_rowid(db)
        if let idx = index, reserved <= (try idx.count) + 1 { reserved = max(1024, (try idx.count) * 2); try idx.reserve(UInt32(reserved)) }
        try index?.add(key: USearchKey(key), vector: v)
    }

    // MARK: Photos

    static func authorize() async -> Bool {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return s == .authorized || s == .limited
    }

    /// Thumbnail from the asset's original data through ImageIO (orientation applied). This is the
    /// path measured at distance 0.084 for the true match; PhotoKit's NSImage thumbnails printed
    /// ~0.31 for the same pair, so they are not used.
    static func thumbnail(_ a: PHAsset, side: CGFloat = 360) -> CGImage? {
        let o = PHImageRequestOptions()
        o.isSynchronous = true; o.deliveryMode = .highQualityFormat; o.isNetworkAccessAllowed = false
        o.version = .current
        var out: CGImage?
        PHImageManager.default().requestImageDataAndOrientation(for: a, options: o) { data, _, _, _ in
            guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return }
            out = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        }
        return out
    }

    static func fullImage(_ id: String, side: CGFloat = 2400) -> CGImage? {
        guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let o = PHImageRequestOptions()
        o.isSynchronous = true; o.deliveryMode = .highQualityFormat; o.isNetworkAccessAllowed = true
        var out: CGImage?
        PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: side, height: side),
                                              contentMode: .aspectFit, options: o) { img, _ in
            out = img?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return out
    }

    struct SyncStats { var total = 0, added = 0, removed = 0, skipped = 0; var seconds = 0.0 }

    /// Adds new and changed assets, drops deleted ones. Film albums go first so a match can land
    /// before the whole library is done.
    func sync(progress: ((Int, Int) -> Void)? = nil) async throws -> SyncStats {
        var stats = SyncStats()
        let t0 = Date()
        // album membership
        var albumsOf: [String: [String]] = [:]
        var filmIds: [String] = []
        let cols = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        cols.enumerateObjects { c, _, _ in
            let title = c.localizedTitle ?? ""
            let assets = PHAsset.fetchAssets(in: c, options: nil)
            let isFilm = title.localizedCaseInsensitiveContains("film")
            assets.enumerateObjects { a, _, _ in
                albumsOf[a.localIdentifier, default: []].append(title)
                if isFilm { filmIds.append(a.localIdentifier) }
            }
        }
        let filmSet = Set(filmIds)
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let all = PHAsset.fetchAssets(with: opts)
        var ordered: [PHAsset] = []
        ordered.reserveCapacity(all.count)
        var rest: [PHAsset] = []
        all.enumerateObjects { a, _, _ in if filmSet.contains(a.localIdentifier) { ordered.append(a) } else { rest.append(a) } }
        ordered += rest
        stats.total = ordered.count

        // dimension from a first print
        if index == nil {
            guard let first = ordered.first, let img = Self.thumbnail(first), let v = Self.featurePrint(img) else { return stats }
            try open(dimension: v.count)
        }
        var have = known()
        let live = Set(ordered.map(\.localIdentifier))
        for (id, (key, _)) in have where !live.contains(id) {
            try? index?.remove(key: USearchKey(key)); exec("DELETE FROM assets WHERE key=\(key)"); stats.removed += 1
        }
        exec("BEGIN")
        var n = 0
        for a in ordered {
            n += 1
            let mod = a.modificationDate?.timeIntervalSince1970 ?? 0
            if let (_, m) = have[a.localIdentifier], abs(m - mod) < 1 { continue }
            guard let img = Self.thumbnail(a), let v = Self.featurePrint(img) else { stats.skipped += 1; continue }
            try upsert(a, albums: albumsOf[a.localIdentifier] ?? [], film: filmSet.contains(a.localIdentifier),
                       vector: v, replacing: have[a.localIdentifier]?.0)
            have[a.localIdentifier] = (0, mod)
            stats.added += 1
            if stats.added % 250 == 0 { exec("COMMIT"); try index?.save(path: indexPath); exec("BEGIN"); progress?(n, ordered.count) }
        }
        exec("COMMIT")
        try index?.save(path: indexPath)
        count = (try? index?.count) ?? 0
        stats.seconds = Date().timeIntervalSince(t0)
        return stats
    }

    // MARK: query

    struct Candidate { var id: String; var distance: Double; var rotation: Int; var albums: String?; var created: Double }

    /// Luminance correlation of two images at a common small size: 1 = same picture, ~0 = unrelated.
    static func structure(_ a: CGImage, _ b: CGImage) -> Double {
        func gray(_ img: CGImage) -> [Double] {
            let s = 24
            var px = [UInt8](repeating: 0, count: s * s)
            let ctx = CGContext(data: &px, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .medium
            // centre 90% so differing crops matter less
            let w = Double(img.width), h = Double(img.height)
            let crop = img.cropping(to: CGRect(x: w * 0.05, y: h * 0.05, width: w * 0.9, height: h * 0.9)) ?? img
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: s, height: s))
            let v = px.map(Double.init); let m = v.reduce(0, +) / Double(v.count)
            return v.map { $0 - m }
        }
        let x = gray(a), y = gray(b)
        let num = zip(x, y).reduce(0) { $0 + $1.0 * $1.1 }
        let den = sqrt(x.reduce(0) { $0 + $1 * $1 } * y.reduce(0) { $0 + $1 * $1 })
        return den > 0 ? num / den : 0
    }

    func query(_ positive: CGImage, k: Int = 10) throws -> (LabMatch?, [Candidate]) {
        guard let index, dim > 0 else { return (nil, []) }
        // Vision's orientation hint does not rotate a feature print (measured: all four scored alike),
        // so the pixels are turned before printing.
        var best: [String: Candidate] = [:]
        for r in 0..<4 {
            guard let turned = Develop.orient(positive, rotation: r, mirrored: false),
                  let q = Self.featurePrint(turned) else { continue }
            let (keys, _) = try index.search(vector: q, count: k)
            for key in keys {
                guard let (id, v, albums, created) = vector(key: Int64(key)) else { continue }
                let d = Self.cosineDistance(q, v)       // exact re-rank
                if best[id].map({ d < $0.distance }) ?? true {
                    best[id] = Candidate(id: id, distance: d, rotation: r, albums: albums, created: created)
                }
            }
        }
        let ranked = best.values.sorted { $0.distance < $1.distance }
        guard let top = ranked.first, top.distance <= Self.maxDistance,
              let a = PHAsset.fetchAssets(withLocalIdentifiers: [top.id], options: nil).firstObject,
              let thumb = Self.thumbnail(a, side: 512),
              let ours = Develop.orient(positive, rotation: top.rotation, mirrored: false)
        else { return (nil, ranked) }
        let s = Self.structure(ours, thumb)
        guard s >= Self.minStructure else { return (nil, ranked) }
        // confidence: how far inside both thresholds, and how clearly it beats the runner-up
        let margin = ranked.count > 1 ? min(1, (ranked[1].distance - top.distance) / 0.1) : 1
        let conf = max(0, min(1, 0.4 * (1 - top.distance / Self.maxDistance) + 0.3 * ((s - Self.minStructure) / (1 - Self.minStructure)) + 0.3 * margin))
        let album = top.albums?.split(separator: "|").first { !$0.localizedCaseInsensitiveContains("film") }.map(String.init)
            ?? top.albums?.split(separator: "|").first.map(String.init)
        return (LabMatch(assetId: top.id, confidence: conf, distance: top.distance, structure: s, rotation: top.rotation,
                         album: album, created: Date(timeIntervalSince1970: top.created)), ranked)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
