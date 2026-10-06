# QA handout — plan 30's fixes, and handout 29 again

**Date:** 2026-10-06
**Build:** `release/1.4.0` at `c17f25e` or later. `describe_app` must say
`serverVersion: "1.4.0"`; record its `buildCommit` (a `+` means uncommitted changes).
**Audience:** the assistant that ran [handout 29](./29-qa-full-app-validation.md), or another, connected
over MCP, with the person watching the screen. About three hours. Each part (§0–§14) stands alone.
**Related:**
- [Plan 30](./30-qa-full-pass-fixes.md): what the QA report found, and what changed
- [Handout 29](./29-qa-full-app-validation.md): the full pass. Its ground rules hold here, with the
  changes below.
- [AGENTS.md](../../AGENTS.md): how to connect

This pass checks plan 30's fixes, then re-runs what handout 29 could not finish. Where a case finds
something wrong, the report says what, with the evidence; it does not try to fix it.

Record each case as **PASS / FAIL / BLOCKED / SKIPPED**, with:

- the tool's JSON for a FAIL;
- what the person saw, when the case is about the screen;
- the `logToken` of any reply that carries a `timing` block and failed or was slow.

---

## What changed since handout 29

1. **What an assistant may do without asking is set kind by kind** (plan 30 A). Settings ▸ AI Agent ▸
   **What an assistant may do without asking** has a row per kind of change, each **Allowed** or
   **Ask me**. The Auto-apply switch is gone.
   - An allowed kind applies at once; any other waits in Pending.
   - **What every assistant is told** (guide tools, tool descriptions) always waits.
   - **Remove what an assistant made** is allowed by default: removing what any assistant made, as the
     session log records it, applies at once. Removing the person's own waits.
   - Each tool's description ends with its kind's setting. `get_current_view` lists them all
     (`permissions`).
2. **Every sheet, popover, confirmation, alert and file panel is known by name while it shows**
   (`presented`). `close_ui` closes any of them by name or `front`, as Esc or Cancel would.
   `open_ui` opens a sheet by its name when nothing has to be chosen first (`opensByName`). Otherwise it
   presses the one control that opens it (`opens` in `list_ui_targets`). A right-click menu stays the
   person's.
3. **`select_ui` selects tabs and segments** too, such as Flexible / Fixed and the Batch Jobs tabs.
4. **No answer takes longer than 45 s.** Slower work carries on and shows on the activity bar.
5. **Counts:** 213 built-in tools in 16 areas, plus the person's guide tools in their own area, "Your
   guide tools".

## Ground rules

Handout 29's twelve rules hold, with two changes:

- **Rule 8 becomes:** a change of a kind the person asks to approve waits in Pending, and so does
  anything that changes what every assistant is told. Propose a destructive change only where a case
  says so. Never treat a waiting proposal as done.
- **Make what you test with under `qa-31-`:** a VOSpace folder `verbinal-qa-31/`, saved queries and
  workflows whose names start with `qa-31-`. Removing them is "what an assistant made", so it applies at
  once by default. Never remove anything else.

## Before you start

1. The person runs Verbinal from `release/1.4.0` and signs in to CADC.
2. Settings ▸ AI Agent: **Allow external AI agents** on. Leave **What an assistant may do without
   asking** as the person has it. `get_current_view` `permissions` records it for the report.
3. Connect, `describe_app`, `start_session`; the person clicks Allow.
4. **Keep the screen unlocked for the whole pass.** Several fixes can only be seen on screen.

---

## 0. Bearings

