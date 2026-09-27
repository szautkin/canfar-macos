# Agent ↔ UI parity matrix

Goal: every user-facing interaction in Verbinal has an agent-tool
equivalent, so an MCP agent can do 100% of what the user can do by
clicking. This matrix is the audit trail: interaction → tool, plus the
short list of interactions that are *intentionally* not exposed and why.

Guardrail: `AgentToolCatalogParityTests` cross-checks the live tool
registry against `AIGuideCatalog` in both directions on every test run.
When you add a UI interaction, add the tool, the catalog entry, and a
row here.

Legend: **live** = view-state tool, applied immediately with a `.live`
activity entry; **write** = proposal-gated (auto-apply or strip);
**read** = pure data.

## Finding your way (tool map)

| Need | Tool | Kind |
|---|---|---|
| The app's areas and how many tools each has | `list_apps` | read |
| One area's tools, one line each | `describe_app` `app` | read |
| A tool by what it does | `search_tools` | read |
| One tool's description and full schema | `man` | read |
| Copy text, or an observation's details | `copy_to_clipboard` | live |
| What can be pointed at on screen | `list_ui_targets` | read |
| Point at a control, with a message | `point_at_ui` | live |
| Open Settings at a section / close it | `open_settings` / `close_settings` | live |

## Long work

| Need | Tool | Kind |
|---|---|---|
| Apply a pending change without waiting (only what auto-apply would) | `start_background_apply` | live |
| Follow a background apply, or an auto-apply still running at its deadline | `get_job_status` | read |

## Seeing the viewers

| Need | Tool | Kind |
|---|---|---|
| The FITS canvas as shown, with the map back to file pixels | `get_fits_image` | read |
| The cube's slice or volume as shown | `get_cube_image` | read |

## Search — form

| UI interaction | Tool | Kind |
|---|---|---|
| Read all constraint fields + resolver status + generated ADQL | `get_search_form` | read |
| Type into any constraint field (all 4 cards) | `set_search_form` | live |
| Data-train checkbox selections (cascade-clears downstream) | `set_search_form` arrays | live |
| Press Search (⌘↩) | `set_search_form` `execute: true` | live |
| Reset button | `reset_search_form` | live |
| Cancel beside the spinner | `cancel_search` (a waiting `run_search` reports `cancelled`) | live |
| Read data-train facet options (filtered by upstream) | `get_data_train_options` | read |
| Data-train refresh button | `refresh_data_train` | live |
| Target resolution (debounced typing) | automatic in `set_search_form` (immediate on execute) | — |
| Switch Search/Results/ADQL sub-tab | `select_search_tab` | live |

## Search — ADQL editor

| UI interaction | Tool | Kind |
|---|---|---|
| Edit raw ADQL | `set_adql_editor` | live |
| Generate from Form | `set_adql_editor` `generateFromForm` | live |
| Execute (⌘⇧↩) | `set_adql_editor` `execute` | live |
| Cancel beside the spinner | `cancel_search` | live |
| The archive's tables, columns and joins | `describe_tap_schema` | read |
| Check a query without running it | `validate_adql_query` | read |
| Save Query | `save_query` (pre-existing) | write |

## Search — results table

| UI interaction | Tool | Kind |
|---|---|---|
| Read rows as the user sees them (sort+filter applied) | `get_search_results` | read |
| Sort by column header | `set_results_view` sort fields | live |
| Per-column filter row (⌘F) | `set_results_view` `filters` | live |
| Pagination + page size (⌘[/⌘]) | `set_results_view` `page`/`rowsPerPage` | live |
| Columns picker (show/hide/reset) | `set_results_view` `visibleColumns`/`resetColumnVisibility` | live |
| Per-column unit switch | `set_results_view` `columnUnits` | live |
| Quick-search cell links | `quick_search` | live |
| Double-click row → detail sheet | `open_observation_detail` (row id), `show_search_row_detail` (row on the page), `show_observation_detail` (publisher id) | live |
| Export menu (server-side CSV/TSV/VOTable) | `export_search_results` (pre-existing) | write |
| Detail sheet's Download | `download_observation` (pre-existing) | write |

## Search — side panel

