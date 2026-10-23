import Foundation
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Photos

@MainActor
final class Store: ObservableObject {
    enum Phase: Equatable {
        case checking
        case needsScanner(Scanner.Status)
        case ready
        case previewing(Double)
        case previewed
        case scanning(Double)
        case editing
    }

    @Published var phase: Phase = .checking
    @Published var edit = Edit()
    @Published var image: CGImage?
    @Published var uncropped: CGImage?        // oriented, full frame, for the crop overlay
    @Published var cropping = false
    @Published var stock: String = UserDefaults.standard.string(forKey: "stock") ?? FilmStock.defaultName {
        didSet { UserDefaults.standard.set(stock, forKey: "stock") }
    }
    @Published var dust: Bool = UserDefaults.standard.object(forKey: "dust") as? Bool ?? true {
        didSet { UserDefaults.standard.set(dust, forKey: "dust") }
    }
    @Published var dpi: Int = UserDefaults.standard.object(forKey: "dpi") as? Int ?? 3600 {
        didSet { UserDefaults.standard.set(dpi, forKey: "dpi") }
    }
    @Published var frameNumber = 1
    @Published var toast: String?
    @Published var errorMessage: String?
    @Published var guess: FilmGuess?
    /// He picked the film type by hand on this roll, so detection stops overriding it.
    @Published var typeLocked: Bool = UserDefaults.standard.bool(forKey: "typeLocked") {
        didSet { UserDefaults.standard.set(typeLocked, forKey: "typeLocked") }
    }
    @Published var onboarded: Bool = UserDefaults.standard.bool(forKey: "onboarded") {
        didSet { UserDefaults.standard.set(onboarded, forKey: "onboarded") }
    }

    /// 1200 dpi costs 5 s more than 300 (21.7 s vs 16.5 s, measured) and gives a preview that is
    /// sharp at window size, so a preview can't be mistaken for a blurry scan.
    static let previewDPI = 1200

    enum LabStatus: Equatable { case idle, searching(String), found(LabMatch), none, denied }
    @Published var lab: LabStatus = .idle
    @Published var labImage: CGImage?
    @Published var comparing = false
    @Published var labSplit: Double = 0.5
    private var labTask: Task<Void, Never>?

    let scanner = Scanner()
    private var device = ""
    private var working: RawImage?       // downsampled, for live editing
    private var full: RawImage?          // the full-resolution scan, kept for export and the loupe
    private var fullClean: RawImage?     // the same with dust removed from the infrared plane
    private var workingClean: RawImage?
    @Published var hasIR = false
    @Published var loupe: CGImage?          // 1:1 crop of the full scan, shown while sharpening
    @Published var zoomed: CGImage?         // the whole picture at 100%, on double-click
    private var focus: (x: Double, y: Double)?
    @Published var cleaningDust = false
    @Published var dustFraction: Double?
    /// The image being edited: dust-cleaned when that's on and ready.
    var displayRaw: RawImage? { (edit.dust && workingClean != nil) ? workingClean : working }
    var exportRaw: RawImage? { (edit.dust && fullClean != nil) ? fullClean : full }
    private var fullURL: URL?            // the full-resolution raw on disk
    private(set) var analysis: Analysis?
    private var renderTask: Task<Void, Never>?
    var isFull: Bool { phase == .editing }
    var look: FilmStock.Look { FilmStock.named(stock)?.look ?? .standard }

    /// Picking a stock also says what kind of film it is.
    func chooseStock(_ name: String) {
        stock = name
        if let s = FilmStock.named(name) { typeLocked = false; guess = guess ?? nil; setFilmType(s.type) }
        rerender(); if phase == .editing { saveSidecar() }
    }

    init() {
        if let f = UserDefaults.standard.string(forKey: "filmType"), let t = FilmType(rawValue: f) { edit.filmType = t }
    }

    // MARK: scanner

    func checkScanner() async {
        phase = .checking
        let s = await scanner.detect()
        if case .ready(let d) = s {
            device = d
            if image == nil { phase = .ready } else if phase == .checking { phase = working == nil ? .ready : .previewed }
        } else {
            phase = .needsScanner(s)
        }
    }

    func quitSilverFastAndRetry() async {
        Scanner.quitSilverFast()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        await checkScanner()
    }