| # | Steps | PASS if |
|---|---|---|
| 0.1 | `describe_app`. | `serverVersion` 1.4.0, `buildCommit`, the brief, the standing rules. The brief says how kinds of change apply, and that answers come within 45 s. |
| 0.2 | `list_apps`. | 16 areas and 213 tools, plus **Your guide tools** with the person's guide tools (e.g. `headless_jobs_rules`). No "Other" area. |
| 0.3 | `get_current_view`. | `permissions`: each kind with `allowed` and its title; `presented` when something is open. |
| 0.4 | `man` `save_query`, then `man` `delete_vospace_node`. | Each description ends with its kind and the person's setting for it: "The person allows it without asking…" or "The person asks to approve it…". |
| 0.5 | `get_service_health`. | Each service's state. The reply's `timing`, if any, never tells you to have the person sign in: a probe's 401 is an answer. |

## 1. Kinds of change (plan 30 A)

| # | Steps | PASS if |
|---|---|---|
| 1.1 | `save_query` `qa-31-query`, with a `why`. | Applies at once (Notes and saved things: Allowed by default); `id` in the answer. |
| 1.2 | `delete_saved_query` `qa-31-query`. | Applies at once: an assistant made it. `get_session_log` shows the rule, "Remove what an assistant made". |
| 1.3 | If `permissions` shows **Remove notes and saved things on this Mac** as Ask me: `remove_recent_search` one of the person's recent searches, `why` "QA 31: checks it waits"; then `withdraw_proposal` it at once. Otherwise SKIPPED. | It waits in Pending, which names the kind and why it waits. Withdrawn, nothing is removed. |
| 1.4 | The person sets **Notes and saved things on this Mac** to Ask me. `save_query` `qa-31-asked`. The person applies it in Pending, then sets the kind back. | It waits, saying the person asks to approve this kind. `man save_query` now says it waits. Once applied, it is there. |
| 1.5 | Only on the person's word: `add_guide_tool` `qa-31-note`; then `withdraw_proposal` it. | It waits, whatever the settings: what every assistant is told always waits. Otherwise SKIPPED. |
| 1.6 | `start_background_apply` a proposal of a kind set to Ask me (the one from 1.3 or 1.4, before it is applied or withdrawn). | Refused, saying the person approves it in Verbinal. |

## 2. Writes on CANFAR (plan 30 W)

Only with CANFAR healthy (`get_platform_load`, `get_service_health`), and with the person's agreement for
each launch.

| # | Steps | PASS if |
|---|---|---|
| 2.1 | **W0b, with the person.** The person launches a small notebook `qa-31-ui` from the launch form, and notes how long it takes to show as Pending, then Running. | It launches. The time goes in the report. |
| 2.2 | `launch_session` a small notebook `qa-31-nb`. `list_activity` while it launches. | A task for the launch on the activity bar, as with the person's. The answer has the session id. The time to Running goes in the report, next to 2.1's. |
| 2.3 | `delete_session` `qa-31-nb`. | An assistant made it, so it applies at once (Remove what an assistant made), unless the person changed that row. The person deletes `qa-31-ui` themselves. |

## 3. Shapes (plan 30 S)

| # | Steps | PASS if |
|---|---|---|
| 3.1 | `bulk_update_observation_notes` with an item that nests its fields: `{"publisher_id": …, "notes": {"text": "x"}}`. | Refused, naming the unknown key and where it is (``items[0]`` `notes`). |
| 3.2 | `update_observation_note` with only `publisher_id`. | Refused: nothing to change. |
| 3.3 | `set_cube_transfer` `opacityCurve` `[1, 2]` (with a cube open). | Refused, saying the shape: `[[value, alpha], …]`. |
| 3.4 | `get_search_results` after a search; `set_results_view` a unit the column does not have. | Each column lists its `units`; the refusal names the valid ones. |

## 4. Jobs CANFAR no longer lists (plan 30 J)

| # | Steps | PASS if |
|---|---|---|
| 4.1 | `list_job_history`; take a job older than a day; `get_headless_job_logs` and `get_headless_job_events` it. | `state: "gone"`, with a note that `list_job_history` keeps what is known. Never `pending`. |

## 5. Search (plan 30 R, D; N5)

