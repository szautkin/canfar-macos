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

**Reviewed by the person on 2026-10-02.** Their decisions are at the end and are built in below.

## Status

| Step | What | State |
|---|---|---|
| **A** | What an assistant may do without asking: kinds of change, and a setting for each | planned — decisions 6–10, for review |
| **W** | Writes on CANFAR: say where they are; why they hung | planned — W0 diagnosis first |
| **S** | Silent no-ops and loose schemas | planned |
| **J** | Jobs CANFAR has dropped read as "gone", not "pending" | planned |
| **T** | Everything that opens, an assistant can open and close: every modal, popover, menu, panel, window | planned — decision 1 |
| **B** | The Batch Jobs filter on every tab, always shown | planned — decision 5 |
| **R** | Search radius, as a field | planned — decision 2 |
| **D** | `download_observation` `file` from another plane of the observation | planned |
| **F** | The file browser opens Downloads | planned — cause to confirm |
| **L** | No answer longer than 45 s; long work goes on, with progress | planned — decision 3 |
| **C** | `capture_view` shows the hints | planned |
| **P** | The channel profile in a range, binned | planned |
| **K** | A compute run that never reports | planned — cause to confirm |
| **G** | Workflow templates: `run_code` by default | planned — decision 4 |
| **N** | Small items | planned |
| **Q** | Handout 29 corrections; handout 31 | planned |

## What the report got wrong, or what was mine

