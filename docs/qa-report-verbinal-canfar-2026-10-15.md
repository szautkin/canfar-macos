# Verbinal QA report — 1.4.1, full-app regression (handout 29) + handout 37

- **Build:** `buildCommit 3ebd72d0`, app `1.4.1 (18)`, schema 1 — run 2026-10-15.
- **Sessions:** `81C78E44-AB42-4593-9F2B-AEDBE22BF0AF` (main sweep; quit during §15.3) and
  `04C3DF27-5E5B-4C7F-A4E8-5BF572CBE2BD` (resumed after the relaunch). Both client
  `opencode/1.19.0`.
- **Scope:** handout 29 §0–§16 re-run (per handout 31), plus the new cases in handout 37
  (R/Q/F/D/M/P/S/L). Only the `verbinal-canfar` MCP was used: no shell, no external network.
- **Permissions in force:** Auto-apply on. Allowed: notes/saved, files on Mac, add-to-storage,
  sessions+compute, batch+probes, *remove what an assistant made*. Held for the person:
  sharing, "what every assistant is told" (always), remove notes/saved, remove files on Mac,
  remove from storage, stop running work, clear everything at once.
- **Standing rules (followed):** `headless_jobs_rules` (no headless job unless directed — run_code
  instead); `storage_rules` (work goes to VOSpace, not the local machine).

## Result at a glance

| Section | PASS | PARTIAL / note | BLOCKED / SKIPPED |
|---|---|---|---|
| §0–§1 View & Navigation | all | — | — |
| §2 Search & Archive | 8 | 2.5 collapsed collection | 2.8 (person) |
| §3 Saved queries | 8 | — | — |
| §4 ADQL / schema | 11 | 4.7, 4.11 | — |
| §5 Research & notes | 8 | 5.7, 5.8 | — |
| §6 FITS Viewer | 13 | 6.8, 6.12 (notes) | — |
| §7 Cube Viewer | 7 | — | — |
| §8 Sessions | 6 | — | 8.7, 8.8 (person) |
| §9 Batch / headless | 5 | 9.3 (person), 9.4 note | 9.7 (not directed) |
| §10 Image discovery | 7 | 10.8 deviation | 10.6, 10.9 |
| §11 Storage | 7 | 11.5 note, 11.7 deviation | — |
| §12 Remote Compute | 4 | 12.2 note | 12.5 (declined) |
| §13 Workflows | 3 | 13.1 note, 13.3 deviation | — |
| §14 AI Guide / proposals / log | 5 | 14.3 note, 14.6 note | 14.2, 14.4 |
| §15 Windows | 3 | — | — |
| §16 By design | n/a | — | — |
| Handout 37 (R/Q/F/D/M/P/S/L) | Q1–Q12, F1/F3/F5/F6, S5 | Q11, L1 | R*, D*, M*, P*, S0–S4/S6, F2/F4 |

No hard FAILs. The items below are PARTIAL/BLOCKED, or PASS with a deviation worth a decision.

## §0–§5 (regression, run earlier this pass)

- §1 all ten modes navigated; Settings sections open/close; file browser panel toggles.
- §2 search form, results, ADQL tab, saved/recent, detail sheets, TAP schema read, favourites —
  PASS. **2.5 PARTIAL:** a collapsed collection in the data-train reads as a single value, not a
  group. **2.8 BLOCKED:** the person's double-click into a row's detail.
- §3 saved-query CRUD PASS, including `delete_saved_query` on an assistant-made query.
- §4 ADQL/schema PASS. **4.7 caveat:** `validate_adql_query` returns `valid:true` for a
  *nonexistent* column when it appears alone (a misspelled column is only caught once another
  clause forces the table). **4.11 PARTIAL/deviation:** a read-only tool reported as a write? — the
  mismatch was withdrawn (`9D67BED3`), see log.
