# QA handout — the whole app: every feature, every tool

**Date:** 2026-10-01
**Build:** `release/1.4.0` at `bdf4a56` or later. `describe_app` must say `serverVersion: "1.4.0"`; record
its `buildCommit` (a `+` means uncommitted changes).
**Audience:** an assistant new to Verbinal, connected to it over MCP, with the person watching the screen.
About four hours. Each part (§0–§16) stands alone, so the pass can be split across sittings.
**Related:**
- [AGENTS.md](../../AGENTS.md): how to connect
- [Agent ↔ UI parity](../agent-ui-parity.md): every interaction and its tool
- [Handout 28](./28-qa-regression-plan27.md): hints, in depth

This pass checks that everything a person can do in Verbinal works, and that an assistant can do it too:
every screen, every feature, and the 213 tools that reach them. It is a validation of the whole app, not
of one plan. Where a case finds something wrong, the report says what, with the evidence; it does not try
to fix it.

Record each case as **PASS / FAIL / BLOCKED / SKIPPED**, with:

- the tool's JSON for a FAIL;
- what the person saw, when the case is about the screen;
- the `logToken` of any reply that carries a `timing` block and failed or was slow.

---

## What Verbinal is

A Mac app for the Canadian Astronomy Data Centre (CADC) and the CANFAR science platform. Its screens
(`navigate_to` `mode`):

| Screen | `mode` | What it does | Sign-in |
|---|---|---|---|
| Home | `landing` | Tiles for each screen; the AI Assistant tile | — |
| Search | `search` | The CADC archive: a form (target, position, time, spectrum, data train), results, ADQL | — |
| Portal | `portal` | CANFAR: platform load, sessions (notebook, desktop, CARTA…), launch form, images, recent launches, Batch Jobs | yes |
| Research | `research` | Observations kept on this Mac, with their files, notes, cutouts | — |
| Storage | `storage` | The person's VOSpace (`arc`) home: browse, upload, download, folders, sharing, quota | yes |
| FITS Viewer | `fitsViewer` | Images: stretch, colour, WCS, probe, bookmarks, blink, marks, figures, spectra | — |
| Cube Viewer | `cubeViewer` | 3D cubes: slices, volume, spectrum, channel profile, marks, figures | — |
| Remote Compute | `remoteCompute` | A CANFAR session that runs code for an assistant (`run_code`) | yes |
| Workflows | `workflows` | Step-by-step protocols, from templates | — |
| AI Guide | `aiGuide` | What every assistant is told: the person's guide tools and tool descriptions | — |

Around them:

- **Settings** (⌘,), with sections `general`, `portal`, `agent`, `imageDiscovery`, `aiCompute`,
  `mcpClients`, `endpoints` and `about`.
- **The file browser panel** (⌘B), for files on this Mac.
- **The activity bar** at the bottom of the window.
- **Pending**, the changes waiting for the person.
- The sheets and modals of each screen.

## Ground rules

These hold for the whole pass. A case never overrides them.

