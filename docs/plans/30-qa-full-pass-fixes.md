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
| **A** | What an assistant may do without asking: kinds of change, and a setting for each | done — A1 `196a757`, A2 `cb37ef1`, A3 `19dfeff`, A5 `6db6106`, A6 (this commit). Next: W1–W4 |
| **W** | Writes on CANFAR: tasks, honest advice, no second launch by accident | done (this commit): W1 SessionLaunches, W2 advice, W3 in A2, W4 retry looks first. W0b with the person |
| **S** | Silent no-ops and loose schemas | done — S1–S5 (this commit) |
| **J** | Jobs CANFAR has dropped read as "gone", not "pending" | done — J1, J2 (this commit) |
| **T** | Everything that opens, an assistant can open and close: every modal, popover, menu, panel, window | planned — decision 1 |
| **B** | The Batch Jobs filter on every tab, always shown | done (this commit) |
| **R** | Search radius, as a field | planned — decision 2 |
| **D** | `download_observation` `file` from another plane of the observation | done (this commit) |
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
| **Add to your CANFAR storage** — new files and folders | create_vospace_folder (and its alias vospace_mkdir), upload_text_to_vospace, upload_file_to_vospace, upload_to_vospace | Allowed |
| **Use your CANFAR allocation: sessions and compute** | launch_session, renew_session, start_compute, run_code | Allowed |
| **Use your CANFAR allocation: batch jobs and image probes** | launch_headless_job, discover_image_packages (a probe is a batch job) | Allowed (the person, decision 6). Their standing rule `headless_jobs_rules` still guides assistants. |
| **Sharing** — who may read or write your files | set_vospace_acl | **Ask me** |
| **What every assistant is told** | add_guide_tool, update_guide_tool, delete_guide_tool, set_tool_description, clear_tool_description | **Ask me, always**: not a setting (decision 8) |

**Changes that remove, replace or stop** (destructive):

| Kind | Tools | Proposed default |
|---|---|---|
| **Remove what an assistant made** — anything the session log shows an assistant created | the delete tools below, when their target was made by an assistant | **Allowed** — this is how a QA pass cleans up after itself. See decision 9. |
| **Remove notes and saved things on this Mac** | delete_saved_query, remove_recent_search, delete_workflow, delete_fits_bookmark, remove_registry_image, clear_probe_failures | Ask me. Removing a guide tool is "what every assistant is told": it could remove the person's own rule. |
| **Remove files on this Mac** | remove_downloaded_file, delete_downloaded_observation | Ask me |
| **Remove from your CANFAR storage** — also an upload over an existing file | delete_vospace_node; an upload that would replace a file | Ask me |
| **Stop running work on CANFAR** — unsaved work in it is lost | delete_session, stop_compute | Ask me |
| **Everything at once** | clear_recent_searches, clear_research_archive, clear_user_site, delete_sessions_bulk, delete_session_logs | Ask me — see decision 10 |

View changes — `navigate_to`, sorting, selecting, opening and closing (step T) — are not changes to
anything and always happen at once, as now.

### How it works

