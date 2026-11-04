import SwiftUI
import AppKit

/// `Lightbox --snapshot <raw> <out-dir>`: opens a scan in a Store and renders the canvas (default
/// view with its flag line), the ring-around and the notebook panel to PNGs with ImageRenderer.
/// For QA when no window can be captured (a locked screen). Never touches Photos or Claude.
@MainActor
enum Snapshot {
    static func run(raw: URL, out: URL) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Store.labSearchEnabled = false; Store.variationsEnabled = false
        let st = Store()
        st.onboarded = st.onboarded
        await st.open(raw)
        await settle { st.image != nil }
        st.detectAmbiguities()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        print("ambiguities:", st.ambiguities.map { "\($0.kind.rawValue): \($0.flag) [\($0.tiles.map(\.label).joined(separator: ", "))]" })
        func shot(_ name: String, _ v: some View, _ w: CGFloat, _ h: CGFloat) {
            let r = ImageRenderer(content: v.environmentObject(st).frame(width: w, height: h)
                .background(Color(white: 0.09)).preferredColorScheme(.dark).environment(\.colorScheme, .dark))
            r.scale = 1
            guard let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t),
                  let png = b.representation(using: .png, properties: [:]) else { print("no image for", name); return }
            try? png.write(to: out.appendingPathComponent(name + ".png")); print("wrote", name)
        }
        shot("1-default", CanvasView(), 1000, 760)
        st.openRing()
        await settle { st.ringCentre != nil && st.ringImages.count == st.openAmbiguities.flatMap(\.tiles).count }
        shot("2-ring", CanvasView(), 1000, 760)
        if let a = st.openAmbiguities.first, let t = a.tiles.last {
            st.accept(t, from: a.kind)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            shot("3-accepted", CanvasView(), 1000, 760)
        }
        shot("4-notebook", NotebookPanel().padding(20), 420, 260)
        st.nextFrame()
        print("frame \(st.frameNumber) starts from:", PrinterUnits.summary(st.edit) ?? "none")
    }

    static func settle(_ ok: () -> Bool) async {
        for _ in 0..<100 where !ok() { try? await Task.sleep(nanoseconds: 100_000_000) }
    }
}
