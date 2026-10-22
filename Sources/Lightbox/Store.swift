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
    @Published var activeTip: CoachTip?
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
        phase = .scanning(0)
        do {
            try await scanner.scan(device: device, settings: .init(dpi: dpi, dust: dust), to: url) { [weak self] p in
                self?.phase = .scanning(p)
            }
            let ft = edit.filmType
            let (w, a) = try await Task.detached { () -> (RawImage, Analysis) in
                let full = try RawImage.loadPNM(url)
                let w = full.downsampled(maxSide: 2000)
                return (w, Develop.analyse(w, filmType: ft))
            }.value
            working = w
            analysis = a
            fullURL = url
            phase = .editing
            rerender()
            saveSidecar()
            if case .found = lab {} else { findLabScan() }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: url)
            phase = .previewed
        } catch {
            errorMessage = error.localizedDescription
            await checkScanner()
        }
    }

    func cancelScan() { scanner.cancel() }

    /// Opens a raw scan Lightbox (or scanimage) wrote earlier, for a re-edit.
    func open(_ url: URL) async {
        do {
            let ft = edit.filmType
            let (w, a) = try await Task.detached { () -> (RawImage, Analysis) in
                let full = try RawImage.load(url)
                let w = full.downsampled(maxSide: 2000)
                return (w, Develop.analyse(w, filmType: ft))
            }.value
            working = w; analysis = a; fullURL = url
            let side = url.deletingPathExtension().appendingPathExtension("json")
            if let d = try? Data(contentsOf: side), let s = try? JSONDecoder().decode(Sidecar.self, from: d) {
                edit = s.edit; stock = s.stock
                analysis = Develop.analyse(w, filmType: edit.filmType)
            }
            guess = FilmDetect.guess(w)
            phase = .editing
            rerender()
            findLabScan()
        } catch { errorMessage = error.localizedDescription }
    }

    func nextFrame() {
        frameNumber += 1
        let keep = edit
        edit = Edit(); edit.filmType = keep.filmType; edit.rotation = keep.rotation; edit.mirrored = keep.mirrored
        image = nil; uncropped = nil; working = nil; analysis = nil; fullURL = nil; lastExport = nil
        labTask?.cancel(); lab = .idle; labImage = nil; comparing = false
        phase = .ready
    }

    /// A new roll: frame 1, no stock, detection back on.
    func newRoll() {
        stock = ""; typeLocked = false; frameNumber = 0
        nextFrame()
    }

    // MARK: editing

    /// Called when he picks the type himself; detection then leaves the roll alone.
    func chooseFilmType(_ t: FilmType) {
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
        guard let w = working, let a = analysis else { return }
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

    func editChanged() { rerender(); if phase == .editing { saveSidecar() } }

    func rotate(_ dir: Int) {
        edit.rotation = ((edit.rotation + dir) % 4 + 4) % 4
        touched("rotate"); editChanged()
    }

    func toggleMirror() { edit.mirrored.toggle(); touched("rotate"); editChanged() }

    func startCrop() { cropping = true; touched("crop"); rerender() }

    func finishCrop(display: NRect?) {
        if let d = display { edit.crop = Develop.toRaw(d, rotation: edit.rotation, mirrored: edit.mirrored) }
        cropping = false
        editChanged()
    }

    func resetCrop() { edit.crop = nil; editChanged() }

    var displayCrop: NRect {
        Develop.toDisplay(edit.crop ?? analysis?.box ?? .full, rotation: edit.rotation, mirrored: edit.mirrored)
    }

    func resetAdjustments() {
        edit.exposure = 0; edit.warmth = 0; edit.tint = 0; edit.contrast = 0; edit.sharpen = 0
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
        touched("lab")
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
        edit.exposure = fit.exposure; edit.warmth = fit.warmth; edit.tint = fit.tint
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
        let (out, version) = Self.versionedURL(folder: fullURL.deletingLastPathComponent(), stem: frameStemFrom(fullURL), ext: ext)
        toast = "Saving…"
        let ok = await Task.detached { () -> Bool in
            guard let full = try? RawImage.load(fullURL),
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

    // MARK: coaching

    func touched(_ id: String) {
        guard let tip = CoachTip.all[id], !UserDefaults.standard.bool(forKey: "tip." + id) else { return }
        withAnimation(.easeOut(duration: 0.2)) { activeTip = tip }
    }

    func dismissTip() {
        if let t = activeTip { UserDefaults.standard.set(true, forKey: "tip." + t.id) }
        withAnimation(.easeOut(duration: 0.2)) { activeTip = nil }
    }

    func resetTips() {
        for id in CoachTip.all.keys { UserDefaults.standard.removeObject(forKey: "tip." + id) }
        onboarded = false
    }
}
