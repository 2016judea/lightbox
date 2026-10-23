import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// One alternative take on the frame: a name, the reason, and the settings that make it.
struct Variation: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var why: String
    var edit: Edit
    var image: CGImage?
    var isDefault = false

    static func == (a: Variation, b: Variation) -> Bool { a.id == b.id && a.image === b.image }
}

/// Asks Claude to look at the scan and propose five good alternatives, using only the settings
/// Lightbox already has. Claude picks the values; the pixels are always made by Develop.render.
enum VariationAI {

    /// What Claude returns for one alternative. Crop is relative to the picture it was shown.
    struct Proposal: Codable {
        var name: String
        var why: String
        var exposure: Double
        var contrast: Double
        var warmth: Double
        var tint: Double
        var sharpen: Double
        var crop: Crop?
        struct Crop: Codable { var x: Double; var y: Double; var w: Double; var h: Double }
    }
    struct Reply: Codable { var variations: [Proposal] }

    enum Failure: LocalizedError {
        case noKey, http(Int, String), refused, badReply
        var errorDescription: String? {
            switch self {
            case .noKey: return "Add an Anthropic API key to ~/Library/Application Support/Lightbox/anthropic.key to get alternatives."
            case .http(let c, let m): return "Couldn't reach Claude (\(c)): \(m)"
            case .refused: return "Claude declined to suggest alternatives for this frame."
            case .badReply: return "Claude's suggestions didn't come back in a usable shape."
            }
        }
    }

    static let model = "claude-opus-5-5"

    /// The key lives outside the repo: the env var if set, else a file only this user can read.
    static var apiKey: String? {
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lightbox/anthropic.key")
        let k = (try? String(contentsOf: u, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (k?.isEmpty ?? true) ? nil : k
    }

    static let system = """
    You are a film photographer and darkroom printer looking at one frame from a 35mm roll, \
    already scanned and inverted. Your job: propose five genuinely different, good versions of \
    this picture that a thoughtful printer might make, each with a clear intent (a mood, a time \
    of day, a subject to emphasise, a print style). Look at what is actually in the frame: the \
    light, the subject, the shadows and highlights, the colour, the composition.

    You can only use these controls. Every value is -1...1, and 0 means the current render:
    - exposure: brightness. ±1 is about one stop. Small moves (±0.1-0.3) matter.
    - contrast: tonal snap. -1 is flat and soft, +1 is punchy with deep blacks.
    - warmth: blue (-1) to amber (+1). ±0.3 is already a clear shift.
    - tint: green (-1) to magenta (+1). Use sparingly; ±0.2 is a lot.
    - sharpen: -1 none, 0 lab-like, +1 crunchy grain.
    - crop: optional reframing as a rectangle in 0...1 of the picture you see (x, y from the \
    top-left, w, h). Use it when a tighter or differently balanced frame genuinely helps; keep at \
    least 60% of the width and height, and keep the 3:2 or 2:3 shape unless a square truly suits it. \
    Use null for no crop.

    Rules:
    - Five variations, each clearly different from the current render and from each other. Not \
    five small nudges in the same direction.
    - Every one must be a picture a good photographer would actually print. Nothing garish, no \
    clipped skies or crushed faces unless that is the clear intent.
    - Respect the film stock's character unless a variation is explicitly about departing from it.
    - name: two or three words, like a print label ("Quiet dusk", "Hard noon", "Close on the line").
    - why: one plain sentence, under 15 words, about what you changed and what it does for the picture.
    """

    static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["variations"],
        "properties": [
            "variations": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["name", "why", "exposure", "contrast", "warmth", "tint", "sharpen", "crop"],
                    "properties": [
                        "name": ["type": "string"],
                        "why": ["type": "string"],
                        "exposure": ["type": "number"],
                        "contrast": ["type": "number"],
                        "warmth": ["type": "number"],
                        "tint": ["type": "number"],
                        "sharpen": ["type": "number"],
                        "crop": ["anyOf": [
                            ["type": "null"],
                            ["type": "object", "additionalProperties": false,
                             "required": ["x", "y", "w", "h"],
                             "properties": ["x": ["type": "number"], "y": ["type": "number"],
                                            "w": ["type": "number"], "h": ["type": "number"]]],
                        ]],
                    ],
                ],
            ],
        ],
    ]

    static func jpeg(_ img: CGImage, maxSide: Int = 1200) -> Data? {
        let s = Double(maxSide) / Double(max(img.width, img.height))
        var src = img
        if s < 1, let ctx = CGContext(data: nil, width: Int(Double(img.width) * s), height: Int(Double(img.height) * s),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            if let r = ctx.makeImage() { src = r }
        }
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, src, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? d as Data : nil
    }

    static func propose(picture: CGImage, current: Edit, stock: String, note: String?) async throws -> [Proposal] {
        guard let key = apiKey else { throw Failure.noKey }
        guard let jpg = jpeg(picture) else { throw Failure.badReply }
        let ctx = """
        Film: \(stock.isEmpty ? current.filmType.label : stock) (\(current.filmType.label)).\
        \(note.map { " The photographer's note on this stock: \"\($0)\"." } ?? "")
        Current settings: exposure \(fmt(current.exposure)), contrast \(fmt(current.contrast)), \
        warmth \(fmt(current.warmth)), tint \(fmt(current.tint)), sharpen \(fmt(current.sharpen)).
        Give absolute values for each variation, not offsets from these.
        """
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": schema]],
            "fallbacks": "default",
            "system": system,
            "messages": [["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpg.base64EncodedString()]],
                ["type": "text", "text": ctx],
            ]]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.badReply }
        guard code == 200 else {
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "unknown error"
            throw Failure.http(code, msg)
        }
        if (obj["stop_reason"] as? String) == "refusal" { throw Failure.refused }
        let text = (obj["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(text.utf8)) else { throw Failure.badReply }
        return Array(reply.variations.prefix(5))
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    /// Turns a proposal into an Edit: values clamped to the sliders' range, and the crop (given in the
    /// picture Claude saw) mapped back into raw-scan coordinates through the current frame.
    static func edit(from p: Proposal, base: Edit, shownCrop: NRect) -> Edit {
        func c(_ v: Double) -> Double { max(-1, min(1, v.isFinite ? v : 0)) }
        var e = base
        e.exposure = c(p.exposure); e.contrast = c(p.contrast); e.warmth = c(p.warmth)
        e.tint = c(p.tint); e.sharpen = c(p.sharpen)
        if let k = p.crop, k.w.isFinite, k.h.isFinite {
            let w = max(0.6, min(1, k.w)), h = max(0.6, min(1, k.h))
            let x = max(0, min(1 - w, k.x)), y = max(0, min(1 - h, k.y))
            if w < 0.995 || h < 0.995 {
                let d = NRect(x: shownCrop.x + x * shownCrop.w, y: shownCrop.y + y * shownCrop.h,
                              w: w * shownCrop.w, h: h * shownCrop.h)
                e.crop = Develop.toRaw(d, rotation: base.rotation, mirrored: base.mirrored)
            }
        }
        return e
    }
}
