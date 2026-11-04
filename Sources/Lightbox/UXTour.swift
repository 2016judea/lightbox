import SwiftUI
import AppKit

/// `Lightbox --ux-tour <photo.jpg> <out-dir>`: the real window, one PNG per step (Load, Preview,
/// Scan, Keep), with a finished positive standing in for the scan. For write-ups. Off-screen;
/// never touches the scanner, Photos or Claude.
@MainActor
enum UXTour {
    static func run(photo: URL, out: URL) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Store.labSearchEnabled = false; Store.variationsEnabled = false
        guard let src = CGImageSourceCreateWithURL(photo as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("can't read", photo.path); return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let st = Store()
        let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 860),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: ZStack { Color(white: 0.09).ignoresSafeArea(); MainView() }
            .frame(width: 1440, height: 860).environmentObject(st).preferredColorScheme(.dark))
        host.sizingOptions = []
        w.contentView = host
        w.setContentSize(NSSize(width: 1440, height: 860))
        w.orderFrontRegardless()

        func shot(_ name: String) async {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let v = w.contentView?.superview else { return }
            v.layoutSubtreeIfNeeded()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
            print("wrote", name)
        }
        st.frameNumber = 1
        st.phase = .ready;           await shot("1-load")
        st.image = img
        st.phase = .previewed;       await shot("2-preview")
        st.phase = .scanning(0.62);  await shot("3-scan")
        st.hasIR = true; st.edit.dust = true
        st.phase = .editing;         await shot("4-keep")
    }
}
