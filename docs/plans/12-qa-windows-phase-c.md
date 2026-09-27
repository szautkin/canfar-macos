# QA handout — Windows catch-up Phase C (marks)

**Date:** 2026-09-27
**Build:** `release/1.4.0` @ `f5d7527` or later
**Audience:** live tester (UI + MCP). ~75 minutes.
**Related:** [Windows catch-up plan](./10-windows-catchup.md) · [Phase A handout](./11-qa-windows-phase-a.md) · [MCP setup](../MCP-Setup.md)

Marks only: drawing, editing, the Marks panel, the mark menu, cube marks,
figures with marks, and the mark tools. Do not file cutouts, Research
records without a file, or the Portal / Remote Compute screens — those are
later phases. Record each case as **PASS / FAIL / BLOCKED**, with the tool
JSON or a screenshot on FAIL.

## Setup

1. Build and run Verbinal from `release/1.4.0`. Settings ▸ AI Agent:
   **Allow external AI agents** on; point the MCP client at this build.
2. Have ready: one FITS image **with** a WCS (any CADC calibrated image),
   one **without** (or a raw frame), one multi-extension file (`*_flt.fits`),
   and one spectral cube (NAXIS3 > 1).
3. Have DS9 (or astropy `regions`) at hand for 4.x.

---

## 1. Drawing and editing on a FITS image (C1–C2)

Open the image with a WCS. Sidebar ▸ **Marks**.

| # | Steps | PASS if |
|---|---|---|
| 1.1 | Turn on **Draw**; click once on a star. | A circle appears where you clicked; a label field opens under it; the pointer over the image is a crosshair. |
| 1.2 | Type `NGC 1` and press Return. | The label shows beside the circle; the list shows `NGC 1` with `circle — hh:mm:ss.ss ±dd:mm:ss.s`. |
| 1.3 | With Draw on, press and drag outward on another star. | The circle grows with the drag and keeps the size you let go at. |
| 1.4 | Draw a **Callout**; press Escape at the label field. | The callout disappears (a callout needs words). Draw another and type `jet` — it stays, with a leader line to the words. |
| 1.5 | Draw a **Text** mark; type `note`. | The words appear at the click, no shape. |
| 1.6 | Turn Draw off. Drag a mark. | It moves with the pointer, the image does not pan; the list's position changes when you let go. |
| 1.7 | Click a mark once; drag a corner grip. | It resizes (a box takes each side; a circle stays round). Click the mark again without moving: it lets go. |
| 1.8 | Double-click a mark; change its words. | Renamed. |
| 1.9 | Select a mark; press ⌫ (Delete). | It is gone. Escape with Draw on turns Draw off. |
| 1.10 | Zoom right out, then in; rotate the view (North Up on a rotated image). | Marks keep their size on the subject, never shrink below a few points, and turn with the image. |
| 1.11 | Click beside the image (in the margin) with Draw on. | No mark. |
| 1.12 | Quit and reopen Verbinal; reopen the file (also via a different path spelling, e.g. a symlink or `~/…`). | The marks are all there. |
| 1.13 | On the multi-extension file, mark HDU 1, switch to HDU 2. | HDU 2 has its own (empty) list; HDU 1's marks come back when you return. |

## 2. The Marks panel and the mark menu (C2)

| # | Steps | PASS if |
|---|---|---|
| 2.1 | With a mark selected, change colour, **B**, label size and outline. | The selected mark changes; a slow drag across the colour wheel does not stutter. With nothing selected, the next new mark takes the style. |
| 2.2 | Make 4+ marks; type part of a label, then part of a position (`00:42`), in the filter. | Both narrow the list. |
| 2.3 | Click a list row. | The view centres on that mark and selects it. |
| 2.4 | Right-click a mark on the image, and right-click its row. | The same menu: Edit Label, Copy Position, Centre on Mark, Search Here, Export Figure Around Mark…, Export Marks as DS9/JSON…, Delete (set apart). |
| 2.5 | **Copy Position**; paste into the Search box; search. | The search runs at that position (two tokens, e.g. `00:42:44.33 +41:16:09.0`). |
| 2.6 | On the image **without** a WCS: the menu. | Search Here is greyed with a tooltip; Copy Position gives `x=…, y=… px`. New marks are pixel marks. |
| 2.7 | **Search Here**. | Search opens at the mark's position. |
| 2.8 | **Clear All** in the panel. | Asks first; then the list is empty. |

