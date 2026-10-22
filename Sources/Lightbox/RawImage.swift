import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A linear scan straight off the scanner: RGB, 0...1, row-major, interleaved.
struct RawImage {
    let width: Int
    let height: Int
    var pixels: [Float]   // width * height * 3

    var pixelCount: Int { width * height }

    enum LoadError: Error, LocalizedError {
        case notPNM, unsupported(String), truncated
        var errorDescription: String? {
            switch self {
            case .notPNM: return "That file isn't a scan Lightbox can read."
            case .unsupported(let s): return "Unsupported scan format: \(s)"
            case .truncated: return "The scan file is incomplete."
            }
        }
    }

    /// Reads the binary PNM that `scanimage --format=pnm` writes (P6 colour or P5 gray, 8 or 16 bit).
    static func loadPNM(_ url: URL) throws -> RawImage {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> RawImage in
            let bytes = buf.bindMemory(to: UInt8.self)
            var i = 0
            func token() -> String {
                // skip whitespace and comments
                while i < bytes.count {
                    if bytes[i] == UInt8(ascii: "#") {
                        while i < bytes.count && bytes[i] != 10 { i += 1 }
                    } else if bytes[i] == 32 || bytes[i] == 9 || bytes[i] == 10 || bytes[i] == 13 {
                        i += 1
                    } else { break }
                }
                var s = ""
                while i < bytes.count, !(bytes[i] == 32 || bytes[i] == 9 || bytes[i] == 10 || bytes[i] == 13) {
                    s.append(Character(UnicodeScalar(bytes[i]))); i += 1
                }
                return s
            }
            let magic = token()
            guard magic == "P6" || magic == "P5" else { throw LoadError.notPNM }
            guard let w = Int(token()), let h = Int(token()), let maxv = Int(token()) else { throw LoadError.notPNM }
            i += 1 // single whitespace after maxval
            let ch = magic == "P6" ? 3 : 1
            let bps = maxv > 255 ? 2 : 1
            guard bytes.count - i >= w * h * ch * bps else { throw LoadError.truncated }
            var px = [Float](repeating: 0, count: w * h * 3)
            let scale = 1.0 / Float(maxv)
            px.withUnsafeMutableBufferPointer { out in
                for p in 0..<(w * h) {
                    for c in 0..<3 {
                        let sc = ch == 3 ? c : 0
                        let o = i + (p * ch + sc) * bps
                        let v: Float = bps == 2 ? Float(UInt16(bytes[o]) << 8 | UInt16(bytes[o + 1])) : Float(bytes[o])
                        out[p * 3 + c] = v * scale
                    }
                }
            }
            return RawImage(width: w, height: h, pixels: px)
        }
    }

    /// Reads any image ImageIO can (the 16-bit TIFF Lightbox keeps as the raw).
    static func loadImage(_ url: URL) throws -> RawImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw LoadError.unsupported(url.pathExtension) }
        let w = img.width, h = img.height
        var buf = [UInt16](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.genericRGBLinear)!
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 16,
                                      bytesPerRow: w * 8, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
            else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw LoadError.unsupported("colour space") }
        var px = [Float](repeating: 0, count: w * h * 3)
        for p in 0..<(w * h) {
            px[p * 3] = Float(buf[p * 4]) / 65535
            px[p * 3 + 1] = Float(buf[p * 4 + 1]) / 65535
            px[p * 3 + 2] = Float(buf[p * 4 + 2]) / 65535
        }
        return RawImage(width: w, height: h, pixels: px)
    }

    static func load(_ url: URL) throws -> RawImage {
        let ext = url.pathExtension.lowercased()
        if ["pnm", "ppm", "pgm"].contains(ext) { return try loadPNM(url) }
        return try loadImage(url)
    }

    /// Keeps the scan as a lossless 16-bit linear TIFF (the "HDRi raw"), so a re-edit never needs a re-scan.
    func writeRawTIFF(_ url: URL) throws {
        var buf = [UInt16](repeating: 0, count: pixelCount * 3)
        for i in 0..<buf.count { buf[i] = UInt16(max(0, min(1, pixels[i])) * 65535) }
        let data = buf.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48,
                                bytesPerRow: width * 6, space: CGColorSpace(name: CGColorSpace.genericRGBLinear)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)
        else { throw LoadError.unsupported("tiff write") }
        let props: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw LoadError.unsupported("tiff write") }
    }

    /// Box-filter downsample so the long side is at most `maxSide`; used for live editing.
    func downsampled(maxSide: Int) -> RawImage {
        let f = max(1, Int(ceil(Double(max(width, height)) / Double(maxSide))))
        if f == 1 { return self }
        let w = width / f, h = height / f
        var out = [Float](repeating: 0, count: w * h * 3)
        let inv = 1 / Float(f * f)
        pixels.withUnsafeBufferPointer { src in
            for y in 0..<h {
                for x in 0..<w {
                    var r: Float = 0, g: Float = 0, b: Float = 0
                    for dy in 0..<f {
                        var o = ((y * f + dy) * width + x * f) * 3
                        for _ in 0..<f { r += src[o]; g += src[o + 1]; b += src[o + 2]; o += 3 }
                    }
                    let d = (y * w + x) * 3
                    out[d] = r * inv; out[d + 1] = g * inv; out[d + 2] = b * inv
                }
            }
        }
        return RawImage(width: w, height: h, pixels: out)
    }
}
