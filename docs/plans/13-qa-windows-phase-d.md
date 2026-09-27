# QA handout — Windows catch-up Phase D (Research and cutouts)

**Date:** 2026-09-27
**Build:** `release/1.4.0` @ `a264cb5` or later
**Audience:** live tester (UI + MCP). ~90 minutes.
**Related:** [Windows catch-up plan](./10-windows-catchup.md) · [Phase C handout](./12-qa-windows-phase-c.md) · [MCP setup](../MCP-Setup.md)

Research records without their file, CADC (SODA) cutouts, and cutouts cut
on this computer. Do not file the Portal, image registry or Remote Compute
screens — Phase E. Record each case as **PASS / FAIL / BLOCKED**, with the
tool JSON or a screenshot on FAIL.

## Setup

1. Build and run Verbinal from `release/1.4.0`; sign in to CADC; Settings ▸
   AI Agent: **Allow external AI agents** on; point the MCP client at the build.
2. Find in Search: a **MegaPipe** tile (collection CFHTSG — has SODA and a
   `.weight` file), an **ALMA or JCMT cube** (SODA with BAND), an **HST**
   calibrated frame (CADC does not cut its mirror), and any small image.
3. Download the MegaPipe image **and** its weight file into the same folder
   (Downloads), and download the small image.

---

## 1. Research without the file (D1)

| # | Steps | PASS if |
|---|---|---|
| 1.1 | Search ▸ a result's detail ▸ **Save to Research**. | The button turns **In Research**; Research lists it with a "not downloaded" mark; its detail says File: Not downloaded and offers **Download**. |
| 1.2 | Right-click a result ▸ **Save to Research**. | Same; greyed for one already in Research. |
| 1.3 | Add a note to the kept record; press **Download** in its detail; save. | The file downloads into the same record (same id, the note still there). |
| 1.4 | On a downloaded record: **Remove File…** ▸ confirm. | The file is gone from disk; the record, details and note stay; Download brings it back. |
| 1.5 | Delete a record without a file. | Only the record goes; nothing else on disk is touched. |
| 1.6 | Assistant: `save_observation_to_research` with a publisher id from the results. | Approved, the record appears with the result's details; again → "already in Research". |
| 1.7 | Assistant: `remove_downloaded_file` with a record's id. | It waits in Pending even with Auto-apply on (destructive); applied, the file goes and the record stays. |
| 1.8 | Assistant: `show_research_observation` by id, by publisher id, by observation id. | Research comes forward with that record selected. |

## 2. Cutouts on CADC's side (D2)

| # | Steps | PASS if |
|---|---|---|
| 2.1 | Search M31 (or the tile's target); open the MegaPipe result ▸ **Cut Out…**. | The editor opens on the file's footprint with a circle at the search target; size estimate "About … of 1.6 GB". |
| 2.2 | Type RA as `00:42:44.3`, radius `2`, then `1,5`; then move the circle off the tile. | Sexagesimal and a decimal comma are read; off the tile → "outside this file's footprint" and Download greys; half off → a warning, still allowed. |
| 2.3 | Switch to **Box**, 3′ × 2′; **Download Cutout**; save. | A few-MB `….cutout-xxxxxxxx.fits`; Research lists it as a cutout (scissors) with its region; **Original Observation** goes to the complete one when kept. |
| 2.4 | Cube result ▸ Cut Out… | Wavelength fields (nm) appear; a band outside the cube is refused; inside → a smaller cube. |
| 2.5 | Search form: tick **Spatial cutout** (and for a cube **Spectral cutout**); a result's detail. | The button reads **Download Cutout**; it downloads only the search's circle / wavelengths; the whole file when the file cannot be cut that way. |
| 2.6 | Assistant: `get_cutout_options` for the tile; `download_cutout` with a circle; a circle far off. | Options list the file, its parameters and a suggested cutout with size; the off one is refused with the reason before any approval. |
| 2.7 | Assistant: `show_cutout_editor` with a box. | The editor opens on screen on that box; the reply says what it shows. |
| 2.8 | A cutout record with its file removed ▸ **Download**. | It is cut again (not the whole file). |

## 3. Cutouts on this computer (D3)

| # | Steps | PASS if |
|---|---|---|
| 3.1 | Research ▸ the downloaded MegaPipe image ▸ **Cut Out…**. | The File picker shows "… — on this computer" (chosen) and "… — by CADC". |
| 3.2 | Cut a 1′ circle on this computer. | Instant, no network; in ds9 the cutout's stars have the same RA/Dec as in the whole tile; FITS header has LTV1/LTV2, a HISTORY line, CHECKSUM/DATASUM (ds9 or `fitsverify` says the checksum is good). |
| 3.3 | Same, ticking **Also cut** the weight file. | A `….weight.cutout-xxxxxxxx.fits` beside the cutout, same size in pixels. |
| 3.4 | A weight file from another tile renamed into the folder under the right name. | Offered greyed: "not on the same pixels". |
| 3.5 | An fpack (`.fits.fz`) MegaPipe or CFHT file downloaded ▸ cut locally. | Works; the cutout is plain FITS; memory stays low for a large file. |
| 3.6 | A multi-extension file (HST `_flt`) ▸ Cut Out… ▸ Images: tick SCI,1 only. | Only that image is kept (plus the primary header). |
| 3.7 | A downloaded cube ▸ Cut Out… with a wavelength range. | Only those channels; CRPIX3 shifted. |
| 3.8 | Assistant: `download_cutout` with `cutBy: local` (file here), then without `cutBy`, then `cutBy: soda`; with `companions: ["….weight.fits"]`. | Local when asked or left out; soda when asked; companions written beside; a local cut when the file is not here is refused with what to do. |

---

## Results log

| # | Case | Result | Notes |
|---|---|---|---|
| 1.1–1.8 | Research without the file | | |
| 2.1–2.8 | SODA cutouts | | |
| 3.1–3.8 | Local cutouts | | |

**Tester:** · **macOS:** · **MCP client:** · **Blockers:**
