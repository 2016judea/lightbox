# Data model: one scan session

Written from the need alone (scan his own 35mm film on a Plustek OpticFilm 8200i,
get a good positive with zero fiddling, keep it), then checked against what the
scanner and the backend can actually produce. Rule 5, `~/.claude/BUSINESS.md`.

## Entities

### Roll
The strip or set of slides being scanned. Answers: *what am I looking at, and how should it be inverted?*

| field | question it answers |
|---|---|
| `id` | which roll is this |
| `filmType` | colour negative, B&W negative, or slide (positive). Drives the inversion. |
| `stock` | e.g. "Kodak Portra 400". Written into the file's metadata; later, a per-stock look. |
| `iso` | box speed, for the caption |
| `shotOn` | camera, optional, for the caption |
| `dateShot` | when the roll was shot, so Photos files it in the right month |
| `holder` | filmstrip (6 frames) or mounted slides (4) |

### Frame
One picture on the roll. Answers: *which picture, and is it the right way up?*

| field | question it answers |
|---|---|
| `id`, `rollId` | join to its roll |
| `index` | frame number on the strip (the holder indexes by notches; the user moves it by hand) |
| `rotation` | 0/90/180/270, because a portrait shot comes off the scanner sideways |
| `mirrored` | true if the strip went in emulsion side up |
| `crop` | the picture area inside the scan, normalised 0..1. Auto-detected from the holder edges and the rebate, then adjustable. |

### Capture
What the scanner actually measured. Never changed after scanning. Answers: *what did the film really contain?*

| field | question it answers |
|---|---|
| `id`, `frameId` | join |
| `kind` | preview or full |
| `dpi` | 300 for preview, 3600 default for full (300 to 7200) |
| `bitDepth` | 16 per channel, linear, after shading correction |
| `exposure` | the backend's light multiplier, 1.0 to 4.0, for dense negatives |
| `rawPath` | the 16-bit RGB file, kept so a re-edit never needs a re-scan |
| `irPath` | the infrared plane, if captured (dust lives here) |
| `irCleaned` | whether the backend's IR dust pass was applied to the raw |
| `scannedAt` | timestamp |

### FilmBase
The orange (or clear) mask of the unexposed film. Answers: *what does "no light" look like on this stock?*

| field | question it answers |
|---|---|
| `captureId` | join |
| `rgb` | base transmittance per channel, sampled from the rebate / densest-light pixels |
| `source` | auto or picked by hand |

### Edit
The user's adjustments, small and reversible, stored as a sidecar beside the raw. Answers: *how should this picture look?*

| field | question it answers |
|---|---|
| `frameId` | join |
| `exposure` | brighter or darker, in stops of density |
| `warmth` | cooler or warmer |
| `tint` | greener or more magenta |
| `contrast` | flatter or punchier print curve |
| `dust` | remove dust and scratches using the IR plane |
| `rotation`, `mirrored`, `crop` | geometry (mirrored from Frame) |

### Export
Where the picture went. Answers: *where is my finished scan?*

| field | question it answers |
|---|---|
| `frameId` | join |
| `format` | JPEG (sharing) or 16-bit TIFF (archive) |
| `path` | the file on disk |
| `photosAlbum` | "Film" if it was sent to Photos |
| `exportedAt` | timestamp |

## Joins

Roll 1—n Frame 1—n Capture 1—1 FilmBase; Frame 1—1 Edit; Frame 1—n Export.

## Reality check (2026-10-22, on the real scanner)

| field | fillable? | how |
|---|---|---|
| Capture.raw 16-bit RGB | yes | `scanimage --mode Color --depth 16`, measured: 432x322 at 300 dpi in 16.5 s |
| Capture.ir | yes | `--mode Infrared` returns one 16-bit plane; dust and a hair are visible in it |
| Capture.irCleaned | yes | the backend's `--ir-clean` does a second IR pass and repairs the colour image |
| Capture.exposure | yes | `--exposure 1..4` |
| Capture.dpi | yes | 300, 600, 1200, 2400, 3600, 7200 |
| FilmBase.rgb | yes | measured base on a colour negative: R 0.348, G 0.153, B 0.085 of full scale |
| Frame.crop (auto) | yes | the holder reads near zero and the rebate reads at the base; the picture is between |
| Frame.index | partly | the holder is moved by hand; the backend scans one frame per start. The app counts frames, it cannot move the holder. |
| Roll.stock | user-entered | nothing on the scanner reads the edge code |
| Edit.*, Export.* | yes | ours |
| Export.photosAlbum | yes | Photos.app AppleScript `import ... into album` |

The one field that cannot be filled as specified is **Frame.index driven by the
scanner**: the 8200i has no motorised holder, so batch scanning of a strip means
the user slides the holder one notch and presses Scan again. That is how the
hardware works under SilverFast too, so it is not a reframe, just a step the app
coaches.
