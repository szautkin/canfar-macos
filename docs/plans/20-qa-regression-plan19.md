# QA handout — regression pass for plan 19

**Date:** 2026-09-29
**Build:** `release/1.4.0` @ `62bdbf6` or later
**Audience:** the MCP QA pass (an assistant connected to Verbinal, with the person watching). ~2 hours.
**Related:** [Plan 19](./19-qa-report-fixes.md) · [Handout 18](./18-qa-regression-plan17.md) · [AGENTS.md](../../AGENTS.md)

This pass confirms the fixes for the twelve defects the Sept 27–29 report
left open. It then covers the four items that report did not test, the
checks it left to the eye, and what the shared changes could have broken.

Record each case as **PASS / FAIL / BLOCKED**. For a FAIL, attach the tool's
JSON or a `capture_view` picture. The person's standing rules still hold:

- No headless jobs unless the person directs one.
- Nothing is stored on this Mac unless the case says so and the person agrees.
- Destructive changes always wait in Pending, for the person to apply.

## Setup

1. Build and run Verbinal from `release/1.4.0`, then sign in to CADC.
2. Settings ▸ AI Agent:
   - Turn on **Allow external AI agents** and **Auto-apply**.
   - Register the client with *this* build's path; Settings ▸ MCP Clients copies it.
   - Grant the client's permission prompts.
3. Have ready:
   - One or two throwaway sessions, 1 core and 1 GB, named `qa-…`.
   - A Research record from Search that is not downloaded yet.
   - The STIS `oezt010e0_x1d.fits`: download it again, or open it from `sn2023ixf-verbinal-qa/` in VOSpace.

---

## 1. Answers that say what happened (S1–S4)

