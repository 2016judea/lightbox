import Foundation

/// One plain-words tip, shown the first time a control is touched.
struct CoachTip: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String

    static let all: [String: CoachTip] = Dictionary(uniqueKeysWithValues: [
        CoachTip(id: "film", title: "Lightbox read the film",
                 body: "It looks at the film's base: orange means colour negative, grey with no colour means B&W, black between frames means slide. If it got it wrong, pick the right one here and it sticks for the roll."),
        CoachTip(id: "stock", title: "Which film is it?",
                 body: "Pick the stock once and every frame on the roll gets it, written into the picture's details. It's on the box, the canister, or the edge of the film."),
        CoachTip(id: "exposure", title: "Exposure",
                 body: "Brighter or darker overall. The scan already sets its own black and white points, so small moves go a long way."),
        CoachTip(id: "contrast", title: "Contrast",
                 body: "Like choosing a paper grade. Left is soft and flat, right is punchy, with deeper blacks and brighter whites."),
        CoachTip(id: "sharpen", title: "Sharpness",
                 body: "Labs sharpen every scan before you see it. Lightbox does the same by default; slide left for the untouched scan, right for crisper edges and grain."),
        CoachTip(id: "warmth", title: "Warmth",
                 body: "Left for cooler and bluer, right for warmer and more golden. Use it when skin or sunlight looks off."),
        CoachTip(id: "tint", title: "Tint",
                 body: "Left for greener, right for more magenta. Fluorescent light and old film often lean green."),
        CoachTip(id: "rotate", title: "Turn it upright",
                 body: "Shots taken with the camera on its side come off the scanner sideways. Mirror fixes a strip that went in shiny side down."),
        CoachTip(id: "crop", title: "Crop",
                 body: "Lightbox already crops to the picture and drops the film's edge. Drag a corner to tighten it, or drag inside to move it."),
        CoachTip(id: "dust", title: "Dust removal",
                 body: "The scanner makes a second pass with infrared light, which sees dust and scratches but not the picture, and paints them out. It doubles the scan time. It doesn't work on B&W silver film, so leave it off for that."),
        CoachTip(id: "dpi", title: "Resolution",
                 body: "3600 is the scanner's real sharpness and about 18 megapixels. 7200 is four times the file for little more detail. 1200 is fine for the web."),
        CoachTip(id: "preview", title: "Preview first",
                 body: "A quick, small scan so you can check the frame is centred and the right way up. Every setting you change now carries into the full scan."),
        CoachTip(id: "scan", title: "The full scan",
                 body: "Takes about a minute with dust removal. The untouched scan is kept beside the picture, so you can re-edit it later without scanning again."),
        CoachTip(id: "next", title: "Next frame",
                 body: "Slide the holder until you feel it click into the next notch, then Preview. Your film type and orientation carry over."),
    ].map { ($0.id, $0) })
}

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