1. **Start with `start_session`**: who you are, your model, your purpose ("Validate every feature of
   Verbinal"). The person allows it in Verbinal and may give instructions for the session. **Follow
   them.** Without a session, only `describe_app` works.
2. **Read the person's standing rules first.** `describe_app` lists them under "The person's standing
   rules" (at the time of writing, `headless_jobs_rules` and `storage_rules`). Call each by name and
   follow it.
3. **Signing in is the person's.** Never ask for a password. Portal, Storage and Remote Compute say
   "sign-in required" until the person signs in.
4. **No headless or batch job unless the person directs one.** That includes `launch_headless_job` and
   `discover_image_packages`, which starts a probe job. Ask; if the answer is no, the case is SKIPPED.
5. **The person's allocation is theirs.** Ask before:
   - `launch_session`
   - `start_compute`
   - `run_code`
   - anything else that starts something on CANFAR

   The platform caps sessions (the launch form shows "Session limit reached (3/3)" when full).
6. **The person's data is theirs.**
   - Make what you test with: a VOSpace folder `verbinal-qa-full/`, saved queries and workflows whose
     names start with `qa-full-`.
   - Delete only what you made.
   - Never delete, clear or overwrite anything else.
7. **Every write carries a `why`.** The person reads it in Pending.
8. **Destructive changes always wait for the person.** That means deletes, clears, stopping a session,
   and removing a file. Propose one only where a case says so, then ask the person whether to apply it
   or not. Never treat the proposal as done.
9. **Say what you are about to do** before anything that changes what the person sees: `navigate_to`,
   `select_ui`, `open_ui`, opening a sheet.
10. **Keep the screen unlocked.** While it is locked, nothing can be read and every tool says so
    (`problem`).
11. **Hints are not marks.**
    - Hints (`point_at_ui`, `show_ui_hints`) point at the app's interface.
    - Marks (`annotate_fits`, `annotate_cube`) are data on an image, kept with its file.
12. **When something is slow or fails, read the log.** Use `explain_log_entry` with the `logToken`,
    or `get_session_log`. Put what it says in the report.

## Before you start

1. The person runs Verbinal from `release/1.4.0` and signs in to CADC.
2. Settings ▸ AI Agent: **Allow external AI agents** on; **Auto-apply** on (it applies reversible changes
   at once; destructive ones wait regardless).
3. Connect as [AGENTS.md](../../AGENTS.md) says (server `verbinal-canfar`, the app's own executable with
   `mcp`). `describe_app` answers.
4. `start_session`; the person clicks Allow.
5. Note what the person has, which shapes what can be tested: sessions running, batch jobs, files in
   Research, a FITS file and a cube on this Mac or in VOSpace, whether Remote Compute is set up
   (Settings ▸ AI Compute).

---

## 0. Bearings

| # | Steps | PASS if |
|---|---|---|
| 0.1 | `describe_app`. | `serverVersion` 1.4.0, `buildCommit`, the brief, the standing rules. |
| 0.2 | `list_apps`; `describe_app` `app` for two areas; `search_tools` "cutout"; `man` `set_search_form`. | 16 areas, about 213 tools; each area's tools one line each; the search finds the cutout tools; `man` gives the full schema. |
| 0.3 | `get_auth_state`, `get_service_health`, `get_endpoints`. | Signed in as the person; each CADC/CANFAR service's state; the effective URLs. |
| 0.4 | `get_current_view`, `list_activity`. | The screen, mode, pending count, auto-apply, hints; what the activity bar shows. |

## 1. Every screen, and finding your way

| # | Steps | PASS if |
|---|---|---|
| 1.1 | `navigate_to` each `mode` in the table above, in turn. After each: `get_current_view` and `list_ui_targets`. | Each screen shows (the person confirms); `screen` names it; `unnamed: 0`; screens needing sign-in show their content, not a lock. |
| 1.2 | `capture_view` on Home, Search and Portal. | An image of the window as the person sees it. |
| 1.3 | `open_settings` each section; `list_ui_targets`; then `close_settings`. | Settings opens at that section; its controls are listed; it closes. Settings are read-only to you: `get_endpoints`, `get_compute_config`. |
| 1.4 | `open_ui` `file browser`; `list_local_folder` the person's Documents; `close_ui` it. | The panel opens; `inside` lists what appeared; the folder lists; it closes. A folder macOS has not granted says so (`request_folder_access`). |
| 1.5 | `list_open_tabs` with a FITS file and a cube open. | Both viewers' tabs, each with its index. |

## 2. Pointing at the interface (hints)

Handout 28 covers this in depth; this is the short form.

| # | Steps | PASS if |
|---|---|---|
| 2.1 | Home: `point_at_ui` `home.search` with a message, 10 s. | A ring and a bubble on the Search tile; gone after 10 s. |
| 2.2 | `show_ui_hints`, five tiles, `numbered`, `dim`, `untilClosed`. | Bubbles 1–5, none overlapping each other or a tile; the window dimmed but the tiles. They stay until the person closes them, or presses Esc (`list_events`: `hintsDismissed`). |
| 2.3 | Portal: `show_ui_hints` `all: {}`. | A ring round every control. `clear_ui_hints` takes them down. |
| 2.4 | Storage: `select_ui` a file by name. | Selected as a click selects it. Nothing downloads. |
| 2.5 | Research: `open_ui` a collapsed collection by its name; `close_ui` it. | It opens; `inside` lists its observations; it folds again. |
| 2.6 | Search: `open_ui` the `Preset` pop-up; then `close_ui`. | The menu opens and waits (`waiting: true`); its items list; nothing is chosen. |
| 2.7 | `open_ui` a tab (`ADQL`). | Refused: tabs are reached with `select_search_tab`, `navigate_to`, `open_settings`. |
| 2.8 | Hide Verbinal (⌘H, the person); `list_ui_targets`. | `problem`: no Verbinal window is showing. |

## 3. Search: the form

| # | Steps | PASS if |
|---|---|---|
| 3.1 | `navigate_to` `search`; `get_search_form`. | Every field, the resolver's status, the ADQL the form makes. |
| 3.2 | `resolve_target` "M101"; `set_search_form` target "M101", a 0.2° radius. | The target resolves (coordinates, resolver); the form shows it. |
| 3.3 | `get_data_train_options`; `set_search_form` a collection (CFHT), then an instrument. | The options narrow as each is chosen; choosing upstream clears what no longer fits downstream. |
| 3.4 | Set a time range and a spectral band; `set_search_form` `execute: true`. | The search runs; `get_current_view` gives the result count; Results shows. |
| 3.5 | `run_search` (the one-call form), "SN 2023ixf", HST. | Results come back; the reply has a `timing` block if it took a while. |
| 3.6 | `cancel_search` during a slow search (a wide radius). | It stops; `run_search` reports `cancelled`. |
| 3.7 | `reset_search_form`. | Every field empty again. |
| 3.8 | `refresh_data_train`. | The data train reloads. |

## 4. Search: results, ADQL, history, saved queries

| # | Steps | PASS if |
|---|---|---|
| 4.1 | `get_search_results` after 3.4. | Rows as the person sees them: sort, filter and page applied. |
| 4.2 | `set_results_view`: sort by a column, a column filter, page 2, 50 per page, hide a column, a unit switch; then `resetColumnVisibility`. | The table follows each; `get_search_results` agrees. |
| 4.3 | `open_observation_detail` a row; `get_observation_caom2`, `get_data_links`, `get_preview_image` for it. | The detail sheet opens; the CAOM2 record, its links and a preview image. |
| 4.4 | `quick_search` from a cell (a target name). | A new search on that value. |
| 4.5 | `select_search_tab` `adql`; `set_adql_editor` `generateFromForm`; `validate_adql_query`; `execute`. | The ADQL appears; it validates; it runs. |
| 4.6 | `describe_tap_schema` the observation table. | Its columns, types and joins. |
| 4.7 | `validate_adql_query` with a mistake (a column that does not exist). | Not run; it says what is wrong. |
| 4.8 | `vizier_cone_search` around M101. | VizieR rows. |
| 4.9 | `list_recent_searches`; `load_saved_search` one; `rename_recent_search` it to `qa-full-recent`. | The list; it loads; it is renamed (with a `why`). |
| 4.10 | `save_query` `qa-full-query`; `list_saved_queries`; `get_saved_query`; `update_saved_query`; `run_saved_query`. | Saved, listed, read, changed, run. |
| 4.11 | `delete_saved_query` `qa-full-query`; `remove_recent_search` `qa-full-recent`. | Both wait in Pending (destructive). The person applies them. |
| 4.12 | `export_search_results` as CSV, with the person's agreement. | A proposal with a `why`; the file where the person chose. |

## 5. Research and downloads

| # | Steps | PASS if |
|---|---|---|
| 5.1 | `save_observation_to_research` a result, without its file. | A record in Research, no file. |
| 5.2 | `download_observation` that record (a small file; ask the person). | Downloaded to the same record, same id; the activity bar shows it. |
| 5.3 | `list_downloaded_observations`; `get_downloaded_observation`; `show_research_observation`. | The list; one record with its file; Research shows it selected. |
| 5.4 | `get_observation_notes`; `update_observation_note`; `bulk_update_observation_notes` two records. | The notes change, each on its own record. |
| 5.5 | `get_cutout_options` an image observation; `show_cutout_editor`; `download_cutout` a small region (ask). | The editor opens on the file and region; the cutout is a new record that names its original. |
| 5.6 | `download_observations_bulk` two small ones (ask). | Both, with progress in the activity bar. |
| 5.7 | `export_research_bundle` (ask where). | A bundle with records, notes and files. |
| 5.8 | `remove_downloaded_file` one of yours; `delete_downloaded_observation` another of yours. | Both wait in Pending; the first keeps the record without its file. Never `clear_research_archive`. |

## 6. FITS Viewer

Use a FITS image the person has (Research, VOSpace or this Mac). §7 uses a 3D file.

| # | Steps | PASS if |
|---|---|---|
| 6.1 | `list_recent_fits`; `open_fits_file` one (or `open_local_file`, `open_vospace_file`). | It opens in a tab. |
| 6.2 | `get_fits_header`, `get_fits_wcs`, `select_hdu` another HDU. | The header; the WCS; the other HDU shows. |
| 6.3 | `set_fits_view`: stretch, colour map, cuts, zoom, fit, north up; `fits_auto_cut`. | The image follows each; `get_fits_view` agrees. |
| 6.4 | `get_fits_image`. | The canvas as shown, with the map back to file pixels. |
| 6.5 | `fits_goto_coordinate` a sky position in the image; `probe_fits_pixel` there. | The view centres there; the pixel's value and sky position. |
| 6.6 | `save_fits_bookmark`; `list_fits_bookmarks`; `delete_fits_bookmark`. | Saved, listed, removed. |
| 6.7 | Two images open: `start_blink`; `set_blink` interval; `stop_blink`; `blink_fits_tabs`; `switch_fits_tab`; `set_tab_sync` crosshair and zoom. | They blink and stop; tabs switch; crosshair and zoom follow across tabs. |
| 6.8 | `search_at_crosshair`. | A Search at that position. |
| 6.9 | Marks: `annotate_fits` a circle with a label; `update_annotation` (move, rename, colour); `select_annotation`; `list_fits_annotations`; `export_annotations` DS9; `remove_annotation`; `clear_annotations`. | Each shows on the image; the list agrees; DS9 text comes back; removed, then cleared. Hints are not involved. |
| 6.10 | `export_fits_figure` the whole image, then around a mark, PNG and PDF (ask where). | Figures with marks and the chosen style. |
| 6.11 | A spectrum (an HST `_x1d`, e.g. SN 2023ixf): `get_fits_spectrum`. | The plot shows; the title is the target; the columns and error band. |
| 6.12 | A file with three or more axes: `open_fits_file`; `get_current_view` `pendingViewerChoice`; `choose_viewer` 2D. | The "Open as…" choice; it opens in the FITS Viewer. |
| 6.13 | `close_tab` by index. | That tab closes. |

## 7. Cube Viewer

| # | Steps | PASS if |
|---|---|---|
| 7.1 | `list_recent_cubes`; `open_cube` (or `choose_viewer` 3D in 6.12). | It opens. |
| 7.2 | `set_cube_view`: channel, playback, colour, `autoWindow` auto / percentile / full; `set_cube_transfer`; `set_cube_camera`. | The view follows; `get_cube_view` agrees. |
| 7.3 | `get_cube_image`. | The slice or volume as shown. |
| 7.4 | `probe_cube_spectrum` a pixel; `show_cube_spectrum`; `get_cube_channel_profile`. | The spectrum at that pixel; the inspector shows; the channel profile. |
| 7.5 | Marks: `annotate_cube`; `update_annotation` `viewer: cube` (move to another channel); `select_annotation` (goes to its channel); `list_cube_annotations`; `export_annotations`; `remove_annotation`. | As in 6.9, on the cube. |
| 7.6 | `export_cube_figure` with marks, PNG (ask where). | The figure. |
| 7.7 | Two cubes: `switch_cube_tab`. | The tab switches. |

## 8. Portal: sessions

| # | Steps | PASS if |
|---|---|---|
| 8.1 | `navigate_to` `portal`; `get_platform_load`; `list_sessions`; `get_session` one. | The load the card shows; every session with its state; one in full. |
| 8.2 | `list_session_types`; `list_session_images` by type and by project. | The types; the images, as the images card shows them. |
| 8.3 | `list_recent_launches`. | Each recent launch, with what it launched. |
| 8.4 | `show_launch_form` on each tab (standard, advanced, headless), then with an `image`; `list_ui_targets`. | The form shows that tab, the image chosen. Every control is named (the CPU, RAM and GPU steppers and sliders under Fixed). `close: true` closes it. Nothing launches. |
| 8.5 | In the launch form, a list with more than 12 choices (Container Image, Project): `open_ui` it; `list_ui_targets`; `select_ui` a row; and, with the person, typing in its search field. | A panel: a search field, "N of M", at most 12 rows, the choice ticked. `select_ui` chooses one and the panel closes. Typing narrows the list; ↑ ↓ and Return choose; Esc closes. Lists of 12 or fewer stay a menu. |
| 8.6 | `get_session_events`, `get_session_logs` of a running session. | Its events; its log. |
| 8.7 | `open_session` a running one (ask). | It opens in the browser. |
| 8.8 | With the person's agreement only: `launch_session` a small notebook `qa-full-nb`; then `renew_session` it; then `delete_session` it. | It launches; it renews; the delete waits in Pending until the person applies it. Otherwise SKIPPED. |

## 9. Portal: batch jobs

| # | Steps | PASS if |
|---|---|---|
| 9.1 | Portal: `point_at_ui` `portal.batchJobs`; the person clicks **Jobs & History…**. | The Batch Jobs sheet opens — with no jobs too — on the first tab with anything in it (History when nothing runs). |
| 9.2 | In the sheet: `list_ui_targets`. | The tabs with counts; each job a row named by its job; each History entry named by its job first ("qa-echo, Succeeded"); `unnamed: 0`. |
| 9.3 | With jobs in a tab: the person types in **Filter jobs by name, image or id**. | The list narrows; "No jobs match" when nothing does. More than 500 in a tab shows "Showing 500 of N" and **Show 500 More**. |
| 9.4 | `list_headless_jobs`; then `phase: failed`; then `contains` a name; then `cursor` from `next`. | Newest first, 200 at a time; `total` and `counts` by phase cover all jobs whatever the filter; `next` while more remain. |
| 9.5 | `get_headless_job`, `get_headless_job_logs`, `get_headless_job_events` one job. | Its record, logs and events. |
| 9.6 | `list_job_history`; `failedOnly`. | Finished jobs CANFAR no longer lists, with why they failed. |
| 9.7 | Only if the person directs one: `launch_headless_job`. | It launches, tagged as the assistant's in History when it ends. Otherwise SKIPPED. |

## 10. Image discovery and the registry

| # | Steps | PASS if |
|---|---|---|
| 10.1 | `search_packages` "astropy"; `find_images_with_packages` astropy and numpy. | Package names; the images that have both, with versions. |
| 10.2 | `describe_image` one with a `filter`; `get_image_manifest`. | Its packages and versions; the counts. |
| 10.3 | The person opens Image Content Discovery (launch form ▸ the magnifier after Container Image); `list_ui_targets`. | It reads as `portal.sheet.sheet`, in front. Both panes are listed — about 2,000 filters and every image row, named by image, its buttons named with it — with Close and Use This Image, `unnamed: 0`. |
| 10.4 | `select_ui` an image row in it. | Selected; Use This Image enables. Nothing is used until the person presses it. |
| 10.5 | `list_probe_failures`; `get_probe_logs` one. | Failures with their reasons; the probe's logs and events. |
| 10.6 | Only if the person directs it: `discover_image_packages` one image (it starts a probe job). | The probe runs and its manifest lands. Otherwise SKIPPED. |
| 10.7 | `search_image_registry` "astro"; `list_my_images`. | Registry images; the person's added images. |
| 10.8 | With the person's agreement: `add_registry_image` one; then `remove_registry_image` it. | Added (it shows in the images card's Added tab); the removal waits in Pending. |
| 10.9 | `clear_probe_failures` — only on the person's word. | Waits in Pending. |

