# QA handout — regression pass for plan 15 (the MCP QA fixes)

**Date:** 2026-09-28
**Build:** `release/1.4.0` @ `c5f32b2` or later
**Audience:** the MCP QA pass, repeated (an assistant connected to Verbinal, with the person watching). ~2 hours.
**Related:** [Plan 15](./15-qa-mcp-pass-fixes.md) · [the Sept 2026 report](https://claude.ai/artifact/659vLcTZ17nkpRErYAC4oz) · [AGENTS.md](../../AGENTS.md)

The same pass as September's, now to confirm each finding is fixed, then
the read-only tools it did not reach. Record each case as **PASS / FAIL /
BLOCKED**, with the tool JSON (or a `capture_view` picture) on FAIL.
The person's standing rules still hold: no headless jobs unless directed,
nothing stored on this Mac unless the case says so and the person agrees.

## Setup

1. Build and run Verbinal from `release/1.4.0`; sign in to CADC.
2. Settings ▸ AI Agent: **Allow external AI agents** on, **Auto-apply** on.
   Register the client as `AGENTS.md` says — with the path of *this*
   build (Settings ▸ MCP Clients copies it); a stale path is the
   "could not attach" failure.
3. Have ready: a CFHT `.fz` frame (e.g. `ivo://cadc.nrc.ca/CFHT?2786546/2786546p`),
   the JADES F444W image, the Europa NIRSpec cube, and a VOSpace text file
   of a few hundred bytes.

---

## 1. Data you can trust (F1–F7)

| # | Steps | PASS if |
|---|---|---|
| 1.1 | Open the CFHT `.fz` frame in the FITS Viewer; `get_fits_image`. | Stars and sky, **no horizontal streaks**; `get_fits_header` shows `BITPIX`, `NAXIS1`, `EXTNAME` once each, no `TTYPE1` or `ZIMAGE`. (F1, F2) |
| 1.2 | In Research, open a record whose file is a 0-byte `pkg-…txt` or a 1024-byte tar (September's leftovers). `list_downloaded_observations`. | The detail says the file holds nothing, with **Download Again**; the tool gives `fileProblem`. (F3) |
| 1.3 | `save_query`, then `update_saved_query` its tags; `list_saved_queries`. | The id appears **once**, with the new tags. A legacy name with `&amp;` now reads `&`. (F4) |
| 1.4 | `read_vospace_file` the text file with `offset: 21, maxBytes: 10`, then walk it in 100-byte chunks. | The bytes from 21 on (not the file's start); `totalBytes` is its size; the chunks rebuild the file. `list_vospace_path` on that folder gives a `.py` the same `contentType` a read does; with `limit` below the count, `truncated: true`. (F5) |
| 1.5 | `save_observation_to_research` the u-band MegaPipe plane `ivo://cadc.nrc.ca/CFHTMEGAPIPE?MegaPipe.016.263/MegaPipe.016.263.U.MP9301` with `filter: "G.MP9401"`. | The record's filter is `u.MP9301`, its target `M 31 LL`, its preview the U gif. `…/CFHT/1525350` (slash form) is refused, naming `ivo://cadc.nrc.ca/CFHT?1525350`. (F6) |
| 1.6 | `get_data_links` for STIS `oezt010e0`; propose `download_observation` with `file: "oezt010e0_x1d.fits"` — **only if the person agrees** to the 80 KB file on this Mac, else BLOCKED. | The proposal names the file; applied, Research holds the `_x1d`, not the `_flt`. (F6, M11) |
| 1.7 | `list_job_history`; `list_probe_failures`. | September's failed probes (`luqe9pc5`, `rzia2s3e`) are in the history; a probe that fails now reads `job_failed` with its log's last line. (F7) |

## 2. Agent safety and audit (S1–S6)

| # | Steps | PASS if |
|---|---|---|
| 2.1 | With auto-apply on: `add_guide_tool` a test rule. | It **waits in Pending** (a standing instruction); the tool's description says so. Reject it. (S1) |
| 2.2 | Apply one proposal from Pending, let one auto-apply, start one with `start_background_apply`; `list_events`. | Each `proposalApplied` says `appliedBy`: `person`, `autoApply`, `background`; Pending's History shows who. (S2) |
| 2.3 | `describe_app`; `get_current_view`. | The brief **opens** with the person's rules (`storage_rules`, `headless_jobs_rules`); `get_current_view` carries `standingRules`. (S3) |
| 2.4 | `list_pending_proposals` with something waiting. | Each has `expiresAtISO` 3 hours after it arrived; the strip says "Expires in …". (A September proposal left pending is gone, and History says it expired.) (S4) |
| 2.5 | Storage home. `list_vospace_path` on it. | `.token`, `.config`, `.bashrc` (if public) are marked, the banner offers **Make Private**; the tool flags `exposedSecret` and a warning. Make Private is the person's click. (S5) |
| 2.6 | Change Settings ▸ AI Compute's cores with a session running; `get_compute_state`; `run_code` `print(1)`. | `drift` names the difference; `run_code`'s answer says it ran on the session already up; the screen offers **Restart with New Settings**. (S6) |

## 3. Viewers (V1–V6)

| # | Steps | PASS if |
|---|---|---|
| 3.1 | `annotate_fits` a callout on JADES; `get_fits_image`. | The callout is in the picture; the caption counts `marks`. (V1) |
| 3.2 | Cube in slice mode: `get_cube_image` with `maxPixels: 800`; probe a pixel; again. | An 800-pixel slice, sharp pixels, on the viewer's dark background; the spectrum under it once probed. (V2) |
| 3.3 | Open JADES fresh; open the Europa cube fresh. | JADES: dark sky, galaxies visible, not washed out; the cube: not black. **Auto** and R return to the same. (V3) |
| 3.4 | JADES fitted to the window ▸ North Up. | All four corners stay in view; zoomed in first, the zoom stays. (V4) |
| 3.5 | `probe_cube_spectrum` with `firstChannel: 100, lastChannel: 199, bin: 10`. | 10 values with `axis` (µm for WAVE) and `unit` (the cube's BUNIT). (V5) |
| 3.6 | Tabs: JADES (GOODS-S) and a COSMOS frame; link the crosshair (`set_tab_sync`). | The tab bar names the COSMOS tab as sharing no sky; the tool returns `fieldsApart`. (V6) |

## 4. Search (R1–R5)

| # | Steps | PASS if |
|---|---|---|
| 4.1 | Search SN 2023ixf, HST; `get_search_results`. | `oezt010e0` levels 1, 2, 3 have **different** `rowIDs` (publisher ids); `open_observation_detail` on one opens that level. "Proposal ID" is text; `includeRows: false` still lists columns. (R1) |
| 4.2 | `set_adql_editor` with a bare `obsID` in a Plane–Observation join, `execute: true`; then with `LIMIT 5`. | Both refused before sending, each with what to write. (R2) |
| 4.3 | `resolve_target` `AT 2023ixf`, `2023ixf`, `AT 2099zzz`. | The first two resolve (as SN 2023ixf); the last names NED, SIMBAD and VizieR. (R3) |
| 4.4 | `vizier_cone_search` Gaia DR3 at M31 with `maxRec: 5`, `columns: ["Source","Gmag"]`; `get_service_health`. | 5 rows, nearest first, `sep_arcsec` rising; two columns plus `sep_arcsec`. Health lists only the two CDS mirrors. (R4) |
| 4.5 | Search M101 in CFHT; `list_recent_searches`. | Named "M101 · CFHT — …". (R5) |

## 5. Other surfaces (O1–O4, Q1)

| # | Steps | PASS if |
|---|---|---|
| 5.1 | Open a Search detail; select a Research record; `get_current_view`. `list_ui_targets` on the home screen, Search, Storage, each Settings section. | `openSearchDetail` and `selectedResearchRecord` set; targets on every one of those screens. `get_platform_load` has a `note` when the counts are missing. (O1) |
| 5.2 | Portal storage card; `get_storage_quota`. | A 200 GB quota reads 200 GB, as Finder. (O2) |
| 5.3 | `list_recent_launches`; `get_session` a flexible notebook; `get_session_events` a quiet session. | Projects filled (canucs, astroai); cores and RAM "flexible"; `events` empty and `hasEvents: false`. (O3) |
| 5.4 | `use_workflow` the CFHT template twice; `list_activity` after a `run_code`; `save_fits_bookmark`; `list_my_images` with an untyped image. | One copy, not two; the run is `kind: compute` with no stage once finished; the bookmark's `id` returned; the untyped image says Advanced. (O4) |
| 5.5 | `capture_view` on the Portal, Settings ▸ Endpoints, and a sheet. | Pictures of each, upright; the caption names the window and mode. (Q1) |

## 6. The read-only tools September did not reach

Run each once and record the answer's shape: `get_observation_caom2`,
`get_cutout_options`, `list_session_images`, `list_recent_fits`,
`list_recent_cubes`, `set_cube_camera`, `set_cube_transfer`,
`annotate_cube`, `get_search_constraints`, `set_search_results_view`,
`quick_search`, `select_hdu`, `get_probe_logs`, `get_job_status`,
`choose_viewer`, `show_launch_form`.

## Leftovers

September's four items remain for the person to delete (each waits in
Pending): Research `3A03A731`, mark `m1` on JADES, saved query
`E7A754EE` (now listed once), bookmark `13FBD0EE`. This pass adds its own;
list them at the end the same way.
