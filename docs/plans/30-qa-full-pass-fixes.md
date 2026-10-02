# Plan 30 — Fixes from the full-app validation pass (Oct 1–2, 2026)

**Date:** 2026-10-02
**Branch:** `release/1.4.0` (after `4b55619`)
**Source:** *QA report — Verbinal, the whole app (MCP validation pass)*, session
`7C0354FE-058D-41A8-AEFD-91336F75B50C`, build `bdf4a56`, run against
[handout 29](./29-qa-full-app-validation.md).

## Where the pass ended

- **Score:** 80 PASS, 7 FAIL, 10 BLOCKED, 3 SKIPPED.
- **BLOCKED:** most of these were CANFAR itself.
  - VOSpace answered HTTP 503 all night. That took out §11 and the cases that need Storage (2.4, 12.4).
  - Every Skaha write hung for 180 s while reads answered in under 1.5 s.
- **This plan** checks each finding against the code before proposing a fix, as plans 19 and 21 did.
  Same rules: a failing test on the reported case first, one owner per rule, and one green commit per
  step.

**Nothing here is built until the person has reviewed it.** The decisions it needs are at the end.

## Status

| Step | What | State |
|---|---|---|
| **W** | Writes on CANFAR: say where they are; why they hung | planned — W0 diagnosis first |
| **S** | Silent no-ops and loose schemas | planned |
| **J** | Jobs CANFAR has dropped read as "gone", not "pending" | planned |
| **T** | Sheets an assistant can open and close; the launch form's resources | planned — decision 1 |
| **R** | Search radius, as a field | planned — decision 2 |
| **D** | `download_observation` `file` from another plane of the observation | planned |
| **F** | The file browser opens Downloads | planned — cause to confirm |
| **L** | Long answers inside the client's patience | planned — decision 3 |
| **C** | `capture_view` shows the hints | planned |
| **P** | The channel profile in a range, binned | planned |
| **K** | A compute run that never reports | planned — cause to confirm |
| **G** | Workflow templates name only tools that exist | planned — decision 4 |
| **N** | Small items | planned |
| **Q** | Handout 29 corrections; handout 31 | planned |

## What the report got wrong, or what was mine

