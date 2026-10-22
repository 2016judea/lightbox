import SwiftUI

/// Shows the whole frame with the crop drawn on it. Drag a corner to resize, drag inside to move.
struct CropOverlay: View {
    @EnvironmentObject var store: Store
    let image: CGImage
    let initial: NRect
    @State private var rect: NRect = .full
    @State private var dragStart: NRect?

    var body: some View {
        GeometryReader { geo in
            let fit = fitted(CGSize(width: image.width, height: image.height), in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
                // dim outside the crop
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: fit))
                    p.addRect(frameRect(fit))
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                let r = frameRect(fit)
                // rule of thirds + border
                Path { p in
                    for i in 1...2 {
                        let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                        p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 0.5).allowsHitTesting(false)
                Rectangle().stroke(Color.white, lineWidth: 1.5)
                    .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    .contentShape(Rectangle())
                    .gesture(move(fit))
                ForEach(0..<4, id: \.self) { c in
                    let pt = CGPoint(x: c % 2 == 0 ? r.minX : r.maxX, y: c < 2 ? r.minY : r.maxY)
                    Corner(index: c).frame(width: 26, height: 26)
                        .position(pt)
                        .gesture(resize(corner: c, size: fit))
                }
            }
            .frame(width: fit.width, height: fit.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .onAppear { rect = initial }
        .onReceive(NotificationCenter.default.publisher(for: .cropDone)) { _ in store.finishCrop(display: rect) }
        .onReceive(NotificationCenter.default.publisher(for: .cropReset)) { _ in
            store.edit.crop = nil
            rect = store.displayCrop
        }
    }

    func fitted(_ img: CGSize, in box: CGSize) -> CGSize {
        let s = min(box.width / img.width, box.height / img.height)
        return CGSize(width: img.width * s, height: img.height * s)
    }

    func frameRect(_ size: CGSize) -> CGRect {
        CGRect(x: rect.x * size.width, y: rect.y * size.height, width: rect.w * size.width, height: rect.h * size.height)
    }

    func move(_ size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { v in
                let s = dragStart ?? rect; if dragStart == nil { dragStart = rect }
                rect.x = min(max(0, s.x + v.translation.width / size.width), 1 - s.w)
                rect.y = min(max(0, s.y + v.translation.height / size.height), 1 - s.h)
            }
            .onEnded { _ in dragStart = nil }
    }

    func resize(corner c: Int, size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { v in
                let s = dragStart ?? rect; if dragStart == nil { dragStart = rect }
                let dx = v.translation.width / size.width, dy = v.translation.height / size.height
                let minSide = 0.1
                var x0 = s.x, y0 = s.y, x1 = s.x + s.w, y1 = s.y + s.h
                if c % 2 == 0 { x0 = min(max(0, x0 + dx), x1 - minSide) } else { x1 = max(min(1, x1 + dx), x0 + minSide) }
                if c < 2 { y0 = min(max(0, y0 + dy), y1 - minSide) } else { y1 = max(min(1, y1 + dy), y0 + minSide) }
                rect = NRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
            }
            .onEnded { _ in dragStart = nil }
    }
}

private struct Corner: View {
    let index: Int
    var body: some View {
        Path { p in
            let l: CGFloat = 16
            let ox: CGFloat = index % 2 == 0 ? 13 : 13, oy: CGFloat = 13
            let sx: CGFloat = index % 2 == 0 ? 1 : -1, sy: CGFloat = index < 2 ? 1 : -1
            p.move(to: CGPoint(x: ox, y: oy + sy * l))
            p.addLine(to: CGPoint(x: ox, y: oy))
            p.addLine(to: CGPoint(x: ox + sx * l, y: oy))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        .contentShape(Rectangle())
    }
}
