# SilverFast 9 parity

What SilverFast 9.2.10 (installed at `/Applications/SilverFast Application/SilverFast 9/`)
actually ships for this scanner, read off its install (`components.xml`, the
`NegaFix/PlustekFilmscanner/` profiles, the strings in its binary) and the Plustek
OpticFilm 8 Series user guide v1.6. Each feature is marked **in this slice**, **later**
or **cut**.

| SilverFast feature | what it does | Lightbox | why |
|---|---|---|---|
| Prescan / preview | low-res scan to frame the shot | **in this slice** | 300 dpi in ~16 s; the first step of every scan |
| Final scan, 300 to 7200 dpi | the real scan | **in this slice** | default 3600 dpi; 7200 is offered but rarely worth it on this optics |
| NegaFix, 120 Plustek stock profiles | per-stock negative inversion | **in this slice, differently** | we sample the film base off the frame itself and normalise each channel's density, so any stock inverts without a profile. LaserSoft's profile files are proprietary and not redistributable. Per-stock looks: later. |
| Film type (colour neg / B&W neg / slide) | picks the inversion | **in this slice** | one segmented control |
| iSRD (infrared dust and scratch removal) | uses the IR channel to repair dust | **in this slice** | the backend reads IR and has its own IR repair pass (`--ir-clean`). One toggle. |
| SRDx (software dust removal, no IR) | for B&W silver film, where IR fails | later | IR does not see through silver grain, so B&W needs a different method |
| Auto Adjust (and its Brighter/Darker/Colourcast variants) | one-click levels and colour | **in this slice, as the default** | every scan opens auto-adjusted; there is no button because there is nothing to press |
| Exposure / brightness | lighter or darker | **in this slice** | one slider |
| Warmth and tint (Global Colour Correction) | colour balance | **in this slice** | two sliders instead of a colour wheel |
| Gradation curves | tonal curve per channel | cut | the contrast slider drives a print curve; per-channel curves are the palette that makes SilverFast hard |
| Histogram / levels | black and white points | cut as a control | the auto levels already set them per channel |
| Crop and rotate | framing | **in this slice** | auto-crop to the picture, rotate 90°, mirror, drag to crop |
| Multi-Exposure (two passes, shadows and highlights merged) | more dynamic range in dense slides | later | the backend has an exposure multiplier, so two passes can be merged in software |
| Multi-Sampling | average several passes to cut noise | later | same mechanism as multi-exposure |
| HDRi raw 48-bit capture | keep the unprocessed scan | **in this slice** | the 16-bit raw is kept beside every scan so a re-edit never needs a re-scan; 16-bit TIFF export |
| Batch scan / multi-frame | scan a whole strip | later | the 8200i holder is moved by hand one notch at a time; the app counts frames now, a "scan next frame" loop comes next |
| JobManager / Batch Editor | queue edits over many frames | later | copy-paste of edits first |
| GANE (grain and noise reduction) | grain removal | later | would use Core Image noise reduction |
| USM (unsharp mask) | sharpening | later | |
| AACO (shadow recovery) | lifts dark areas | cut | exposure plus the print curve's toe cover it for a personal scanner |
| Selective Colour | edit one hue | cut | out of scope for "way less complicated" |
| Densitometer | read density at a point | cut | a lab tool |
| ColorServer / Photoshop plug-in | hand-off to other apps | cut | export to Photos and a folder instead |
| IT8 colour calibration | profile the scanner | cut | needs a paid target |
| IntelliScan / QuickScan front buttons | launch software from the scanner | later | the backend exposes both buttons as sensors, so QuickScan could trigger a scan in-app |
| Send to Photos | not in SilverFast | **in this slice** | one button, into the "Film" album |