| UI interaction | Tool | Kind |
|---|---|---|
| Recent Searches list / Load | `list_recent_searches`, `load_saved_search` (pre-existing) | read/live |
| Recent Searches rename | `rename_recent_search` | write |
| Recent Searches remove / Clear All | `remove_recent_search`, `clear_recent_searches` | write (destructive) |
| Saved Queries CRUD + Run | `list/get/save/update/delete_saved_query`, `load_saved_search` (pre-existing) | mixed |

## FITS viewer

| UI interaction | Tool | Kind |
|---|---|---|
| Open file / tabs / stretch / colormap / cuts / zoom / fit / north-up / goto / probe / bookmarks / close tab | pre-existing control batch (`open_fits_file`, `set_fits_view` incl. `tabIndex`, `fits_goto_coordinate`, `probe_fits_pixel`, `*_fits_bookmark`, `list_open_tabs`, `close_tab` — FITS or cube, by index — with `close_active_tab` as its alias) | mixed |
| HDU list selection | `select_hdu` | live |
| Auto cut button | `fits_auto_cut` | live |
| Blink (⌘⇧B) start | `start_blink` | live |
| Blink pause/resume, interval slider, A/B | `set_blink` | live |
| Blink stop (Esc) | `stop_blink` | live |
| Windows-shaped blink command / activate tab | `blink_fits_tabs`, `switch_fits_tab` | live |
| Link Crosshair / Sync Zoom toggles | `set_tab_sync` | live |
| Search Here (⌘⇧L) | `search_at_crosshair` | live |
| Export Figure sheet: region (whole image / view / around a mark), marks, style, PNG/PDF | `export_fits_figure` (`region` also box and sky) | write |
| Mark menu ▸ Export Figure Around Mark… | `export_fits_figure` `region: mark` | write |
| "Open as…" 2D vs 3D sheet (NAXIS≥3) | `choose_viewer`; `get_current_view.pendingViewerChoice` | live/read |
| Draw a mark (Marks panel ▸ Draw, click or drag the image) | `annotate_fits` | live |
| Move, resize (grip), rename (double-click, Edit Label), restyle (panel colour/bold/size/outline) | `update_annotation` | live |
| Delete a mark (menu, ⌫), Clear All | `remove_annotation`, `clear_annotations` | live |
| Pick out a mark (click, list row), Centre on Mark | `select_annotation` | live |
| Marks list and its filter | `list_fits_annotations` (the filter is presentation) | read |
| Copy Position | `copy_to_clipboard` with the position `list_fits_annotations` gives | live |
| Search Here on a mark | `run_search` with its position | live |
| Export Marks (DS9 / JSON, to a file) | `export_annotations` (returns the text) | read |

## Cube viewer

| UI interaction | Tool | Kind |
|---|---|---|
| Every side-panel control, playback, channel, camera, spectrum probe, figure export (with marks, PNG/PDF) | pre-existing (`set_cube_view`, `set_cube_camera`, `probe_cube_spectrum`, `export_cube_figure` `marks`/`format`) | mixed |
| Auto (99.9%) / Full Range window buttons | `set_cube_view` `autoWindow` | live |
| Recent cubes, spectrum inspector, channel profile, transfer curve | `list_recent_cubes`, `show_cube_spectrum`, `get_cube_channel_profile`, `set_cube_transfer` | read/live |
| Cube document tabs | `switch_cube_tab`, `list_open_tabs` | live/read |
| Draw a mark on the slice (Marks panel ▸ Draw) | `annotate_cube` | live |
| Move, resize, rename, restyle, move to another channel | `update_annotation` `viewer: cube` | live |
| Delete a mark, Clear All | `remove_annotation`, `clear_annotations` `viewer: cube` | live |
| Pick out a mark, Centre on Mark (goes to its channel) | `select_annotation` `viewer: cube` | live |
| Marks list | `list_cube_annotations` | read |
| Export Marks | `export_annotations` `viewer: cube` | read |

## Portal / sessions

| UI interaction | Tool | Kind |
|---|---|---|
| List/launch/renew/delete, images, platform load | pre-existing batch | mixed |
| Launch Session (opens the launch form sheet), its tabs, "Use this image" | `show_launch_form` (`tab`, `image`, `close`) | live |
| Session Events sheet | `get_session_events` | read |
| Session log view | `get_session_logs` | read |
| Connect button (opens browser) | `open_session` | live |
| Headless jobs (logs/events/launch) | pre-existing batch | mixed |

## Image discovery

