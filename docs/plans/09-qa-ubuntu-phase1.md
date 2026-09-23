# QA handout — Ubuntu catch-up Phase 1 (correctness)

**Date:** 2026-09-20  
**Build:** `release/1.3.4` @ `63342ef` (or later on the same branch)  
**Audience:** live tester (UI + MCP). Not a unit-test checklist.  
**Time:** ~60–90 minutes.  
**Related:** [Ubuntu catch-up plan](./08-ubuntu-catchup.md) · [MCP setup](../MCP-Setup.md)

This pass covers the Phase 1 **bug fixes only**. Do not file “missing marks / `get_fits_image` / `list_apps` / adaptive poll” — those are later phases.

Record each case as **PASS / FAIL / BLOCKED**. On FAIL, attach the tool JSON (or a screenshot) and the exact publisher / file id.

---

## Setup

1. Build and run Verbinal from `release/1.3.4` (`63342ef` or later).
2. Settings ▸ Agents: **Allow external AI agents** ON.
3. Point the MCP client at this build’s `canfar-mcp` ([MCP setup](../MCP-Setup.md)). Restart the client after switching binaries.
4. Sign in to CADC (needed for downloads and some DataLink rows).
5. Call `describe_app` once. If the client rejects the whole tool list, stop and file that — the schema audit is supposed to prevent it.

Keep two Agents settings in mind:

| Toggle | Use for |
|---|---|
| **Auto-apply agent writes ON** (default) | Cases 4, 5, 6, 7 (immediate result) |
| **Auto-apply OFF** | Cases 3.x (proposal strip + restart) |

---

## Fixtures

Use public archive data. Substitute if an id 404s, but note the substitute.

| Role | Suggested id |
|---|---|
| JWST with `#this` mix (asn.json + i2d) | Search JWST NIRCam, pick a public calibrated observation. Confirm `get_data_links` lists both `*_asn.json` (or similar) and `*_i2d.fits`. |
| Ordinary 2D FITS | Any CFHT / JCMT / HST public science FITS you can download. |
| Spectral cube | Any NAXIS≥3 public cube (or a local cube under `~/Downloads`). |
| Broken file | Copy any `.txt` to `~/Downloads/not-a-fits.fits`. |
| Harmless write (proposal tests) | `save_query` with a unique name, e.g. `qa-phase1-<initials>-<date>`. Delete it afterwards. |

---

## 1. WCS — PC+CDELT (JWST i2d)

**Bug that was:** PC rotation ignored; sky at the far corner off tens of arcsec; 90° rotation treated as invalid.

### 1.1 Open a JWST i2d and read WCS

1. Download a JWST NIRCam `*_i2d.fits` (Research or `download_observation`).
2. `open_fits_file` (or Open in Research) and wait until the image is on screen.
3. `get_fits_wcs` and/or `get_fits_header`.

**PASS if:**

- Header has `PC1_1` / `PC1_2` (and usually `CDELT1`/`CDELT2`) **without** `CD1_1`.
- `get_fits_wcs` is valid (not “no WCS” / approximate).
- If the PC matrix is a non-zero rotation, **north angle is not 0**.

**FAIL if:** north angle is 0° while `PC1_2`/`PC2_1` are clearly non-zero.

### 1.2 Far-corner sky vs a second source

1. `probe_fits_pixel` (or the FITS crosshair) at a **corner** pixel, not CRPIX.
2. Compare RA/Dec to CADC’s preview / another WCS tool (astropy, ds9) on the **same file**.

**PASS if:** agreement is at the sub-arcsecond to few-arcsecond level, not tens of arcsec.  
**FAIL if:** offset looks like ~40–90″ at the far corner.

### 1.3 Cube uses the same sky

If you also open the same (or another PC+CDELT) file as a cube:

**PASS if:** cube sky readout at CRPIX matches the FITS viewer (same header → same matrix). Skip if you have no cube with PC keywords.

### 1.4 90° rotation still usable (optional)

