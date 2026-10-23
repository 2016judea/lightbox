import SwiftUI

/// The adjust pane, after Photos: a few sliders, grouped, each with its own reset.
struct EditPane: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Section("Film") {
                    FilmChips()
                    if let why = store.look.explain {
                        Label(why, systemImage: "info.circle")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Light") {
                    AdjustSlider(id: "exposure", label: "Exposure", symbol: "sun.max", value: $store.edit.exposure)
                    AdjustSlider(id: "contrast", label: "Contrast", symbol: "circle.righthalf.filled", value: $store.edit.contrast)
                    AdjustSlider(id: "sharpen", label: "Sharpness", symbol: "triangle", value: $store.edit.sharpen,
                                 onEditing: { on in if on { store.updateLoupe() } },
                                 onHover: { on in if on { store.updateLoupe() } else { store.hideLoupe() } })
                }

                Section("Colour") {
                    AdjustSlider(id: "warmth", label: "Warmth", symbol: "thermometer.medium", value: $store.edit.warmth,
                                 track: [Color(red: 0.35, green: 0.55, blue: 1), Color(white: 0.5), Color(red: 1, green: 0.72, blue: 0.3)])
                    AdjustSlider(id: "tint", label: "Tint", symbol: "drop", value: $store.edit.tint,
                                 track: [Color(red: 0.3, green: 0.85, blue: 0.4), Color(white: 0.5), Color(red: 0.95, green: 0.35, blue: 0.85)])
                }

                Section("Crop & Rotate") {
                    HStack(spacing: 6) {
                        IconButton(symbol: "rotate.left", help: "Rotate left") { store.rotate(-1) }
                        IconButton(symbol: "rotate.right", help: "Rotate right") { store.rotate(1) }
                        IconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Mirror") { store.toggleMirror() }
                        Spacer()
                        ResetButton(setting: .cropRotate)
                        Button(store.cropping ? "Cropping…" : "Crop") { store.startCrop() }
                            .buttonStyle(QuietButton()).disabled(store.cropping).fixedSize()
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

                Section("Dust") {
                    if store.hasIR {
                        HStack {
                            Toggle(isOn: Binding(get: { store.edit.dust }, set: { store.edit.dust = $0 })) {
                                Label("Remove dust", systemImage: "sparkles")
                            }
                            .toggleStyle(.switch)
                            if store.cleaningDust { ProgressView().controlSize(.small) }
                            Spacer()
                            ResetButton(setting: .dust)
                        }
                        if store.cleaningDust {
                            Text("Finding dust in the infrared scan…").font(.system(size: 11)).foregroundStyle(.secondary)
                        } else if let f = store.dustFraction {
                            Text(String(format: "Dust and scratches cover %.2f%% of this frame.", f * 100))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    } else if store.phase == .editing {
                        Text("This scan was made without infrared, so its dust can't be removed now.")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                        Button { Task { await store.scan() } } label: { Label("Rescan to remove dust (about 1 min)", systemImage: "arrow.clockwise") }
                            .buttonStyle(QuietButton())
                    } else {
                        Text("Dust is removed on the full scan, from its infrared pass.")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Scan") {
                    HStack {
                        Label("Resolution", systemImage: "square.resize").font(.system(size: 13))
                        Spacer()
                        Picker("", selection: Binding(get: { store.dpi }, set: { store.dpi = $0 })) {
                            ForEach([1200, 2400, 3600, 7200], id: \.self) { Text(verbatim: "\($0) dpi").tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                        ResetButton(setting: .dpi)
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
    @ViewBuilder var content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.45))
            content()
        }
        .padding(.top, 6)
    }
}

/// The small Photos-style reset: only there when the setting differs from its default.
struct ResetButton: View {
    @EnvironmentObject var store: Store
    let setting: Setting
    var body: some View {
        let on = store.isChanged(setting)
        Button { store.reset(setting) } label: {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .opacity(on ? 1 : 0)
        .allowsHitTesting(on)
    }
}

struct AdjustSlider: View {
    @EnvironmentObject var store: Store
    let id: String
    let label: String
    let symbol: String
    @Binding var value: Double
    var track: [Color]? = nil
    var onEditing: ((Bool) -> Void)? = nil
    var onHover: ((Bool) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(label, systemImage: symbol).font(.system(size: 13))
                Spacer()
                // values under half a step read as Auto, never "-0"
                let shown = (value * 100).rounded()
                Text(shown == 0 ? "Auto" : String(format: "%+.0f", shown))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(shown == 0 ? .secondary : .primary)
                if let s = Setting(rawValue: id) { ResetButton(setting: s) }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if let s = Setting(rawValue: id) { store.reset(s) } }
            ZStack {
                if let track {
                    LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing)
                        .frame(height: 3).clipShape(Capsule()).opacity(0.55).padding(.horizontal, 2)
                }
                Slider(value: $value, in: -1...1) { editing in if editing { store.recordUndo() }; onEditing?(editing) }
                    .controlSize(.small)
                    .tint(track == nil ? .white : .clear)
            }
        }
        .onHover { onHover?($0) }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain).accessibilityLabel(help)
    }
}
