import SwiftUI

/// Two chips: what kind of film (detected from the preview) and which stock (picked once per roll).
struct FilmChips: View {
    var body: some View {
        // stacked: side by side they are wider than the 290 pt pane
        VStack(alignment: .leading, spacing: 8) {
            HStack { TypeChip(); Spacer(); ResetButton(setting: .filmType) }
            HStack { StockChip(); Spacer(); ResetButton(setting: .stock) }
        }
    }
}

struct Chip: View {
    let text: String
    var detail: String? = nil
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
            Text(text).font(.system(size: 13, weight: .medium)).lineLimit(1)
            if let detail { Text("· " + detail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Color.white.opacity(0.09)))
        .contentShape(Capsule())
    }
}

struct TypeChip: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Menu {
            ForEach(FilmType.allCases) { t in
                Button { store.chooseFilmType(t) } label: {
                    if t == store.edit.filmType { Label(t.label, systemImage: "checkmark") } else { Text(t.label) }
                }
            }
            if store.typeLocked, let g = store.guess {
                Divider()
                Button("Use what Lightbox detected (\(g.type.label))") { store.useDetectedType() }
            }
        } label: {
            // a Menu label is flattened to one text run, so the "detected" note is part of it
            Text(store.edit.filmType.label + (store.typeIsDetected ? " · detected" : ""))
                .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct StockChip: View {
    @EnvironmentObject var store: Store
    @State private var open = false
    @State private var query = ""

    var matches: [FilmStock] {
        let words = query.lowercased().split(separator: " ")
        return FilmStock.all.filter { s in words.allSatisfy { (s.name + " " + (s.note ?? "")).lowercased().contains($0) } }
    }

    var body: some View {
        Button { query = ""; open = true } label: {
            Chip(text: store.stock.isEmpty ? "Film stock" : store.stock, symbol: "film")
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Search films", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                    .onSubmit { if let first = matches.first { pick(first.name) } }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { s in
                            Button { pick(s.name) } label: {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.name).font(.system(size: 13, weight: .medium))
                                        if let n = s.note {
                                            Text(n).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if s.name == store.stock { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 340)
                Divider()
                Text("Applies to every frame on this roll.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(10)
            }
            .frame(width: 300)
        }
    }

    private func pick(_ name: String) {
        store.chooseStock(name)
        open = false
    }
}
