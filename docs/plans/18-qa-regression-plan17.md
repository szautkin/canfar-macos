# QA handout — regression pass for plan 17

**Date:** 2026-09-29
**Build:** `release/1.4.0` @ `4c3a99d` or later
**Audience:** the MCP QA pass (an assistant connected to Verbinal, with the person watching). ~2 hours.
**Related:** [Plan 17](./17-qa-regression-fixes.md) · [Handout 16](./16-qa-regression-plan15.md) · [AGENTS.md](../../AGENTS.md)

This pass confirms the fixes for what regression runs 1 and 2 found still
failing (phase G), the audit gaps (A), and the requests about the screen
(U). It then covers what those runs never reached. Record each case as
**PASS / FAIL / BLOCKED**. For a FAIL, attach the tool's JSON or a
`capture_view` picture. The person's standing rules still hold:

- No headless jobs unless the person directs one.
- Nothing is stored on this Mac unless the case says so and the person agrees.
- Destructive changes always wait in Pending, for the person to apply.

## Setup

1. Build and run Verbinal from `release/1.4.0`, then sign in to CADC.
2. Settings ▸ AI Agent:
   - Turn on **Allow external AI agents** and **Auto-apply**.
   - Register the client with *this* build's path; Settings ▸ MCP Clients copies it.
   - Grant the client's permission prompts. Run 1's hangs were unanswered prompts.
3. Have ready:
   - The CFHT frame `745234p.fits.fz`, which refused to open in run 2.
   - The STIS `oezt010e0_x1d.fits`, already in Research.
   - The JADES F444W image, downloaded.
   - The Europa NIRSpec cube.
   - A COSMOS frame, and an image with no sky WCS.
   - Two or three throwaway sessions, 1 core and 1 GB, named `qa-…`.

---

## 1. What still failed (G1–G9)

| # | Steps | PASS if |
|---|---|---|
| 1.1 | Open `745234p.fits.fz` in the FITS Viewer; `get_fits_image`. | It opens: stars and sky, no refusal, no streaks. A file with no BYTEPIX is read as 32-bit Rice. (G1, H1) |
| 1.2 | `get_fits_header` on that frame; then again with `keywords: ["NAXIS", "CRVAL", "DATE-OBS"]`. | No `EXTNAME = 'COMPRESSED_IMAGE'`, no blank cards, `BITPIX` 16. The filtered call returns only the cards that begin with those names, plus `totalCards`. (G4, M17) |
| 1.3 | `list_downloaded_observations`; open NOAO `tu636792` (the 1024-byte tar in `~/Documents/test_qa`) in Research. | It says `downloaded: false` with a `fileProblem`. The detail shows the problem and **Download Again**. Records whose files are good are unchanged. (G2, H2) |
| 1.4 | Quit, relaunch and sign in; watch the activity bar; `list_activity`. Read the M31 MegaPipe record. | One task, "Check Research records against the archive", started by Verbinal (`startedBy: app`), ends "Corrected N of M". The MegaPipe record now reads filter `u.MP9301`, and blank observation ids are filled. Signing in again does not repeat the check. (G3, H5, M2) |
| 1.5 | `list_vospace_path` on the Storage home. | `.bashrc` and other dotfiles are `text/plain`; `.DS_Store` keeps the server's type. (G5, L5) |
| 1.6 | `list_probe_failures`; `list_job_history`. If the person agrees, run `discover_image_packages` on an image that cannot pull. | A failure's reason is the error line from the log (e.g. `ModuleNotFoundError …`), not a status line. A job that logged nothing gives its last Warning event, e.g. `Failed Error: ErrImagePull`. (G6, L17) |
| 1.7 | Storage home with `.vnc` public; `list_vospace_path`. | `.vnc` (and `.Xauthority`, if public) is marked and the banner offers **Make Private**; the tool gives `exposedSecret: true`. If a public `.token` is *not* flagged, record the exact JSON: this did not reproduce here. (G7, M14) |
| 1.8 | Tabs: JADES plus the image without a sky WCS; link the crosshair and sync zoom (`set_tab_sync`). | The tab bar reads "No precise WCS in *name* — sync may be imprecise", and the tool returns `impreciseWCS: ["name"]`. (G8, M18) |
| 1.9 | `list_ui_targets` on the Search tab, then on Results with rows. `set_adql_editor` with `SELECT * FROM caom2.Plane LIMIT 5`, `execute: true`. | Search offers `search.observation`, `.spatial`, `.target`, `.temporal`, `.spectral`, `.dataTrain` and `.run`. Results offers `results.export`, `.columns`, `.rowsPerPage`, `.header` and `.filters` (`.pages` with more than one page). The query answers `executed: false`, with "Not sent: …" in `searchError`. (G9, M19, L13) |

## 2. Audit (A1–A5)