## 11. Storage (VOSpace)

| # | Steps | PASS if |
|---|---|---|
| 11.1 | `navigate_to` `storage`; `get_storage_quota`; `list_vospace_path` the home; `get_vospace_node` a file. | Used / quota; the folder; the node's properties. |
| 11.2 | `show_storage_folder` a folder deep down. | The screen opens there. |
| 11.3 | `create_vospace_folder` `verbinal-qa-full`; `upload_text_to_vospace` a small `notes.txt` into it; `read_vospace_file` it. | Folder made; file uploaded; its text reads back. |
| 11.4 | `upload_file_to_vospace` a small file from this Mac (the person chooses); `download_vospace_file` it back (ask where). | Up and down, the same bytes. |
| 11.5 | `set_vospace_acl` on `verbinal-qa-full` — read only, then back. | The sharing changes and returns. |
| 11.6 | `open_vospace_file` a FITS file. | It opens in the FITS Viewer. |
| 11.7 | `delete_vospace_node` `verbinal-qa-full`. | Waits in Pending; the person applies it. Never `clear_user_site`. |

## 12. Remote Compute

| # | Steps | PASS if |
|---|---|---|
| 12.1 | `navigate_to` `remoteCompute`; `get_compute_state`; `get_compute_config`; `get_compute_view`. | Its state (not set up, stopped, running…), size, uptime; the configured image; what the screen shows. |
| 12.2 | `list_compute_runs`; `show_compute_run` the newest. | Runs with who sent them, language, status; the run shows. |
| 12.3 | `set_compute_snippet` a one-line Python. | It appears in the Run code box; nothing runs (the person presses Run). |
| 12.4 | Only if set up and the person agrees: `run_code` `print(1+1)`; `run_code_output`. | `2`, with the run listed as the assistant's. |
| 12.5 | Only if the person agrees: `start_compute`, then `stop_compute`. | It starts; the stop waits in Pending. |

