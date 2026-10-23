import SwiftUI

/// Six takes on the frame after a scan. The default (no changes) sits top right; Claude's five fill the
/// other places in order: two along the top, three along the bottom. Click one to edit from it.
struct VariationsView: View {
    @EnvironmentObject var store: Store

    /// Grid slots in reading order: alt 1, alt 2, default / alt 3, alt 4, alt 5.
    private var slots: [Variation?] {
        let def = store.variations.first { $0.isDefault }
        let alts = store.variations.filter { !$0.isDefault }
        func alt(_ i: Int) -> Variation? { i < alts.count ? alts[i] : nil }
        return [alt(0), alt(1), def, alt(2), alt(3), alt(4)]
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow { ForEach(0..<3, id: \.self) { tile(slots[$0]) } }
                GridRow { ForEach(3..<6, id: \.self) { tile(slots[$0]) } }
            }
        }
    }

    @ViewBuilder var header: some View {
        HStack(spacing: 10) {
            switch store.variationState {
            case .thinking:
                ProgressView().controlSize(.small)
                Text("Claude is looking at your frame…").foregroundStyle(.secondary)
            case .failed(let m):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(m).foregroundStyle(.secondary).lineLimit(2)
                Button("Try again") { store.generateVariations() }.buttonStyle(.link)
            default:
                Text("Pick a starting point").foregroundStyle(.secondary)
                Button("Five more") { store.generateVariations() }.buttonStyle(.link)
            }
            Spacer()
            Button { store.showingVariations = false } label: { Text("Close") }
                .buttonStyle(.link).keyboardShortcut(.cancelAction)
        }
        .font(.system(size: 13))
    }

    @ViewBuilder func tile(_ v: Variation?) -> some View {
        if let v { VariationTile(v: v) } else { PlaceholderTile(thinking: store.variationState == .thinking) }
    }
}

struct VariationTile: View {
    @EnvironmentObject var store: Store
    let v: Variation
    @State private var hover = false

    var body: some View {
        Button { store.chooseVariation(v) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Color.black.opacity(0.25)
                    if let img = v.image {
                        Image(decorative: img, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(hover ? 0.9 : (v.isDefault ? 0.35 : 0)), lineWidth: hover ? 2 : 1))
                HStack(spacing: 6) {
                    Text(v.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    if v.isDefault { Text("Default").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Text(v.why).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

struct PlaceholderTile: View {
    let thinking: Bool
    @State private var pulse = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(pulse ? 0.09 : 0.04))
            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06)).frame(width: 90, height: 12)
            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.04)).frame(height: 10)
        }
        .onAppear {
            guard thinking else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