| Report item | Checked | Finding |
|---|---|---|
| **Finding 1** "17 areas / 215 tools; the handout says 16 / 213" | `AIGuideCatalog.categoryByTool` maps all 213 built-in tools. The "Other" area held the person's two guide tools (`headless_jobs_rules`, `storage_rules`), which no built-in area can name. | **Handout error.** Handout 29 counted the built-in tools only. Kept as N1: the person's guide tools get an area of their own, "Your guide tools", instead of "Other — not yet sorted". |
| **Finding 13** "the Batch Jobs sheet has no filter field" | `HeadlessJobsDetailSheet` shows the filter above a tab that has jobs. The pass had 0 jobs on every tab; only History had entries (19). | **Not a defect: no jobs.** Handout 29's 9.3 said "with jobs in a tab", but a reader could miss that. Decision 5 asks whether History, kept to 50, should have the filter too. |
| **Finding 4** "the Search form has no cone radius" | `SpatialBuilder.circle` reads a radius written after the target, as CADC's own search does: `M101 0.2deg`, `M31 30'`. Without one, the radius is 1′. The Windows app has a separate **Radius (deg)** field and `set_search_form`'s `searchRadius`. | **Half right.** The radius can be set, but nothing says how: not the field, and not `set_search_form`. The Windows app has the field, so this is a parity gap. Step R. |
| **Finding 5** "an agent cannot cancel a search" | Every search tool waits for TAP's answer before returning, so an assistant has nothing in flight to cancel. | **A testability gap, not a defect.** The Cancel button works (the "nothing running" reply is right). Step R adds `wait: false`. |
| **Finding 18** "with auto-apply on, `start_background_apply` has nothing to act on" | True by design: with auto-apply on, only destructive or standing changes wait, and the tool refuses those. | **Handout error.** 14.4 needs auto-apply off. The tool's description will say so (N). |
| **Finding 3** "`capture_view` cannot photograph the hints" | `CaptureViewTool.composited` captures one window (`.optionIncludingWindow`). The hints draw in their own panel above it. | **A real limitation.** Step C. |
| **§3** "the Portal RAM label" | QA withdrew it, rightly. | No change. |

## Defects confirmed

### W — Writes on CANFAR (Finding 12, HIGH)

**What we know** (from the code):

1. `LaunchSessionApplier.apply` and the headless launch run outside the task runner. Downloads use the
   runner (`changes.run`), and the runner is what the activity bar shows. So a launch never appears in
   `list_activity`, nor in the session log's `now.tasksRunning`.
2. `withApplierTimeout` (in VerbinalKit) ends every timeout with "check the in-app activity feed before
   retrying". For these applies, that feed has no record of them, so a person who follows the advice may
   launch again.
3. `now.proposalsWaiting` lists every proposal not yet done. It explains each with `backgroundRefusal`,
   whose `default` case reads "auto-apply is off". A proposal that is *applying* (auto-applied, past the
   call's deadline), or has *failed*, reaches that case with the wrong reason.
4. `list_events` showed `proposalFailed` twice per launch, minutes apart. The cause is not found yet.

**What we don't know:** why `POST /session` and `POST /batch` hung while every GET answered.
- VOSpace was answering 503 the same night, which points at CANFAR.
- A request of ours that CANFAR's newer API no longer takes would point at the app.

| Part | Fix |
|---|---|
| **W0 — diagnose first** | Read the launch's request lines in the person's session log (tokens 446, 475): method, URL, the service's id, timeout, outcome. Compare with the canfar Python client's launch, `POST` to the same registry-resolved URL with the same form fields, while CANFAR is healthy. The person launches once from the UI, and an assistant once, to see whether both hang. **No fix to the request until W0 says it is ours.** |
| **W1** | Every apply that calls CANFAR runs as a task: launch, headless launch, renew, delete, bulk delete. It shows on the activity bar and in `list_activity`, by the assistant, with its stage, like downloads. One path, `changes.run`, for every apply. |
| **W2** | The timeout's advice names what exists. "Follow it with `get_job_status`; `list_sessions` or `list_headless_jobs` shows whether it was made." The activity bar is named too, now that W1 puts the task there. |
| **W3** | `now.proposalsWaiting` lists only proposals waiting for the person, with the right reason. One that is applying goes under `tasksRunning`, through W1. One that failed is in the log as failed, not waiting. |
| **W4** | One `proposalFailed` per failure. Find the second emitter and add a test on the event stream. |

### S — Silent no-ops and loose schemas (Findings 7, 9, units; MEDIUM)

| Part | Cause | Fix |
|---|---|---|
| **S1** | `bulk_update_observation_notes` describes `items` as `"items": {"type": "object"}`, with no inner shape. With no types to follow, a client sent `rating: 3` as `"3"`, and the strict `Int` decode refused it. A nested `notes:{…}` key was not refused either, and the item decoded with no fields. | The inner schema is `update_observation_note`'s own, the same definition used by both tools. Each item has `additionalProperties: false`. |
| **S2** | The router refuses unknown arguments at the top level only. | The check walks nested objects and arrays wherever the schema says `additionalProperties: false`, for every tool, not just this one. A test feeds every tool's schema a nested unknown key. |
| **S3** | A note with only `publisher_id` passes and writes nothing, reported `applied: true`. | A change that changes nothing is refused: "nothing to change: give `text`, `rating` or `tags`". The single-note tool and the bulk tool use one rule. |
| **S4** | `set_cube_transfer.opacityCurve` is `{"type":"array"}`. The same curve is described properly in `set_cube_view`. | One schema fragment for an opacity curve (`[[value, alpha], …]`, values 0–1), used by both tools. The decode error names the expected shape, not just "Invalid arguments". |
| **S5** | `set_results_view` `columnUnits` takes unit ids that are listed nowhere. `Unknown unit 'deg'` doesn't list the valid ones. | `get_search_results` gives each column's valid units. The error lists them. |

### J — Dropped jobs (Findings 14, 15; MEDIUM)

| Part | Cause | Fix |
|---|---|---|
| **J1** | `get_headless_job_logs` and `_events` treat a 404 as a pod not yet started (`isPendingPodSignal`), so they answer `pending`. For a job CANFAR has dropped, that stays `pending` forever, and the documented polling loop never ends. | Before answering `pending`, the tool asks for the job. If CANFAR does not list it, the answer is `state: "gone"`, with "CANFAR no longer lists this job; `list_job_history` keeps what is known". |
| **J2** | History says "`get_probe_logs` has both" after CANFAR has dropped the job. | The advice is qualified: "while CANFAR still lists the job (about a day)". `get_probe_logs` answers a 404 the same way as J1. |

### D — A file from another plane (Finding 6; MEDIUM)

**Cause (found):**
- `get_data_links` lists the artifacts of every plane of the observation.
- `download_observation` looks for `file` only in the plane its publisher id names (`DownloadService.planeArtifacts`).
- `of4302010_sx1.fits` is in a sibling plane, so the download refused a file the other tool had just offered.

**Fix:**
- `caom2Artifacts[]` gives each file its `productID` and `publisherID`.
- `download_observation` refuses a file from another plane with that plane's publisher id: "of4302010_sx1.fits is in of4302010-PRODUCT: download it from that publisher id". It doesn't fetch it into the wrong record.
- The description says so.

### F — The file browser and Downloads (Finding 2; MEDIUM)

**Likely cause, to be confirmed by a failing test first:**
- The panel starts at `FileManager`'s Downloads (`LocalFolderAccessStore.downloadsRoot`). In the sandbox, that is the container's `Downloads`, a symlink to the person's.
- The panel lists it with `contentsOfDirectory(at:)`, without resolving the link.
- `list_local_folder` lists `/Users/<name>/Downloads` itself.
- A symlink listed unresolved fails with exactly the message seen: "couldn't be opened", with no reason.

**Fix:**
- The panel resolves the folder it lists, and starts at the person's Downloads (`userFacingDownloadsRoot`), as the tool does.
- One rule for "the folder to list", used by both.

*Separate:* Research records under `~/Documents` that ask to be reopened need a security-scoped bookmark per file. That's out of this plan; noted for the deferred storage review.

### L — Long answers (§7.2 of the report; MEDIUM)

The agent's MCP client gave up at 60 s, while Verbinal's own deadline for that VOSpace read was 120 s.
Clients differ, and Claude Code waits longer, but 60 s is a common limit. **Fix:** no synchronous
answer takes longer than 45 s (decision 3), as one shared constant.
- A read past it answers with a typed timeout and its `timing` block ("still waiting for VOSpace after 45 s").
- A write past it answers with its job id, as proposals already do ("still applying; follow with `get_job_status`").

The service's own deadline stays as it is, and the work goes on behind the answer.

## Gaps

### T — Sheets an assistant can open and close (Findings 8, 11)

The person opens these sheets and an assistant cannot: Batch Jobs (its presentation is the card's
private state) and Image Content Discovery. `show_cutout_editor` opens Cut Out but nothing closes it.
And `select_ui` rightly never presses the launch form's **Flexible / Fixed**.

| Part | Fix |
|---|---|
| **T1** | Each sheet's presentation lives in `AppState`, as `launchFormPresented` does. That means Batch Jobs (`batchJobsTab`), Image Content Discovery (one flag, whether it opens from Portal or from the launch form) and Cut Out. One owner per sheet. Closing the main window resets them all, already (`mainWindowClosed`). |
| **T2** | `show_batch_jobs` (`tab`, `filter`, `close`) and `show_image_discovery` (`close`), in the shape of `show_launch_form`. `show_cutout_editor` takes `close`. |
| **T3** | `close_ui` closes any open sheet as Esc would: the sheet's cancel action, so it works for every sheet, those without a tool of their own included. Decision 1. |
| **T4** | `show_launch_form` takes `resources` (`flexible`, `fixed`) and `cores`, `ram`, `gpus`. It fills the form as `image` chooses one, and launches nothing. |
| **T5** | `use_workflow` takes `name`, so a copy is named when made. |

### R — Search radius (Finding 4) and cancel (Finding 5)

| Part | Fix |
|---|---|
| **R1** | A **Radius** field beside Target, in degrees, default 1′ as now. It is the same parameter as a radius typed after the target (`M101 0.2deg`), which keeps working, and the field shows it. `set_search_form`/`get_search_form` take and give `searchRadius`, the Windows name. One owner, `SpatialBuilder`. Decision 2. |
| **R2** | `set_search_form` and `set_adql_editor` with `execute` take `wait: false`, which answers at once that the search has started. `cancel_search` can then stop it, and `get_search_results` follows it. |

### C — `capture_view` shows the hints (Finding 3)

The capture composites the window together with its hint panel, the window server's picture of both
(`CGImage(windowListFromArrayScreenBounds:…)`). It then shows what the person sees: rings, bubbles and
the dimming.

### P — The channel profile in a range, binned (Finding 10)

`get_cube_channel_profile` takes `firstChannel`, `lastChannel` and `bin`, the same as
`probe_cube_spectrum`, through the same binning code. Its default answer is binned to at most 500 points.
3,610 channels come back as 111 KB today.

### K — A compute run that never reports (Finding 16)

Run `634F932B` (`time.sleep(480)`) is still "running" two days later, though the session itself is
fine. The cause is not found yet: its result file never landed in `/arc` …`/.verbinal/exec`, or it
landed and was never read. **K0:** look at that run's folder in VOSpace when Storage is back.
**Fix either way:** a run with no result 10 minutes past its deadline is marked `lost`, with "no result
came back: the code may have stopped the session's runner". It never stays "running".

### G — Workflow templates (Finding 17)

Four templates name the Notebook add-on's tools, which the app does not have:
`variable-star-photometry`, `dao-espadons-spectroscopy`, `jcmt-cube-kinematics` and
`proposal-due-diligence` (`create_analysis_notebook`, `run_all_cells`).

- **Fix:** those steps use `run_code` (Remote Compute), or say "with the Notebook add-on" (decision 4).
- **Guardrail:** a test reads every template and fails on any tool-like name that is not a registered tool.

## Small items (N)

| # | Item | Fix |
|---|---|---|
| N1 | Finding 1: the person's guide tools sit under "Other — Tools not yet sorted" | Their own area, "Your guide tools". `list_apps` then counts 16 built-in areas plus that one. |
| N2 | `get_service_health`'s `timing` says to sign in while the person is signed in. The probe is anonymous, so a 401 is expected. | A health probe's expected 401 is "answered (sign-in required for data)", not a sign-in verdict. |
| N3 | `save_observation_to_research` answers `applied: true` for a record already there | `changed: false`, "already in Research — left as it was". The same convention for every write that finds nothing to do. |
| N4 | `navigate_to` says `navigated: true` while no Verbinal window is showing | It adds `showing: false` and the reason. One rule: the one `list_ui_targets` uses (`UISnapshot.problem`). |
| N5 | `export_search_results` exports only the visible columns | The description says so, and the answer says how many columns. |
| N6 | `list_recent_cubes` keeps files that are gone, including figure temp files | Recents drop missing files when listed. Figure exports never enter recents. |
| N7 | `set_cube_camera` answers the eased value (80.21°) | It answers the clamped target (80°). |
| N8 | "CFHTMEGAPIPE, 1 items" | A plural rule in the catalogue: "1 item", "n items". French too. |
| N9 | `start_background_apply`'s description | It says that with auto-apply on, only destructive or standing changes wait, and it never starts those. |

## Handout corrections (handout 31)

1. **Counts:** 213 built-in tools in 16 areas, plus the person's guide tools in their own area (N1).
2. **3.2:** the radius is the Radius field, or typed after the target (R1).
3. **3.6:** `set_search_form` `execute` with `wait: false`, then `cancel_search` (R2).
4. **9.1–9.3:** `show_batch_jobs` opens it (T2). The filter shows above a tab with jobs (decision 5).
5. **10.3:** reads as `portal.sheet` from the images card and `portal.sheet.sheet` from the launch form.
6. **14.4:** the person turns auto-apply off for this case only.
7. **Re-run with CANFAR healthy:**
   - all of §11;
   - 2.4, 8.8, 9.5, 9.7, 10.5, 10.6, 12.4, 12.5, and §15 with the person;
   - every FAIL above, once its step is done.

## Order

1. **W0**, the diagnosis, before anything else touches the launch request.
2. **W1–W4, S, J, D**: what misleads or fails silently.
3. **T, R, F, L**: the gaps that blocked cases.
4. **C, P, K, G, N.**
5. **Q**: handout 31.

## Decisions for the person

1. **Closing sheets.** Should `close_ui` close any open sheet the way Esc would, alongside each sheet's
   `show_… close: true`? Or only the per-sheet tools?
2. **The search radius.** A **Radius** field like the Windows app, with `M101 0.2deg` still accepted?
   And the default stays 1′?
3. **Long answers.** Is 45 s the right cap for any synchronous answer, with the work carrying on behind
   it?
4. **Workflow templates.** Rewrite the notebook steps for `run_code`, or keep them and mark them "with
   the Notebook add-on"?
5. **Batch Jobs History.** Should it get the filter too? It holds 50 entries.
