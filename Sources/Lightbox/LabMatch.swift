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
    static let thumbMethod = "imageio-360-normalized-v3"

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
            exec("CREATE TABLE IF NOT EXISTS skipped(local_id TEXT PRIMARY KEY, modified REAL)")
            exec("""
                CREATE TABLE IF NOT EXISTS assets(key INTEGER PRIMARY KEY AUTOINCREMENT, local_id TEXT UNIQUE,
                  created REAL, modified REAL, albums TEXT, is_film INTEGER, vector BLOB)
                """)
        }
        let stale = metaGet("dimension") != String(dimension) || metaGet("vision_revision") != String(Self.visionRevision)
            || metaGet("thumb_method") != Self.thumbMethod
        if stale {
            exec("DELETE FROM assets"); exec("DELETE FROM skipped"); exec("DELETE FROM meta WHERE key='change_token'")
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

    struct SyncStats { var total = 0, added = 0, removed = 0, skipped = 0, incremental = false; var seconds = 0.0; var phases: [String: Double] = [:] }

    static var log: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lightbox/lab.log") }
    static func note(_ s: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + " " + s + "\n"
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: log, atomically: true, encoding: .utf8) }
    }


    static let caching = PHCachingImageManager()

    /// PhotoKit's own small thumbnail: local even for iCloud-only photos, no download.
    static func fastThumbnail(_ a: PHAsset, side: CGFloat = 300) -> CGImage? {
        let o = PHImageRequestOptions()
        o.isSynchronous = true; o.deliveryMode = .highQualityFormat; o.resizeMode = .exact
        o.isNetworkAccessAllowed = false
        var out: CGImage?
        caching.requestImage(for: a, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit, options: o) { img, _ in
            guard let img else { return }
            var r = CGRect(origin: .zero, size: img.size)
            out = img.cgImage(forProposedRect: &r, context: nil, hints: nil)
        }
        return out
    }

    /// Index path: ImageIO thumbnail from the local original (true pair 0.103 on the bench) or,
    /// for iCloud-only photos with no local original, PhotoKit's best local image at the same size.
    /// PhotoKit's fast thumbnails printed 0.251 for the true pair and are not used.
    static func indexThumbnail(_ a: PHAsset) -> CGImage? {
        (thumbnail(a) ?? fastThumbnail(a, side: 360)).flatMap(normalized)
    }

    /// The ONE path every image takes before a feature print, query and index alike: JPEG at 0.9,
    /// then an ImageIO thumbnail at 360 px. Same size, colour space and encoding on both sides.
    static func normalized(_ img: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(d), let src = CGImageSourceCreateWithData(data, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 360,
            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }

    /// Lightbox's own exports (frame-01.jpg, "frame-01 v2.jpg") land in his Film album; they are
    /// our scans, never the lab's, so they are never a match.
    static func isOurs(_ a: PHAsset) -> Bool {
        let name = PHAssetResource.assetResources(for: a).first?.originalFilename ?? ""
        return name.range(of: #"^frame-\d+( v\d+)?\.(jpg|jpeg|tif|tiff)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func isSkipped(_ id: String, _ mod: Double) -> Bool {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT 1 FROM skipped WHERE local_id=? AND modified=?", -1, &st, nil)
        sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT); sqlite3_bind_double(st, 2, mod)
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW
    }

    private func markSkipped(_ id: String, _ mod: Double) {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO skipped(local_id, modified) VALUES(?,?)", -1, &st, nil)
        sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT); sqlite3_bind_double(st, 2, mod)
        sqlite3_step(st); sqlite3_finalize(st)
    }

    /// Opens an existing store from disk without touching Photos (dimension from the stored meta).
    func openIfExists() {
        if index != nil { return }
        var tmp: OpaquePointer?
        guard FileManager.default.fileExists(atPath: dbPath), sqlite3_open(dbPath, &tmp) == SQLITE_OK else { return }
        var st: OpaquePointer?; var dim = 0
        sqlite3_prepare_v2(tmp, "SELECT value FROM meta WHERE key='dimension'", -1, &st, nil)
        if sqlite3_step(st) == SQLITE_ROW { dim = Int(String(cString: sqlite3_column_text(st, 0))) ?? 0 }
        sqlite3_finalize(st); sqlite3_close(tmp)
        if dim > 0 { try? open(dimension: dim) }
    }

    private var syncTask: Task<SyncStats, Error>?
    var isBuilt: Bool { count > 0 }

    /// One sync at a time; callers share it. `onPriority` fires once the Film album (and
    /// film-shaped frames) are in, so a match can be tried before the rest of the library.
    func sharedSync(progress: ((Int, Int) -> Void)? = nil, onPriority: (() -> Void)? = nil) async throws -> SyncStats {
        let (t, mine): (Task<SyncStats, Error>, Bool) = lock.withLock {
            if let t = syncTask { return (t, false) }
            let t = Task { try await self.sync(progress: progress, onPriority: onPriority) }
            syncTask = t
            return (t, true)
        }
        defer { if mine { lock.withLock { syncTask = nil } } }
        return try await t.value
    }

    /// Brings the index up to date. With a stored change token only the changed assets are read;
    /// otherwise a full diff against the library (deleted dropped, new added, unavailable remembered).
    func sync(progress: ((Int, Int) -> Void)? = nil, onPriority: (() -> Void)? = nil) async throws -> SyncStats {
        var stats = SyncStats()
        let t0 = Date()
        var tp = Date()
        func phase(_ n: String) { stats.phases[n, default: 0] += Date().timeIntervalSince(tp); tp = Date() }
        let lib = PHPhotoLibrary.shared()
        let tokenAtStart = lib.currentChangeToken

        openIfExists()
        if index == nil {
            // dimension from one print
            let o = PHFetchOptions(); o.fetchLimit = 1
            o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            guard let first = PHAsset.fetchAssets(with: o).firstObject, let img = Self.indexThumbnail(first),
                  let v = Self.featurePrint(img) else { return stats }
            try open(dimension: v.count)
            exec("CREATE TABLE IF NOT EXISTS skipped(local_id TEXT PRIMARY KEY, modified REAL)")
        }
        phase("open")

        var work: [PHAsset] = []
        var albumsOf: [String: [String]] = [:]
        var filmSet = Set<String>()

        // incremental path
        if count > 0, let d = metaGet("change_token").flatMap({ Data(base64Encoded: $0) }),
           let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: d),
           let changes = try? lib.fetchPersistentChanges(since: token) {
            stats.incremental = true
            var changed = Set<String>(), deleted = Set<String>()
            for c in changes {
                guard let det = try? c.changeDetails(for: .asset) else { continue }
                changed.formUnion(det.insertedLocalIdentifiers); changed.formUnion(det.updatedLocalIdentifiers)
                deleted.formUnion(det.deletedLocalIdentifiers)
            }
            let have = known()
            for id in deleted { if let (key, _) = have[id] { try? index?.remove(key: USearchKey(key)); exec("DELETE FROM assets WHERE key=\(key)"); stats.removed += 1 } }
            if !changed.isEmpty {
                let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(changed), options: nil)
                fetched.enumerateObjects { a, _, _ in
                    guard a.mediaType == .image else { return }
                    work.append(a)
                    let cols = PHAssetCollection.fetchAssetCollectionsContaining(a, with: .album, options: nil)
                    cols.enumerateObjects { c, _, _ in
                        let t = c.localizedTitle ?? ""
                        albumsOf[a.localIdentifier, default: []].append(t)
                        if t.localizedCaseInsensitiveContains("film") { filmSet.insert(a.localIdentifier) }
                    }
                }
            }
            stats.total = work.count
            phase("changes")
        } else {
            // full diff
            let cols = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            cols.enumerateObjects { c, _, _ in
                let title = c.localizedTitle ?? ""
                let isFilm = title.localizedCaseInsensitiveContains("film")
                PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { a, _, _ in
                    albumsOf[a.localIdentifier, default: []].append(title)
                    if isFilm { filmSet.insert(a.localIdentifier) }
                }
            }
            let opts = PHFetchOptions()
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let all = PHAsset.fetchAssets(with: opts)
            var live = Set<String>(); live.reserveCapacity(all.count)
            let have = known()
            all.enumerateObjects { a, _, _ in
                live.insert(a.localIdentifier)
                let mod = a.modificationDate?.timeIntervalSince1970 ?? 0
                if let (_, m) = have[a.localIdentifier], abs(m - mod) < 1 { return }
                work.append(a)
            }
            for (id, (key, _)) in have where !live.contains(id) {
                try? index?.remove(key: USearchKey(key)); exec("DELETE FROM assets WHERE key=\(key)"); stats.removed += 1
            }
            stats.total = all.count
            phase("diff")
        }
        // skip what we already know is unavailable, and Lightbox's own exports
        work = work.filter { !isSkipped($0.localIdentifier, $0.modificationDate?.timeIntervalSince1970 ?? 0) }
        let ours = work.filter { Self.isOurs($0) }
        for a in ours { markSkipped(a.localIdentifier, a.modificationDate?.timeIntervalSince1970 ?? 0) }
        if !ours.isEmpty { let o = Set(ours.map(\.localIdentifier)); work.removeAll { o.contains($0.localIdentifier) } }
        stats.skipped += ours.count
        // likely matches first: Film album, then film-shaped (3:2) frames, then the rest
        func rank(_ a: PHAsset) -> Int {
            if filmSet.contains(a.localIdentifier) { return 0 }
            let r = Double(max(a.pixelWidth, a.pixelHeight)) / Double(max(1, min(a.pixelWidth, a.pixelHeight)))
            return abs(r - 1.5) < 0.06 ? 1 : 2
        }
        work.sort { rank($0) < rank($1) }
        let priorityCount = work.prefix { rank($0) == 0 }.count
        let have = known()
        phase("plan")

        let batch = 96
        var done = 0
        var firedPriority = priorityCount == 0
        while done < work.count {
            let slice = Array(work[done..<min(work.count, done + batch)])
            var out = [[Float]?](repeating: nil, count: slice.count)
            out.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: slice.count) { i in
                    if let img = Self.indexThumbnail(slice[i]) { buf[i] = Self.featurePrint(img) }
                }
            }
            phase("thumb+vision")
            exec("BEGIN")
            for (a, v) in zip(slice, out) {
                let mod = a.modificationDate?.timeIntervalSince1970 ?? 0
                guard let v else { markSkipped(a.localIdentifier, mod); stats.skipped += 1; continue }
                try upsert(a, albums: albumsOf[a.localIdentifier] ?? [], film: filmSet.contains(a.localIdentifier),
                           vector: v, replacing: have[a.localIdentifier]?.0)
                stats.added += 1
            }
            exec("COMMIT")
            phase("write")
            done += slice.count
            progress?(done, work.count)
            if !firedPriority && done >= priorityCount { firedPriority = true; count = (try? index?.count) ?? 0; onPriority?() }
        }
        if stats.added > 0 || stats.removed > 0 { try index?.save(path: indexPath) }
        if let d = try? NSKeyedArchiver.archivedData(withRootObject: tokenAtStart, requiringSecureCoding: true) {
            metaSet("change_token", d.base64EncodedString())
        }
        count = (try? index?.count) ?? 0
        phase("save")
        stats.seconds = Date().timeIntervalSince(t0)
        Self.note(String(format: "sync %@: %d to read, +%d -%d skipped %d in %.2fs %@", stats.incremental ? "incremental" : "full",
                         work.count, stats.added, stats.removed, stats.skipped, stats.seconds,
                         stats.phases.map { "\($0.key)=\(String(format: "%.2f", $0.value))" }.sorted().joined(separator: " ")))
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

    /// For the false-positive check: the same query with some assets removed from the library.
    var excluded: Set<String> = []

    struct Scored { var id: String; var distance: Double; var ncc: Double; var rotation: Int; var albums: String?; var created: Double }
    private(set) var lastScored: [Scored] = []

    // Gates, from the bench (2026-10-22, 30 Film frames + the Gold 200 frame): his real scan vs its
    // lab scan correlates 0.908 (runner-up 0.313); a frame vs a degraded copy of itself 0.97-0.999;
    // unrelated frames <= 0.79; near-identical neighbouring frames (bursts) 0.85-0.96, which no gate
    // separates from his real pair, so a clear lead over the runner-up is required too.
    static var minNCC = 0.85
    static var minMargin = 0.08
    static var duplicateNCC = 0.98
    static var maxCandidateDistance = 0.35

    /// Luminance correlation at 48 px, maximised over small crops and shifts of the candidate,
    /// because lab scans are cropped and framed a little differently from ours.
    static func alignedNCC(_ ours: CGImage, _ cand: CGImage) -> Double { alignedNCC(ours, cand, size: 48, fine: false) }

    static func alignedNCC(_ ours: CGImage, _ cand: CGImage, size S: Int, fine: Bool) -> Double {
        func gray(_ img: CGImage, _ r: CGRect?, _ s: Int) -> [Double] {
            var px = [UInt8](repeating: 0, count: s * s)
            let ctx = CGContext(data: &px, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .medium
            let src = r.flatMap { img.cropping(to: $0) } ?? img
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: s, height: s))
            let v = px.map(Double.init); let m = v.reduce(0, +) / Double(v.count)
            let c = v.map { $0 - m }; let n = sqrt(c.reduce(0) { $0 + $1 * $1 })
            return n > 0 ? c.map { $0 / n } : c
        }
        let W = Double(ours.width), H = Double(ours.height)
        let a = gray(ours, CGRect(x: W * 0.06, y: H * 0.06, width: W * 0.88, height: H * 0.88), S)
        let cw = Double(cand.width), ch = Double(cand.height)
        var best = -1.0
        let scales = fine ? Array(stride(from: 0.80, through: 1.0, by: 0.02)) : [0.80, 0.86, 0.92, 0.98]
        let shifts = fine ? Array(stride(from: -0.06, through: 0.0601, by: 0.015)) : [-0.06, -0.03, 0, 0.03, 0.06]
        for sc in scales {
            for dx in shifts { for dy in shifts {
                let w = cw * sc, h = ch * sc
                let x = (cw - w) / 2 + dx * cw, y = (ch - h) / 2 + dy * ch
                guard x >= 0, y >= 0, x + w <= cw, y + h <= ch else { continue }
                let b = gray(cand, CGRect(x: x, y: y, width: w, height: h), S)
                var d = 0.0; for i in 0..<(S * S) { d += a[i] * b[i] }
                best = max(best, d)
            } }
        }
        return best
    }

    /// Same picture or a near-identical neighbouring frame? At the best alignment, correlate 4x4
    /// tiles separately; a neighbour has moved somewhere, so its worst tiles drop while the true
    /// lab scan differs from ours only evenly (tone, grain). Returns the mean of the two worst tiles.
    static func worstTiles(_ ours: CGImage, _ cand: CGImage) -> Double {
        func gray(_ img: CGImage, _ r: CGRect?, _ s: Int) -> [Double] {
            var px = [UInt8](repeating: 0, count: s * s)
            let ctx = CGContext(data: &px, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(r.flatMap { img.cropping(to: $0) } ?? img, in: CGRect(x: 0, y: 0, width: s, height: s))
            return px.map(Double.init)
        }
        func ncc(_ a: [Double], _ b: [Double]) -> Double {
            let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
            var n = 0.0, da = 0.0, db = 0.0
            for i in a.indices { let x = a[i] - ma, y = b[i] - mb; n += x * y; da += x * x; db += y * y }
            return da > 0 && db > 0 ? n / sqrt(da * db) : 0
        }
        let S = 128, T = 4, ts = S / T
        let W = Double(ours.width), H = Double(ours.height)
        let a = gray(ours, CGRect(x: W * 0.06, y: H * 0.06, width: W * 0.88, height: H * 0.88), S)
        let cw = Double(cand.width), ch = Double(cand.height)
        var bestWhole = -2.0, bestB: [Double] = []
        for sc in stride(from: 0.80, through: 1.0, by: 0.02) {
            for dx in stride(from: -0.06, through: 0.0601, by: 0.015) { for dy in stride(from: -0.06, through: 0.0601, by: 0.015) {
                let w = cw * sc, h = ch * sc, x = (cw - w) / 2 + dx * cw, y = (ch - h) / 2 + dy * ch
                guard x >= 0, y >= 0, x + w <= cw, y + h <= ch else { continue }
                let b = gray(cand, CGRect(x: x, y: y, width: w, height: h), S)
                let v = ncc(a, b)
                if v > bestWhole { bestWhole = v; bestB = b }
            } }
        }
        guard !bestB.isEmpty else { return -1 }
        var tiles: [Double] = []
        for ty in 0..<T { for tx in 0..<T {
            var ta: [Double] = [], tb: [Double] = []
            for y in (ty * ts)..<((ty + 1) * ts) { for x in (tx * ts)..<((tx + 1) * ts) { ta.append(a[y * S + x]); tb.append(bestB[y * S + x]) } }
            // flat tiles (sky, water haze) carry no evidence either way
            let m = ta.reduce(0, +) / Double(ta.count)
            let sd = sqrt(ta.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(ta.count))
            if sd > 6 { tiles.append(ncc(ta, tb)) }
        } }
        tiles.sort()
        return tiles.count >= 2 ? (tiles[0] + tiles[1]) / 2 : (tiles.first ?? -1)
    }

    func query(_ positive: CGImage, k: Int = 20) throws -> (LabMatch?, [Candidate]) {
        openIfExists()
        guard let index, dim > 0 else { return (nil, []) }
        // 1. recall: ANN top k for each quarter turn, exact re-rank on the stored vectors
        var best: [String: Candidate] = [:]
        var turnedQ: [Int: CGImage] = [:]
        for r in 0..<4 {
            guard let turned = Develop.orient(positive, rotation: r, mirrored: false),
                  let norm = Self.normalized(turned), let q = Self.featurePrint(norm) else { continue }
            turnedQ[r] = norm
            let (keys, _) = try index.search(vector: q, count: k)
            for key in keys {
                guard let (id, v, albums, created) = vector(key: Int64(key)), !excluded.contains(id) else { continue }
                let d = Self.cosineDistance(q, v)
                if best[id].map({ d < $0.distance }) ?? true {
                    best[id] = Candidate(id: id, distance: d, rotation: r, albums: albums, created: created)
                }
            }
        }
        let ranked = best.values.sorted { $0.distance < $1.distance }
        // 2. an independent check: aligned image correlation for the closest candidates
        var scored: [Scored] = []
        for c in ranked.prefix(8) where c.distance <= Self.maxCandidateDistance {
            guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [c.id], options: nil).firstObject,
                  let th = Self.indexThumbnail(a), let q = turnedQ[c.rotation] else { continue }
            scored.append(Scored(id: c.id, distance: c.distance, ncc: Self.alignedNCC(q, th), rotation: c.rotation,
                                 albums: c.albums, created: c.created))
        }
        scored.sort { $0.ncc > $1.ncc }
        // the same photo imported twice is one photo: drop exact twins of the leader before the margin test
        if scored.count > 1, let lead = PHAsset.fetchAssets(withLocalIdentifiers: [scored[0].id], options: nil).firstObject,
           let leadTh = Self.indexThumbnail(lead) {
            scored = [scored[0]] + scored.dropFirst().filter { c in
                guard c.ncc >= Self.minNCC, let a = PHAsset.fetchAssets(withLocalIdentifiers: [c.id], options: nil).firstObject,
                      let th = Self.indexThumbnail(a) else { return true }
                return Self.alignedNCC(leadTh, th) < Self.duplicateNCC
            }
        }
        lastScored = scored
        // 3. accept only a clear winner: high correlation AND well ahead of the runner-up
        guard let top = scored.first, top.ncc >= Self.minNCC else { return (nil, ranked) }
        let second = scored.dropFirst().first?.ncc ?? 0
        let margin = top.ncc - second
        guard margin >= Self.minMargin else { return (nil, ranked) }
        let conf = max(0, min(1, 0.5 * (top.ncc - Self.minNCC) / (1 - Self.minNCC) + 0.5 * min(1, margin / 0.3)))
        let album = top.albums?.split(separator: "|").first { !$0.localizedCaseInsensitiveContains("film") }.map(String.init)
            ?? top.albums?.split(separator: "|").first.map(String.init)
        return (LabMatch(assetId: top.id, confidence: conf, distance: top.distance, structure: top.ncc, rotation: top.rotation,
                         album: album, created: Date(timeIntervalSince1970: top.created)), ranked)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
