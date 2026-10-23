import SwiftUI

struct MainView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            StepBar().padding(.top, 14).padding(.bottom, 10)
            HStack(spacing: 0) {
                CanvasView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if store.image != nil && !isBusy {
                    EditPane()
                        .frame(width: 420)
                        .clipped()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: store.image != nil && !isBusy)
            ActionBar().padding(.vertical, 16)
        }
        .overlay(alignment: .top) { ToastView().padding(.top, 54) }
        .overlay(alignment: .bottomLeading) { LabChip().padding(.leading, 24).padding(.bottom, 24) }
    }

    var isBusy: Bool {
        switch store.phase { case .previewing, .scanning, .checking, .needsScanner: return true; default: return false }
    }
}

// MARK: step indicator

struct StepBar: View {
    @EnvironmentObject var store: Store
    private let steps = ["Load", "Preview", "Scan", "Keep"]

    var current: Int {
        switch store.phase {
        case .checking, .needsScanner, .ready: return 0
        case .previewing, .previewed: return 1
        case .scanning: return 2
        case .editing: return 3
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 6) {
                    if i == 0 && store.canGoBackToLoad {
                        LoadStepLink()
                    } else {
                        Text(s)
                            .font(.system(size: 12, weight: i == current ? .semibold : .regular))
                            .foregroundStyle(i == current ? Color.white : Color.white.opacity(i < current ? 0.55 : 0.3))
                    }
                    if i < steps.count - 1 {
                        Rectangle().fill(Color.white.opacity(0.15)).frame(width: 22, height: 1)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: current)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            Text("Frame \(store.frameNumber)")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.trailing, 20)
        }
    }
}

/// "Load" in the step bar, clickable once you're past it.
struct LoadStepLink: View {
    @EnvironmentObject var store: Store
    @State private var hover = false
    var body: some View {
        Button { store.backToLoad() } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                Text("Load").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(hover ? 1 : 0.7))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(hover ? 0.14 : 0.06)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("Back to Load")
    }
}

// MARK: canvas

struct CanvasView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ZStack {
            switch store.phase {
            case .checking:
                ProgressView().controlSize(.large)
            case .needsScanner(let s):
                ScannerMissingView(status: s)
            case .ready:
                ReadyView()
            case .previewing(let p):
                if let img = store.image { ImageView(image: img).opacity(0.35).blur(radius: 6) }
                BusyView(title: "Previewing", detail: "About 15 seconds", progress: p)
            case .scanning(let p):
                if let img = store.image { ImageView(image: img).opacity(0.35).blur(radius: 6) }
                BusyView(title: "Scanning at \(store.dpi) dpi",
                         detail: store.dust ? "About a minute, with dust removal" : "About 35 seconds", progress: p)
            case .previewed, .editing:
                if store.showingVariations && store.phase == .editing {
                    VariationsView()
                } else if store.cropping, let full = store.uncropped {
                    CropOverlay(image: full, initial: store.displayCrop)
                } else if store.comparing, let img = store.image, let lab = store.labOriented {
                    CompareView(ours: img, lab: lab)
                } else if let z = store.zoomed {
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: z, scale: NSScreen.main?.backingScaleFactor ?? 2)
                    }
                    .onTapGesture(count: 2) { store.toggleZoom() }
                    .overlay(alignment: .topLeading) { Text("100%  ·  double-click to fit").chipStyle().padding(12) }
                } else if let img = store.image {
                    ImageView(image: img)
                        .onTapGesture(count: 2) { if store.phase == .editing { store.toggleZoom() } }
                        .overlay(alignment: .topTrailing) {
                            if let l = store.loupe {
                                Image(decorative: l, scale: NSScreen.main?.backingScaleFactor ?? 2)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.8), lineWidth: 1.5))
                                    .overlay(alignment: .topLeading) { Text("100%").chipStyle().padding(8) }
                                    .shadow(radius: 12).padding(12)
                                    .transition(.opacity)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if store.phase == .previewed {
                                Text(verbatim: "Preview · \(Store.previewDPI) dpi. Scan for the full picture.")
                                    .chipStyle().padding(12)
                            }
                        }
                }
            }
        }
        .padding(24)
    }
}

struct ImageView: View {
    let image: CGImage
    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
    }
}

struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol).font(.system(size: 54, weight: .light)).foregroundStyle(.white.opacity(0.85))
            Text(title).font(.system(size: 26, weight: .semibold))
            Text(detail).font(.system(size: 15)).foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            actions().padding(.top, 8)
        }
    }
}