| Part | What |
|---|---|
| **A0 — decisions** | 6: the kinds and defaults as above, batch jobs Allowed. 7: two choices, Allowed and Ask me. 8: what every assistant is told always waits; it is listed but not settable. 9: "made by an assistant" means any assistant, any session, as the session log records it. 10: everything at once is its own row, Ask me by default. |
| **A1 — one owner** | `ChangeKind` in VerbinalKit: each kind's name, whether it is destructive, and its default. Every changing tool declares its kind (`static let change`) in place of `verbClass`'s three write classes. `AutoApplyPolicy.appliesAtOnce(kind, settings)` is the only place that decides. A tool whose kind depends on its target asks one function. That covers a delete of what an assistant made (A3) and an upload over an existing file. |
| **A2 — the setting** | Settings ▸ AI Agent ▸ **What an assistant may do without asking**: a row per kind, **Allowed** or **Ask me**, the destructive kinds marked, each with one line on what it covers, and **Restore defaults**. The master Auto-apply switch goes: on maps to the defaults above; off maps to Ask me for every kind. Kept per Mac, like the rest of Settings. |
| **A3 — made by an assistant** | The session log already records every change with who made it. One lookup answers "was this made by an assistant, and in which session" for a record, a file, a folder, a saved query, a workflow or a bookmark. It is created when the change applies and read by A1. Nothing the person made is ever in it. |
| **A4 — what an assistant is told** | Each tool's description ends with the person's current setting for its kind ("You allow this: it applies at once", or "The person asks to approve this: it waits in Pending"). `get_current_view` gives the table. When the setting changes, the tool list is re-announced, as it is when Verbinal starts. |
| **A5 — what the person is told** | Pending names each change's kind, and why it waits ("You asked to approve: Stop running work on CANFAR"). The session log's decisions cite the setting, not "Auto-apply is on". This also fixes W3's wrong reason. |
| **A6 — the person's own clicks** | Unchanged. The confirmation dialogs in the app ("Stop and delete this running job?") guard the person's clicks; an assistant's changes go through this setting and Pending. |
| **A7 — tests** | Every changing tool has a kind; a test fails on one without. Each kind, Allowed and Ask me, applies or waits. A delete of something an assistant made is allowed while the same delete of the person's own waits. An upload over an existing file is classed as a replacement. The settings round-trip, and the old Auto-apply switch maps as above. |

## Defects confirmed

### W — Writes on CANFAR (Finding 12, HIGH)

**W0, done: what the person's session log shows** (`20261001-192812-7C0354FE.jsonl`)

| Time (UTC) | What |
|---|---|
| 03:13:27 | `launch_session` `qa-full-nb` applied at once (token 445). No task was started for it. |
| 03:16:27 | Its `POST` timed out: URLError −1001 after its 180 s (474). It failed (475). |
| 03:23:41 | `launch_headless_job` `qa-full-echo` applied at once, as **task 9** on the activity bar (493, 494). |
| 03:26:41 | Its `POST` timed out the same way; task 9 failed (517–519). |
| 03:26:38, 03:26:45 | **The person pressed Apply on both failed proposals in Pending.** That started a second notebook launch and task 10 (521). |
| 03:29:38, 03:29:46 | Both timed out again (535–541). |

Every `GET` to the same service in those minutes answered in 0.4–1.4 s. The cluster's memory was 100%
reserved (the Portal's load card; the report's §3).

**Conclusions:**
- CANFAR took both kinds of launch request and did not answer them in three minutes, four times.
  Nothing in the log points at our request. **W0b**, with the person when CANFAR is healthy: one launch
  from the launch form and one by an assistant, both timed, to rule the request out.
- The report's "duplicate `proposalFailed`" is the person's second Apply, not a second emitter.
- The real risk is a retry. A launch that timed out may have been made by CANFAR all the same, and
  Apply again would start a second session.

| Part | Fix |
|---|---|
| **W1** | Every apply that calls CANFAR runs as a task, through the one path downloads use (`changes.run`): launch, renew, delete, bulk delete, start and stop compute. The batch-job launch already does. |
| **W2** | The timeout's advice names what exists: "it may have been made all the same: `list_sessions` (or `list_headless_jobs`) shows whether it was; `get_job_status` follows it". The activity bar is named only where W1 puts the task. |
| **W3** | `now.proposalsWaiting` lists only proposals waiting for the person, with the reason step A gives. A proposal that is applying is under `tasksRunning`. One that failed is in the log as failed. |
| **W4 — no second launch by accident** | Before a launch is applied again after a timeout, Verbinal asks CANFAR whether a session or job of that name was made since the first attempt. If it was, the apply ends as done, naming it, and nothing new is launched. Pending's Apply on such a proposal says "The last attempt timed out — CANFAR may have made it; checked first". The same applies to a retry of a delete: it skips one that is already gone. |

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
6. **The kinds and defaults** as section A proposes, with batch jobs and image probes **Allowed**. → A.
7–10. "Proceed" on the plan's proposals:
   - two choices;
   - what every assistant is told always waits;
   - "made by an assistant" is any assistant;
   - everything at once is its own row, Ask me. → A0.

