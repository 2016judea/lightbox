TITLE: Lightbox Alternatives Grounded in Analog Practice
[paragraph] 2026-11-03 · @Aidan
[heading_2] Principle
[paragraph] Every frame opens on one rendering: the stock profile fitted to his own lab scans. Alternatives exist only where a veteran printer would genuinely hesitate, and each one is a move that printer would actually make.
[paragraph] A colour negative records more range than a print can show, and the orange mask plus the scene's light leave balance open to judgment. Labs resolve this with an operator at a scan station that works much like a digital enlarger colour head (Schlueter). Lightbox's alternatives should speak that operator's language: print density, colour filtration, paper contrast, and which tone or light to balance for. Generative "moods" are not on that list.
[heading_2] The scan-station operator's levers
[paragraph] A lab operator on a Frontier or Noritsu works a short, fixed set of controls, frame by frame, on a preview before the final scan.
[bulleted_list_item] Density. Brighter or darker print exposure. One Frontier self-scanner reports corrections running roughly −3 to +3, and makes a second, darker pass to protect red saturation (Jac & Heath).
[bulleted_list_item] C / M / Y balance. Colour filtration, used to remove casts. The same source adjusts it only sometimes, because the scanner's auto balance catches major casts.
[bulleted_list_item] Tone presets (soft / hard). Available, but that operator uses them only as a last resort because they look artificial.
[bulleted_list_item] Machine character. The choice of scanner is itself a rendering decision. Frontier: punchier contrast, warm or golden skin, deep slightly cool shadows, highlights pushed toward clipping. Noritsu: flatter, peachier skin, more neutral shadows with lifted detail, gentle highlight roll-off (Optik Oldschool, Drunk Wedding Photographer).
[bulleted_list_item] Per-frame review. Pro labs correct white balance, density, contrast, highlight protection and saturation per frame, with stock-aware interpretation (Fulltone).
[paragraph] The takeaway for Lightbox: operators adjust two things per frame (density and colour) and choose a machine or paper character per roll. Everything else is rescue work.
[heading_2] Darkroom heritage: filtration and the ring-around
[paragraph] The scan station's controls descend from RA-4 colour printing, where a printer judges a test print and corrects it with filtration and exposure.
[bulleted_list_item] Filter pack. Corrections are written as CC values in yellow, magenta and cyan, such as Y10 M15, typically in steps of 5 (dofmaster).
[bulleted_list_item] Ring-around. A printer makes one neutral print, then variations shifting yellow and magenta by 5, 10 and 20 units (cyan held at zero), plus density variations of ±5, 10 and 15%. These are mounted around the neutral print. To correct a test print, the printer finds its match on the chart and applies the opposite change (Photrio).
[bulleted_list_item] Viewing filters. Held briefly in front of a print, because the eye adapts to a cast within seconds.
[bulleted_list_item] The notebook. For the same film and paper, a printer starts from the previous filter pack. The roll carries its correction forward; frames inherit it.
[paragraph] Three lessons transfer directly: corrections have units and directions; they are judged against a neutral reference, side by side; and they are inherited across a roll.
[heading_2] Where a negative is genuinely ambiguous
[paragraph] Most frames have one good reading. These situations have several, and they are where alternatives earn their place.
[table] 
  [table_row] 
  [table_row] 
  [table_row] 
  [table_row] 
  [table_row] 
  [table_row] 
  [table_row] 
[paragraph] Your stocks map onto these directly. Superia 400 (expired) is a crossover case. CineStill-style and Candido frames under lamps are mixed-light cases. Portra 400 and 800 portraits are skin cases.
[heading_2] The alternatives Lightbox offers
[paragraph] Six kinds of alternative, each a real printer's move, each shown only when its trigger fires. The default stays at the centre; alternatives are steps away from it in named units.
[table] 
  [table_row] 
  [table_row] 
  [table_row] 
  [table_row] 
  [table_row] 
  [table_row] 
  [table_row] 
