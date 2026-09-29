# Plan 19 — Fixes from the QA report on 1.4.0 (Sept 27–29, 2026)

**Date:** 2026-09-29
**Branch:** `release/1.4.0` (continues [plan 17](./17-qa-regression-fixes.md))
**Source:** *Verbinal macOS: QA report (Sept 27–29, 2026)* — four passes,
the last on `4c3a99d` against [handout 18](./18-qa-regression-plan17.md).

43 of the first pass's 47 findings are fixed, including every High. The
report leaves twelve open defects, none of which corrupts data, plus
three things to check by eye and four not yet tested. This plan goes
through each: its cause, found in the code, and its fix. The steps are
grouped as:

- **S**: answers that say what happened.
- **T**: the activity trail.
- **F**: figures and files.
- **C**: capture.
- **R**: Research.
- **K**: kept as they are.
- **Q**: the next handout.

The rules are those of plans 15 and 17:

- A failing test on the reported case comes first.
- Each rule has one owner.
- Each step is one green commit: app tests, VerbinalKit tests, iOS build.
- Each step gets a CHANGELOG entry, and the parity doc changes with any tool.

## Status

| Phase | State | Commits |
|---|---|---|
| S say what happened | planned — S1–S4 | — |
| T the trail | planned — T1–T2 | — |
| F figures and files | planned — F1–F2 | — |
| C capture | planned — C1 (decision 1) | — |
| R Research | planned — R1–R2 | — |
| K kept | — | — |
| Q handout 20 | planned | — |

## S — Answers that say what happened