## 13. Workflows

| # | Steps | PASS if |
|---|---|---|
| 13.1 | `list_workflows`; `get_workflow` a template (e.g. `variable-star-photometry`). | The seven templates and any local copies; the protocol. |
| 13.2 | `use_workflow` it as `qa-full-workflow`; `set_workflow_step` the first step done; `update_workflow` a line; `save_workflow` a short new one `qa-full-mine`. | A local copy; the step checked; the change; the new one. |
| 13.3 | `delete_workflow` both `qa-full-` ones. | Each waits in Pending. |

## 14. AI Guide, proposals and the log

| # | Steps | PASS if |
|---|---|---|
| 14.1 | `navigate_to` `aiGuide`; `list_guide_tools`. | The person's guide tools, the standing rules among them. |
| 14.2 | Do not change the guide. `set_tool_description`, `add_guide_tool` and the rest are **standing**: they change what every later assistant is told, and never auto-apply. Only on the person's word: `add_guide_tool` `qa-full-note`, then `delete_guide_tool` it. | Both wait in Pending. Otherwise SKIPPED. |
| 14.3 | `list_pending_proposals`; `get_proposal_state` one; `withdraw_proposal` one of yours. | What waits, with each `why`; its state; withdrawn. |
| 14.4 | `start_background_apply` a reversible proposal; `get_job_status`. | Applied in the background; the job's state. |
| 14.5 | `list_events`. | What happened: changes, who made them, hints dismissed. |
| 14.6 | `get_session_log`; again with `only: failures`; `explain_log_entry` a `logToken`. | Your session's calls, the CADC/CANFAR requests each made, changes with who and why; the failures; one entry's causes and effects. |
| 14.7 | `list_session_logs`; `export_session_log` yours (ask where). | The sessions kept; the file. `delete_session_logs` is the person's housekeeping: SKIPPED. |