| # | Steps | PASS if |
|---|---|---|
| 5.1 | `set_search_form` target "M101", `searchRadius` 0.2 (degrees). | The **Radius** field shows it; the ADQL uses 0.2°. |
| 5.2 | `set_search_form` target "M101 0.2deg", no radius. | Still read as a 0.2° radius. |
| 5.3 | `set_search_form` a wide search with `execute: true`, `wait: false`; then at once `cancel_search`. | The first answers at once (`started`); the search stops. |
| 5.4 | `get_data_links` an observation with several planes; `download_observation` a file from a plane other than the one its publisher id names (ask; a small file). | The links give each file's `productID` and `publisherID`. The download is refused, naming the publisher id that holds it. |
| 5.5 | `export_search_results` CSV (ask where). | The answer gives the file and "N rows × M columns: the columns shown in the results table". |

## 6. Opening and closing (plan 30 T)

Say what you are about to open before each case.

| # | Steps | PASS if |
|---|---|---|
| 6.1 | Portal: `open_ui` `Batch Jobs`. `list_ui_targets`. | The sheet opens; `presented` lists it. The filter field is there on every tab, empty ones included. |
| 6.2 | In it: `select_ui` the History tab (named with its count, `History (12)`), then another. | Each tab shows, as a click shows it. Nothing else changes. |
| 6.3 | `close_ui` `Batch Jobs`. Then `open_ui` `portal.batchJobs` (the Jobs & History… button); `close_ui` `front`. | Closed; opened again from its button (`opens: "Batch Jobs"` in `list_ui_targets`); closed. |
| 6.4 | `show_launch_form` with `cores` and `ram` the form offers. Then with a `cores` it does not offer. | The form opens on Fixed with those sizes. The second is refused, listing what it offers. Nothing launches. |
| 6.5 | In the launch form: `select_ui` `Flexible`, then `Fixed`. `close_ui` `Launch Session`. | The segment follows; the form closes. |
| 6.6 | Search results: `open_ui` `Columns`; `list_ui_targets`; `close_ui` `Columns`. | The popover opens from its button and lists its columns; it closes. |
| 6.7 | An observation's detail (Search or Research): `open_ui` `Cut Out`; `close_ui` `Cut Out`. | The editor opens from its Cut Out… button and closes. Nothing is cut. |
| 6.8 | Storage: `open_ui` `Upload File`; `list_ui_targets`, `get_current_view`; `close_ui` `Upload File`. | The system panel opens (`waiting: true`). While it is up, the tools still answer, and `presented` lists it as a file panel. It closes as Cancel; nothing is uploaded. |
| 6.9 | `open_ui` `About Verbinal`; `close_ui` `front`. `open_ui` `Pending Changes`; `close_ui` it. | Each opens by name and closes. |
| 6.10 | `open_ui` an element with a right-click menu (a Research observation). | Not opened: a right-click menu is the person's. |
| 6.11 | The person opens a confirmation (a Delete button on something of their own, then stops). `close_ui` `front`. | It closes as Cancel; nothing is deleted. |
| 6.12 | The person minimizes the main window. `open_ui` `Main Window`. Then the person closes it (no sheet open) and you `open_ui` `Main Window` again. | Restored. After a close, it reopens — or the answer says to ask the person to click Verbinal in the Dock. Either way, the report says which. |
| 6.13 | `use_workflow` a template with `name` `qa-31-copy`, twice. | Titled `qa-31-copy`, then `qa-31-copy (2)`. Remove both (applies at once). |

## 7. Answers within 45 s (plan 30 L)

| # | Steps | PASS if |
|---|---|---|
| 7.1 | Any call that waits on CADC (a wide `run_search`, a big `list_vospace_path`). Time it. | An answer by 45 s. If the work is not done, the answer says it carries on, and `list_activity` shows "Answering …" until it ends. |

## 8. The picture shows the hints (plan 30 C)