    var sessionFolder: URL {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        var name = df.string(from: Date())
        let s = stock.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { name += " " + s.replacingOccurrences(of: "/", with: "-") }
        let u = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lightbox").appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    var frameStem: String { String(format: "frame-%02d", frameNumber) }

    func preview() async {
        guard !device.isEmpty else { await checkScanner(); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lightbox-preview.pnm")
        phase = .previewing(0)
        do {
            try await scanner.scan(device: device, settings: .init(dpi: Store.previewDPI, dust: false), to: url) { [weak self] p in
                self?.phase = .previewing(p)
            }
            let raw = try await Task.detached { try RawImage.loadPNM(url) }.value
            working = raw
            fullURL = nil
            edit.crop = nil
            let g = FilmDetect.guess(raw)
            guess = g
            if !typeLocked { edit.filmType = g.type }
            analysis = Develop.analyse(raw, filmType: edit.filmType)
            phase = .previewed
            rerender()
            findLabScan()
        } catch is CancellationError {
            phase = image == nil ? .ready : .previewed
        } catch {
            errorMessage = error.localizedDescription
            await checkScanner()
        }
    }

    func scan() async {
        guard !device.isEmpty else { await checkScanner(); return }
        let folder = sessionFolder
        let url = folder.appendingPathComponent(frameStem + "-raw.pnm")
        let irURL = Dust.irURL(for: url)
        phase = .scanning(0)
        do {
            if scanner.canCaptureIR {
                try await scanner.scanWithIR(device: device, dpi: dpi, exposure: 1.0, rgb: url, ir: irURL) { [weak self] p in
                    self?.phase = .scanning(p)
                }
            } else {
                try await scanner.scan(device: device, settings: .init(dpi: dpi, dust: dust), to: url) { [weak self] p in
                    self?.phase = .scanning(p)
                }
            }
            edit.dust = dust
            try await load(url, keepEdit: true)
            saveSidecar()
            if case .found = lab {} else { findLabScan() }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: irURL)
            phase = .previewed
        } catch {
            errorMessage = error.localizedDescription
            await checkScanner()
        }
    }

    /// Loads a full scan (and its infrared plane, if it has one) for editing.
    private func load(_ url: URL, keepEdit: Bool) async throws {
        let ft = edit.filmType
        let (f, w, a) = try await Task.detached { () -> (RawImage, RawImage, Analysis) in
            let full = try RawImage.load(url)
            let w = full.downsampled(maxSide: 2000)
            return (full, w, Develop.analyse(w, filmType: ft))
        }.value
        full = f; working = w; analysis = a; fullURL = url; focus = nil; loupe = nil; zoomed = nil
        fullClean = nil; workingClean = nil; dustFraction = nil
        let irURL = Dust.irURL(for: url)
        hasIR = FileManager.default.fileExists(atPath: irURL.path)
        phase = .editing
        rerender()
        if hasIR { cleanDust(irURL) }
    }

    /// Finds and removes dust off the main thread; the toggle shows a spinner meanwhile.
    private func cleanDust(_ irURL: URL) {
        guard let f = full else { return }
        cleaningDust = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let t0 = Date()
            guard let ir = try? Dust.loadPGM(irURL) else { await self?.dustDone(nil, nil, nil); return }
            let (clean, frac) = Dust.clean(f, ir: ir)
            let wc = clean.downsampled(maxSide: 2000)
            LabIndex.note(String(format: "dust: %.2f%% of the frame in %.1fs", frac * 100, Date().timeIntervalSince(t0)))
            await self?.dustDone(clean, wc, frac)
        }
    }

    private func dustDone(_ c: RawImage?, _ wc: RawImage?, _ f: Double?) {
        fullClean = c; workingClean = wc; dustFraction = f; cleaningDust = false
        rerender()
    }

    func cancelScan() { scanner.cancel() }

    /// Opens a raw scan Lightbox (or scanimage) wrote earlier, for a re-edit.
    func open(_ url: URL) async {
        do {
            let side = url.deletingPathExtension().appendingPathExtension("json")
            if let d = try? Data(contentsOf: side), let s = try? JSONDecoder().decode(Sidecar.self, from: d) {
                edit = s.edit; stock = s.stock
            }
            try await load(url, keepEdit: true)
            if let w = working { guess = FilmDetect.guess(w) }
            findLabScan()
        } catch { errorMessage = error.localizedDescription }
    }

