import SwiftUI

// The printer's bench on screen (docs/ALTERNATIVES.md, "UX"): one print on a neutral grey surround,
// a quiet flag line when the frame is genuinely ambiguous, a ring-around on demand, hold-to-flip,
// and the roll notebook.

/// Mid grey, about 18% reflectance in sRGB: the surround a print is judged against.
let benchGrey = Color(white: 0.46)

/// One quiet line naming the ambiguity, with Compare. Nothing at all on a normal frame.
struct FlagLine: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if let first = store.openAmbiguities.first {
            HStack(spacing: 12) {
                Text(first.flag).font(.system(size: 13))
                if store.openAmbiguities.count > 1 {
                    Text("+\(store.openAmbiguities.count - 1) more").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                Button("Compare") { store.openRing() }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
                    .keyboardShortcut("r", modifiers: [])
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.6)))
        }
    }
}

/// After an alternative is taken: press and hold to see the frame as it was, release to come back.
/// Brief on purpose: the eye adapts to a cast within seconds (the viewing-filter practice).
struct HoldToFlip: View {
    @EnvironmentObject var store: Store
    @Binding var held: Bool
    var body: some View {
        if store.beforeImage != nil {
            Text(held ? "Default" : "Hold to see the default")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(held ? 0.8 : 0.55)))
                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in held = true }.onEnded { _ in held = false })
        }
    }
}

/// The ring-around: the frame as it prints now at the centre, the open alternatives around it at the
/// same size, each labelled in printer's units. Click one to take it; press and hold one to flip the
/// centre to it.
struct RingView: View {
    @EnvironmentObject var store: Store
    @State private var held: UUID?
    @State private var pressStart: Date?

    struct Slot: Identifiable { let id: UUID; let tile: RingTile; let kind: Ambiguity.Kind }

    var slots: [Slot] {
        Array(store.openAmbiguities.flatMap { a in a.tiles.map { Slot(id: $0.id, tile: $0, kind: a.kind) } }.prefix(8))
    }

    /// Ring positions around the centre (index 4 of a 3x3 grid). A density row reads darker on the
    /// left, lighter on the right (−⅔ −⅓ | default | +⅓ +⅔); other alternatives fill above and below.
    private var order: [Int] {
        store.openAmbiguities.first?.kind == .density ? [0, 3, 5, 2, 1, 7, 6, 8] : [3, 5, 1, 7, 0, 2, 6, 8]
    }

    var body: some View {
        let s = slots
        var grid = [Slot?](repeating: nil, count: 9)
        let order = self.order
        for (i, slot) in s.enumerated() { grid[order[i]] = slot }
        return VStack(spacing: 12) {
            HStack {
                Text(store.openAmbiguities.map(\.flag).joined(separator: "   ·   "))
                    .font(.system(size: 13)).foregroundStyle(.white).lineLimit(2)
                Spacer()
                Button("Close") { store.showingRing = false }.buttonStyle(.link).keyboardShortcut(.cancelAction)
            }
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(0..<3, id: \.self) { r in
                    GridRow {
                        ForEach(0..<3, id: \.self) { c in
                            let i = r * 3 + c
                            if i == 4 { centre } else if let slot = grid[i] { tile(slot) } else { Color.clear }
                        }
                    }
                }
            }
        }
    }

    var centre: some View {
        let img = held.flatMap { store.ringImages[$0] } ?? store.ringCentre
        return VStack(spacing: 6) {
            picture(img).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.9), lineWidth: 2))
            Text(held == nil ? "Default" : (slots.first { $0.id == held }?.tile.label ?? ""))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
        }
    }

    func tile(_ s: Slot) -> some View {
        VStack(spacing: 6) {
            picture(store.ringImages[s.id])
            Text(s.tile.label).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white)
        }
        .contentShape(Rectangle())
        // a click takes it; a press held longer flips the centre to it until released
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if pressStart == nil { pressStart = Date() }; held = s.id }
            .onEnded { _ in
                let quick = Date().timeIntervalSince(pressStart ?? Date()) < 0.3
                held = nil; pressStart = nil
                if quick { store.accept(s.tile, from: s.kind) }
            })
    }

    func picture(_ img: CGImage?) -> some View {
        ZStack {
            Color.black.opacity(0.15)
            if let img { Image(decorative: img, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
            else { ProgressView().controlSize(.small) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// The roll's notebook: its character, this frame's correction, what the next frame will start from,
/// and which frames used it. Reset per frame or per roll.
struct NotebookPanel: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let now = Correction(store.edit)
        let used = store.notebook.frames(using: now).filter { $0 != store.frameNumber }
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: Binding(get: { store.notebook.character }, set: { store.setCharacter($0) })) {
                ForEach(PrintCharacter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            row("This frame", now.summary + (store.notebook.character == .normal ? "" : ", \(store.notebook.character.notebookName)"))
            if !store.frameStart.isNeutral { row("Started from", store.frameStart.summary) }
            if !used.isEmpty { row("Same as frames", frameList(used)) }
            HStack(spacing: 14) {
                Button("Reset frame") { store.resetFrame() }.disabled(now.isNeutral)
                Button("Reset roll") { store.resetRoll() }.disabled(now.isNeutral && store.notebook.carried.isNeutral && store.notebook.frames.isEmpty)
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
            Text("The next frame starts from this frame's correction.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(size: 12, weight: .medium).monospacedDigit()).multilineTextAlignment(.trailing)
        }
    }
}
