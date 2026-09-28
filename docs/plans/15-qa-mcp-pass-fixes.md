# Plan 15 — Fixes from the MCP QA pass (Sept 2026)

**Date:** 2026-09-27
**Branch:** `release/1.4.0` (continues [plan 10](./10-windows-catchup.md))
**Source:** [Verbinal macOS — QA Findings (MCP pass, Sept 2026)](https://claude.ai/artifact/659vLcTZ17nkpRErYAC4oz) — 8 High, 20 Medium, 19 Low, run 21:48–22:20 UTC against this branch (the build of 14:43 PDT; its 202 tools are this branch's 200 plus two aliases, whatever the version string says).

Data integrity first, then agent safety, then the viewers, search, and the
rest; the Portal layout, reported the same day, is already fixed (P1).
Every step is one green commit (app tests, VerbinalKit tests, iOS build),
with its tests and a CHANGELOG entry; a tool change also updates
`docs/agent-ui-parity.md`.

## Status

| Phase | State | Commits |
|---|---|---|
| P Portal layout | done — P1 | `64a2500` |
| F data you can trust | done — F1 Rice high-entropy blocks, 8/16/32-bit; F2 a compressed image's own header; F3 downloads that hold nothing; F4 one row per saved query; F5 Storage reads at an offset, one media type; F6 a record describes its plane, ids checked, a file by name; F7 jobs not seen finishing, probe failures that say why | `59af802`, `6e3a57e`, `fadd302`, `97dfe72`, `0a15669`, `e9edbb9`, F7 |
| S agent safety and audit | done — S1 standing instructions wait for the person; S2 who applied a change; S3 the person's rules come first; S4 proposals expire after 3 hours; S5 public secrets flagged, Make Private; S6 a session that differs from Settings says so | `445d1e5`, `7662e58`, `bc245a2`, `d7a12bc`, `0079fbc`, `b793e65` |
| V viewers | done — V1 marks in get_fits_image; V2 the cube picture as seen; V3 a linear first look; V4 North Up re-fits; V5 the spectrum with its axis and unit; V6 fields apart said | `3753b7c`, `4c0b179`, `f3cb0de`, `675d2c3`, `eb97833`, `04ce64c` |
| R search, ADQL, resolver, VizieR | done — R1 a row per plane, text proposal ids; R2 bare ambiguous columns, checked before sending; R3 transient names; R4 VizieR mirrors that answer, nearest first; R5 target-first names | `8befbf2`, `89e5a35`, `81645df`, `03bbe89`, `4fed789` |
| O other surfaces | done — O1 view state, pointable targets, platform counts; O2 decimal GB; O3 launch project, flexible sessions, no events; O4 workflow copies, finished stages, bookmark id, untyped images | `db90e5b`, `6fca536`, `f83129b`, `c1ba0e3` |
| Q capture and regression | Q1 `capture_view` done; Q2 handout written ([16](./16-qa-regression-plan15.md)) — the pass itself is the next live QA | `c5f32b2`, Q2 |

## How the work is done

- **Prove it first.** Each fix starts with a test that fails on the case
  the report names — the `.fz` frame, the 1024-byte tar, the updated query
  — and passes after. Where the cause is not yet confirmed (marked
  *suspected*), the step starts by reproducing it.
- **One owner, one change (DRY, orthogonality).** A rule lives in the one
  module that owns it, and every surface — the screen, the agent tool, the
  applier — reads it from there. No fix in a tool that belongs in a service.
- **Open for extension (SOLID).** New behaviour is added where the design
  already bends: a new approval class in `VerbClass` rather than a list of
  tool names in the policy; an `actor` on the applied event rather than a
  second event stream.
- **Fail loudly, never silently.** A bad download, an unreadable tile, an
  expired proposal each say so, to the person and to the agent.

## P — The Portal (done)

**P1** The grid worked out column widths from the cards' contents, and with
real sessions and images it gave the first column the whole window: Storage
and Batch Jobs off the right edge, the session and image cards cut, a row's
cards ragged. Each card's width is now given (`PortalLayout.width(ofSpan:in:)`,
tested), a Portal card style makes each box fill its cell (one height per
row, as on Windows), and a card waiting for sign-in keeps its column without
leaving an empty row. — `64a2500`

## F — Data you can trust