## 15. The windows

| # | Steps | PASS if |
|---|---|---|
| 15.1 | Open Settings; the person closes the main window (with no sheet on it — macOS does not close a window with a sheet). | Settings closes too; hints go; `list_ui_targets` says no window is showing. |
| 15.2 | The person opens a window again (Dock icon). | Tools read it again. |
| 15.3 | The person quits Verbinal; call `get_current_view`; the person opens it again. | "Verbinal is not running"; then the tools come back by themselves (a new `start_session` may be needed). |

## 16. What is not an assistant's, on purpose

Do not report these as missing. They are the person's by design (see the parity doc):

- signing in and out;
- writing Settings (endpoints, the compute image, the MCP switches);
- Allow or Deny for a session;
- Clear Finished (activity bar) and Clear History (Batch Jobs);
- copying to the clipboard uninvited;
- the Terms, Welcome and About sheets;
- canvas pan and pinch gestures, which have tool equivalents (go to, zoom, fit).

---

## Appendix — every tool, by area (`list_apps`)

| Area | Tools |
|---|---|
| Foundational (10) | describe_app, list_apps, search_tools, man, copy_to_clipboard, get_auth_state, get_current_view, list_activity, get_service_health, get_endpoints |
| View & Navigation (18) | list_ui_targets, point_at_ui, show_ui_hints, clear_ui_hints, select_ui, open_ui, close_ui, capture_view, open_settings, close_settings, set_search_focus, navigate_to, list_open_tabs, close_active_tab, close_tab, list_local_folder, open_local_file, request_folder_access |
| Search & Archive (36) | search_observations, export_search_results, load_saved_search, load_recent_search, run_saved_query, vizier_cone_search, resolve_target, get_observation_caom2, get_data_links, get_preview_image, list_recent_searches, rename_recent_search, remove_recent_search, clear_recent_searches, get_search_form, set_search_form, run_search, reset_search_form, cancel_search, describe_tap_schema, validate_adql_query, get_search_constraints, get_data_train_options, set_search_constraints, refresh_data_train, set_adql_query, set_adql_editor, execute_adql_query, select_search_tab, quick_search, get_search_results, set_search_results_view, set_results_view, open_observation_detail, show_search_row_detail, show_observation_detail |
| Saved Queries (5) | list_saved_queries, get_saved_query, save_query, update_saved_query, delete_saved_query |
| Research & Notes (9) | list_downloaded_observations, export_research_bundle, get_downloaded_observation, save_observation_to_research, remove_downloaded_file, show_research_observation, get_observation_notes, update_observation_note, bulk_update_observation_notes |
| Downloads (7) | get_cutout_options, download_cutout, show_cutout_editor, download_observation, download_observations_bulk, delete_downloaded_observation, clear_research_archive |
| Sessions (14) | show_launch_form, list_sessions, get_session, list_session_types, list_session_images, list_recent_launches, launch_session, renew_session, delete_session, delete_sessions_bulk, get_platform_load, get_session_events, get_session_logs, open_session |
| FITS (31) | get_fits_header, get_fits_wcs, get_fits_spectrum, open_fits_file, choose_viewer, get_fits_view, set_fits_view, fits_goto_coordinate, probe_fits_pixel, get_fits_image, annotate_fits, list_fits_annotations, update_annotation, select_annotation, remove_annotation, clear_annotations, export_annotations, list_fits_bookmarks, save_fits_bookmark, delete_fits_bookmark, select_hdu, fits_auto_cut, start_blink, set_blink, stop_blink, blink_fits_tabs, switch_fits_tab, set_tab_sync, search_at_crosshair, export_fits_figure, list_recent_fits |
| Cube Viewer (14) | open_cube, get_cube_view, get_cube_image, annotate_cube, list_cube_annotations, set_cube_view, set_cube_camera, probe_cube_spectrum, list_recent_cubes, show_cube_spectrum, get_cube_channel_profile, set_cube_transfer, switch_cube_tab, export_cube_figure |
| Storage (16) | list_vospace_path, show_storage_folder, get_vospace_node, read_vospace_file, upload_to_vospace, upload_text_to_vospace, download_vospace_file, download_from_vospace, create_vospace_folder, vospace_mkdir, delete_vospace_node, clear_user_site, get_storage_quota, upload_file_to_vospace, set_vospace_acl, open_vospace_file |
| Headless / Batch (6) | list_headless_jobs, get_headless_job, get_headless_job_logs, get_headless_job_events, launch_headless_job, list_job_history |
| Image Discovery (12) | find_images_with_packages, discover_image_packages, list_probe_failures, get_probe_logs, get_image_manifest, clear_probe_failures, search_packages, describe_image, search_image_registry, list_my_images, add_registry_image, remove_registry_image |
| AI Compute (10) | run_code, run_code_output, start_compute, stop_compute, get_compute_state, list_compute_runs, get_compute_view, show_compute_run, set_compute_snippet, get_compute_config |
| Agent Control (12) | list_guide_tools, set_tool_description, clear_tool_description, add_guide_tool, update_guide_tool, delete_guide_tool, list_pending_proposals, get_proposal_state, withdraw_proposal, start_background_apply, get_job_status, list_events |
| Workflows (7) | list_workflows, get_workflow, save_workflow, update_workflow, set_workflow_step, use_workflow, delete_workflow |
| Session Log (6) | start_session, get_session_log, explain_log_entry, list_session_logs, export_session_log, delete_session_logs |

Some names are older aliases of others, kept so earlier assistants keep working. For example,
`run_search` is the one-call form of `set_search_form`, and `vospace_mkdir` is the same as
`create_vospace_folder`. The parity doc lists them all.

A tool not covered by a case above is still in scope. Call it read-only where it is a read, and report
what it answers.

## Report

Write the report where the person asks. Earlier passes used
`~/Documents/Default Project/qa-report-verbinal-canfar-<date>.md`.

1. **The build:** `buildCommit`, the date, and the session id.
2. **A table of every case:** PASS / FAIL / BLOCKED / SKIPPED, with one line each.
3. **For each FAIL:**
   - the tool's JSON;
   - what the person saw (a screenshot when it is about the screen);
   - the `logToken`, and what `explain_log_entry` says.
4. **Anything you found outside the cases:** a tool that misdescribes itself, a screen element without a
   name, a slow reply.
5. **Clean-up:** what you made, and what is gone. Leave anything still waiting in Pending for the person
   to apply or not.