- §5 Research/notes PASS. **5.7 note:** a metadata-only save keeps a record without a file and the
  answer says so. **5.8 deviation:** destructive ops on *assistant-made* items auto-apply (see
  Findings).

## §6 FITS Viewer — PASS (6.1–6.13)

6.5 `fits_goto_coordinate(211.236, 54.4353)` → `onImage:true`; `probe_fits_pixel(1023,1023)` →
value 4943, RA 211.236190892162, Dec 54.43518236439687. 6.6 bookmark saved/listed/deleted.
6.7 blink start/set/pause/stop, WCS-aligned; `set_tab_sync` linked crosshair+zoom
(`fieldsApart: ["C130512_0053_SCI.fits"]`). 6.9 marks annotate→move→select→list→ds9 export
(`circle(1101,1101,40)`)→remove→clear. 6.10 PNG (whole image) and PDF (around a mark). 6.11 opened
`oezt010e0_x1d` (SN 2023ixf); spectrum hdu 1, Å, `errorMedianFraction 0.0076`, 1024 points.
6.13 `close_tab` fits index 3.

- **6.8 note:** `search_at_crosshair` needs a crosshair on the *active* tab; on a tab without one
  it fails `targetNotResolved: 'No crosshair with sky coordinates — place one with
  fits_goto_coordinate'` (logToken **706**). Passing after switching to the tab with a crosshair.
- **6.12 deviation:** `open_fits_file` on a NAXIS≥3 file opens **directly in the FITS Viewer**, with
  no "Open as…" sheet; the sheet appears only via `open_local_file` without `viewer`. See Findings.

## §7 Cube Viewer — PASS (7.1–7.7)

7.1 recent cubes; `open_cube` jw09230 s3d. 7.2 channel 900 / viridis / log / percentile / FPS 20,
transfer curve and camera 120°/45°/4 — `get_cube_view` agrees (view mode volume). 7.3
`get_cube_image` 768×576 volume. 7.4 `probe_cube_spectrum` (MJy/sr, µm axis, blanked nulls),
`show_cube_spectrum`, `get_cube_channel_profile` means. 7.5 annotate→update (channel 500)→select→
json export (2 marks)→list→remove. 7.6 `cube_ch501-20261015-064811.png`. 7.7 opened a second cube
(`dragons_FDF_clean_tot_Kgal.car.32bit.fits`, 36 s) then `switch_cube_tab(0)`.

## §8 Sessions — PASS (8.1–8.6); 8.7/8.8 the person's

`get_platform_load` (cores 847.25/3000, RAM 9131.1/15032 GB); `list_sessions` (`unhu3ymm`
verbinal-compute contributed, `dyvmjyat` notebook astroml:latest); types & images; recent launches;
`show_launch_form` (Standard/Advanced/Headless, the four pop-ups, resource steppers);
`open_ui("Container Image")` panel with search and "32 of 32" (12 rows), `select_ui`; session
events empty + Jupyter logs.

## §9 Batch / headless — PASS (9.1, 9.2, 9.4, 9.5, 9.6)