If you have a file with `CROTA2 = 90` (or PC that zeros the diagonal):

**PASS if:** the image opens, WCS is valid, Go To / crosshair still move on sky.  
Skip if you have no such file — unit tests cover the matrix.

### 1.5 Crosshair value is the drawn pixel

**Bug that was:** the crosshair / hover value came from the vertically mirrored row (RA/Dec were right).

1. In the FITS Viewer, click a bright, compact source in the **top third** of an image that is not vertically symmetric.
2. `get_fits_view` → note `crosshair.x`, `crosshair.y`, `crosshair.value`.
3. `probe_fits_pixel` with that `x` / `y`.

**PASS if:** the sidebar value is source-bright (not background), and the probe returns the same value.  
**FAIL if:** a bright source reads as background, or the probe and crosshair values differ.

---

## 2. DataLink — faults and JWST product pick

**Bug that was:** all-error DataLink rows looked like “no files”; JWST `#this` could pick `asn.json` instead of `i2d`.

### 2.1 JWST `#this` prefers i2d

1. `get_data_links` on the JWST publisher id from 1.1.

**PASS if:**

- `files[]` lists the science FITS (and may also list json).
- `bestDirectFileURL` (or the file you would download) is the `*_i2d.fits`, **not** `*_asn.json`.

2. `download_observation` for that id.

**PASS if:** the saved file is the i2d FITS (non-zero size), not an association JSON / 0-byte `pkg-*.txt`.

### 2.2 Faults are visible when `#this` is unusable

Pick one:

- A proprietary / embargoed id **without** being in the allowed group, or
- An id whose DataLink rows are all `error_message` / unauthorized.

**PASS if:** `get_data_links` returns a non-empty `faults[]` (or a typed error that names the DataLink reason) instead of a silent empty `files[]` with no explanation.  
**PASS if:** a subsequent `download_observation` that cannot get science data **fails with that reason**, not a 0-byte file.

If every public id you try has healthy `#this` rows, mark **BLOCKED** and say so — do not fail the case.

---

## 3. Pending proposals survive restart

**Bug that was:** the strip emptied on quit; agents could not see `failed` vs `rejected`.

Set **Auto-apply agent writes OFF**. Confirm `get_current_view.autoApplyEnabled` is `false`.

### 3.1 Rehydrate under the same id

1. Agent: `save_query` (unique name) or another **non-destructive** write.
2. Strip shows the proposal. Copy the UUID (`list_pending_proposals` or the strip).
3. **Quit Verbinal fully** (⌘Q). Relaunch. Re-enable Agents if needed. Auto-apply still OFF.
4. `list_pending_proposals` / `get_proposal_state`.

**PASS if:** the same UUID is still **pending**, summary intact.  
**FAIL if:** the strip is empty or the id is `unknown`.

### 3.2 Apply once; cannot apply twice

1. Click **Apply** on that proposal (or auto-apply it).
2. Confirm the query (or write) landed.
3. `get_proposal_state` → `applied`.
4. Try to apply the **same** id again (strip should be gone; a second apply must no-op / error).

**PASS if:** first apply works; second apply does not run the write again.

### 3.3 Failed apply ≠ reject

1. Queue a write that will **fail at apply** (example: `delete_vospace_node` on a path that does not exist — still a real proposal, then Apply).
2. Click Apply.

**PASS if:**

- Strip still shows the item (retry is possible).
- `get_proposal_state` is `failed`, **not** `rejected` or stuck `pending`.
- Clicking **Reject** then yields `rejected` and the row disappears.

3. Restore Auto-apply ON when this section is done.

---

## 4. Unknown arguments are refused

**Bug that was:** `additionalProperties: false` was advertised and ignored; typos were dropped.

With Agents on, call a documented tool with a **deliberate extra key**, e.g.:

- `get_fits_header` with `downloaded_observation_id` **and** `downloaded_obervation_id` (typo), or
- `get_proposal_state` with `id` **and** `ids`.