    func nextFrame() {
        frameNumber += 1
        let keep = edit
        edit = Edit(); edit.filmType = keep.filmType; edit.rotation = keep.rotation; edit.mirrored = keep.mirrored
        image = nil; uncropped = nil; working = nil; analysis = nil; fullURL = nil; lastExport = nil
        full = nil; fullClean = nil; workingClean = nil; hasIR = false; dustFraction = nil
        loupe = nil; zoomed = nil; focus = nil
        labTask?.cancel(); lab = .idle; labImage = nil; comparing = false
        labMatched = nil; undoStack.removeAll(); redoStack.removeAll()
        phase = .ready
    }

    /// A new roll: frame 1, no stock, detection back on.
    func newRoll() {
        stock = ""; typeLocked = false; frameNumber = 0
        nextFrame()
    }

    // MARK: resets and undo

    /// Values from "Match lab colour", which become the reset point for exposure, warmth and tint.
    @Published var labMatched: Edit?
    private var undoStack: [Edit] = [], redoStack: [Edit] = []

    /// What each setting resets to for this frame.
    var baseline: Edit {
        var b = Edit(filmType: guess?.type ?? edit.filmType)
        if let m = labMatched { b.exposure = m.exposure; b.warmth = m.warmth; b.tint = m.tint }
        if case .found(let lm) = lab { b.rotation = lm.rotation }
        b.dust = dust
        return b
    }

    func isChanged(_ s: Setting) -> Bool {
        switch s {
        case .stock: return stock != FilmStock.defaultName
        case .dpi: return dpi != 3600
        default: return Setting.differs(s, edit, baseline)
        }
    }

    func reset(_ s: Setting) {
        recordUndo()
        switch s {
        case .stock: chooseStock(FilmStock.defaultName)
        case .dpi: dpi = 3600
        case .filmType: typeLocked = false; let t = baseline.filmType; edit = Setting.reset(s, edit, to: baseline); setFilmType(t); editChanged()
        default: edit = Setting.reset(s, edit, to: baseline); editChanged()
        }
    }

    /// Call before a discrete change (a reset, a rotate, the start of a slider drag).
    func recordUndo() {
        if undoStack.last != edit { undoStack.append(edit); if undoStack.count > 100 { undoStack.removeFirst() } }
        redoStack.removeAll()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(edit); edit = prev
        if let w = working { analysis = Develop.analyse(w, filmType: edit.filmType) }
        editChanged()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(edit); edit = next
        if let w = working { analysis = Develop.analyse(w, filmType: edit.filmType) }
        editChanged()
    }

    // MARK: editing

    /// Called when he picks the type himself; detection then leaves the roll alone.
    func chooseFilmType(_ t: FilmType) {
        recordUndo()
        typeLocked = (t != guess?.type)
        setFilmType(t)
    }

    func useDetectedType() {
        typeLocked = false
        if let g = guess { setFilmType(g.type) }
    }

    var typeIsDetected: Bool { !typeLocked && guess?.type == edit.filmType }

    func setFilmType(_ t: FilmType) {
        guard t != edit.filmType else { return }
        edit.filmType = t
        UserDefaults.standard.set(t.rawValue, forKey: "filmType")
        if let w = working { analysis = Develop.analyse(w, filmType: t) }
        rerender()
    }

