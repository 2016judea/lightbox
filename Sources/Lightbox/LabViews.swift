import SwiftUI

/// "Looking for your lab scan…" → "Lab scan found · Big Sky 2025", or gone if nothing matched.
struct LabChip: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Group {
            switch store.lab {
            case .searching(let text):
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(text)
                }
                .chipStyle()
            case .found(let m):
                Button { store.comparing.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                        Text("Lab scan found" + (m.album.map { " · \($0)" } ?? ""))
                        Text(store.comparing ? "Hide" : "Compare").foregroundStyle(Color.accentColor)
                    }
                    .chipStyle()
                }
                .buttonStyle(.plain)
                .help(String(format: "Match confidence %.0f%%", m.confidence * 100))
            case .denied:
                Text("Photos access is off, so Lightbox can't look for your lab scan")
                    .chipStyle()
            default:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.lab)
    }
}

extension View {
    func chipStyle() -> some View {
        self.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(.regularMaterial))
    }
}

/// Ours on the left, the lab's on the right, with a divider to drag.
struct CompareView: View {
    @EnvironmentObject var store: Store
    let ours: CGImage
    let lab: CGImage

    var body: some View {
        GeometryReader { geo in
            let aspect = CGFloat(ours.width) / CGFloat(ours.height)
            let fit = geo.size.width / geo.size.height > aspect
                ? CGSize(width: geo.size.height * aspect, height: geo.size.height)
                : CGSize(width: geo.size.width, height: geo.size.width / aspect)
            let x = fit.width * store.labSplit
            ZStack(alignment: .topLeading) {
                Image(decorative: lab, scale: 1).resizable().interpolation(.high).scaledToFill()
                    .frame(width: fit.width, height: fit.height).clipped()
                Image(decorative: ours, scale: 1).resizable().interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
                    .mask(alignment: .leading) { Rectangle().frame(width: x) }
                Rectangle().fill(Color.white).frame(width: 2, height: fit.height).offset(x: x - 1)
                Circle().fill(Color.white).frame(width: 28, height: 28)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.black))
                    .offset(x: x - 14, y: fit.height / 2 - 14)
                Text("Lightbox").chipStyle().padding(10)
                Text("Lab").chipStyle().padding(10).frame(width: fit.width, alignment: .trailing)
            }
            .frame(width: fit.width, height: fit.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                store.labSplit = min(1, max(0, v.location.x / fit.width))
            })
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}