Batch Jobs sheet (History 19, others 0); tabs named, `unnamed:0`. **9.4 note:** with no live jobs,
`list_headless_jobs` returns `total 0`, `counts {}`; the `phase`/`contains`/`cursor` sub-cases were
N/A. 9.5 `get_headless_job(t9nqdskz)` → `source:"history"`; logs/events `state:"gone"` (events feed
404). 9.6 `list_job_history` incl. `failedOnly` with `failureReason`. **9.3 PARTIAL** (typing a
filter is the person's); **9.7 SKIPPED** (headless job forbidden by the standing rule).

## §10 Image discovery / registry — PASS (10.1–10.5, 10.7, 10.8)

`search_packages("astropy")` 11; `find_images_with_packages(python [astropy,numpy])` 122;
`describe_image`/`get_image_manifest` (astropy 7.0.1, debian 13, py3.13.16, dpkg 568, py 25,
`contentHash sha256:8011…`); Image Content Discovery sheet "Discovered 218 of 435", filter+type,
Uses-This-Image enables on select; `list_probe_failures` empty; `search_image_registry("astro")`;
`list_my_images`. **10.6 SKIPPED** (probe = batch allocation, the person directs); **10.9 SKIPPED**
(no failures to clear).

- **10.8 deviation:** `remove_registry_image` on an assistant-added image auto-applied
  (`applied:true`), not Pending — same assistant-made rule as §5.8.

## §11 Storage — PASS (11.1–11.7)

11.1 quota 78.9% (157.8/200 GB) + home listing — **root warning: many public folders and
`exposedSecret` files** (`.vnc`, `.config`, `.bashrc`, `.token`, `.zshrc`, `.netrc`*, `.globus*`),
and `.ollama` ≈114 GB, see Findings. 11.2 `get_vospace_node("test.txt")` + `show_storage_folder`.
11.3 `create_vospace_folder` + `upload_text_to_vospace` (201) + `read_vospace_file` (87 B
round-trip). 11.4 `upload_file_to_vospace` (cutout 43 200 B) + `download_vospace_file`. 11.6
`open_vospace_file("verbinal-qa-full/cutout.fits")` → FITS tab.

- **11.5 note:** `set_vospace_acl(..., isPublic:true)` **waits in Pending**
  (`pending:true, applied:false, waitsFor:"the person, in Pending"`) — sharing is held. Proposal
  `50C5D6FE-715A-4A6A-B4B6-0D16F4262E4D` was withdrawn after observing it.
- **11.7 deviation:** `delete_vospace_node("verbinal-qa-full", recursive:true)` auto-applied
  (assistant-made) rather than waiting; 7 storage calls, ~7.6 s.

## §12 Remote Compute — PASS (12.1–12.4); 12.5 declined

12.1 state `running` (verbinal-execution:0.0.2, 4 c / 8 GB, session `unhu3ymm`, uptime 32 min),
config, screen tab `run`. 12.2 `list_compute_runs` (25 runs, author/language/status/image each) +
`show_compute_run`. 12.3 `set_compute_snippet("print(1+1)")` shown. 12.4 `run_code` → output
`2` (exit 0, 1 637 ms). **12.5 SKIPPED:** starting/stopping the instance would disrupt the running
session and needs the person.

- **12.2 note:** `show_compute_run.selectedRun` omits the `image` field that `list_compute_runs`
  carries (see Findings).

## §13 Workflows — PASS (13.1–13.3)

13.1 `list_workflows` + `get_workflow(builtin:variable-star-photometry)` (10 steps, tools/view/note
+ rawText). 13.2 `use_workflow` → `local:qa-full-workflow`; step 0 ticked; one line edited
(`Time: ~3 h (QA-edited 2026-10-15)`); `save_workflow("qa-full-mine")` → `qa-full-mine-2`.
13.3 both deleted.

- **13.1 note:** the catalogue now lists **nine** built-in templates, not the "seven" in the handout.
- **13.3 deviation:** both `delete_workflow` calls auto-applied (assistant-made), not Pending.
- **Read-after-write:** `get_workflow` issued in the same batch as `set_workflow_step` returned
  `done:false`; a later read showed `done:true`. A read racing a write can be one step stale.

## §14 AI Guide, proposals, log — PASS (14.1, 14.3, 14.5, 14.6, 14.7)

14.1 `list_guide_tools` → the two standing rules. 14.3 `list_pending_proposals` empty;
`get_proposal_state`/`withdraw_proposal` on a resolved id. 14.5 `list_events` (arrived/applied/
failed/withdrawn + hints dismissed, `expired:false`). 14.6 `get_session_log` head and `only:failures`
(+ summary: 403 calls, 8 failed; slowest 38.7 s CADC archive); `explain_log_entry(706)` gave the
entry, cause chain and story. 14.7 `list_session_logs` (retention rule) + `export_session_log` →
`~/Downloads/Verbinal session log 2026-10-15 0656.txt`.

- **14.3 note:** a resolved proposal aged out of the memory window and reports
  `state:"unknown"` (not `"withdrawn"`) within minutes; the handout expects `withdrawn`.
- **14.6 note:** `explain_log_entry` on a leaf **call** failure returns `causes:[]`, `effects:[]`
  (only `story`) — the chain is empty for a call that never made a proposal.
- **14.4 BLOCKED:** `start_background_apply` needs a reversible *Pending* proposal; because every
  allowed write auto-applies, none is ever left waiting. Nothing to background-apply.
- **14.2 SKIPPED:** changing guides/descriptions is "what every assistant is told" and always waits;
  no instruction to change them.

## §15 Windows — PASS (15.1–15.3)

15.1 with Settings open, the person closed the main window; Settings closed with it and
`list_ui_targets` read *"No Verbinal window is showing"*. 15.2 reopened from the Dock; tools read it
again. 15.3 quit → `get_current_view` answered **"Verbinal is not running: the server it last named
has quit."** After relaunch the tools did **not** reattach to the existing client socket; a fresh
`start_session` was required (new session `04C3DF27…`), after which `get_current_view` read
`mode: landing`. This matches the handout ("a new `start_session` may be needed").

## Handout 37 cases

| Case | Result | Note |
|---|---|---|
| Q1 | PASS | `vizier_cone_search` B/vsx/vsx near M31 answers rows. |
| Q2 | **PASS** | Two `run_code` runs: the second's timing shows **no `vospace 409`** (a benign 404 pre-check appears), and no failed `vospace_mkdir`. Second run exit 0, `qa37 Q2 second run 3.11.15`, 1 638 ms. |
| Q3 | PASS | `get_headless_job` → `source:history` + `finishedAt`; `get_job_status` names `get_headless_job`. |
| Q4 | PASS | A waiting write answers `applied:false, pending:true, waitsFor`. |
| Q5 | PASS | `resolve_target("M31", "simbad")` answered. |
| Q6 | PASS | `adqlExecuted` reports `TOP 20`. |
| Q7 | PASS | `wait:false` → `state:searching`, then `ready` with the new rows. |
| Q8 | PASS | `set_results_view` filter `ra(j2000)` works as `ra(j20000)`. |
| Q9 | PASS | `update_guide_tool`/`delete_guide_tool` accept the guide's **name**. |
| Q10 | PASS | With Pending Changes open, `open_ui("Launch Session")` → `done:false`, names it in front; then opens. |
| Q11 | **PARTIAL** | The inline auto-applied failure returned **no `proposalID`**, so `withdraw_proposal` had nothing to act on — the `withdrew:false, state:withdrawn` half is untestable. |
| Q12 | PASS | `read_vospace_file` on a job's PNG returns a visible image. |
| F1 | PASS | Both runs record `verbinal-execution:0.0.2`. |
| F2 | — | On-screen export (the person's). |
| F3 | **PASS** | `run_code` over the three targets (M101, M31, SN 2023ixf; `count:3`); `list_compute_runs` shows each run's `image`; the Remote Compute run line shows it too. |
| F4 | BLOCKED | `launch_headless_job` forbidden by the standing rule. |
| F5 | PASS | Research tags filter (`tag:"candidate"`, `text:"transit"`); entries carry `tags`/`rating`. |
| F6 | PASS | `upload_text_to_vospace` + `read_vospace_file` round-trip. |
| R1 | BLOCKED | Needs the developer's `xcodebuild test` (no shell). |
| R2/R3 | BLOCKED | The person's (screen/report). |
| D1–D9 | BLOCKED | Two-Mac sync — the person's. |
| M1–M6 | BLOCKED | Research→database move is the person's action only. |
| P1–P7 | BLOCKED | Portal/launch-form clicks the person performs. |
| S0–S4, S6 | BLOCKED | Settings the person changes. |
| S5 | PASS | Sign-in/gating read correctly through the sweep. |
| L1 | PARTIAL | Screen-click confirmation is the person's; not exercised by tools. |
| F2 (37) | PARTIAL | Export sheet is on screen. |

## Findings outside the cases (decisions for the developer)

1. **Assistant-made destructive writes auto-apply even when their *kind* is held.** Allowed =
   removeAssistantMade. `delete_saved_query`, `remove_downloaded_file`,
   `delete_downloaded_observation`, `remove_registry_image`, `delete_workflow`,
   `delete_vospace_node` (assistant-made) all returned `applied:true` at once; only items the
   assistant did **not** create (`remove_recent_search`, `set_vospace_acl`) waited. The scale
   (e.g. a recursive VOSpace delete) runs without a person click. Expected? If not, the kinds
   `removeNotesAndSaved`/`removeFromStorage` should gate assistant-made items too.
2. **`open_fits_file` skips the "Open as…" sheet** for NAXIS≥3 and opens the FITS Viewer directly;
   the sheet appears only via `open_local_file` without `viewer`. Intentional, but inconsistent.
3. **`get_proposal_state` forgets resolved proposals fast** — minutes later a withdrawn proposal
   reads `state:"unknown"`, not `"withdrawn"` (handout 37 Q11 expects `withdrawn`).
4. **`explain_log_entry` on a leaf call failure** has empty `causes`/`effects` (only `story`).
5. **`show_compute_run.selectedRun` omits `image`**, which `list_compute_runs` provides — the run
   line on the Remote Compute screen can't show the image from this tool alone.
6. **`list_workflows` now returns nine built-in templates**, not the seven the handout names.
7. **Read racing a write in one batch is one step stale** (§13 `set_workflow_step` → immediate
   `get_workflow` showed the old state).
8. **Storage privacy:** the VOSpace home exposes many public folders and `exposedSecret` files
   (`.token`, `.netrc`, `.ssh…`, `.globus*`) and `.ollama` ≈114 GB — flagged for the person.

## Slow / failed replies seen (with tokens)

| What | Reply | logToken |
|---|---|---|
| `get_search_form(limit:)` | `invalidArgument: unknown argument ["limit"]` | 555 |
| `resolve_target("Ceres")` | `targetNotResolved` (CADC resolver HTTP 425) | 550/574/576 |
| `list_local_folder(~/Documents)` | `notReadable` (outside sandbox) | 520 |
| `search_at_crosshair` (no crosshair on active tab) | `targetNotResolved` | 706 |
| `get_downloaded_observation(bad id)` | `observationNotFound` | 674 |
| `get_headless_job_events/logs` (history job) | `state:"gone"` (events 404) | — |
| `select_ui("test.txt")` | "no single entry is called test.txt" | — |

## Clean-up

- **Created and left:** `qa37-plan36/verbinal-results-20261015-061603.csv` in VOSpace; Downloads
  artifacts `M101-20261015-064420.png/.pdf`, `cube_ch501-20261015-064811.png`, `cutout.fits`,
  `C130512_0053_SCI.cutout-d47e1601.fits`, `dragons_FDF_clean_tot_Kgal.car.32bit.fits`; the session
  log export in Downloads. (Per the person's "leave everything as is".)
- **Created and removed:** VOSpace `verbinal-qa-full/` (11.3–11.7); workflows
  `qa-full-workflow` + `qa-full-mine-2` (13.2–13.3); bookmark `qa-full-bookmark`; registry image
  add/remove; FITS and cube test marks (the pre-existing cube mark `m1` was left).
- **Waiting in Pending:** none — `list_pending_proposals` is empty; proposer
  `50C5D6FE…` (set_vospace_acl) was withdrawn after it was observed.
