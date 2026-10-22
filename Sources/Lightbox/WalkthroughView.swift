import SwiftUI

struct WalkthroughView: View {
    @EnvironmentObject var store: Store
    @State private var page = 0
    private let pages = WalkthroughPage.pages

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            let p = pages[page]
            VStack(spacing: 28) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.06)).frame(width: 148, height: 148)
                    Image(systemName: p.symbol)
                        .font(.system(size: 58, weight: .light))
                        .foregroundStyle(.white.opacity(0.92))
                }
                Text("Step \(page + 1) of \(pages.count)")
                    .font(.system(size: 12, weight: .semibold)).tracking(1.2).textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(p.title).font(.system(size: 34, weight: .semibold, design: .default))
                Text(p.body)
                    .font(.system(size: 17)).foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center).lineSpacing(4)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(page)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            Spacer()
            HStack(spacing: 8) {
                ForEach(pages) { pg in
                    Capsule().fill(pg.id == page ? Color.white : Color.white.opacity(0.22))
                        .frame(width: pg.id == page ? 22 : 7, height: 7)
                }
            }
            .animation(.spring(duration: 0.3), value: page)
            .padding(.bottom, 28)
            HStack {
                Button("Skip") { store.onboarded = true }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .opacity(page < pages.count - 1 ? 1 : 0)
                Spacer()
                if page > 0 {
                    Button("Back") { withAnimation(.easeInOut(duration: 0.3)) { page -= 1 } }
                        .buttonStyle(QuietButton())
                }
                Button(page == pages.count - 1 ? "Start scanning" : "Continue") {
                    if page == pages.count - 1 { store.onboarded = true }
                    else { withAnimation(.easeInOut(duration: 0.3)) { page += 1 } }
                }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: 520)
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 40)
    }
}

struct PrimaryButton: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(Capsule().fill(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1)))
            .foregroundStyle(.white)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09)))
            .foregroundStyle(.white.opacity(0.9))
            .contentShape(Capsule())
    }
}