[paragraph] Two rules keep this honest:
[numbered_list_item] Step sizes come from your data. The calibration fit measures how far the lab's per-frame corrections spread for each stock. That spread sets the colour and density ring steps, so a step means "one typical lab correction" for that film.
[numbered_list_item] Accepted corrections carry forward. As in the printer's notebook, a correction accepted on one frame becomes the starting point for the next frame of the same roll.
[heading_2] UX
[paragraph] The screen behaves like a printer's bench: one print under good light, a ring-around on demand, and a notebook that remembers.
[bulleted_list_item] Default view. One rendering, on a neutral mid-grey surround, with no choices on screen. On a normal frame you go from preview to kept without making a decision.
[bulleted_list_item] A quiet flag, not a grid. When a trigger fires, a single line names the ambiguity in plain words ("Lamp and window light — which should be neutral?") with a button to compare.
[bulleted_list_item] Ring-around view. The default at the centre, the triggered alternatives around it at the same size. The labels use printer's units ("+10 Y", "+⅓ stop", "neutral shadows"), not adjectives.
[bulleted_list_item] Brief comparison. Hold to flip between the default and an alternative, rather than leaving casts on screen to stare at. This follows the viewing-filter practice: the eye adapts to a cast within seconds.
[bulleted_list_item] Roll notebook. A small panel per roll showing the current correction (for example "Y+5 M−5, +⅓ density, Noritsu-soft") and which frames used it. Corrections can be reset per frame or per roll.
[bulleted_list_item] Fine controls stay. The existing sliders remain for anything the ring doesn't cover. Their readouts move to the same units as the ring.
[bulleted_list_item] AI variations become a secondary "explore" tool. They stay available but are no longer the default view, and they're labelled as interpretations rather than corrections.
[heading_2] Scope, limits and open questions
[paragraph] Depends on calibration landing first. The default is the fitted stock profile, and the ring step sizes come from the fit's per-frame spread. Build the alternatives after the calibration prompt is done.
[paragraph] Not building:
[bulleted_list_item] A full 36-print ring-around. Show only the directions the frame is actually ambiguous along.
[bulleted_list_item] Emulation presets for stocks you didn't shoot. Lightbox renders your negative, not someone else's film.
[bulleted_list_item] Triggers that fire on every frame. If a flag appears on more than about one frame in five on a normal roll, its threshold is wrong.
[paragraph] Open questions:
[to_do] Which lab and scanner produced your Photos JPEGs? If it's a Frontier, the fitted default already carries Frontier character, and "normal" and "hard" in the character row would nearly coincide.
[to_do] Mixed-light and face detection need a method: Vision's face detection is available; illuminant splitting needs a small spike to test.
[to_do] Crossover detection: measure per-channel slope mismatch from the fitted curves, or trigger only on stocks marked expired?
[heading_2] Sources
[bulleted_list_item] Self scanning Fuji Frontier SP-3000, Jac & Heath
[bulleted_list_item] The magic Fuji Frontier SP-3000, Sebastian Schlueter
[bulleted_list_item] Frontier vs Noritsu: why film scans look different, Optik Oldschool
[bulleted_list_item] Noritsu vs Frontier: 2026 film scanner review
[bulleted_list_item] Professional film scanning and color correction techniques, Fulltone
[bulleted_list_item] Viewing filters for color printing, Photrio
[bulleted_list_item] Color bias in characteristic curve in negative films, Photrio
[bulleted_list_item] Color printing filtration quiz, dofmaster
[bulleted_list_item] Kodak Ektar 100 technical data (E-4046), Kodak

=== TABLE: Where a negative is genuinely ambiguous ===
Situation | Why there's no single answer | What a printer decides
Unusual subject key (snow, night, backlight) | Average-based exposure pulls high-key scenes grey and low-key scenes muddy | Print density: where middle grey sits
Mixed light (tungsten indoors, window plus lamp) | Only one light source can render neutral | Which light to balance for, or keep the warmth as mood
Faces | Skin and scene greys rarely balance to the same filtration | Balance on skin or on the scene's greys. Kodak forehead densities ~1.08–1.18 light, 0.93–1.03 dark (Ektar datasheet)
Crossover (expired film, some stocks) | R, G and B curves aren't parallel; per-channel linearisation | Which tone range to make neutral
Exposure placement | Dense negative holds more highlight than print can show; thin one has weak shadows | Print for shadows or for highlights
Stock character | Ektar's saturation, Portra's softness, Redscale's cast are the point | How far to neutralise toward correct

=== TABLE: The alternatives Lightbox offers ===
Alternative | Analog origin | Shown when | What varies
Density ring | Ring-around density row; scan-station density key | Subject key unusual, or negative thin or dense | Print exposure in ±⅓ and ±⅔ stop steps
Colour ring | Ring-around Y/M filtration; C/M/Y keys | Low lab-match confidence, no reliable neutral, or a cast flagged | Filtration toward Y,M,C,R,G,B in CC-style steps, only the 2-3 directions the frame is ambiguous along
Balance for the light | Printer's choice under mixed illumination | Two or more light sources detected (warm and cool regions) | Neutral for light A, neutral for light B, or keep the cast
Balance on skin | Portrait printing practice | Faces detected | Balance on skin or on the scene's greys
Balance by tone | Per-layer correction for crossover | Expired stock, or measured channel-slope mismatch | Neutral highlights, midtones or shadows
Paper and machine character | Paper contrast grade; Frontier vs Noritsu | Chosen once per roll, not per frame | Soft (Noritsu-like roll-off, open shadows), normal (fitted profile), hard (Frontier-like punch, compressed highlights)
