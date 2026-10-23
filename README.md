# Lightbox

**Launch:** open `/Applications/Lightbox.app` (or `build/Lightbox.app`). Rebuild with `scripts/build_app.sh --install`.

A calm Mac app for scanning your own 35mm film on a Plustek OpticFilm 8200i, in place of
SilverFast. Slide the holder in, press Preview, press Scan, keep the picture. It tells colour
negative, B&W and slide apart by itself, inverts with the film's own base as the reference, and
opens every scan already adjusted. A first-run walkthrough shows how to load and scan.

## What it does

- **Preview** at 1200 dpi (about 22 s), then **Scan** at 3600 dpi with infrared dust removal (about 61 s).
- **Film type, detected**: orange base → colour negative; neutral base with no colour → B&W; black between frames → slide.
- **Film stock**, picked once per roll from the films on aidanjude.vercel.app/films.js. Profiles for Gold 200 (tuned to a lab scan of the same frame), Redscale, CineStill 800T and expired Portra 160VC.
- **Adjust**: exposure, contrast, sharpness, warmth, tint, rotate, mirror, crop. Double-click a slider's name to reset it.
- **Keep**: JPEG or 16-bit TIFF in `~/Pictures/Lightbox/<date> <stock>/`, the untouched 16-bit raw beside it, and an "Add to Photos" button for the Film album.
- **Lab scan**: after a preview or scan, it looks through your Photos for the lab's scan of the same frame. You can compare the two with a split view, or borrow the lab's colour.

## Setup on a new Mac

1. `scripts/build_sane.sh` builds the scanner driver into `~/Library/Lightbox/sane`. The driver is
   [cschalle/OpticFilm8200i-sane](https://github.com/cschalle/OpticFilm8200i-sane) (LGPL-2.1),
   pinned to a known commit. A unit that reports USB ID `07b3:1825` uses a GL128 controller, and
   Homebrew's SANE 1.4.0 can't drive it.
2. `scripts/build_app.sh --install` builds and installs the app. It uses SwiftPM's native build
   system, because Xcode's build system can't link USearch.
3. Quit SilverFast first. Only one app can hold the scanner.

Tests: `swift test -c release --build-system native` (with full Xcode selected for XCTest). The
real-frame and lab-baseline tests read `samples/`, which is kept out of git, and skip without it.

## Lab match

The library index lives in `~/Library/Application Support/Lightbox/`. It holds a USearch HNSW graph
(cosine) over Vision feature prints, with SQLite alongside it for asset IDs, dates, albums, the
exact vectors, a change token and the photos that can't be read. Query and index images both go
through one path: JPEG, then an ImageIO thumbnail at 360 px.

It takes the 20 nearest photos by feature print and re-ranks them by image correlation, searched
over small crops and shifts. A match needs a correlation of at least 0.85 and a lead of at least
0.08 over the runner-up; exact duplicates count as one photo. Lightbox's own exports
(`frame-01.jpg`) are never candidates.

Bench run, 2026-10-22, on his library of 3,720 photos (`Lightbox --lab-bench <raw> <dir>`):

- **First build:** 25.4 s, with the Film album ready at 9.8 s.
- **Warm sync** (change token): 0.05 s.
- **Query:** 199 ms.
- **The Gold 200 frame:** finds IMG_7810 at correlation 0.908; the runner-up scores 0.313.
- **30 Film frames,** each queried with a cropped, rotated, colour-shifted copy of itself:
  - 27/30 find themselves;
  - with the frame itself removed, 2/30 match something else. Both are near-identical
    neighbouring shots that score 0.90–0.96, which no gate separates from his real pair (0.908).

Builds are signed with a local self-signed identity (`scripts/make_signing_identity.sh`), so
Photos access survives rebuilds.

See `DATA_MODEL.md` for the model, and `PARITY.md` for what was kept from SilverFast and why.

MIT licence for Lightbox's own code. The SANE backend keeps its LGPL-2.1 licence and runs as a
separate `scanimage` process.
