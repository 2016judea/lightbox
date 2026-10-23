import Foundation

// The films Aidan shoots, in his order, with his notes VERBATIM.
// Origin: https://aidanjude.vercel.app/films.js (the single source of truth on his personal
// site, read 2026-10-22). Change the list there first, then here. Never rewrite the notes.
//
// The scanner can't read the stock: the 8200i's scan area is 25.4 mm tall (Plustek guide v1.6)
// against a 24 mm frame, and the edge print sits outside the sprocket holes. So it is picked
// once per roll, remembered, and written into each export's metadata.

struct FilmStock: Identifiable, Hashable {
    let name: String
    let note: String?
    let type: FilmType
    var look: Look = .standard
    var id: String { name }

    /// How the inversion treats this stock.
    struct Look: Hashable {
        /// How far to pull the three channels' medians together (0 keeps the film's colour as shot).
        var neutral: Float = 0.6
        /// Fixed warm (+) or cool (-) offset applied after balancing, in normalised density.
        var warmBias: Float = 0
        /// Fixed exposure and tint offsets, same units (tint + = magenta).
        var exposureBias: Float = 0
        var tintBias: Float = 0
        /// Output black level, 0...1, as a lab print lifts its deepest shadow.
        var outputBlack: Float = 0
        /// Print-curve steepness multiplier (1 = standard paper).
        var contrastBias: Float = 1
        /// Output white level, 0...1: below 1 keeps highlights off pure white, as lab scans do.
        var outputWhite: Float = 1
        /// Normalise each channel to its own density range. This is what removes the orange mask;
        /// off, all three share one range and the film's colour survives.
        var perChannelLevels = true
        /// Start every channel's range at the measured film base instead of at its own darkest
        /// percentile. The base still removes the mask, but a colour cast across the exposed picture
        /// (tungsten light) is no longer stretched away.
        var anchorToBase = false
        /// Colour saturation around each pixel's grey (1 = as inverted).
        var saturation: Float = 1
        /// Density fraction treated as fog and clipped to black: n' = (n - b) / (1 - b).
        var blackPoint: Float = 0
        /// One plain line for the edit pane when the profile does something on purpose.
        var explain: String? = nil
        static let standard = Look()
    }

    static let defaultName = "Kodak Gold 200"   // the roll in the scanner on 2026-10-22

    static let all: [FilmStock] = [
        // Tuned against his own lab scan of the same frame (Photos IMG_7810, Big Sky 2025) by
        // coordinate descent over seven values (GoldSearch test, 2026-10-22): quantile distance to the
        // lab 31.0 (untuned) -> 8.9 (exposure/warm/tint) -> 5.2 here. Contrast x1.24 deepens the
        // blacks, the tint moved from magenta to slightly green to take the pink out of the water,
        // and highlights stop just short of white as the lab's do.
        .init(name: "Kodak Gold 200", note: "very consistent, seldom misses the mark", type: .colorNegative,
              look: .init(neutral: 0.55, warmBias: 0.02, exposureBias: 0.12, tintBias: -0.006, contrastBias: 1.24, outputWhite: 0.995)),
        .init(name: "Black & White", note: "tone, texture, shadow", type: .bwNegative),
        // Expired: fog adds density everywhere, so blacks print grey and the colour drifts.
        // The film base is measured off the fogged frame itself; then 6% of the range is clipped as
        // fog (deeper blacks), the channel medians are pulled 85% together (undoes the drift), and
        // saturation goes up 25% (about +10% after the print curve) for his "little more pop".
        .init(name: "Kodak Portra 160VC", note: "discontinued (expired) film, think Portra elegance with a little more pop",
              type: .colorNegative, look: .init(neutral: 0.85, saturation: 1.25, blackPoint: 0.06,
                                                explain: "Portra 160VC: correcting for expired-film fog, with a little extra colour.")),
        // Shot through the base, so the red/amber IS the picture: no median balancing, and all three
        // channels share one density range so the red-heavy density survives the inversion.
        .init(name: "Redscale", note: "reds, yellows and amber… can be great in bright light", type: .colorNegative,
              look: .init(neutral: 0, perChannelLevels: false, explain: "Redscale: keeping the warm cast on purpose.")),
        .init(name: "Aurora 400", note: "faster and somewhat grainier than Gold 200", type: .colorNegative),
        .init(name: "Kodak Ultramax 400", note: "Gold’s faster, slightly rowdier cousin. More grain, punchier color", type: .colorNegative),
        .init(name: "Kodak ColorPlus 200", note: "softer, less saturated, slightly more muted/vintage", type: .colorNegative),
        .init(name: "Kodak Portra 400", note: "premium portrait film, good for up-close", type: .colorNegative),
        .init(name: "Kodak Portra 800", note: "expensive as hell, but special. Grainy without being ugly, beautiful warm rendering, and ISO 800 opens up evening/night photography", type: .colorNegative),
        .init(name: "Kodak Ektar 100", note: "sharp, saturated, rich reds/blues. Fantastic for landscapes, architecture", type: .colorNegative),
        // C-41 without remjet: tungsten balance and halation are the look. The mask is removed by the
        // measured base, each channel's range starts AT that base (so a cast across the picture
        // survives), medians are pulled only 20% together, and nothing local is done, so the red glow
        // around highlights is kept.
        .init(name: "CineStill 800T", note: "tungsten-balanced for artificial light… think neon, bars, diners, streetlights, gas stations",
              type: .colorNegative, look: .init(neutral: 0.2, anchorToBase: true,
                                                explain: "CineStill 800T: keeping the tungsten colour and the red glow around lights.")),
        .init(name: "Other colour negative", note: nil, type: .colorNegative),
    ]

    static func named(_ name: String) -> FilmStock? { all.first { $0.name == name } }
}