**PASS if:** the call fails `invalidArgument`, the **unknown key is named**, and the tool does not silently succeed.  
**PASS if:** the same tool with only the real argument still works.

### 4.1 `proposalId` alias

`get_proposal_state` with `{ "proposalId": "<uuid>" }` and **no** `id`.

**PASS if:** it returns the same state as `{ "id": "<uuid>" }`.

---

## 5. Open tools report the real load

**Bug that was:** `opened: true` as soon as the URL was queued, even if parse failed or the viewer never mounted.

### 5.1 Happy path

1. `open_fits_file` on a downloaded 2D FITS.
2. Watch the FITS Viewer.

**PASS if:** the tool returns **after** the image is actually loaded (`opened: true`), and `get_current_view` / `list_open_tabs` show that file.

3. Repeat with `open_cube` on a real cube (or `open_local_file` with `viewer: "cube"`).

**PASS if:** Cube Viewer has data before the tool returns success.

### 5.2 Failure path

`open_local_file` on `~/Downloads/not-a-fits.fits` (the text file).

**PASS if:** the tool **fails** (backend / invalid file), **not** `{ "opened": true }` / `{ "applied": true }`. The viewer may show an error; it must not pretend the file opened.  
**PASS if:** with two FITS tabs already open and the **first** one active, the failed open leaves the first tab active (not the last), and `get_fits_view.openTabPaths[activeTabIndex]` is that tab's file.

### 5.3 NAXIS≥3 sheet (regression)

`open_local_file` on a cube **without** `viewer`.

**PASS if:** you get `pendingViewerChoice: true` (or the Open as… sheet), and `choose_viewer` still works. Not a new feature — just don’t regress it.

---

## 6. Manifest / client can list tools

1. MCP `tools/list` (or the client’s tool picker) after `describe_app`.

**PASS if:** the client accepts the list (no “invalid inputSchema” / whole-server reject).  
**PASS if:** `get_proposal_state` and `get_data_links` are present.

---

## 7. Light regression (don’t burn the whole matrix)

Only if 1–6 are green. One pass each:

| Check | PASS if |
|---|---|
| Search → one public cone/object search | Rows appear |
| `vizier_cone_search` on a known table (e.g. Gaia at M31) | Rows, not HTTP 400 |
| Download a non-JWST public FITS (ESPaDOnS / CFHT if handy) | Non-zero FITS, not 0-byte `pkg-*.txt` |
| `list_local_folder` on `~/Downloads` | Listing, not sandbox error |
| Quit / relaunch with Agents off | App starts; no crash on empty proposal journal |

---

## Out of scope (do not test as bugs)

- Marks / `annotate_fits` / `annotate_cube`
- `get_fits_image` / `get_cube_image`
- `list_apps` / `search_tools` / `man`
- Adaptive session polling, toast queue
- ADQL editor checker / `describe_tap_schema`
- Notebook (Verbinal Pi only)
- Destructive Portal mass-deletes, ACL changes, unless you already used a fake path in 3.3

---

## Results log (fill in)

| # | Case | Result | Notes / ids |
|---|---|---|---|
| 1.1 | JWST i2d WCS + north angle | | |
| 1.2 | Far-corner vs second WCS | | |
| 1.3 | Cube sky matches FITS | | |
| 1.4 | 90° rotation (optional) | | |
| 1.5 | Crosshair value = drawn pixel | | |
| 2.1 | DataLink prefers i2d | | |
| 2.2 | DataLink faults visible | | |
| 3.1 | Proposal survives quit | | |
| 3.2 | Apply once only | | |
| 3.3 | Failed ≠ rejected | | |
| 4 | Unknown arg refused | | |
| 4.1 | `proposalId` alias | | |
| 5.1 | Open waits for load | | |
| 5.2 | Bad file is an error | | |
| 5.3 | Open as… sheet | | |
| 6 | tools/list accepted | | |
| 7 | Light regression | | |

**Tester:**  
**macOS / Xcode build:**  
**MCP client:**  
**Blockers:**
