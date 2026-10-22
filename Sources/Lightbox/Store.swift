import Foundation
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

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
    @Published var stock: String = UserDefaults.standard.string(forKey: "stock") ?? "" {
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
    @Published var lastSaved: URL?
    @Published var errorMessage: String?
    @Published var activeTip: CoachTip?
    @Published var onboarded: Bool = UserDefaults.standard.bool(forKey: "onboarded") {
        didSet { UserDefaults.standard.set(onboarded, forKey: "onboarded") }
    }

    let scanner = Scanner()
    private var device = ""
    private var working: RawImage?       // downsampled, for live editing
    private var fullURL: URL?            // the full-resolution raw on disk
    private(set) var analysis: Analysis?
    private var renderTask: Task<Void, Never>?
    var isFull: Bool { phase == .editing }

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
            try await scanner.scan(device: device, settings: .init(dpi: 300, dust: false), to: url) { [weak self] p in
                self?.phase = .previewing(p)
            }
            let raw = try await Task.detached { try RawImage.loadPNM(url) }.value
            working = raw
            fullURL = nil
            edit.crop = nil
            analysis = Develop.analyse(raw, filmType: edit.filmType)
            phase = .previewed
            rerender()
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
            phase = .editing
            rerender()
        } catch { errorMessage = error.localizedDescription }
    }

    func nextFrame() {
        frameNumber += 1
        let keep = edit
        edit = Edit(); edit.filmType = keep.filmType; edit.rotation = keep.rotation; edit.mirrored = keep.mirrored
        image = nil; uncropped = nil; working = nil; analysis = nil; fullURL = nil; lastSaved = nil
        phase = .ready
    }

    // MARK: editing

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
        let wantUncropped = cropping
        renderTask?.cancel()
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let img = Develop.render(w, a, e)
            let full = wantUncropped ? Develop.render(w, a, e, crop: .full) : nil
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
        edit.exposure = 0; edit.warmth = 0; edit.tint = 0; edit.contrast = 0
        editChanged()
    }

    // MARK: export

    struct Sidecar: Codable { var edit: Edit; var stock: String; var dpi: Int; var dust: Bool; var scannedAt: Date }

    func saveSidecar() {
        guard let u = fullURL else { return }
        let s = Sidecar(edit: edit, stock: stock, dpi: dpi, dust: dust, scannedAt: Date())
        if let d = try? JSONEncoder().encode(s) {
            try? d.write(to: u.deletingPathExtension().appendingPathExtension("json"))
        }
    }

    enum Format { case jpeg, tiff }

    @discardableResult
    func export(_ format: Format) async -> URL? {
        guard let fullURL, let a = analysis else {
            errorMessage = "Scan the frame first. The preview is too small to keep."
            return nil
        }
        let e = edit
        let stock = self.stock
        let ext = format == .jpeg ? "jpg" : "tif"
        let out = fullURL.deletingLastPathComponent().appendingPathComponent(frameStemFrom(fullURL) + "." + ext)
        toast = "Saving…"
        let ok = await Task.detached { () -> Bool in
            guard let full = try? RawImage.load(fullURL),
                  let img = Develop.render(full, a, e, sixteenBit: format == .tiff),
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
            return CGImageDestinationFinalize(dest)
        }.value
        if ok { lastSaved = out; toast = "Saved to \(out.deletingLastPathComponent().lastPathComponent)" }
        else { toast = nil; errorMessage = "Couldn't save the picture." }
        return ok ? out : nil
    }

    private func frameStemFrom(_ raw: URL) -> String {
        let n = raw.deletingPathExtension().lastPathComponent
        return n.hasSuffix("-raw") ? String(n.dropLast(4)) : n
    }

    func addToPhotos() async {
        var file = lastSaved
        if file == nil || file?.pathExtension != "jpg" { file = await export(.jpeg) }
        guard let file else { return }
        toast = "Adding to Photos…"
        let path = file.path.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Photos"
            if not (exists album "Film") then make new album named "Film"
            import {POSIX file "\(path)"} into album "Film" skip check duplicates true
        end tell
        """
        let result = await Task.detached { () -> String? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
            do { try p.run() } catch { return error.localizedDescription }
            p.waitUntilExit()
            return p.terminationStatus == 0 ? nil : String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }.value
        if let result { toast = nil; errorMessage = "Photos didn't take it: \(result)" }
        else { toast = "In Photos, in your Film album" }
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