    func rerender() {
        guard let w = displayRaw, let a = analysis else { return }
        let e = edit
        let look = self.look
        let wantUncropped = cropping
        renderTask?.cancel()
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let img = Develop.render(w, a, e, look: look)
            let full = wantUncropped ? Develop.render(w, a, e, crop: .full, look: look) : nil
            if Task.isCancelled { return }
            await self?.apply(img, full, wantUncropped)
        }
    }

    private func apply(_ img: CGImage?, _ full: CGImage?, _ wantUncropped: Bool) {
        image = img
        if wantUncropped { uncropped = full }
    }

    func editChanged() {
        rerender(); if phase == .editing { saveSidecar() }
        if loupe != nil { updateLoupe() }
    }

    /// The busiest detail in the frame (highest local Laplacian variance), where sharpening shows.
    private func busiestPoint() -> (Double, Double) {
        if let focus { return focus }
        guard let w = working else { return (0.5, 0.5) }
        let W = w.width, H = w.height, t = 64
        var best = (0.5, 0.5), bestV = -1.0
        let box = analysis?.box ?? .full
        for ty in stride(from: Int(box.y * Double(H)) + t, to: Int((box.y + box.h) * Double(H)) - t, by: t) {
            for tx in stride(from: Int(box.x * Double(W)) + t, to: Int((box.x + box.w) * Double(W)) - t, by: t) {
                var s = 0.0, s2 = 0.0, n = 0.0
                for y in stride(from: ty, to: ty + t, by: 2) { for x in stride(from: tx, to: tx + t, by: 2) {
                    func g(_ x: Int, _ y: Int) -> Double { Double(w.pixels[(y * W + x) * 3 + 1]) }
                    let l = g(x - 1, y) + g(x + 1, y) + g(x, y - 1) + g(x, y + 1) - 4 * g(x, y)
                    s += l; s2 += l * l; n += 1
                } }
                let v = s2 / n - (s / n) * (s / n)
                if v > bestV { bestV = v; best = ((Double(tx) + Double(t) / 2) / Double(W), (Double(ty) + Double(t) / 2) / Double(H)) }
            }
        }
        focus = best
        return best
    }

    /// Shows or refreshes the 100% loupe: a 420 px crop of the FULL scan, sharpened at export scale.
    func updateLoupe() {
        guard let f = exportRaw, let a = analysis else { return }
        let (cx, cy) = busiestPoint()
        let side = 420.0
        let r = NRect(x: max(0, min(1 - side / Double(f.width), cx - side / 2 / Double(f.width))),
                      y: max(0, min(1 - side / Double(f.height), cy - side / 2 / Double(f.height))),
                      w: side / Double(f.width), h: side / Double(f.height))
        let e = edit, look = self.look
        Task.detached(priority: .userInitiated) { [weak self] in
            let img = Develop.render(f, a, e, crop: r, look: look)
            await MainActor.run { self?.loupe = img }
        }
    }

    func hideLoupe() { loupe = nil }

    /// Double-click: the whole picture at 100% (one scan pixel per screen pixel), and back.
    func toggleZoom() {
        if zoomed != nil { zoomed = nil; return }
        guard let f = exportRaw, let a = analysis else { return }
        let e = edit, look = self.look
        toast = "Rendering at 100%…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let img = Develop.render(f, a, e, look: look)
            await MainActor.run { self?.zoomed = img; self?.toast = nil }
        }
    }

    func rotate(_ dir: Int) {
        recordUndo()
        edit.rotation = ((edit.rotation + dir) % 4 + 4) % 4
        editChanged()
    }

    func toggleMirror() { recordUndo(); edit.mirrored.toggle(); editChanged() }

    func startCrop() { cropping = true; rerender() }

    func finishCrop(display: NRect?) {
        recordUndo()
        if let d = display { edit.crop = Develop.toRaw(d, rotation: edit.rotation, mirrored: edit.mirrored) }
        cropping = false
        editChanged()
    }

    func resetCrop() { edit.crop = nil; editChanged() }

    var displayCrop: NRect {
        Develop.toDisplay(edit.crop ?? analysis?.box ?? .full, rotation: edit.rotation, mirrored: edit.mirrored)
    }

    func resetAdjustments() {
        recordUndo()
        let b = baseline
        edit.exposure = b.exposure; edit.warmth = b.warmth; edit.tint = b.tint; edit.contrast = b.contrast; edit.sharpen = b.sharpen
        editChanged()
    }

    // MARK: lab scan

    @Published var indexProgress: (done: Int, total: Int)? = nil {
        didSet { if let p = indexProgress, case .searching = lab {
            lab = .searching("Reading your Photos: \(p.done.formatted()) of \(p.total.formatted())") } }
    }

    /// At launch, if Photos access is already granted: bring the index up to date in the background,
    /// so a scan only ever needs a query. Progress shows only while the first build runs.
    /// Off in tests, which must never touch his Photos library.
    nonisolated(unsafe) static var labSearchEnabled = true

    func warmLabIndex() {
        guard Store.labSearchEnabled, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        let idx = LabIndex.shared
        Task.detached(priority: .utility) { [weak self] in
            idx.openIfExists()
            let first = !idx.isBuilt
            _ = try? await idx.sharedSync(progress: { n, t in
                if first { Task { @MainActor in self?.indexProgress = (n, t) } }
            })
            await MainActor.run { self?.indexProgress = nil }
        }
    }

    /// After a preview or scan: query straight away if the index is warm (one ANN search, ~50 ms);
    /// otherwise build it, Film album first, and try the query as soon as that part is in.
    func findLabScan() {
        guard Store.labSearchEnabled, let w = working, let a = analysis else { return }
        labTask?.cancel()
        let e0 = Edit(filmType: edit.filmType)          // raw orientation; the matcher tries all four
        let look = self.look
        lab = .searching("Looking for your lab scan…")
        labTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard await LabIndex.authorize() else { await self?.setLab(.denied, nil); return }
            let idx = LabIndex.shared
            guard let q = Develop.render(w, a, e0, crop: .full, look: look) else { return }
            let t0 = Date()
            func attempt(_ label: String) async -> Bool {
                guard let (m, _) = try? idx.query(q), let m else { return false }
                LabIndex.note(String(format: "match (%@) in %.0f ms after scan: d=%.4f s=%.3f conf=%.2f",
                                     label, Date().timeIntervalSince(t0) * 1000, m.distance, m.structure, m.confidence))
                let img = LabIndex.fullImage(m.assetId, side: 2400)
                await self?.setLab(.found(m), img)
                return true
            }
            idx.openIfExists()
            if idx.isBuilt, await attempt("warm") {
                _ = try? await idx.sharedSync()           // pick up new photos quietly, after the answer
                return
            }
            let first = !idx.isBuilt
            var found = false
            _ = try? await idx.sharedSync(progress: { n, t in
                if first { Task { @MainActor in self?.indexProgress = (n, t) } }
            }, onPriority: {
                Task { if await attempt("film album first") { found = true } }
            })
            await MainActor.run { self?.indexProgress = nil }
            if Task.isCancelled { return }
            if !found, await attempt("after sync") { return }
            if !found {
                LabIndex.note(String(format: "no match after %.1fs", Date().timeIntervalSince(t0)))
                if case .found = await self?.lab {} else { await self?.setLab(.none, nil) }
            }
        }
    }

    private func setLab(_ s: LabStatus, _ img: CGImage?) {
        lab = s; labImage = img
        if case .found(let m) = s {
            // the lab scan knows which way is up: turn ours to match if he hasn't turned it himself
            if edit.rotation == 0 && m.rotation != 0 { edit.rotation = m.rotation; rerender() }
            if phase == .editing { saveSidecar() }
        }
    }

    /// Lab scan rotated to sit the same way up as our picture on screen.
    var labOriented: CGImage? {
        guard let labImage, case .found(let m) = lab else { return nil }
        return Develop.orient(labImage, rotation: ((edit.rotation - m.rotation) % 4 + 4) % 4, mirrored: edit.mirrored)
    }

    /// Sets exposure, warmth and tint so our render lands on the lab scan's colour. Still adjustable.
    func matchLabColour() async {
        guard let w = working, let a = analysis, let lab = labOriented else { return }
        let e = edit, look = self.look
        toast = "Matching the lab's colour…"
        let (fit, before, after) = await Task.detached { LabCompare.fit(w, a, e, look: look, lab: lab) }.value
        recordUndo()
        edit.exposure = fit.exposure; edit.warmth = fit.warmth; edit.tint = fit.tint
        labMatched = edit
        editChanged()
        toast = after < before - 0.5 ? "Matched the lab's colour" : "Already close to the lab's colour"
    }

    // MARK: export

    struct Sidecar: Codable {
        var edit: Edit; var stock: String; var dpi: Int; var dust: Bool; var scannedAt: Date
        var labMatch: LabMatch? = nil
    }

    private var sidecarTask: Task<Void, Never>?

    /// Debounced, and written off the main thread: called on every edit, so never from a view body.
    func saveSidecar() {
        guard let u = fullURL else { return }
        var labMatch: LabMatch? = nil
        if case .found(let m) = lab { labMatch = m }
        let s = Sidecar(edit: edit, stock: stock, dpi: dpi, dust: dust, scannedAt: Date(), labMatch: labMatch)
        sidecarTask?.cancel()
        sidecarTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            if let d = try? JSONEncoder().encode(s) { try? d.write(to: u.deletingPathExtension().appendingPathExtension("json")) }
        }
    }

    enum Format { case jpeg, tiff }

    /// What was last written, so an unchanged picture isn't written or imported twice.
    struct ExportRecord: Equatable {
        var edit: Edit; var stock: String; var format: String; var url: URL; var version: Int; var inPhotos: Bool
    }
    @Published private(set) var lastExport: ExportRecord?
    var lastSaved: URL? { lastExport?.url }

    /// frame-01.jpg, then "frame-01 v2.jpg", "frame-01 v3.jpg"… never overwriting an earlier version.
    nonisolated static func versionedURL(folder: URL, stem: String, ext: String) -> (URL, Int) {
        let fm = FileManager.default
        let first = folder.appendingPathComponent("\(stem).\(ext)")
        if !fm.fileExists(atPath: first.path) { return (first, 1) }
        var n = 2
        while fm.fileExists(atPath: folder.appendingPathComponent("\(stem) v\(n).\(ext)").path) { n += 1 }
        return (folder.appendingPathComponent("\(stem) v\(n).\(ext)"), n)
    }

    /// Renders the CURRENT edit at full resolution. If nothing changed since the last save of this
    /// format, returns that file instead of writing a duplicate.
    @discardableResult
    func export(_ format: Format) async -> URL? {
        guard let fullURL, let a = analysis else {
            errorMessage = "Scan the frame first. The preview is too small to keep."
            return nil
        }
        let ext = format == .jpeg ? "jpg" : "tif"
        if let le = lastExport, le.edit == edit, le.stock == stock, le.format == ext,
           FileManager.default.fileExists(atPath: le.url.path) {
            toast = "Already saved" + (le.version > 1 ? " as v\(le.version)" : ""); return le.url
        }
        let e = edit, stock = self.stock, look = self.look
        let cached = exportRaw
        let (out, version) = Self.versionedURL(folder: fullURL.deletingLastPathComponent(), stem: frameStemFrom(fullURL), ext: ext)
        toast = "Saving…"
        let ok = await Task.detached { () -> Bool in
            guard let full = cached ?? (try? RawImage.load(fullURL)),
                  let img = Develop.render(full, a, e, sixteenBit: format == .tiff, look: look),
                  let dest = CGImageDestinationCreateWithURL(out as CFURL,
                        (format == .jpeg ? UTType.jpeg : UTType.tiff).identifier as CFString, 1, nil)
            else { return false }
            var props: [CFString: Any] = [
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFImageDescription: stock.isEmpty ? e.filmType.label : "\(stock) (\(e.filmType.label))",
                    kCGImagePropertyTIFFSoftware: "Lightbox",
                    kCGImagePropertyTIFFMake: "Plustek",
                    kCGImagePropertyTIFFModel: "OpticFilm 8200i",
                ] as [CFString: Any],
            ]
            if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
            else { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5, kCGImagePropertyTIFFSoftware: "Lightbox"] as [CFString: Any] }
            CGImageDestinationAddImage(dest, img, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return false }
            // this version's own sidecar, next to it; the raw's sidecar is left alone
            let side = Sidecar(edit: e, stock: stock, dpi: 0, dust: false, scannedAt: Date())
            if let d = try? JSONEncoder().encode(side) { try? d.write(to: out.deletingPathExtension().appendingPathExtension("json")) }
            return true
        }.value
        if ok {
            lastExport = ExportRecord(edit: e, stock: stock, format: ext, url: out, version: version, inPhotos: false)
            toast = "Saved" + (version > 1 ? " v\(version)" : "") + " to \(out.deletingLastPathComponent().lastPathComponent)"
        } else { toast = nil; errorMessage = "Couldn't save the picture." }
        return ok ? out : nil
    }

    private func frameStemFrom(_ raw: URL) -> String {
        let n = raw.deletingPathExtension().lastPathComponent
        return n.hasSuffix("-raw") ? String(n.dropLast(4)) : n
    }

    /// Sends a file to the Film album; returns an error message or nil. Swappable for tests.
    var photosImporter: (URL) async -> String? = { file in
        let path = file.path.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Photos"
            if not (exists album "Film") then make new album named "Film"
            import {POSIX file "\(path)"} into album "Film" skip check duplicates true
        end tell
        """
        return await Task.detached { () -> String? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
            do { try p.run() } catch { return error.localizedDescription }
            p.waitUntilExit()
            return p.terminationStatus == 0 ? nil : String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }.value
    }

    /// Always the current edit: saves a new version if anything changed, then imports that file.
    func addToPhotos() async {
        guard let file = await export(.jpeg), let rec = lastExport, rec.url == file else { return }
        if rec.inPhotos { toast = "Already in Photos"; return }
        toast = "Adding to Photos…"
        if let err = await photosImporter(file) { toast = nil; errorMessage = "Photos didn't take it: \(err)"; return }
        lastExport?.inPhotos = true
        toast = "Saved" + (rec.version > 1 ? " v\(rec.version)" : "") + " to Photos · Film"
    }

    func revealInFinder() {
        if let u = lastSaved ?? fullURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

}