| Report item | Checked | Finding |
|---|---|---|
| **Finding 1** "17 areas / 215 tools; the handout says 16 / 213" | `AIGuideCatalog.categoryByTool` maps all 213 built-in tools. The "Other" area held the person's two guide tools (`headless_jobs_rules`, `storage_rules`), which no built-in area can name. | **Handout error.** Handout 29 counted the built-in tools only. Kept as N1: the person's guide tools get an area of their own, "Your guide tools", instead of "Other — not yet sorted". |
| **Finding 13** "the Batch Jobs sheet has no filter field" | `HeadlessJobsDetailSheet` shows the filter above a tab that has jobs. The pass had 0 jobs on every tab; only History had entries (19). | **Behaved as built, but built wrong.** The person's decision is that the filter is always there, on every tab. Step B. |
| **Finding 4** "the Search form has no cone radius" | `SpatialBuilder.circle` reads a radius written after the target, as CADC's own search does: `M101 0.2deg`, `M31 30'`. Without one, the radius is 1′. The Windows app has a separate **Radius (deg)** field and `set_search_form`'s `searchRadius`. | **Half right.** The radius can be set, but nothing says how: not the field, and not `set_search_form`. The Windows app has the field, so this is a parity gap. Step R. |
| **Finding 5** "an agent cannot cancel a search" | Every search tool waits for TAP's answer before returning, so an assistant has nothing in flight to cancel. | **A testability gap, not a defect.** The Cancel button works (the "nothing running" reply is right). Step R adds `wait: false`. |
| **Finding 18** "with auto-apply on, `start_background_apply` has nothing to act on" | True by design: with auto-apply on, only destructive or standing changes wait, and the tool refuses those. | **Handout error.** 14.4 needs auto-apply off. The tool's description will say so (N). |
| **Finding 3** "`capture_view` cannot photograph the hints" | `CaptureViewTool.composited` captures one window (`.optionIncludingWindow`). The hints draw in their own panel above it. | **A real limitation.** Step C. |
| **§3** "the Portal RAM label" | QA withdrew it, rightly. | No change. |

## A — What an assistant may do without asking (the person, 2026-10-02)

The person: "make a clear distinction about what's destructive or not, and what kind of destructive is
allowed; a setting for what is allowed — then proceed without issues; if not allowed, wait for
confirmation from the user."

**Today** there is one switch, Auto-apply, over three classes (`VerbClass`, `AutoApplyPolicy`):

| Class | Tools | With Auto-apply on |
|---|---|---|
| `semanticWrite` | 33 | at once |
| `destructive` | 17 | always waits |
| `standingInstruction` | 4 | always waits |

`semanticWrite` mixes changes with very different consequences:

- a note on this Mac;
- a session launched on the person's allocation;
- a batch job, which the person's standing rule says needs their word, yet it applies at once;
- who may read their files (`set_vospace_acl`).

`destructive` mixes deleting a bookmark with deleting a VOSpace folder or stopping a session that
holds unsaved work.

**Proposed:** each change declares its *kind*, by what it does to what. The person sets each kind to
**Allowed** (it applies at once, with its `why` in the log) or **Ask me** (it waits in Pending for
them).

### The kinds

**Changes that add or change** (not destructive):

| Kind | Tools | Proposed default |
|---|---|---|
| **Notes and saved things on this Mac** | update_observation_note, bulk_update_observation_notes, save_query, update_saved_query, rename_recent_search, save_workflow, update_workflow, use_workflow, set_workflow_step, save_fits_bookmark, save_observation_to_research, add_registry_image | Allowed |
| **Files saved on this Mac** — new files, never over an existing one | download_observation, download_observations_bulk, download_cutout, download_vospace_file, open_vospace_file, export_search_results, export_fits_figure, export_cube_figure, export_research_bundle, export_session_log | Allowed |
| **Add to your CANFAR storage** — new files and folders | create_vospace_folder, upload_text_to_vospace, upload_file_to_vospace, upload_to_vospace | Allowed |
| **Use your CANFAR allocation: sessions and compute** | launch_session, renew_session, start_compute, run_code | Allowed |
| **Use your CANFAR allocation: batch jobs and image probes** | launch_headless_job, discover_image_packages (a probe is a batch job) | **Ask me**, as the standing rule says |
| **Sharing** — who may read or write your files | set_vospace_acl | **Ask me** |
| **What every assistant is told** | add_guide_tool, update_guide_tool, set_tool_description, clear_tool_description | **Ask me**, see decision 8 |

**Changes that remove, replace or stop** (destructive):

| Kind | Tools | Proposed default |
|---|---|---|
| **Remove what an assistant made** — anything the session log shows an assistant created | the delete tools below, when their target was made by an assistant | **Allowed** — this is how a QA pass cleans up after itself. See decision 9. |
| **Remove notes and saved things on this Mac** | delete_saved_query, remove_recent_search, delete_workflow, delete_fits_bookmark, remove_registry_image, clear_probe_failures, delete_guide_tool | Ask me |
| **Remove files on this Mac** | remove_downloaded_file, delete_downloaded_observation | Ask me |
| **Remove from your CANFAR storage** — also an upload over an existing file | delete_vospace_node; an upload that would replace a file | Ask me |
| **Stop running work on CANFAR** — unsaved work in it is lost | delete_session, stop_compute | Ask me |
| **Everything at once** | clear_recent_searches, clear_research_archive, clear_user_site, delete_sessions_bulk, delete_session_logs | Ask me — see decision 10 |

View changes — `navigate_to`, sorting, selecting, opening and closing (step T) — are not changes to
anything and always happen at once, as now.

### How it works

| Part | What |
|---|---|
| **A1 — one owner** | `ChangeKind` in VerbinalKit: each kind's name, whether it is destructive, and its default. Every changing tool declares its kind (`static let change`) in place of `verbClass`'s three write classes. `AutoApplyPolicy.appliesAtOnce(kind, settings)` is the only place that decides. A tool whose kind depends on its target asks one function. That covers a delete of what an assistant made (A3) and an upload over an existing file. |
| **A2 — the setting** | Settings ▸ AI Agent ▸ **What an assistant may do without asking**: a row per kind, **Allowed** or **Ask me**, the destructive kinds marked, each with one line on what it covers, and **Restore defaults**. The master Auto-apply switch goes: on maps to the defaults above; off maps to Ask me for every kind. Kept per Mac, like the rest of Settings. |
| **A3 — made by an assistant** | The session log already records every change with who made it. One lookup answers "was this made by an assistant, and in which session" for a record, a file, a folder, a saved query, a workflow or a bookmark. It is created when the change applies and read by A1. Nothing the person made is ever in it. |
| **A4 — what an assistant is told** | Each tool's description ends with the person's current setting for its kind ("You allow this: it applies at once", or "The person asks to approve this: it waits in Pending"). `get_current_view` gives the table. When the setting changes, the tool list is re-announced, as it is when Verbinal starts. |
| **A5 — what the person is told** | Pending names each change's kind, and why it waits ("You asked to approve: Stop running work on CANFAR"). The session log's decisions cite the setting, not "Auto-apply is on". This also fixes W3's wrong reason. |
| **A6 — the person's own clicks** | Unchanged. The confirmation dialogs in the app ("Stop and delete this running job?") guard the person's clicks; an assistant's changes go through this setting and Pending. |
| **A7 — tests** | Every changing tool has a kind; a test fails on one without. Each kind, Allowed and Ask me, applies or waits. A delete of something an assistant made is allowed while the same delete of the person's own waits. An upload over an existing file is classed as a replacement. The settings round-trip, and the old Auto-apply switch maps as above. |

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
Clients differ, and Claude Code waits longer, but 60 s is a common limit.

**Fix (decision 3):** no synchronous answer takes longer than 45 s. That is one shared constant. Past
it, the tool answers and the work goes on, with a progress bar.

- **A read past 45 s** answers that it is still waiting, with its `timing` block: "VOSpace has not
  answered in 45 s; it carries on". The request keeps going and fills the screen and the cache when it
  answers. A second call answers from that.
- **A write past 45 s** answers with its job id, as proposals already do: "still applying; follow with
  `get_job_status`".
- **What goes on shows as a task**, with a progress bar on the activity bar and its stage in
  `list_activity`. That uses W1's single path, so the person and the assistant see the same thing.
- The service's own deadline stays as it is.

## Gaps

### T — Everything that opens, an assistant can open and close (Findings 8, 11; decision 1)

The person's decision: "MCP should be able to open and close any modal, screen, dropdown — anything in the
app". Today it can open folded sections, pop-up menus, menu buttons and the file browser. It can also
open a few sheets, through their own tools (`show_launch_form`, `show_cutout_editor`,
`open_observation_detail`). It cannot close most of them.

**What there is to open** (today's source):

| Kind | Count |
|---|---|
| Sheets | 34, in 24 files |
| Popovers | 7 |
| Confirmation dialogs | 13 |
| Alerts | 5 |
| System Open/Save file panels | 22 places |
| Menus and menu buttons | 18 |
| Right-click menus | 9 |
| Folded sections | 10 |
| Hidden panels | 1 (the file browser) |
| Windows | Settings, and the main window |

A tool per sheet would not stay true as sheets are added. So this is one mechanism, guarded by a test.

| Kind | Open | Close |
|---|---|---|
| Folded section, pop-up, menu button, hidden panel | `open_ui`, as now | `close_ui`, as now |
| Sheet, popover, About, Settings | `open_ui` on the control that opens it. Or `open_ui` by its name, when it needs nothing chosen first: Batch Jobs, Image Content Discovery, About. | `close_ui` by its name, or the front one: its own dismissal |
| Right-click menu | `open_ui` on the element it belongs to (`AXShowMenu`) | `close_ui` (Esc) |
| System Open/Save panel | `open_ui` on the control that opens it | `close_ui`: Cancel |
| Confirmation, alert | Only by the action it confirms, never on its own: a destructive confirmation is the person's. | `close_ui`: Cancel |
| The main window, when none is showing | `open_ui` `main window` (the `problem` answer names it) | the person |
| Tabs and segments: Batch Jobs' tabs, Flexible / Fixed, a sheet's tabs | `select_ui` selects one: view state, never an action | — |

Choosing in a menu or pressing a button inside a sheet stays what it is today: a dedicated tool's job,
or the person's. Opening never chooses.

| Part | Fix |
|---|---|
| **T1 — one registry of what is shown** | `.uiSheet(name, isPresented:)`, `.uiSheet(name, item:)`, `.uiPopover(…)`, `.uiConfirmation(…)` and `.uiAlert(…)` wrap SwiftUI's modifiers. While something is shown, it registers its name, kind, window and how to dismiss it. Every `.sheet`, `.popover`, `.confirmationDialog` and `.alert` in the app moves to them, and the system file panels go through one helper that does the same. `list_ui_targets` lists what is open (`presented`). `get_current_view` names the front one. |
| **T2 — what opens them** | `.opens(name)` marks the control that presents something: Jobs & History…, Cut Out…, an info button, Upload…. `list_ui_targets` lists it with `opens: name` and `closed`. `open_ui` presses it once, as the person's click would, and nothing inside is chosen. A hand tag and the marker share the identifier (`vb:portal.batchJobs` plus the marker), so they are encoded together. |
| **T3 — by name** | A presentation that needs nothing chosen first has its flag in `AppState`: Batch Jobs (with its tab), Image Content Discovery (one flag, from Portal or from the launch form), About, and the others the inventory finds. `open_ui` by its name sets the flag, after `navigate_to` its screen. One owner per flag. Closing the main window resets them all (`mainWindowClosed`, already). The `show_…` tools that take arguments stay: `show_launch_form`, `show_cutout_editor`, `open_observation_detail`. |
| **T4 — closing** | `close_ui` closes any open presentation, by its name or the front one, through T1's registry. It never presses a button inside. |
| **T5 — tabs and segments** | `select_ui` selects a tab or a segment: Flexible / Fixed (Finding 11), Batch Jobs' tabs, Standard / Advanced / Headless. Selecting one is view state, and buttons that act are still never pressed. `show_launch_form` also takes `resources`, `cores`, `ram` and `gpus` to fill the form. It launches nothing. |
| **T6 — named copies** | `use_workflow` takes `name` (Finding 11). |
| **T7 — guardrails** | A test scans the source and fails on any `.sheet(`, `.popover(`, `.confirmationDialog(`, `.alert(` or `NSOpenPanel`/`NSSavePanel` outside T1's wrappers. A test opens and closes each named presentation through the tools. `EveryScreenNamedTests` lists each screen's openers. |

### B — The Batch Jobs filter on every tab (decision 5)

The filter field is always there, on every tab, History and empty tabs included. On History it matches
a job's name, image, id and failure reason. With nothing to match it says "No jobs match". On an empty
tab it says that tab's empty sentence. `show_batch_jobs`, or `open_ui` by name, takes `filter`.

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

### G — Workflow templates (Finding 17; decision 4)

Four templates name the Notebook add-on's tools, which the app does not have:
`variable-star-photometry`, `dao-espadons-spectroscopy`, `jcmt-cube-kinematics` and
`proposal-due-diligence` (`create_analysis_notebook`, `run_all_cells`).

- **The default is `run_code`.** Each of those steps says what to run with `run_code` on Remote Compute.
  With the Notebook add-on installed, its tools are the alternative. `get_workflow` says which applies on
  this Mac: the add-on's tools when they are registered, otherwise `run_code`.
- **Guardrail:** a test reads every template and fails on any tool-like name that is neither a
  registered tool nor in the declared list of add-on tools.

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
4. **9.1–9.3:** `open_ui` opens it by name or from Jobs & History… (T2, T3). The filter is on every tab
   (B). Add cases that open and close a sheet, a popover, a right-click menu and a file panel, and select
   a tab and a segment (T).
5. **10.3:** reads as `portal.sheet` from the images card and `portal.sheet.sheet` from the launch form.
6. **14.4:** the person turns auto-apply off for this case only.
7. **Re-run with CANFAR healthy:**
   - all of §11;
   - 2.4, 8.8, 9.5, 9.7, 10.5, 10.6, 12.4, 12.5, and §15 with the person;
   - every FAIL above, once its step is done.

## Order

1. **W0**, the diagnosis, before anything else touches the launch request. **A**, once its decisions
   are made: the rest of the plan's writes are classed by it.
2. **W1–W4, S, J, D**: what misleads or fails silently.
3. **T, B, R, F, L**: the gaps that blocked cases. T is the largest step. It goes T1 (the registry)
   then T7 (the guardrail, red until every presentation is moved), then T2–T6.
4. **C, P, K, G, N.**
5. **Q**: handout 31.

## Decisions (the person, 2026-10-02)

1. **Open and close.** "MCP should be able to open and close any modal, screen, dropdown — anything in
   the app." → **T**, everything that opens. *The plan's boundary:* a confirmation or an alert opens
   only through the action it confirms, never on its own, and opening never chooses.
2. **Search radius.** A **Radius** field like the Windows app; `M101 0.2deg` still accepted; the
   default stays 1′. → **R1**.
3. **Long answers.** 45 s is the cap; show a progress bar and carry on. → **L**, with W1.
4. **Workflow templates.** `run_code` is the default when the add-on is not there. → **G**.
5. **Batch Jobs filter.** On every tab, by default, never hidden. → **B**.
**Still open — section A:**

6. **The kinds and their defaults** (section A). Are these the right rows, and the right defaults?
7. **Two choices or three?** Allowed / Ask me, as asked. Or also **Never**, refused outright with "the
   person does not allow this" (e.g. "Everything at once")?
8. **What every assistant is told.** Configurable like the rest, or always Ask me? Text an assistant
   reads, in a file or a web page, could make it set an instruction that steers every later assistant.
   That is why it waits today.
9. **"Made by an assistant"** — by any assistant, any session? Or only the session asking to remove it?
10. **Everything at once** — its own row, Ask me by default, even when single removals of the same kind
    are allowed?

