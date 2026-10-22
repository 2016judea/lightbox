import Foundation
import AppKit

/// Drives the OpticFilm 8200i through the GL128 SANE backend's `scanimage`.
/// See scripts/build_sane.sh for where that comes from.
final class Scanner {
    enum Status: Equatable {
        case unknown, ready(String), notFound, blockedBySilverFast, noDriver
    }

    struct ScanError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let prefix: URL
    private var process: Process?

    init() {
        if let env = ProcessInfo.processInfo.environment["LIGHTBOX_SANE"] {
            prefix = URL(fileURLWithPath: env)
        } else if let p = Bundle.main.object(forInfoDictionaryKey: "LBSanePrefix") as? String {
            prefix = URL(fileURLWithPath: p)
        } else {
            prefix = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Lightbox/sane")
        }
    }

    var scanimage: URL { prefix.appendingPathComponent("bin/scanimage") }
    var configDir: URL { prefix.appendingPathComponent("etc/sane.d") }

    static var silverFastRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { ($0.localizedName ?? "").localizedCaseInsensitiveContains("SilverFast") }
    }

    static func quitSilverFast() {
        for app in NSWorkspace.shared.runningApplications where (app.localizedName ?? "").localizedCaseInsensitiveContains("SilverFast") {
            app.terminate()
        }
    }

    private func makeProcess(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = scanimage
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["SANE_CONFIG_DIR"] = configDir.path
        p.environment = env
        return p
    }

    func detect() async -> Status {
        guard FileManager.default.isExecutableFile(atPath: scanimage.path) else { return .noDriver }
        if Scanner.silverFastRunning { return .blockedBySilverFast }
        let p = makeProcess(["-L"])
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return .noDriver }
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self)
        if let r = s.range(of: "plustek8200i:[^']+", options: .regularExpression) {
            return .ready(String(s[r]))
        }
        return .notFound
    }

    struct Settings {
        var dpi: Int
        var dust: Bool
        var exposure: Double = 1.0
    }

    /// Scans one frame to a 16-bit PNM. `progress` is called with 0...1 on the main thread.
    func scan(device: String, settings: Settings, to url: URL,
              progress: @escaping (Double) -> Void) async throws {
        var args = ["-d", device, "--mode", "Color", "--depth", "16",
                    "--resolution", "\(settings.dpi)", "--format=pnm", "--progress",
                    "--exposure", String(format: "%.2f", settings.exposure), "-o", url.path]
        if settings.dust { args += ["--ir-clean=yes"] }
        let p = makeProcess(args)
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        let tail = TailBuffer()
        err.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            tail.append(s)
            if let m = s.range(of: "Progress: ([0-9.]+)%", options: [.regularExpression, .backwards]) {
                let num = s[m].dropFirst(10).dropLast()
                if let v = Double(num) { DispatchQueue.main.async { progress(v / 100) } }
            }
        }
        process = p
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { proc in
                err.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 { cont.resume() }
                else if proc.terminationReason == .uncaughtSignal { cont.resume(throwing: CancellationError()) }
                else {
                    let last = tail.value.replacingOccurrences(of: "\r", with: "\n")
                        .split(separator: "\n").filter { !$0.hasPrefix("Progress") }.last.map(String.init) ?? "unknown error"
                    cont.resume(throwing: ScanError(message: "The scanner stopped: \(last)"))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
        process = nil
    }

    func cancel() { process?.terminate() }
}

/// Last 2 KB of the scanner's stderr, written from the pipe's queue, read on exit.
final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var s = ""
    func append(_ x: String) { lock.lock(); s = String((s + x).suffix(2000)); lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return s }
}