| Step | Findings | Cause | Fix, and where |
|---|---|---|---|
| **F1** | H1 | *Confirmed:* the Rice decoder has no high-entropy block — `fs == fsmax` (14 for 16-bit) means raw values, not Rice codes — so the bit stream desynchronises into streaks; and only BYTEPIX 2 is decoded. | `RiceDecoder` (VerbinalKit): the high-entropy case, and BYTEPIX 1 and 4 (`fsbits`/`fsmax`/`bbits` per width, one table). A small `.fz` fixture made by astropy/cfitsio with noise and high-entropy blocks, and its expected values, both widths. Local fpack cutouts (D3c) use the same decoder and are fixed with it. |
| **F2** | M17 | *Confirmed:* the parser adds the image cards to the compressed table's header, so `BITPIX`, `NAXIS1`, `EXTNAME` appear twice. | `FITSParser`: a compressed HDU exposes the image header (Z-cards mapped back) as its header, and the table header apart; `get_fits_header` and the header panel read the first. |
| **F3** | H2 | *Confirmed in part:* an empty download is refused since 2026-09-20, but records saved before say `downloaded`, and a 1024-byte empty tar is not recognised. | `DownloadService`: one check of a finished download — empty, an archive with no members, an error page where data was expected, a length short of Content-Length. Research: a record's file is checked when read (`fileProblem`), shown with Download again, and `list_downloaded_observations` reports it. |
| **F4** | H3, L19 | *Confirmed:* `SavedQueryStore.save` always inserts, and the update applier calls it. | `SavedQueryStore`: save is an upsert by id; loading keeps the newest row per id and unescapes legacy `&amp;` once, then writes back. |
| **F5** | H4, L5, L6 | *Confirmed:* the server answers a `Range` request with 200 and the whole file; `fetchBytes` keeps the first bytes, not the slice at `offset`. | `VOSpaceBrowserService.fetchBytes`: a 200 body is sliced at `offset` locally and `totalBytes` is its length. One MIME rule by extension for listing and reading; `list_vospace_path` says when it stopped at `limit`. |
| **F6** | H5, M2, M11 | H5 *confirmed:* the download applier kept the details the agent passed — the g band's filter and preview with the u band's publisher id — and, without DataLink, a science file could come from any plane of the observation. M2, M11 *confirmed* by the report. | `ResearchRecordDetails`: a record's details are the archive's for the plane its publisher id names, then the description's, then the id's; downloads and Save to Research share it (`AppState.researchRecord(describing:)`), and a science file is only the named plane's. `PublisherID` reads the `caom:` form too, and a malformed id is refused with the one it likely means. `download_observation` takes `file` (a filename from `get_data_links`; in CAOM a *product* is the plane, so the argument is named for what it picks), so the `_x1d` can be chosen over the `_flt`. The CAOM 2.4 footprint (`points/point`) is read, which it was not. |
| **F7** | H8, L17 | *Confirmed:* the monitor records only transitions it watches, so a job already finished at the first poll is never kept; history began with this build. | `HeadlessMonitorModel`: every finished job it sees and the history lacks is recorded. The coordinator records a failed probe it had a job id for; `list_probe_failures`' job ids seed the history once. Probe failures carry their real category; the tool description's example images are corrected. |

## S — Agent safety and audit

| Step | Findings | Fix, and where |
|---|---|---|
| **S1** | H6 | A new approval class, `VerbClass.standingInstruction` (VerbinalKit): never applies at once, whatever auto-apply says, like `destructive` — one line in `AutoApplyPolicy`, whose sentence every tool description and `describe_app` already read. `set_tool_description`, `clear_tool_description`, `add_guide_tool` and `update_guide_tool` take it. |
| **S2** | H7 | The applied event says who applied it: `proposalApplied(id, kind, by:)` with `person`, `autoApply` or `background`, set where each path applies (the strip, the auto-apply hook, `start_background_apply`). `list_events` and the activity feed show it. |
| **S3** | M10 | The person's standing rules — their guide tools (there is no separate "rule" mark; `storage_rules` is a guide tool like any other, and since S1 only the person can add one) — come first in `describe_app` (its brief opens with them) and in `get_current_view` (named first in its description; JSON keys have no order), from the AI Guide snapshot that holds them (`AIGuideSnapshot.standingRules`). |
| **S4** | L18 | A pending proposal expires after 3 hours and says so (`expired`), in the strip and to `get_proposal_state`. |
| **S5** | M14 | Storage flags a public file whose name marks it as a secret (`.token`, `.netrc`, `.ssh/…`, `.config` and the like): a warning in the listing and on screen, and `list_vospace_path` says so; **Make Private** uses the existing ACL call. |
| **S6** | M7 | Remote compute compares the running session with Settings: `get_compute_state` reports the difference, `run_code`'s answer says it ran on the older session, and the screen offers Stop and Start to take the new settings. |