| UI interaction | Tool | Kind |
|---|---|---|
| Package search / probe an image | `find_images_with_packages`, `discover_image_packages` (pre-existing) | read/write |
| Failure rows | `list_probe_failures` | read |
| View probe logs/events | `get_probe_logs` | read |
| Manifest detail | `get_image_manifest` | read |
| Dismiss error / Clear all errors | `clear_probe_failures` | write (destructive) |

## Storage (VOSpace)

| UI interaction | Tool | Kind |
|---|---|---|
| Browse/read/upload/download/mkdir/delete/ACL/quota | pre-existing batch | mixed |
| "Open in FITS Viewer" context action | `open_vospace_file` | write |
| Copy Path context action | trivial string op — covered by `list_vospace_path` output | — |

## Shell / navigation / settings

| UI interaction | Tool | Kind |
|---|---|---|
| Navigate between modes (now incl. AI Guide) | `navigate_to` (`aiGuide` added) | live |
| Current view incl. Search sub-tab + result counts | `get_current_view` (enriched) | read |
| Local file-browser panel: browse | `list_local_folder` | read |
| Local file-browser panel: open file | `open_local_file` (optional `viewer` skips Open as…) | live |
| Settings ▸ Endpoints (effective URLs) | `get_endpoints` | read |
| Settings ▸ AI Compute | `get_compute_config` | read |
| Research module (downloads, notes, open in viewer, export) | pre-existing batch | mixed |
| Save to Research (Search detail, row menu) — no file | `save_observation_to_research` | write |
| Remove File… (Research detail) — keep the observation | `remove_downloaded_file` (always waits for approval) | write |
| Download a record kept without its file (Research detail, row menu) | `download_observation` (same record, same id) | write |
| Select a record, detail open | `show_research_observation` | live |
| Cutout record: Original Observation | `show_research_observation` with its publisher id | live |
| Cut Out… (Search and Research detail): the editor, its file, region, band, checks, size | `show_cutout_editor`; `get_cutout_options` | live/read |
| Download Cutout | `download_cutout` | write |
| Search form: Spatial cutout / Spectral cutout boxes | `set_search_form` `spatialCutout`/`spectralCutout` (read by `get_search_form`) | live |
| AI Guide content (overrides, guides) | pre-existing batch | mixed |

## Workflows

| UI interaction | Tool | Kind |
|---|---|---|
| List templates + local copies | `list_workflows` | read |
| Open / read one protocol | `get_workflow` | read |
| Save / update markdown | `save_workflow`, `update_workflow` | write |
| Check off a step | `set_workflow_step` | write |
| Instantiate a template | `use_workflow` | write |
| Delete a local copy | `delete_workflow` | write (destructive) |

## Wire-name aliases (Windows = canonical)

Mac keeps legacy names as aliases so older agents keep working:
`set_search_form`↔`run_search` / constraints tools, `set_adql_editor`↔
`set_adql_query`/`execute_adql_query`, `set_results_view`↔
`set_search_results_view`, `load_saved_search`↔`load_recent_search`/
`run_saved_query`, blink suite↔`blink_fits_tabs`, `vospace_mkdir`↔
`create_vospace_folder`, `download_from_vospace`↔`download_vospace_file`.

## Intentionally not exposed

- **Ephemeral gesture state**: FITS canvas scroll-pan/pinch and Cube
  slice-view pan/zoom are transient local view state; the semantic
  equivalents (goto coordinate, zoom level, fit, channel, camera) are
  covered. Exposing raw pan offsets would fight the user's hand.
- **New empty FITS tab + file picker**: agents open files directly via
  `open_fits_file` / `open_local_file` (each opens its own tab); an
  empty tab exists only to host the interactive picker.
- **Settings writes** (endpoints, compute image/credentials, MCP
  toggles): deliberate policy — the agent's own capabilities and
  backends stay a user decision. Read tools exist.
- **Auth (login/logout)**: credentials are the user's alone;
  `get_auth_state` reports state.
- **Clipboard copies** (Copy Row / Copy Path / Copy RA-Dec): the data
  is already in the corresponding read-tool output; writing to the
  user's clipboard uninvited is hostile.
- **Legal/Terms, Welcome, About sheets**: one-shot chrome, no agent value.
- **Notebook module**: ships as the VerbinalPi addon on macOS, not the
  main app (Windows integrates Notebook natively). No notebook MCP tools
  in the main catalog for 1.3.2.
