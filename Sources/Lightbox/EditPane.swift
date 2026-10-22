import SwiftUI

/// The adjust pane, after Photos: a few sliders, grouped, each explained the first time it's touched.
struct EditPane: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                TipCard(ids: ["preview", "scan", "next", "lab"])

                Section("Film", tips: ["film", "stock"]) {
                    FilmChips()
                    if let why = store.look.explain {
                        Label(why, systemImage: "info.circle")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Light", tips: ["exposure", "contrast"]) {
                    AdjustSlider(id: "exposure", label: "Exposure", symbol: "sun.max", value: $store.edit.exposure)
                    AdjustSlider(id: "contrast", label: "Contrast", symbol: "circle.righthalf.filled", value: $store.edit.contrast)
                    AdjustSlider(id: "sharpen", label: "Sharpness", symbol: "triangle", value: $store.edit.sharpen)
                }

                Section("Colour", tips: ["warmth", "tint"]) {
                    AdjustSlider(id: "warmth", label: "Warmth", symbol: "thermometer.medium", value: $store.edit.warmth,
                                 track: [Color(red: 0.35, green: 0.55, blue: 1), Color(white: 0.5), Color(red: 1, green: 0.72, blue: 0.3)])
                    AdjustSlider(id: "tint", label: "Tint", symbol: "drop", value: $store.edit.tint,
                                 track: [Color(red: 0.3, green: 0.85, blue: 0.4), Color(white: 0.5), Color(red: 0.95, green: 0.35, blue: 0.85)])
                }

                Section("Crop & Rotate", tips: ["rotate", "crop"]) {
                    HStack(spacing: 8) {
                        IconButton(symbol: "rotate.left", help: "Rotate left") { store.rotate(-1) }
                        IconButton(symbol: "rotate.right", help: "Rotate right") { store.rotate(1) }
                        IconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Mirror") { store.toggleMirror() }
                        Spacer()
                        Button(store.cropping ? "Cropping…" : "Crop") { store.startCrop() }
                            .buttonStyle(QuietButton()).disabled(store.cropping)
                    }
                    if store.edit.crop != nil && !store.cropping {
                        Button("Back to auto crop") { store.resetCrop() }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
                    }
                }

                if case .found = store.lab {
                    Section("Lab scan") {
                        Toggle(isOn: $store.comparing) { Label("Compare with lab", systemImage: "rectangle.split.2x1") }
                            .toggleStyle(.switch)
                        Button { Task { await store.matchLabColour() } } label: {
                            Label("Match lab colour", systemImage: "eyedropper.halffull")
                        }
                        .buttonStyle(QuietButton())
                    }
                }

                Section("Scan", tips: ["dust", "dpi"]) {
                    Toggle(isOn: Binding(get: { store.dust }, set: { store.touched("dust"); store.dust = $0 })) {
                        Label("Remove dust", systemImage: "sparkles")
                    }
                    .toggleStyle(.switch)
                    .disabled(store.phase == .editing)
                    HStack {
                        Label("Resolution", systemImage: "square.resize").font(.system(size: 13))
                        Spacer()
                        Picker("", selection: Binding(get: { store.dpi }, set: { store.touched("dpi"); store.dpi = $0 })) {
                            ForEach([1200, 2400, 3600, 7200], id: \.self) { Text(verbatim: "\($0) dpi").tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                    .disabled(store.phase == .editing)
                    if store.phase == .editing {
                        Text("These apply to the next scan.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }

                if store.edit.exposure != 0 || store.edit.contrast != 0 || store.edit.warmth != 0 || store.edit.tint != 0 || store.edit.sharpen != 0 {
                    Button("Reset adjustments") { store.resetAdjustments() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .scrollIndicators(.never)
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.trailing, 16)
        .onChange(of: store.edit) { _, _ in store.editChanged() }
    }
}

private struct Section<Content: View>: View {
    let title: String
    let tips: Set<String>
    @ViewBuilder var content: () -> Content
    init(_ title: String, tips: Set<String> = [], @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.tips = tips; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.45))
            content()
            TipCard(ids: tips)
        }
        .padding(.top, 6)
    }
}

struct AdjustSlider: View {
    @EnvironmentObject var store: Store
    let id: String
    let label: String
    let symbol: String
    @Binding var value: Double
    var track: [Color]? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(label, systemImage: symbol).font(.system(size: 13))
                Spacer()
                Text(value == 0 ? "Auto" : String(format: "%+.0f", value * 100))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(value == 0 ? .secondary : .primary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = 0 }
            .help("Double-click to reset")
            ZStack {
                if let track {
                    LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing)
                        .frame(height: 3).clipShape(Capsule()).opacity(0.55).padding(.horizontal, 2)
                }
                Slider(value: $value, in: -1...1) { editing in if editing { store.touched(id) } }
                    .controlSize(.small)
                    .tint(track == nil ? .white : .clear)
            }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14))
                .frame(width: 34, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain).help(help)
    }
}

/// The inline coach tip: appears where you are, once, and goes when you've read it.
struct TipCard: View {
    @EnvironmentObject var store: Store
    var ids: Set<String>? = nil      // nil = show any tip
    var body: some View {
        if let tip = store.activeTip, ids?.contains(tip.id) ?? true {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "lightbulb").foregroundStyle(.yellow)
                    Text(tip.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                Text(tip.body).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.78))
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Got it") { store.dismissTip() }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor) }
            }
            .padding(14)
            .frame(maxWidth: 360)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.2)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))
            .transition(.scale(scale: 0.96).combined(with: .opacity))
            .padding(.top, 8)
        }
    }
}
