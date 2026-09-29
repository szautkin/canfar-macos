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
| S say what happened | in progress — S1 an unknown session id is not deleted; S2 every use a numbered copy, its id returned; S3 start_compute says the size it kept; S4 an apply says since when, one cut short by a quit fails saying so; K1 every Python interpreter probed, a cache hit says so | `3d2f55a`, `98e6872`, `176d858`, `3214bc4`, K1 |
| T the trail | done — T2 a detached probe keeps who started it; T1 an assistant's batch job on the bar | `35911ca`, T1 |
| F figures and files | done — F2 one Downloads, one path; F1 a spectrum exports as a figure | `563aba8`, F1 |
| C capture | planned — C1 (decision 1) | — |
| R Research | in progress — R3 a slash-form record corrected; R1 the archive's answers kept in SQLite, records completed when added, 2 at a time with progress | `8ca2773`, R1 |
| K kept | — | — |
| Q handout 20 | planned | — |

## S — Answers that say what happened

| Step | Finding | Cause (found) | Fix |
|---|---|---|---|
| **S1** | N20 (Medium) | Skaha answers a DELETE for an id it does not have with success. `SessionService.deleteSession` sees 2xx, so both `delete_session` and `delete_sessions_bulk` report a typo as deleted. | `SessionActions` looks the ids up on the platform (interactive and headless) before deleting. An id not listed is not sent, and fails with "no session *id*". The bulk task names it: "Deleted 1 of 2 — *id*: no such session". The Portal is unaffected, since it deletes only what it lists. |
| **S2** | N17 (Medium) | `WorkflowApplier` discards the id `useWorkflow` returns (`_ = try store.useWorkflow`). An unstarted copy of the template was reused by the plan 15 rule (QA L4), and the answer never said so. | Every `use_workflow` makes a new copy, numbered when its title is taken ("… (2)", "… (3)"), and returns its `id` (decision 2). The plan 15 reuse rule goes. |
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
| **R1** | N15 (Low), and the blank records in Research | `ResearchRecordRepair` asks `caom2ops/meta` for one record at a time, and that endpoint takes 30–50 s under load. So 35 records took about 20 minutes. Worse, a record added from Search (Download, Save to Research) keeps only what the search row had: only an assistant's download asks the archive. So a record starts blank, and every check asks again. | The archive's answer is kept on this Mac, in the app's SQLite database (`AppDatabase` v3, an `archiveObservation` table: the observation's URI, the archive's XML, and when it was fetched). `CAOM2Service` owns it: memory first, then the database, then the network. One `ResearchArchiveDetails` completes a record from it, and every way into Research uses it: the Search's Download and Save to Research, and an assistant's download and save. So a record gets its details when it is added, in the background, on the activity bar. The check reads the database, and asks the network only for what is missing, 2 requests at a time. Its progress shows on the activity bar ("12 of 35") and at the top of the Research list (decision 3). |
| **R2** | M2 (Low) | Target and instrument come from the observation, and filter and calibration level from its plane. With no product part in the publisher ID (CFHT?1573200), `plane(of:in:)` picks a plane only when there is exactly one. A record the archive did not answer (a timeout during the slow run) stayed blank and was counted done. | With no product part, the plane is the one whose artifact is the downloaded file, else the only one. A record the archive did not answer is asked again at the next check. Before coding, fetch `caom:CFHT/1573200` and one DECam observation live, as fixtures. |
| **R3** | The blank `1525350` record (the person's screenshot) | It was saved in September under the slash form, `ivo://cadc.nrc.ca/CFHT/1525350`. `PublisherID` does not parse that form, so the archive is never asked. Plan 15 only refuses the form for new saves. | `PublisherID.likely(_:)` — the ID a slash form most likely means, already worked out inside `malformed`'s message, now one function both use. The check rewrites such a record to `ivo://cadc.nrc.ca/CFHT?1525350`, moves its note with it, and completes it from the archive. |
| **R4** | Records in the list say nothing | A row shows only the observation ID and size when the details are blank. | Covered by R1–R3; the handout checks that the rows fill in. |

## K — Kept as they are

- **L2:** column ids such as `ra(j20000)` stay, by decision. They are the keys Verbinal for Windows uses.
- **N9:** `list_local_folder` lists every file the person's permissions allow (plan 17 decision 2).
- **N4** (*found:* `astroai/improc` is Debian 13 — its science packages are apt's, for `/usr/bin/python3`, while the `python3` first on PATH is a separate 3.13.15 build that has only pip, and the probe asked only that one): plan 17 P1 is still to do. It fixes a cached probe answering "applied" at once and the `astroai/improc` manifest undercounting packages. It is carried here as step **K1**, done with phase S.
- **`cpu_count()` returns 192 on the compute image:** CANFAR's node, not Verbinal. `run_code`'s description and the Remote Compute screen will advise `len(os.sched_getaffinity(0))` for sizing pools (**K2**).
- **`notebook1`** (deleted Sept 28, 05:23 local): the Portal's confirmed **Delete** is the only code path that writes that line (plan 17). Since A1, the bar says who; handout 20 checks it.

## Q — Handout 20

Handout 20 covers S1–S4, T1–T2, F1–F2, R1–R4 and C1 (or the checks by eye, if C1 is declined). It adds the four items handout 18 left untested:

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

## Decisions (2026-09-29)

1. **C1 capture:** as recommended. The window's text goes in `capture_view`'s answer, from accessibility. A true window capture is adopted only if it needs no Screen Recording prompt.
2. **S2 workflows:** every `use_workflow` makes a new, numbered copy.
3. **R1 Research:** the archive's answers are kept on this Mac, in SQLite. Records get their details when added. The network is asked 2 requests at a time, with the progress shown.

## Order

S1–S4 and K1, T1–T2, F2 then F1, R3 then R1 then R2, C1, K2, then Q.
