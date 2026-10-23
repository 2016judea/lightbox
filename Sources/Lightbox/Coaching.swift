import Foundation

/// The first-run walkthrough. Copy follows the Plustek OpticFilm 8 Series guide v1.6.
struct WalkthroughPage: Identifiable {
    let id: Int
    let symbol: String
    let title: String
    let body: String

    static let pages: [WalkthroughPage] = [
        .init(id: 0, symbol: "film", title: "Load the strip",
              body: "Lay the film in the filmstrip holder with the dull side down and the top of the pictures toward the back of the scanner, where the cables are. The writing on the film's edge should read normally, not backwards. Snap the cover shut."),
        .init(id: 1, symbol: "arrow.right.to.line", title: "Slide it in",
              body: "Push the holder into the scanner, label side up, from either side. It clicks into each frame. Give it a gentle push and pull to make sure it has settled."),
        .init(id: 2, symbol: "eye", title: "Preview",
              body: "Press Preview. In about fifteen seconds you'll see the frame, already turned positive and cropped. Check it's centred and the right way up."),
        .init(id: 3, symbol: "circle.lefthalf.filled", title: "It reads the film",
              body: "Lightbox tells colour negative, B&W negative and slide apart from the preview, and inverts each the right way. Tell it the stock once per roll, and it remembers."),
        .init(id: 4, symbol: "camera.aperture", title: "Scan and keep",
              body: "Press Scan for the full picture, about a minute. Then save it to a folder or send it to your Film album in Photos."),
    ]
}