| # | Steps | PASS if |
|---|---|---|
| 1.1 | Propose `delete_sessions_bulk` with one real throwaway id and a made-up one; the person applies it. Then propose `delete_session` with a made-up id; the person applies it. | The bulk task reads "Deleted 1 of 2 — *made-up*: no such session *made-up* — …". The single delete fails with "no such session", not success. Only the real session is gone. (S1, N20) |
| 1.2 | `use_workflow` the CFHT template twice; `list_workflows`. | Two new copies: the second titled "… (2)", or higher if copies exist. Each answer's `id` is its copy's, and `get_workflow` reads it. (S2, N17) |
| 1.3 | With the compute session running at a size other than Settings, `start_compute` with the Settings' size. | The answer's `note` reads "Kept the verbinal-compute session already running, which has *n* cores and *m* GB." It says how that differs, and not the size asked. The Remote Compute screen says a running session was kept. (S3, N18) |
| 1.4 | Start `discover_image_packages` on an image not yet probed with `start_background_apply`. While it runs, `get_proposal_state` and `list_pending_proposals`. Then quit Verbinal mid-probe, relaunch, and read them again. | While running: `state: applying` with `applyingSince`, and `list_activity` shows the probe's stage. After the relaunch: `state: failed` with `failureReason` "Verbinal quit while this was being applied — …", also shown in Pending. (S4, N7) |
| 1.5 | Make an apply fail (propose `renew_session` for a made-up id; the person applies it). Relaunch; `get_proposal_state`. | Its `failureReason` is still there after the relaunch. (Handout 18's untested item) |

## 2. The activity trail (T1–T2)

| # | Steps | PASS if |
|---|---|---|
| 2.1 | `discover_image_packages` on an image not yet probed; `list_activity`. | The "Inspect *image*" task is `startedBy: assistant`, and the bar shows "Your assistant". (T2, N19) |
| 2.2 | **Only if the person agrees to a job:** `launch_headless_job` a one-line `echo`; `list_activity`. | A "Launch batch job *name*" task, by Your assistant, ends "Job *id*". The launch's answer carries the id. (T1, A1) |
| 2.3 | The person deletes a throwaway session from the Portal (the card's **Delete**, confirmed). | The bar reads "Delete session *id*", by **You**; `list_activity` says `startedBy: person`. (Handout 18's untested item) |

## 3. Figures and files (F1–F2)

| # | Steps | PASS if |
|---|---|---|
| 3.1 | Open the `_x1d` in the FITS Viewer. Use **Export Figure** under the plot: PNG 2×, then PDF. Then `export_fits_figure` with `format: "png"`, then with `region: "box"`. | The files show the plot titled by the object and instrument, with Å and power-of-ten flux axes and the error band. The tool's answer has `file`. The box region is refused, saying a spectrum is drawn whole. (F1, N13) |
| 3.2 | `export_fits_figure` on JADES; `download_observation` of a small file (only if the person agrees); `list_downloaded_observations`. | Every path reads `/Users/<name>/Downloads/…`, never `…/Library/Containers/…`. (F2, L9) |

## 4. Research (R1–R4)

| # | Steps | PASS if |
|---|---|---|
| 4.1 | Quit and relaunch; sign in. Watch Research and the activity bar. | Research shows "Getting archive details — *n* of *m*" at the top of its list while it runs. The bar has one task, by Verbinal, ending "The archive answered for *a* of *m*". It takes minutes, not twenty. (R1, N15) |
| 4.2 | After 4.1, sign out and in again. | No task, or a short one: the records the archive answered are read from this Mac. Only those it did not answer are asked again. (R1) |
| 4.3 | In Research, find the record `1525350`; `list_downloaded_observations`. | Its publisher id is `ivo://cadc.nrc.ca/CFHT?1525350`, and it reads ESPaDOnS, target Betelgeuse, with its note, if it had one. The row is no longer only a number and a size. (R3, the person's screenshot) |
| 4.4 | Read CFHT `1573200` and the NOAO/DECam records. | CFHT 1573200: ESPaDOnS, Betelgeuse, and a calibration level from the plane of its file (1 for `…o`, 2 for `…i`). NOAO `tu636792`'s instrument reads `mosaic_2`. (R2, M2) |
| 4.5 | From Search, **Save to Research** a result not in Research; watch it. | The record appears, and within a minute its target, instrument and filter fill in from the archive. An "Archive details of …" task shows on the bar. (R1, R4) |

## 5. Capture (C1) and the checks by eye

| # | Steps | PASS if |
|---|---|---|
| 5.1 | `capture_view` on the Portal, the Cube Viewer with its side panel, and the `_x1d` spectrum. | The Portal header's text, the Cube side panel's labels and the spectrum's axis titles are all readable: no grey bars. The caption says `drawnBy: "screen"`. (C1, N16) |
| 5.2 | From those captures, and by eye: the Batch Jobs card with no current jobs. | It reads "0 running · 0 pending · 0 done · 0 failed" (N12). The Portal header shows text, not bars (N14). |
| 5.3 | A sheet open (e.g. Export Figure on JADES); `capture_view`. | The picture is the sheet. |

## 6. Probes (K1, K2)

| # | Steps | PASS if |
|---|---|---|
| 6.1 | `discover_image_packages` on `astroai/improc:latest`, without `force`; then again. | The first answer's `note` reads "Probed now …": the older probe's manifest is probed again. `find_images_with_packages` with `astropy` and `numpy` now finds it, with packages whose `env` is `/usr/bin/python3…`. The second answer reads "Answered from the cache: probed …". (K1, N4) |
| 6.2 | `run_code` `import os; print(os.cpu_count(), len(os.sched_getaffinity(0)))`. | The two differ (e.g. 192, 4). `run_code`'s description and the Remote Compute screen name `sched_getaffinity` for sizing pools. (K2) |

## 7. What could have broken

| # | Steps | PASS if |
|---|---|---|
| 7.1 | Portal: Delete and Renew on a session card. | They work as before, and the list refreshes. A delete now first reads the platform's list. |
| 7.2 | The Batch Jobs launch form (only if the person agrees to a job). | The launch works and is on the bar. A replica failure, if one occurs, reads as before. |
| 7.3 | Search: open an observation's detail; `get_observation_caom2` on a Research record's publisher id, twice. | The detail loads as before. The tool answers, and the second time at once: an assistant's archive lookups share Research's client and the answers it keeps. |
| 7.4 | A FITS image (JADES) and a cube: Export Figure. | Unchanged, and saved to `~/Downloads`. |
| 7.5 | Research: download an observation (only if the person agrees). | The record keeps its file and path after its details arrive: a background answer never undoes a download. |

## Kept, by decision

- **L2:** column ids such as `ra(j20000)` stay; Verbinal for Windows uses the same keys.
- **N9:** `list_local_folder` lists every file the person's permissions allow.

## Leftovers

List everything this pass creates, each deletion through Pending:

- throwaway sessions
- workflow copies
- the job, if launched
- figures in Downloads
- Research records

Still the person's to delete, from before, if they remain:

- Research `3A03A731` and `850C5ABD`
- saved query `E7A754EE`
- mark `m1` on JADES
- the JCMT workflow copy
- VOSpace `sn2023ixf-verbinal-qa/`