| # | Steps | PASS if |
|---|---|---|
| 2.1 | The person deletes throwaway session A from the Portal. Then propose `delete_session` for B and `renew_session` for C, and the person applies both. `list_activity`. | The bar shows "Delete session A" by **You**, and "Delete session B" and "Renew session C" by **Your assistant**; `startedBy` is `person` and `assistant`. An assistant's delete appears on the bar at all (it never did before). (A1, the notebook1 question) |
| 2.2 | Propose `delete_sessions_bulk` with one real throwaway id and one made-up id; the person applies it. | A single task, "Delete 2 sessions", fails with "Deleted 1 of 2 — *made-up id*: …". (A1) |
| 2.3 | **Only if the person agrees to a job:** `launch_headless_job` a one-line `echo`. When it ends, `list_job_history`. | The launch's answer carries the job id(s) (`id`, `succeeded`). The history says `origin: agent`, and Batch Jobs History reads "Batch job by your assistant". (A2, A3, N2, N3) |
| 2.4 | `export_fits_figure` (PDF) on JADES; `export_cube_figure` on the cube. | Each answer carries `file`: the path it wrote in Downloads, and that file exists. (A3, N8) |
| 2.5 | Propose `renew_session` for an id that does not exist; the person applies it. `get_proposal_state`; `list_pending_proposals`; look at Pending. Then `withdraw_proposal`. | Pending shows "Couldn't apply this proposal: …", and the tools give `state: failed` with `failureReason`. The reason is still there after a relaunch. The withdrawal answers `budgetRemaining` one higher than before. (A4, N7) |
| 2.6 | Launch a throwaway session and, while it says Pending, `get_session`. | `status` is still CANFAR's `Pending`. Once its container has started, a `note` says so. A Running session has no note. (A5, N10) |

## 3. The screen (U1–U5)

| # | Steps | PASS if |
|---|---|---|
| 3.1 | With a proposal waiting: Landing, Portal (signed in and signed out), Search, Storage, the FITS Viewer. `point_at_ui` `agent.pending` on each. | The robot is in the toolbar beside Settings and Info on every view, with its count. Clicking it opens Pending, and the pointer lands on it. (U1, N11) |
| 3.2 | Portal ▸ Batch Jobs card, with no current jobs and then with some. | It always reads "*n* running · *n* pending · *n* done · *n* failed", zeros included (dimmed). An empty queue still shows the line and "No batch jobs". (U2, N12) |
| 3.3 | Fresh launch: open the Europa cube; `list_open_tabs`. | The cube tabs list the cube only: no tab with `path: ""`. (U3, N6) |
| 3.4 | Open `oezt010e0_x1d.fits` in the FITS Viewer. `get_fits_view`; `get_fits_spectrum` (without an id, then with its `downloaded_observation_id`); `get_fits_image`. | See the U4 checks below this table. |
| 3.5 | Open a FITS table with no spectrum (any catalogue table). | It reads "No spectrum in this table" and lists its columns with their units. (U4) |
| 3.6 | `get_cutout_options` on the downloaded JADES; `download_cutout` with no region. | The file's `cutBy: local` and its `suggested.cutBy` agree. The proposal reads "Cut out locally", not a CADC download. (U5, N5) |

U4 checks for case 3.4 (QA N1):

- The viewer shows a spectrum, not a blank 38946×1 image:
  - The plot runs 5258–10250 Å.
  - The flux axis reads "Flux (10^-14 erg/s/cm**2/Angstrom)", with the error as a band.
  - The HDU list shows "HDU 1 [table SCI]", and there are no render controls.
- `get_fits_view` returns `shows: "spectrum"`.
- `get_fits_spectrum` gives:
  - `pointCount` 1024 and `wavelengthUnit` "Angstroms".
  - `fluxRange` about [3.34e-15, 3.98e-14], the same as astropy.
  - `segments` binned to about 200 points.
- `get_fits_image` answers that the tab shows a table and names `get_fits_spectrum`.
- An echelle `_x1d` (E140H/E230H), if one is at hand, plots one line per order.

## 4. What could have broken

These changes touch shared code. Check that nothing near them regressed.

| # | Steps | PASS if |
|---|---|---|
| 4.1 | Open the CFHT `2786546p` `.fz` frame and a local cutout of it. | It is still an image (the table rule leaves compressed images alone), and the cutout is correct. |
| 4.2 | Europa cube: `probe_cube_spectrum`. | The wavelength axis is still in µm. The WAVE-TAB reader now uses the shared table reader. |
| 4.3 | Open a file from Research while an empty FITS tab is focused. | The file replaces the empty tab, and a file already open is focused rather than opened twice. |
| 4.4 | The activity bar's list. | Every row names who started it (You, Your assistant, Verbinal) at the right. Remote-compute runs are labelled by the language and session, no longer prefixed "Assistant:". |
| 4.5 | Portal: Delete and Renew on a session card. | They behave as before (with the confirm dialog on delete), and the list refreshes. |

## 5. Never reached in September

Run each once and record the answer. Destructive steps wait in Pending for the person.

- `use_workflow` the CFHT template twice (L4).
- Research ordering and paths: `list_downloaded_observations` newest first (L9).
- `export_cube_figure`, if not done in 2.4.
- `renew_session` from the Portal and by an assistant (2.1 covers the latter).
- Remote compute:
  - `start_compute` and `stop_compute`, then `run_code` `print(1)`.
  - `get_compute_state` before and after.
- Bulk operations: `download_observations_bulk` with two small files (only if the person agrees); `bulk_update_observation_notes`.
- Moving this pass's downloads to VOSpace, as the person's storage rule asks.

## Not in this pass

- P1 is still to come: a cached probe will say `cached: true`, and `astroai/improc:latest`'s one-package manifest will be looked into. Record today's `discover_image_packages` answer for that image as a baseline.
- L2's column ids (`ra(j20000)`) stay, by decision: they are the keys Verbinal for Windows uses.
- P2: `list_local_folder` lists every file in the folders the person has given Verbinal, as the person's permissions allow.

## Leftovers

List everything this pass creates, for the person to delete; each deletion waits in Pending:

- throwaway sessions
- the job, if launched
- figures and the cutout in Downloads
- any Research records

September's four items are still the person's to delete, if they remain:

- Research `3A03A731`
- mark `m1` on JADES
- saved query `E7A754EE`
- bookmark `13FBD0EE`