struct ScannerMissingView: View {
    @EnvironmentObject var store: Store
    let status: Scanner.Status
    var body: some View {
        switch status {
        case .blockedBySilverFast:
            EmptyState(symbol: "hand.raised", title: "SilverFast has the scanner",
                       detail: "Only one app can talk to the scanner at a time. Quit SilverFast and Lightbox will pick it up.") {
                Button("Quit SilverFast") { Task { await store.quitSilverFastAndRetry() } }.buttonStyle(PrimaryButton())
            }
        case .noDriver:
            EmptyState(symbol: "wrench.and.screwdriver", title: "The scanner driver isn't installed",
                       detail: "Run scripts/build_sane.sh in the Lightbox folder once, then try again.") {
                Button("Try again") { Task { await store.checkScanner() } }.buttonStyle(QuietButton())
            }
        default:
            EmptyState(symbol: "powerplug", title: "Turn on the scanner",
                       detail: "Plug the OpticFilm into this Mac (not a hub) and press its power button. The light on the front should glow.") {
                Button("Look again") { Task { await store.checkScanner() } }.buttonStyle(QuietButton())
            }
        }
    }
}

struct ReadyView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        EmptyState(symbol: "film", title: store.frameNumber == 1 ? "Slide the holder in" : "Move to the next frame",
                   detail: store.frameNumber == 1
                   ? "Dull side of the film down, label side of the holder up. Push until it clicks into a frame."
                   : "Slide the holder until it clicks into the next notch.") {
            VStack(spacing: 10) {
                StockChip()
                Text("Lightbox works out colour, B&W or slide from the preview.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

struct BusyView: View {
    @EnvironmentObject var store: Store
    let title: String
    let detail: String
    let progress: Double
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 5)
                Circle().trim(from: 0, to: max(0.02, progress))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.4), value: progress)
                Text("\(Int(progress * 100))%").font(.system(size: 17, weight: .medium).monospacedDigit())
            }
            .frame(width: 92, height: 92)
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(detail).font(.system(size: 14)).foregroundStyle(.secondary)
            Button("Cancel") { store.cancelScan() }.buttonStyle(QuietButton()).padding(.top, 4)
        }
    }
}

// MARK: bottom actions — one primary action per step

struct ActionBar: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 12) {
            switch store.phase {
            case .ready:
                Button { Task { await store.preview() } } label: {
                    Label("Preview", systemImage: "eye")
                }.buttonStyle(PrimaryButton()).keyboardShortcut(.return, modifiers: [])
            case .previewed:
                if store.cropping { cropButtons } else {
                    Button { store.backToLoad() } label: { Label("Load another strip", systemImage: "chevron.left") }
                        .buttonStyle(QuietButton())
                        .keyboardShortcut(.leftArrow, modifiers: .command)
                    // Esc does the same
                    Button("") { store.backToLoad() }.keyboardShortcut(.cancelAction).frame(width: 0, height: 0).opacity(0)
                    Button("Preview again") { Task { await store.preview() } }.buttonStyle(QuietButton())
                    Button { Task { await store.scan() } } label: {
                        Label("Scan", systemImage: "camera.aperture")
                    }.buttonStyle(PrimaryButton()).keyboardShortcut(.return, modifiers: [])
                }
            case .editing:
                if store.cropping { cropButtons } else {
                    Button { store.nextFrame() } label: { Label("Next frame", systemImage: "arrow.right") }
                        .buttonStyle(QuietButton())
                    Button { store.showingVariations.toggle() } label: {
                        Label(store.showingVariations ? "Back to edit" : "Alternatives", systemImage: "square.grid.3x2")
                    }
                    .buttonStyle(QuietButton())
                    .disabled(store.variations.isEmpty)
                    Button { Task { await store.export(.jpeg) } } label: { Label("Save", systemImage: "square.and.arrow.down") }
                        .buttonStyle(QuietButton())
                    Button { Task { await store.addToPhotos() } } label: { Label("Add to Photos", systemImage: "photo.on.rectangle") }
                        .buttonStyle(PrimaryButton())
                }
            default:
                EmptyView()
            }
        }
        .frame(height: 40)
    }

    @ViewBuilder var cropButtons: some View {
        Button("Reset") { NotificationCenter.default.post(name: .cropReset, object: nil) }.buttonStyle(QuietButton())
        Button("Done") { NotificationCenter.default.post(name: .cropDone, object: nil) }
            .buttonStyle(PrimaryButton()).keyboardShortcut(.return, modifiers: [])
    }
}

struct ToastView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Group {
            if let t = store.toast {
                HStack(spacing: 10) {
                    Text(t).font(.system(size: 13, weight: .medium))
                    if store.lastSaved != nil && !t.hasSuffix("…") {
                        Button("Show") { store.revealInFinder() }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Capsule().fill(.regularMaterial))
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: t) {
                    if !t.hasSuffix("…") {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        if store.toast == t { withAnimation { store.toast = nil } }
                    }
                }
            }
        }
        .animation(.spring(duration: 0.35), value: store.toast)
    }
}

extension Notification.Name {
    static let cropDone = Notification.Name("lightbox.cropDone")
    static let cropReset = Notification.Name("lightbox.cropReset")
}