| Step | Finding | Cause (found) | Fix |
|---|---|---|---|
| **S1** | N20 (Medium) | Skaha answers a DELETE for an id it does not have with success. `SessionService.deleteSession` sees 2xx, so both `delete_session` and `delete_sessions_bulk` report a typo as deleted. | `SessionActions` looks the ids up on the platform (interactive and headless) before deleting. An id not listed is not sent, and fails with "no session *id*". The bulk task names it: "Deleted 1 of 2 — *id*: no such session". The Portal is unaffected, since it deletes only what it lists. |
| **S2** | N17 (Medium) | `WorkflowApplier` discards the id `useWorkflow` returns (`_ = try store.useWorkflow`). An unstarted copy of the template is reused by the plan 15 rule (QA L4), and the answer never says so. | `use_workflow` reports the copy's `id`. When it reuses an unstarted copy, it says so in `note`: "an unstarted copy already exists — pass `name` for another". The rule stays (decision 2). |
| **S3** | N18 (Low) | The start_compute answer (and the ack) repeats the proposal's summary, which states the configured size. Only the activity entry says a session was reused. | `StartComputeApplier` reports what it found: the session's own cores and RAM, whether it was reused, and the drift from the configuration (`ComputeDrift`, as `run_code` does). |
| **S4** | N7 (Medium) | A probe may run up to 600 s (QA's failed at 509 s). Until it ends, the proposal is rightly `applying`, but nothing says since when or how far it has got. An apply interrupted by a quit comes back plain `pending`, with no reason, because `applyingIDs` is not journaled. Both apply paths do record a failure's reason (plan 17 A4). | `get_proposal_state` and `list_pending_proposals` give an applying proposal's `applyingSince` and its activity stage ("Waiting for job …"). The store journals what is being applied, and after a relaunch marks it failed with "Verbinal quit while this was being applied". A test reproduces QA's path: a background-applied probe that fails reads `failed` with its reason. |

## T — The activity trail

| Step | Finding | Cause (found) | Fix |
|---|---|---|---|
| **T1** | A1 (Low) | `LaunchHeadlessJobApplier` calls the service directly. Only the Batch Jobs launch form (`HeadlessLaunchModel`) puts a launch on the bar. | One owner for launching a batch job on the bar, used by the form and the applier, as `SessionActions` is for deleting sessions. An assistant's launch shows "Launch batch job *name*" by Your assistant. |
| **T2** | N19 (Low) | `ImageDiscoveryCoordinator.discover` runs the probe in `Task.detached`, which drops the task-local `Initiator`, so the task records `person`. | Capture the initiator before detaching and pass it to `track(…, by:)`: `track` takes `by`, as `begin` does. Audit every `Task.detached` that starts tracked work. |

## F — Figures and files

| Step | Finding | Cause (found) | Fix |
|---|---|---|---|
| **F1** | N13 (Medium) | The figure export draws the rendered image; a spectrum tab has none ("No rendered FITS image is open"). | A spectrum figure: the plot as the viewer draws it, with title, axis units and error band, PNG (scale 1–4) or PDF, through `ImageRenderer`. The Export Figure sheet offers it on a spectrum tab. `export_fits_figure` on such a tab writes it, refuses image-only options (region, marks) with the reason, and returns `file`. |
| **F2** | L9 (Low) | *Not two places:* the app's container `Downloads` is a link to `~/Downloads` (the `files.downloads.read-write` entitlement). What differs is the path reported. Four helpers find Downloads on their own (`FileHelper`, `DownloadsFolder`, `AppState+ResearchTools`, `VOSpaceWriteTools`), and some report the container's form of the path. | One owner, `DownloadsFolder`, whose URL is the resolved `~/Downloads`. Every export, download and tool answer goes through it, so every path reads `~/Downloads/…`. Paths already stored in Research are resolved the same way when shown. |

## C — Capture

| Step | Finding | Cause (found) | Fix |
|---|---|---|---|
| **C1** | N16 (Medium), and the checks by eye (N12, N14, spectrum axes) | `capture_view` draws the window's layers itself (`layer.render(in:)`). That leaves out what the window server composites: materials and vibrancy, and text drawn over them. Hence the grey bars in the Portal header and the Cube side panel, and the Charts axis labels. | Decision 1. **Recommended:** the answer also carries the window's text, read from its accessibility tree (labels, values, counts — what VoiceOver reads). That needs no permission and makes labels checkable. Also spike a true window capture: ScreenCaptureKit, or `CGWindowListCreateImage` of the app's own window. Adopt it only if it needs no Screen Recording prompt. |

## R — Research

| Step | Finding | Cause (found) | Fix |
|---|---|---|---|
| **R1** | N15 (Low) | `ResearchRecordRepair` asks `caom2ops/meta` for one record at a time, and that endpoint takes 30–50 s under load (its own comment). So 35 records took about 20 minutes. | Ask for a few at once: 4 in flight (decision 3). Cap each record at 60 s. The stage reads "12 of 35". Estimated 35 records in about 5 minutes. |
| **R2** | M2 (Low) | Target and instrument come from the observation, and filter and calibration level from its plane. CFHT?1573200's publisher ID has no product part, and `plane(of:in:)` then picks a plane only when there is exactly one. Its blank target and instrument mean the observation itself did not arrive, probably the 60 s timeout during the slow run. A live check could not confirm this here: `caom2ops/meta` gave no answer within 60 s. The DECam records' instrument is the same question. | With no product part, the plane is the one whose artifact is the downloaded file, else the only one. A record whose archive did not answer is retried at the next check, rather than counted done. Before coding, fetch `caom:CFHT/1573200` and one DECam observation live, and add them as fixtures. |

## K — Kept as they are

- **L2:** column ids such as `ra(j20000)` stay, by decision. They are the keys Verbinal for Windows uses.
- **N9:** `list_local_folder` lists every file the person's permissions allow (plan 17 decision 2).
- **N4:** plan 17 P1 is still to do. It fixes a cached probe answering "applied" at once and the `astroai/improc` manifest undercounting packages. It is carried here as step **K1**, done with phase S.
- **`cpu_count()` returns 192 on the compute image:** CANFAR's node, not Verbinal. `run_code`'s description and the Remote Compute screen will advise `len(os.sched_getaffinity(0))` for sizing pools (**K2**).
- **`notebook1`** (deleted Sept 28, 05:23 local): the Portal's confirmed **Delete** is the only code path that writes that line (plan 17). Since A1, the bar says who; handout 20 checks it.

## Q — Handout 20

Handout 20 covers S1–S4, T1–T2, F1–F2, R1–R2 and C1 (or the checks by eye, if C1 is declined). It adds the four items handout 18 left untested:

- a delete made from the Portal, labelled You;
- a failure's reason surviving a relaunch;
- N4 against its baseline;
- N9, noted as kept.

## For the person, not the code

- **Public secrets:** `.vnc` and `.config` in VOSpace are world-readable. **Make Private** in Storage, one approval each.
- **Compute session `ojgffpjr`** (4 cores, 8 GB): stop it when idle.
- **QA leftovers**, each deletion through Pending:
  - Research `3A03A731` and `850C5ABD` (with its local file)
  - saved query `E7A754EE`
  - mark `m1` on JADES
  - the JCMT workflow copy
  - the two figure exports
  - VOSpace `sn2023ixf-verbinal-qa/`

## Decisions (proposed)

1. **C1 capture:**
   - The window's text in `capture_view`'s answer, from accessibility. This is recommended: no permission needed.
   - Plus a true window capture, only if it needs no Screen Recording prompt.
   - Alternatively, accept a one-time Screen Recording permission for pixel-exact captures.
2. **S2 workflows:** keep reusing an unstarted copy (the plan 15 rule) and say so, recommended. The alternative is for every `use_workflow` to make a new numbered copy.
3. **R1:** 4 archive requests at once, recommended. The alternatives are 2, which is gentler on CADC, or one batched TAP query, which is fast but reads the details a second way.