## 3. Cubes (C3)

Open the cube. Sidebar ▸ Marks section.

| # | Steps | PASS if |
|---|---|---|
| 3.1 | Slice mode: scroll, ⌘-scroll, pinch, drag, double-click. | Scroll pans; ⌘-scroll and pinch zoom toward the pointer; drag pans; double-click resets. ←/→ still step channels and Space still plays. |
| 3.2 | Click a pixel near its right/lower edge. | The spectrum probe reports that pixel's (x, y) — not its neighbour's. The cursor read-out matches. |
| 3.3 | Draw a circle on channel N; step to N+1, then back. | Only on channel N. |
| 3.4 | Centre on Mark from the list while on another channel. | The slice goes to the mark's channel and centres on it. |
| 3.5 | Switch to Volume. Orbit and zoom. | Marks sit where they are in the cube (every channel's), move with the orbit, and are drawn without grips. |
| 3.6 | Delete / Escape with a mark selected (slice). | As on the FITS image. |

## 4. Export (C1, C4)

| # | Steps | PASS if |
|---|---|---|
| 4.1 | Panel ▸ Export ▸ DS9 Regions…; load the file in DS9 on the same image/HDU. | Sky marks land on the same stars (fk5, sizes in arcsec); pixel marks too (1-based image coordinates); labels show; `{`/`}` in a label became `(`/`)`. |
| 4.2 | Export ▸ JSON…. | A file with `format: verbinal-marks`, the file path and one `extensions` entry with its `hdu` and marks. |
| 4.3 | Render panel ▸ **Export Figure…**: Region = Whole image, then View on screen; toggle **Marks**. | Preview shows the marks and labels on their stars; View shows only what is on screen; the legend's Center is the figure's centre and **Field** its size. |
| 4.4 | Mark menu ▸ **Export Figure Around Mark…**. | The sheet opens with Region "Around …" framing that mark. |
| 4.5 | Save PNG 4× and PDF. | Marks and text are crisp at 4×; the PDF opens. Saving into a folder you cannot write shows a message instead of nothing. |
| 4.6 | Cube Export Figure (slice, then volume) with Marks on. | Slice: the channel's marks on the whole slice. Volume: marks where the volume shows them. |

## 5. The assistant (C1, C3, C4)

| # | Steps | PASS if |
|---|---|---|
| 5.1 | `annotate_fits` with `raDeg`/`decDeg`, `radius` (degrees), `kind: callout`, `text`. | Drawn in the assistant's colour; the list says "— by the assistant". |
| 5.2 | `annotate_fits` with both `x`/`y` and `raDeg`/`decDeg`; with only `x`; with `channel`. | Each refused, saying why. On the image without WCS, a sky position is refused. |
| 5.3 | `list_fits_annotations` with `target` = a closed multi-extension file. | Every extension's marks, each with its `hdu`. |
| 5.4 | `update_annotation` (move, restyle), `select_annotation` (view centres, the FITS Viewer comes forward), `remove_annotation`, `clear_annotations` `allHdus`. | Each changes the screen at once. |
| 5.5 | `export_annotations` on a file with marks on two extensions, default format. | Refused (a DS9 file is one image) — suggests `hdu` or `json`; `format: json` works. |
| 5.6 | `annotate_cube` `{x, y, channel, radius}`; with `channel` past the last; with `raDeg`. | First drawn on that channel; the others refused. `list_cube_annotations` gives `channel`. `update_annotation` `viewer: cube`, `channel: N` moves it to channel N. |
| 5.7 | `export_fits_figure` with `region: mark` + `markId`; `region: sky`; `region: box`; `format: pdf`. Approve in Pending (or with Auto-apply). | Files in Downloads framed as asked. `markId` with `region: view` is refused. |
| 5.8 | `export_cube_figure` `format: pdf`, `marks: false`. | A PDF without marks. |

---

## Results log

| # | Case | Result | Notes |
|---|---|---|---|
| 1.1–1.13 | Drawing and editing | | |
| 2.1–2.8 | Panel and menu | | |
| 3.1–3.6 | Cubes | | |
| 4.1–4.6 | Export | | |
| 5.1–5.8 | Assistant | | |

**Tester:** · **macOS:** · **MCP client:** · **Blockers:**