## V — Viewers

| Step | Findings | Fix, and where |
|---|---|---|
| **V1** | M3 | `get_fits_image` draws the marks, through the drawing the figure export already uses (one path for both). |
| **V2** | M4, L11 | The cube slice capture honours `maxPixels`; the capture uses the background the state reports and includes the spectrum panel when it is shown. |
| **V3** | M5 | Better first looks, still linear: a FITS auto-cut that does not saturate a deep-field background, and a cube window from the data's percentiles instead of 0–1. |
| **V4** | M6 | North-up fits the rotated image to the window. |
| **V5** | M13 | `probe_cube_spectrum` returns the spectral axis values and BUNIT, and takes a channel range and a binning. |
| **V6** | M18 | Linking the crosshair across images whose fields do not overlap says so, on screen and in the tool's answer. |

## R — Search, ADQL, resolver, VizieR

| Step | Findings | Fix, and where |
|---|---|---|
| **R1** | M1, L1, L2, L12 | A result row is identified by its plane's publisher id (numbered when repeated), so `open_observation_detail` can pick a calibration level; "Proposal ID" is text, "Download" is the publisher id. L2 is kept as it is: the column ids (`ra(j20000)`) are the keys Verbinal for Windows uses too, and saved column settings are stored under them — the tool now says so, and `label` carries the name. L12 did not reproduce: with results loaded, `includeRows: false` returns the columns; a test pins it. |
| **R2** | M16, L13 | The ADQL checker flags an unqualified column that more than one joined table has; the editor runs the checker before sending, so `LIMIT` is caught at home. |
| **R3** | M12 | The resolver accepts transient names (`AT 2023ixf`, `SN 2023ixf`, `2023ixf`) by trying the spellings NED and SIMBAD know (`TransientName`) — a TNS lookup of its own would need a TNS account — and its error names every service and spelling tried. A 200 answer saying `error=` is a miss, not a position at 0, 0. |
| **R4** | M8, M9 | The VizieR mirror list is corrected (hosts that resolve, HTTPS only); a cone search can choose its columns and returns the nearest rows first, with their separation. |
| **R5** | L3 | A recent search is named after its target before its collection. |

## O — Other surfaces

| Step | Findings | Fix, and where |
|---|---|---|
| **O1** | M19, M20 | `get_current_view` includes the open detail sheet and the selected Research record; the home tiles, Search, Storage and every Settings section get pointable targets; `get_platform_load` returns the instance counts, or its description stops promising them. |
| **O2** | M15 | Quota in the units it says: decimal GB, as Finder counts. |
| **O3** | L7, L8, L15 | Recent launches show the project of every image shape; a flexible session says "flexible" for CPU and RAM; `get_session_events` answers an empty list. |
| **O4** | L4, L9, L10, L14, L16 | Using a template again reuses an unstarted copy and numbers a new one (existing copies are the person's, not merged); a finished task drops its stage, and compute runs are their own kind; `save_fits_bookmark` returns the new id; a registry image with no session type says it cannot be launched from Standard. Research is newest first by download date (the store orders it, on load and on every save). L9's paths are taken with the deferred storage-architecture review: they differ because the files do live in different places (older builds downloaded into the app's container), and the viewers' `~/Downloads` for a container file is that review's to settle. |

## Q — Capture and regression

- **Q1** `capture_view`: the window as a PNG, so a QA pass can see every
  screen. Drawing the window's layer tree works — it is how P1 was checked
  offscreen.
- **Q2** Run the read-only tools the pass did not reach, then repeat the
  pass as a regression (handout 16). Its leftovers — a Research record, a
  mark, a duplicated saved query, a bookmark — are the person's to delete.

## Not bugs

The report withdrew four findings; one of them names an archive quirk
worth passing on: `Plane.time_exposure` is a median per pixel, so a short
value is not a failed exposure — ObsCore `t_exptime` or the header
`EXPTIME` is the total.

## Decisions (2026-09-27)

1. **S4:** a pending proposal expires after **3 hours**.
2. **V3:** the first look stays **linear**, with a better cut.
3. **O2:** quota in **decimal GB**, as Finder counts.
4. **Auto-apply:** only non-destructive writes; a destructive one always
   waits for the person — and so, by S1, does a standing instruction.