| # | Steps | PASS if |
|---|---|---|
| 8.1 | `show_ui_hints` three numbered hints with `dim`; `capture_view`. | The picture has the rings, bubbles and dimming as the person sees them; the caption says `hints: true`. |

## 9. The channel profile (plan 30 P)

| # | Steps | PASS if |
|---|---|---|
| 9.1 | A cube open: `get_cube_channel_profile`. | At most 500 values; `bin` says how many channels each holds; `unit` and the spectral `axis`. |
| 9.2 | `firstChannel` / `lastChannel` a short range, `bin: 1`. | Every channel in it, with its place on the axis. |

## 10. Compute runs (plan 30 K)

| # | Steps | PASS if |
|---|---|---|
| 10.1 | `list_compute_runs`. | No run is "running" past its timeout and five minutes. Run `634F932B` from handout 29 reads `noResult` (or its result, if it came). |
| 10.2 | Only if set up and the person agrees: `run_code` a five-second sleep, then `print(1)`; the person signs out and in at once; `list_compute_runs` after a minute. | The run ends `ok` with `1`: it was watched again after sign-in. |

## 11. Workflow templates (plan 30 G)

| # | Steps | PASS if |
|---|---|---|
| 11.1 | `get_workflow` `builtin:variable-star-photometry` (the id `list_workflows` gives). | Its analysis steps' `use` is `run_code` (without the Notebook add-on), with `addonTools` naming the add-on's. |

## 12. Small items (plan 30 N)

| # | Steps | PASS if |
|---|---|---|
| 12.1 | `save_observation_to_research` a result twice. | The second answers `changed: false`, "already in Research — left as it was". |
| 12.2 | The person hides Verbinal (⌘H). `navigate_to` `search`. The person shows it again. | `navigated: true`, `showing: false`, and why. |
| 12.3 | `set_cube_camera` `elevationDeg` 90. | The answer says 80, not 80.21. |
| 12.4 | Research: a collection holding one observation; `list_ui_targets`. | Its name reads "…, 1 item, …". |
| 12.5 | The person deletes a file the cube viewer opened lately; `list_recent_cubes`. | That file is not listed. No figure temp file is either. |
| 12.6 | The file browser (`open_ui` `file browser`). | It opens on the person's Downloads and lists it. |

## 13. Handout 29 again

Re-run these from handout 29 with CANFAR healthy, with the corrections in brackets:

- All of **§11** (Storage), under `verbinal-qa-31/`.
- **2.4**, **8.8**, **9.5**, **9.7**, **10.5**, **10.6**, **12.4**, **12.5**, and **§15** with the person.
- **3.2** [the radius is the Radius field, or typed after the target], **3.6** [`set_search_form`
  `execute`, `wait: false`, then `cancel_search`].
- **9.1–9.3** [`open_ui` opens the sheet by name or from Jobs & History…; the filter is on every tab].
- **10.3** [it reads as `portal.sheet` from the images card, and `portal.sheet.sheet` from the launch
  form].
- **14.4** [`start_background_apply` a proposal of a kind the person allows; one they ask to approve is
  refused, as 1.6].
- Every case that FAILED in handout 29's report.

## 14. Clean-up

Remove everything `qa-31-`: saved queries, workflows, the VOSpace folder, sessions. It applies at once,
as an assistant made it. Leave anything still waiting in Pending for the person.

---

## Report

Write it where the person asks; earlier passes used
`~/Documents/Default Project/qa-report-verbinal-canfar-<date>.md`.

1. **The build:** `buildCommit`, the date, the session id, and `permissions` as they were.
2. **A table of every case:** PASS / FAIL / BLOCKED / SKIPPED, one line each.
3. **For each FAIL:** the tool's JSON; what the person saw; the `logToken` and what `explain_log_entry`
   says.
4. **W0b:** the two launch times, side by side.
5. **Anything found outside the cases.**
6. **Clean-up:** what you made, and what is gone.
