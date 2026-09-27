# Changelog

All notable changes to Verbinal for macOS (and the new iOS port) are documented
in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] - Unreleased

Catching up with Verbinal for Windows 1.4.1 (see
`docs/plans/10-windows-catchup.md`).

### Fixed
- **A full image reference on the launch form's Advanced tab** — pasted,
  or given by your assistant's `show_launch_form`, it was put under the
  chosen registry a second time (`images.canfar.net/images.canfar.net/…`)
  and the launch was refused; a pasted `https://` was kept as part of the
  name. It is now used as it is, without the scheme or spaces.
- **Storage shows the folder last asked for** — a listing that answered
  late (a slow folder, then a quick click elsewhere) replaced the newer
  one, leaving the breadcrumb and the files out of step.
- **Sexagesimal rounding** — a position just under a whole minute printed
  as `23h59m60.00s` in the FITS and cube viewers, bookmarks and figure
  legends; the carry now happens everywhere a position is written, from
  one formatter that the search table shares.
- **Go To in the FITS viewer** reads a position as the rest of the app
  does: decimal degrees with a point or a comma (a French Mac types
  `10,68`), or sexagesimal. A position it cannot read now says so instead
  of doing nothing.
- **Viridis is viridis** — the FITS and cube viewers drew a teal-to-orange
  approximation, and figures went out labelled VIRIDIS. Viridis, inferno,
  magma and plasma are now matplotlib's own 256-entry tables (the other
  three had been 9-point approximations, up to 17/255 off), so a colormap
  looks as it does in astropy and ds9.
- **Positions on distorted images** — SIP distortion (`-SIP` headers:
  HST's calibrated frames, many ground-based pipelines) was ignored, so
  the crosshair, Go To, bookmarks, blink alignment and the agent's sky
  read-outs were up to ~8 px (0.3″) out toward the corners of a WFC3
  frame. The polynomial now applies both ways — sky to pixel is solved
  against it, starting from `AP`/`BP` when the header has them — and
  agrees with astropy to 1e-9° and 1e-6 px. Header values written with a
  `D` exponent (`1.5D-07`) are now read.
- **Your assistant while Verbinal is closed, starting or quitting** — an
  assistant started before Verbinal got a failed handshake and gave up on
  it for the whole session (Claude Code, Claude Desktop and others do),
  and one connected when Verbinal quit lost its tools until reconnected by
  hand. The bridge an assistant launches (`Verbinal mcp`) now answers the
  handshake itself, lists the tools Verbinal listed last time — each
  answering that Verbinal is not running and what to turn on, as a tool
  error the assistant reads — then connects when Verbinal starts, replays
  the assistant's handshake to it and tells the assistant its tool list
  has changed. A request Verbinal was holding when it quit is answered
  instead of left hanging, and a handshake is never held up by a stalled
  first connection attempt.

### Added
- **A map of the tools for your assistant** — `list_apps` gives the app's
  areas and how many tools each has, `describe_app` with `app` gives one
  area's tools a line each, `search_tools` finds a tool by what it does
  (matching the query's words, not the whole phrase), and `man` gives one
  tool's full description and schema, or the nearest names for a typo.
  They read the tool list exactly as the assistant receives it.
- **Your assistant can show you where things are** — `point_at_ui` rings
  a control on screen with a short message beside it for a few seconds,
  and `list_ui_targets` lists what it can point at (the Search, ADQL and
  launch buttons, the AI Agent settings, the FITS Go To…). A name that
  matches no control — or two equally — points at nothing and lists what
  is there instead of guessing. `open_settings` opens Settings at a
  section and `close_settings` closes it; nothing is set for you.
- **Your assistant can see the viewers** — `get_fits_image` returns a
  picture of the FITS Viewer as you see it (zoom, pan, rotation,
  colormap, crosshair) with the exact map from a point in the picture to
  the file's pixel, so an assistant can point at what it sees;
  `get_cube_image` returns the cube's slice or volume. Pictures are made
  small enough for the assistant to receive.
- **Marks on FITS images** — mark what you are looking at: a circle or
  box around a source, a callout with a leader line to its label, or a
  label alone. Turn on **Draw** in the FITS viewer's new **Marks** panel,
  click the image (or drag to size the mark) and type its label; drag a
  mark to move it, a corner grip to resize it, double-click to rename it,
  and right-click it to copy its position (in the form the Search box
  reads), centre on it, search there, export or delete it. The panel
  lists the image's marks — each row goes to its mark — with a filter,
  colour, bold, label size and outline for the selected mark (or the next
  one), DS9 or JSON export and Clear All. Marks are pinned to the sky when
  the image has a WCS (so a mark finds the same place in another image of
  the field), keep their size on the subject as you zoom, turn with the
  view, and are kept with the file and extension — however its path is
  spelled — so they are there when you open it again. Cubes have marks
  too, in the Cube Viewer's panel: a cube mark lives on a channel — drawn
  on the slice showing it, and Centre on Mark goes to that channel — and
  the volume shows every channel's marks where they sit in the cube. Your
  assistant can mark too, and its marks say so: `annotate_fits` and
  `list_fits_annotations`, `annotate_cube` and `list_cube_annotations`,
  and for either viewer `update_annotation`, `select_annotation` (picks
  one out and centres the view on it), `remove_annotation`,
  `clear_annotations`, and `export_annotations`, which gives a file's
  marks — open or not — as a DS9 region file (sky in fk5 with sizes in
  arcseconds, pixels 1-based as DS9 counts them) or as JSON grouped by
  extension.
- **Figures of part of an image, with its marks** — the FITS viewer's
  Export Figure draws the image's marks and labels (a **Marks** toggle)
  and shows the whole image or the view on screen; a mark's menu has
  **Export Figure Around Mark…**. The legend gives the figure's own
  centre and field of view. For assistants, `export_fits_figure` takes
  `region` — the view on screen (the default), the whole image, a pixel
  box, a circle on the sky, or around a mark — and `format` (PNG or PDF),
  `marks`, `annotate` and `dark`. The Cube Viewer's figures draw the
  cube's marks too — on a slice, those of the channel shown; in the
  volume, where they sit — and `export_cube_figure` takes `format` and
  `marks`.
- **Research without the file** — **Save to Research** (in an
  observation's detail and on a search result's menu) keeps an
  observation, its details and a place for notes, without downloading
  it; **Download** in Research fetches the file into the same record
  later. **Remove File…** deletes a downloaded file from this computer
  and keeps the observation and its notes. Rows without a file say so.
  For assistants: `save_observation_to_research`,
  `remove_downloaded_file` (always waits for you), and
  `show_research_observation` to show a record by its id, publisher id
  or observation id; `list_downloaded_observations` marks records
  without a file `downloaded: false`, and `download_observation` into a
  record Research has keeps its id.
- **Cutouts** — part of a file, cut on CADC's side, so a few MB come
  down instead of a 1.6 GB tile — or, when the observation's file is
  already downloaded, cut on this computer: instant, offline, and the
  only way for files CADC will not cut. A local cut keeps the pixels as
  they are (same BITPIX and scaling), rewrites the header so the same sky
  lands on the same pixel (CRPIX, LTV/LTM, SIP kept valid), adds a
  HISTORY line and fresh CHECKSUM/DATASUM, can keep chosen images of a
  mosaic, cuts a cube to the channels of a wavelength range (its
  frequency, wavelength, wavenumber or velocity axis read as metres), and
  cuts an fpack-compressed (RICE_1) image by decoding only the tiles the
  region touches, writing the cutout uncompressed. It can cut the
  observation's other files beside it with the same box — a MegaPipe
  tile's weight map — after checking they lie on the same pixels (a file
  on another grid is offered greyed, with why); each is saved beside the
  cutout under the same key. **Cut Out…** in an observation's detail
  (Search, and Research) opens an editor on the file's footprint: a circle
  or box — RA and Dec in degrees or sexagesimal, sizes in arcminutes — and
  for a cube a wavelength range in nanometres, started from what the
  search asked for, checked as you type (off the file, partly off, the
  wrong shape for this file), with the size it will be. **Spatial
  cutout** and **Spectral cutout** in the search form, as on CADC's
  search page, make Download in a result's detail fetch only the part
  of the file within the search's circle, or its wavelengths — the whole
  file when the file cannot be cut that way. A cutout is kept in
  Research beside its observation, marked with what it was cut from and
  where, with a way back to the complete observation; downloading it
  again cuts it again. For assistants: `get_cutout_options` (what each
  file can be cut by, its footprint and band, and a suggested cutout from
  the last search, with its size — or why CADC offers none) and
  `download_cutout` (a circle, box or polygon, optionally a band, checked
  against the file before it is proposed) and `show_cutout_editor` (the
  editor on the person's screen, on a region or the suggestion);
  `get_search_form` and `set_search_form` read and set the two boxes.
  `cutBy` chooses who cuts (`soda` or `local`; left out, this computer
  when it can), `extensions` the images of a mosaic to keep, and
  `companions` the files to cut along (listed by `get_cutout_options`).
- **Images the catalogue does not list** — the images card's **Find in
  Registry…** searches the registry behind the platform (Settings ▸ Image
  Discovery's host and credentials) for a colleague's build or a tag not
  yet picked up, and **Add** keeps one in your images: they join the
  catalogue on the card (its **Added** tab) and on the launch form, typed
  by the session types their registry labels name. For assistants:
  `search_image_registry`, `list_my_images`, `add_registry_image` and
  `remove_registry_image` (which waits for you); `list_session_images`
  includes your images.
- **Remote Compute** — a home tile (it needs you signed in) for the
  session your assistant's `run_code` uses: its state, size and uptime,
  **Start Session** and **Stop Session**, every run with its code, output
  and errors, **Run Again**, and a box to run Python or bash yourself.
  Until a compute image is set it says what it takes; **Open Folder in
  Storage** shows the folder the session works in. For assistants:
  `get_compute_view`, `show_compute_run`, `set_compute_snippet` (fills the
  box, never runs it), `navigate_to remoteCompute`, and
  `show_storage_folder` to open Storage at a folder of your home.
- **Remote compute remembers its runs** — every piece of code sent to
  the compute session, by your assistant (`run_code`) or by you, is kept
  with who sent it, when, and how it ended (ok, error, timeout, no
  result, not sent), and is watched until its result arrives whether or
  not anyone asks for it. For assistants: `get_compute_state` (not set
  up, stopped, starting, running, stopping or failed, with the size asked
  for and the size granted, and the uptime) and `list_compute_runs`. A
  session left on your account from another install is reported, not
  hidden behind "not set up". The compute image field drops a pasted
  `https://` and spaces.
- **What is inside an image, for your assistant** — `describe_image`
  gives a probed image's OS, Python and packages with versions by
  ecosystem (Python per environment, R, dpkg, rpm, apk), and
  `search_packages` says what packages are actually called across the
  probed images ("spec" → specutils, pyspeckit), shortest first.
- **The archive's schema for your assistant** — `describe_tap_schema`
  reads CADC's own TAP_SCHEMA (tables, what each column means with units
  and UCDs, and the joins it declares; one table, or a search across
  columns), fetched once an hour. `validate_adql_query` checks a query
  against it without running it: `LIMIT` (ADQL writes `SELECT TOP n`),
  unknown tables and columns, and the qualifier CADC rejects as
  ambiguous — reporting only what it is sure of, with the fix when there
  is one.
- **ADQL checked as you type** — the ADQL editor checks the query
  against CADC's own schema while you type, underlines each problem and
  lists it under the query (click one to select it), and keeps Execute
  off until the query can run: `LIMIT` (ADQL writes `SELECT TOP n`), a
  table or column the archive does not have (with the name that exists),
  a qualifier CADC would call ambiguous. Nothing it cannot be sure of is
  flagged. Queries run from the editor are kept in Recent Searches,
  named by the query, and load back into the editor; for assistants
  `list_recent_searches` marks them `fromEditor`, and an empty
  `set_adql_query` clears the editor.
- **Tabs and details for your assistant** — `close_tab` closes a FITS or
  cube tab by its index (or the active one); `close_active_tab`, which
  could close only FITS tabs, is now its alias. `show_search_row_detail`
  opens the detail of a row on the results page shown, and
  `show_observation_detail` that of an observation in the results by its
  publisher ID.
- **Copy an observation, or any result** — right-click a cell of the
  search results to copy its value, the observation's details, the row,
  or the whole page as tab-separated text that pastes into a spreadsheet.
  Research's list and detail have **Copy Details**. The details read the
  same everywhere — ID, collection, publisher ID, target, the position as
  the Search box, Simbad and DS9 read it with the degrees beside it,
  instrument, filter, date, calibration level, proposal, release — and
  the Search box now reads a pasted `00:42:44.3 +41:16:09` position. For
  assistants: `copy_to_clipboard`, text or an observation's details.
- **Cancel a search** — a search that takes long could not be stopped:
  Search stayed greyed with a spinner until CADC answered. **Cancel** now
  sits beside the spinner, on the form and in the ADQL editor (Esc), and
  stops it; the results already shown stay, and a cancelled search is not
  kept as a recent one. For assistants: `cancel_search`, and `run_search`,
  `set_search_form`, `set_adql_query` and `execute_adql_query` say
  `cancelled: true` when the person cancelled the search they started.
- **Session notifications** — a pending session that comes up, or fails
  to start, is announced, as batch jobs already were. Nothing that
  settled before Verbinal looked is announced.

- **Long changes your assistant starts** — an auto-applied write that
  ran longer than the assistant waits for a tool (a 1.6 GB download) read
  as a failure while it carried on. After ~40 s the call now answers
  `applying: true` with a job id, the work continues, and
  `get_job_status` says how it ended — with the download's result or
  the reason it failed. `start_background_apply` starts a pending change
  the same way, but only one auto-apply would have applied without you:
  never a destructive change, and nothing while Auto-apply is off. A
  change being applied shows as applying in Pending and cannot be
  applied a second time meanwhile.
- **Opening large files through your assistant** — `open_fits_file`,
  `open_cube`, `open_local_file`, `choose_viewer` and `open_vospace_file`
  wait for the pixels, and a very large file ran past the time an
  assistant waits for a tool, so it read as a failure and was opened
  again. Past ~40 s they now answer `stillLoading: true` with a note
  while the file carries on loading. Opening a file that is already open
  — in either viewer, however its path is spelled — switches to its tab
  instead of adding a duplicate. `list_open_tabs` gives each cube tab's
  real path.

- **What tools told your assistant about applying changes** — several
  destructive tools said they "run immediately when auto-apply is on",
  but destructive changes never auto-apply (they always wait for you), and
  `describe_app` said the same. Each tool that proposes a change now ends
  its description with the app's own rule, from the same place that
  decides it — and it stays there under a description you write for the
  tool in AI Guide.

- **Go To off the image** — the FITS viewer's Go To said only
  "Coordinates outside image bounds"; it now says which pixel the
  position falls on, and the assistant's `fits_goto_coordinate` says
  where it lies ("320 px left of the image") with the pixel, from the
  same answer the viewer gets.
- **The cube's spectrum probe and cursor read-out** used a pixel's corner
  as its centre, so a click on the right or lower half of a spatial pixel
  probed its neighbour, and the sky read-out was half a pixel out. One map
  from the screen to the cube's voxels now serves the probe, the read-out
  and marks.
- **A figure's "Center"** was the WCS reference point (CRVAL), which is
  often not the middle of the image; it is now the centre of what the
  figure shows. A figure that could not be written said nothing, in
  either viewer; the sheet now says so.
- **`get_fits_wcs` without an HDU** reads the HDU on screen when the file
  is open, otherwise the first HDU with a WCS, and says which
  (`hduChosenBy`).

### Changed
- **The Portal, laid out as on Verbinal for Linux and Windows** —
  platform load, storage and batch jobs across the top, active sessions
  the full width, then CANFAR images beside recent launches; one column
  in a narrow window. The launch form is no longer a card: **Launch
  Session** on Active Sessions opens it in a sheet (as does "Use this
  image"), and it closes when the session is launched. For assistants,
  `show_launch_form` opens it at a tab, with an image, or closes it.
- **CANFAR images by type and by project** — the images card shows the
  session types as chips, each with how many images it has, and a row of
  the type's projects (skaha, cadc, …) to narrow to one; the count of
  images inspected stays in its header. `list_session_images` takes
  `project` and says each image's project.
- **The cube slice moves like the FITS image** — scroll to pan, ⌘-scroll
  to zoom toward the pointer (as well as pinch), drag to pan, double-click
  to reset. The slice's zoom and pan now survive a trip to volume mode.
- **A click on a search result selects it** — five columns (collection,
  instrument, target, proposal, PI) were filter links, so clicking a
  row's target narrowed the search instead of selecting the observation.
  Narrowing to a value is now on the cell's right-click menu.
- **Polling follows what is happening** — sessions and batch jobs were
  polled every 15 s and 45 s whatever was going on, so a notification
  came up to that late, and a job that started and failed between two
  polls was never announced. Polls now come about 5 s after a change,
  ease off while nothing moves (to 8 s for a pending session, 20 s for a
  running job), and drop to 45 s when nothing is in flight — still
  watching, since work can start from another machine. A job first seen
  already finished is announced when it appeared between two polls.
  Notifications are now translated.

## [1.3.4] - Unreleased

Post–1.3.3 polish: Workflows local Edit/Delete, Storage recursive folder
delete, Cube Intel volume hardening, Research local FITS import (see
`docs/plans/`).

### Added
- Dev plans under `docs/plans/` for the 1.3.4 backlog.
- MCP `choose_viewer` resolves the NAXIS≥3 "Open as…" sheet;
  `get_current_view.pendingViewerChoice` reports it; `open_local_file`
  accepts optional `viewer` (`fits` / `cube`) to skip the sheet.
- Workflows UI: Edit and Delete for local working copies; clearer
  “New Workflow” toolbar control (store/MCP already supported these).
- Workflows overview: empty-state description + New CTA; Overview
  clears selection back to the empty workarea; New/Edit editor shows
  `.workflow.md` format hints and live advisory warnings (EN/FR).

### Fixed
- Storage: deleting a non-empty folder now walks children first (shared
  with MCP `delete_vospace_node` recursive path, 100-node safety cap)
  so ARC no longer rejects the UI DELETE. Status bar shows delete
  progress; clearer HTTP errors for 403/404/409.
- Cube Viewer: volume Metal failures no longer blank the whole view —
  wireframe can draw without the volume texture, and a banner explains
  pipeline/texture/GPU problems (Intel Mac diagnosis aid).
- Auth: logout and confirmed session expiry leave Portal/Storage for
  Landing (login sheet on expiry). Silent reauth keeps the session live
  so Portal does not flash the chrome-less wall. Post-login pending
  restore only applies while still on Landing.
- Auth: `AppMode.requiresAuthentication` + `navigateOrPromptLogin` are
  the single policy for Portal/Storage gating (Landing tiles / ⌘5 / ⌘6).
- MCP tool surface (QA 2026-08-28): `upload_file_to_vospace` accepts a
  local path, copies it into app temp, and PUTs a real body (small files
  in-memory) so the MCP call does not wait and CADC does not get a
  0-byte node; 401 retry on PUT/GET; package-fallback downloads pull
  CAOM-2 science artifacts and unique filenames; VizieR cone posts
  `REQUEST=doQuery` to TAPVizieR (`tapvizier.cds.unistra.fr`); FITS tools
  try the security-scoped bookmark and sandbox path twins before
  `observationNotFound`, and accept a unique hex id prefix;
  `save_query` returns the new id; bulk download partial-success
  envelope; `export_search_results` can omit `adql`; publisher-id
  forms (`ivo://…/COLL/id`, `COLL?id`) normalize; VOSpace paths strip
  `/home/<user>` once; `list_local_folder` expands `~` and lists the
  first readable Downloads twin; `request_folder_access` does not hang
  MCP clients; `delete_saved_query` stays on the live surface;
  `save_workflow` documents the `- [ ]` requirement; cube export/probe
  errors name `navigate_to(mode: cubeViewer)` and the streamed-cube
  limit; `resolve_target` caveats noisy Simbad types.
- FITS WCS: PC+CDELT headers (JWST i2d) apply rotation instead of
  ignoring PC; a 90° CROTA2/PC is valid (`|det(CD)|` instead of
  diagonal-only). Cube celestial WCS uses the same matrix builder.
- `probe_fits_pixel` uses 0-based FITS array coordinates (astropy
  `origin=0`). It had been applying the canvas Y-flip, so sky at a
  rotated JWST i2d corner was off by ~130″ while `get_fits_wcs`
  north angle was already correct. `get_fits_view.crosshair` reports
  the same array indices (the pixel under the crosshair), so an agent
  can probe it without converting.
- FITS Viewer: the crosshair, hover and linked-crosshair pixel values
  read the pixel actually drawn under the cursor. They had read the
  vertically mirrored row (RA/Dec were already right), so the value
  disagreed with the image except on vertically symmetric data.
- Failed `open_fits_file` / `open_cube` loads discard the new tab and
  hand focus back to the tab that had it; `get_fits_view.isOpen` is
  true only when an image HDU actually loaded — a PDF renamed `.fits`
  no longer stays as an active dead document. `openTabPaths` keeps
  one entry per tab, index-aligned with `activeTabIndex`.
- Search: MJD date cells and the ADQL date literals (public-only,
  data-release) use a fixed Gregorian/POSIX formatter. On a Mac set to
  a non-Gregorian calendar (e.g. Buddhist) they had rendered the year
  as 2569 and queried the wrong release date.
- Image Discovery inspector: POSIX `mktemp` (BusyBox Alpine hosts
  reject GNU `--suffix=.py` — live job `wzvbjl5j`); syft unpacks to
  `/scratch` when present; inspector job size is 2 CPU / 8 GB so
  syft no longer OOM-kills on large targets (Ubuntu 1.4.x). In-target
  probes stay at 1 CPU / 1 GB.
- Pending proposals journal to disk and rehydrate under their original
  ids; a failed apply reports `failed` rather than looking like a
  rejection. `get_proposal_state` accepts `proposalId` as an alias of
  `id`.
- MCP router refuses undeclared arguments when the schema sets
  `additionalProperties: false`, and one argument passed under two
  spellings. The camelCase / snake_case twin of a declared name is
  renamed to the declared spelling before the tool reads it, so it is
  honoured rather than accepted and ignored. `open_fits_file` / `open_cube` /
  `open_local_file` wait for the viewer load and report the real
  outcome. DataLink surfaces `error_message` / unauthorized rows as
  `faults` and prefers JWST `*_i2d.fits` over `asn.json` among `#this`
  products.

### Changed
- Marketing version 1.3.4 (build 17).

## [1.3.3] - 2026-07-23

Storage browser reliability pass: navigation, selection, transfer progress
with cancel, and French strings that were still missing after 1.3.2.

### Fixed
- Storage browser navigation: VOSpace container listings were including
  the folder itself as a child (Windows parser only walks `<vos:nodes>`),
  so every folder appeared to contain itself and each open appended a
  duplicate breadcrumb segment. List selection was also broken — a
  high-priority double-click gesture stole the single-click that drives
  Delete. Failed navigations now keep the previous folder on screen and
  surface the backend error in an always-visible orange status bar
  (previously errors only showed when the list was empty).
- Storage uploads and downloads share one determinate progress path in the
  status bar ("Uploading/Downloading name — 12 MB of 48 MB" + bar +
  cancel) via a single `StorageTransfer` model and
  `URLSession.upload` / `download` task delegates. Downloads stream to a
  temp file instead of buffering the whole body in `Data`. Save panel
  opens before the transfer (canceling the panel skips the download).
  Download progress uses a dedicated `URLSessionDownloadDelegate` session
  (async `download(for:delegate:)` suppresses `didWriteData`, so the bar
  never moved). Listing `#length` / `Content-Length` seed the “X of Y”
  total. Listings now request `detail=max` (Windows parity) so Modified/Size
  populate from `#date`/`#mtime`/`#length`, with robust date parsing for
  ARC's mixed ISO shapes.
- Missed French translations and minor localization polish for Storage
  transfer chrome and related strings.

### Changed
- Marketing version 1.3.3 (build 15).

## [1.3.2] - 2026-07-21

Windows wire/UI parity (skip Notebook): MCP tool names aligned with the
Windows 1.3.3 companion, Workflows module, Cube/FITS MCP+UI gaps, Endpoints
auth hardening, agent activity snackbar / sandbox folder grants, and French
strings for all new chrome. Notebook remains the VerbinalPi addon.

### Added
- **Workflows** — research-protocol tile with markdown-checklist templates
  (local + VOSpace), check-off progress, and seven MCP tools
  (`list_workflows`, `get_workflow`, `save_workflow`, `update_workflow`,
  `set_workflow_step`, `use_workflow`, `delete_workflow`).
- **Windows-canonical MCP names** (Mac names kept as aliases): `run_search`,
  `get/set_search_constraints`, `set_adql_query` / `execute_adql_query`,
  `set_search_results_view`, `load_recent_search` / `run_saved_query`,
  `blink_fits_tabs`, `switch_fits_tab`, `create_vospace_folder`,
  `download_vospace_file`, plus Cube tools `show_cube_spectrum`,
  `get_cube_channel_profile`, `set_cube_transfer`, `switch_cube_tab`,
  `list_recent_cubes`.
- **FITS Image Info** panel and **2D vs 3D viewer choice** for NAXIS≥3 files.
- **Cube multi-tab** host (agent `switch_cube_tab` / `list_open_tabs`).
- **Robot icon parity** — custom `robot` SF Symbol matching the Windows
  Fluent glyph on every agent surface: the tool-call snackbar, per-item
  "created by AI agent" badges, the proposals sheet/toolbar button, Settings
  tab, setup wizard, welcome sheet, and landing tile. Agent-created workflow
  copies now carry the badge too (attribution sidecar keeps `.workflow.md`
  bytes Windows-compatible).
- Carries forward the 1.3.1-era WIP: offline auth, Settings ▸ Endpoints +
  registry resolution, full agent↔UI search/viewer parity, concurrent MCP
  dispatch + hard deadlines, agent activity snackbar, sandbox folder grants,
  ATS `skipped` health status.

### Fixed
- Bearer token allow-list now includes effective (override/registry) endpoint
  hosts so non-default Endpoints can authenticate.
- VOSpace browser uses effective endpoints (no more silent default CANFAR URLs).
- `silentReauth` no longer clears stored credentials on transient login
  network failures.
- Negative FITS `PCOUNT` clamped (no infinite parse loop).
- Registry refresh merges partial capability results into the prior cache.
- Destructive agent writes never auto-apply (Windows `AutoApplyPolicy`).
- `get_service_health` auth probe targets `/whoami`; 404/5xx are not reported
  as healthy; response includes `ok` / `healthyCount`.
- Workflow templates ship under `Resources/Workflows/` (Bundle subdirectory)
  so built-in checklists load; sidecar probe is time-boxed so a wedged App
  Group cannot freeze Settings or the test host.
- Agent-activity snackbar was silently disabled: the unit-test suite (which
  runs hosted inside the app) persisted `showActivitySnackbar = false` into
  the real app preferences on every test run. Test instances no longer write
  to UserDefaults. The snackbar also now pulses at dispatch START (Windows
  `onAgentDispatchStart` parity) so it is visible during slow calls, not
  only after they complete.
- Snackbar headline is now the generic "AI agent is working…" (Windows
  `MainWindow_AgentWorking` parity) instead of the raw MCP client id; the
  specific client remains in the proposals history and audit log. FR added.
- Settings cog now appears in every toolbar (landing, module, Portal) —
  it used to vanish when navigating into a module.
- Workflow UI strings (`Wf_*` keys) shipped French-only — the English UI
  showed raw key IDs like "Wf_MyWorkflowsHeader". English source values
  added to the catalog.
- Localization completeness pass, verified against the compiler's extracted
  string list (SWIFT_EMIT_LOC_STRINGS): every user-facing string in the app
  now has French — not just the 1.3.2 chrome (proposals sheet, attribution
  badge, snackbar, setup wizard, Endpoints) but ~380 older gaps across
  Search/results export menus, FITS + Cube viewer controls and tooltips,
  Image Discovery, Storage browser, headless jobs, and the iOS views.
  Translations reuse the Windows client's fr-FR resources where the same
  string exists (94 strings), keeping cross-platform terminology identical
  (AD/Déc, "sans interface", "points d'accès", "Visionneuse Cube").
  Pure-format strings ("%@ / %@" and friends) are marked do-not-translate.
- Strings that bypassed the catalog at runtime (invisible to the compiler
  audit because they were built as plain Swift strings) now route through
  `String(localized:)`: the Batch Jobs dialog's Running/Pending/Completed/
  Failed filter tabs and empty-state line, the "No events/logs available" +
  "Failed to load:" log fallbacks, the auth status line ("Please log in",
  "Validating session...", offline/expired messages, "Welcome"), Storage
  browser transfer status ("Uploading/Downloading/Saved …"), Image
  Discovery's relative timestamps ("just now", "42s ago"), and the mode
  chrome titles (Storage → Stockage, etc.). Locale-sensitive unit tests
  (byte units, date formats, status prompts) were rewritten to assert
  against the same catalog/formatter output so the suite passes
  regardless of the app's language override.

### Changed
- Marketing version 1.3.2 (build 14). French localization for all new UI
  (Workflows, Image Info, viewer choice, Grant Access, snackbar).

## [1.3.1] - 2026-07-07

Patch release: offline resilience for the launch auth check, fully
configurable CANFAR/CADC service endpoints backed by live IVOA-registry
resolution, and a FITS-viewer parity pass bringing the macOS client in line
with the Windows companion.

### Fixed

- Launching without a network connection no longer hangs on the
  "Checking authentication…" spinner: the auth check now consults the
  network-path monitor and defers instead of firing a doomed request, and
  the `/whoami` validation probe uses a 15 s timeout (down from 60 s) for
  half-dead networks the reachability gate can't catch.
- The app signs in automatically when connectivity returns — no manual
  retry needed (a "Try Again" button is also available on the landing
  screen while offline).
- Launching **online with an expired token** no longer hangs on the same
  spinner: the `/whoami` 401 used to re-enter the network client's
  401-recovery interceptor, whose recovery path is that very validation
  call — an unbounded 401 → validate → 401 loop. The auth flow's own
  `/whoami` and `/login` requests now bypass the interceptor, so an
  expired token falls through to silent re-login (when a password is
  remembered) or a clean "Session expired" prompt.
- Being offline mid-session is no longer misreported as "Session expired":
  the stored token and remembered password are kept, the login sheet stays
  closed, and the session resumes on reconnect.
- **Blink comparison** now frames both images on their shared (overlapping)
  field of view, so comparing a wide-field and a narrow-field image no longer
  renders the second as a tiny square: the overlay's matched zoom is derived
  from angular field width (not pixel scale), the wider frame is zoomed in to
  the overlap, and the pre-blink framing is restored when blink stops.
- **Multi-extension fpack files** (e.g. CFHT MegaCam MEFs) no longer drop
  every HDU after the first tile-compressed table: the FITS parser now sizes
  compressed HDUs with the full FITS 4.4.1 `PCOUNT`/`GCOUNT` heap formula so
  the walk to the next extension lands on the right byte offset.
- **SIP-distorted WCS headers** (`CTYPE = "RA---TAN-SIP"`) are no longer
  degraded to a plain linear transform: the projection parser now reads the
  base projection through the `-SIP` marker, so crosshair/read-out on
  wide-field/TESS data use the proper spherical projection.
- A deterministically-failing agent auto-apply write is now withdrawn from
  the proposal queue instead of lingering there only to fail again.

### Added

- **Full agent ↔ UI parity — 34 new agent (MCP) tools** (125 total) so an agent can
  drive 100% of the app's user-facing interactions (audited in
  `docs/agent-ui-parity.md`, guarded by a registry↔catalog parity test):
  - *Search form & data train*: `get_search_form`, `set_search_form`
    (every constraint field + data-train cascade, optional execute),
    `reset_search_form`, `get_data_train_options`, `refresh_data_train`,
    `select_search_tab`, `quick_search`; the search model is now
    app-owned (hoisted onto `AppState` like the viewers) so tools steer
    the same live form the user sees, and agent-side saved/recent-query
    stores are unified with the UI's instances.
  - *ADQL editor*: `set_adql_editor` (set text / generate-from-form /
    execute without saving).
  - *Results table*: `get_search_results` (rows exactly as the user sees
    them, live sort/filter applied), `set_results_view` (sort, per-column
    filters, pagination, column visibility, display units),
    `open_observation_detail`.
  - *Recent searches*: `rename_recent_search`, `remove_recent_search`,
    `clear_recent_searches`.
  - *FITS viewer*: `select_hdu`, `fits_auto_cut`, blink suite
    (`start_blink` / `set_blink` / `stop_blink`), `set_tab_sync`
    (link crosshair / sync zoom), `search_at_crosshair`,
    `export_fits_figure`.
  - *Sessions*: `get_session_events`, `get_session_logs`, `open_session`
    (Connect button — opens the session in the browser).
  - *Image discovery diagnostics*: `list_probe_failures`,
    `get_probe_logs`, `get_image_manifest`, `clear_probe_failures`.
  - *Storage / local files*: `open_vospace_file` (download + open in the
    right viewer), `list_local_folder`, `open_local_file`.
  - *Settings (read-only)*: `get_endpoints`, `get_compute_config`.
  - Plus: `navigate_to` gains the `aiGuide` mode, `set_cube_view` gains
    `autoWindow` (percentile / full range), and `get_current_view` now
    reports the Search sub-tab and loaded-result counts.
- **FITS viewer "Export Figure…"**: annotated publication-figure export
  (header + colorbar/stretch/WCS legend, light/dark themes, PNG 2×/4× and
  PDF) mirroring the Cube Viewer's exporter — with a headless twin behind
  the `export_fits_figure` agent tool.
- **Settings ▸ Endpoints**: every CANFAR/CADC service base URL the app uses
  (login/AC, Skaha, VOSpace storage, archive TAP/DataLink, external web,
  and the IVOA registry itself) is now editable, with the CANFAR defaults
  shown as placeholders, per-field source badges, validation, reset, and a
  relaunch-to-apply banner.
- Live endpoint resolution from the CADC registry: the app pulls
  `reg/resource-caps` and each service's VOSI capabilities in the
  background (never blocking launch), caches the result locally, and
  re-checks daily. Per-field precedence is user override → resolved value
  → CANFAR default; a failed or offline refresh keeps the previous cache.
- The `get_service_health` agent tool now probes the IVOA registry and
  derives its probe set from the effective endpoints instead of a
  hardcoded list.
- **27 new agent (MCP) tools** closing the gap to the Windows client's tool
  surface: `renew_session`, `get_platform_load`, `get_storage_quota`,
  `export_search_results` (server-side CSV/TSV/VOTable to Downloads),
  `load_saved_search`, `upload_file_to_vospace` (arbitrary local file),
  `export_research_bundle`, full FITS-viewer steering (`get_fits_view`,
  `set_fits_view`, `fits_goto_coordinate`, `probe_fits_pixel`, plus
  list/save/delete bookmarks), Cube-viewer steering (`get_cube_view`,
  `set_cube_view`, `probe_cube_spectrum`), and tab management
  (`list_open_tabs`, `close_active_tab`), plus `set_vospace_acl` (VOSpace
  sharing: public / group read / group write, with the cavern container-tail
  fix), `export_cube_figure` (headless publication-figure PNG to Downloads),
  and the six AI Guide management tools (`list_guide_tools`,
  `set_tool_description`, `clear_tool_description`, `add_guide_tool`,
  `update_guide_tool`, `delete_guide_tool` — guide names are validated
  against the live tool table so a guide can never shadow a built-in).
  Writes flow through the same proposal/auto-apply gate as every other
  agent write.
- **Viewer state now survives navigation**: the FITS tab strip and the
  loaded cube are owned by the app, not the screen — switching to Search
  and back no longer discards open tabs, stretch, crosshair, or the
  rendered cube (matches the Windows client's singleton viewers). Agent
  tools steer the same live models, and bookmarks saved by an agent
  appear in the panel immediately.
- **Settings ▸ Endpoints ▸ Test Connections**: a one-tap reachability
  self-test that probes each configured CANFAR/CADC endpoint in parallel
  (bounded per-probe timeout) and reports per-service status and latency,
  reusing the same probe engine as `get_service_health`.
- **FITS viewer** now warns when a cross-tab crosshair/zoom sync is active
  and any linked tab has missing, invalid, or approximate WCS — the sync may
  not land on the exact sky position.
- **Research**: the observation Open button now names the **Cube Viewer**
  when the downloaded file is a spectral cube (matching the viewer the app
  will actually open it in).
- **Landing tiles** adapt their column count to the window width (3–5
  columns) and use fixed icon/title bands so tiles stay aligned and long
  localized titles (e.g. French "Visionneuse FITS") wrap cleanly.
- **Landing page UX pass**: the app no longer blocks launch behind a
  full-screen "Checking authentication…" interstitial — the launchpad
  renders immediately (auth-gated tiles stay locked, the toolbar shows the
  validation spinner); the page scrolls instead of clipping tiles in short
  windows; the duplicated status line under the grid is gone (the toolbar
  owns it); the offline state is a single actionable banner with the
  reason and a Try Again button; tiles give pressed-state feedback
  (Reduce-Motion aware); and VoiceOver now hears each tile's subtitle and
  locked state.
- **App-wide HIG polish pass** (~50 files, driven by a full per-surface UI
  audit): one shared inline-error style everywhere (bounded two-line message
  + copy button — a long backend error can no longer blow out a dashboard
  panel); the three Launch tabs present one consistent primary action; every
  progress spinner uses native control sizes instead of scale hacks; sheet
  keyboard contract fixed app-wide (Escape always dismisses, Return triggers
  the default action, New Folder/Login fields get initial focus); dismiss-only
  Close buttons are no longer styled as primary actions; session cards drop
  their action labels instead of clipping in narrow windows; the Go menu
  gained the missing Cube Viewer entry (⌘4) and Help regained ⌘?; dates
  honor the user's locale instead of hardcoded formats; dozens of
  catalog-bypassing strings (ternaries, String-typed params, concatenations)
  now localize; Title-Case/ellipsis/iconography/type-ramp/padding-scale
  consistency across Portal, Search, Research, Storage, both viewers,
  Settings, and every sheet; VoiceOver coverage for all icon-only controls.
- **Agent-driven Cube Viewer presentation**: `set_cube_view` now covers
  every control in the panel (background theme, spectral scale, render
  quality, slice-plane marker, playback FPS, and the full opacity
  transfer-function curve) and takes `reveal: true` to bring the user's
  window to the viewer; a new `set_cube_camera` tool rotates/zooms the 3D
  volume with a short eased animation (smoothstep, ~0.6 s; Reduce-Motion
  and `animated: false` jump instantly; a user drag always cancels the
  agent's move) so people can watch the agent walk them through a cube;
  `get_cube_view` reports the full state including the camera pose. A
  tool-set colormap/stretch/window now repaints the slice immediately
  (the tool path previously skipped the re-render the UI bindings do).
- **Viewer-panel unification pass**: the FITS and Cube control panels now
  share one design language — colormaps are chosen from the same gradient
  swatch grid in both (the FITS text menu made users memorize names),
  stretch is a segmented control in both, and the Cube panel is
  user-resizable (240–340pt) like the FITS sidebar instead of a fixed
  width. The View menu gained FITS zoom commands (⌘+/⌘−, ⌥⌘1 Actual
  Size, ⌥⌘0 Zoom to Fit). The observation-detail sheet keeps Download as
  its single prominent action (Done is now quiet, and ⎋ dismisses).
- **Layout & chrome consistency pass**: the offline banner floats over the
  bottom edge (appearing no longer reflows the centered launchpad, and it
  can't scroll out of sight); tile titles/subtitles get a horizontal inset
  so wrapped text no longer touches the tile border; the file-browser
  toggle (and ⌘B) is now available in every mode's toolbar — previously a
  panel opened in Search couldn't be closed from Portal; the account
  control is one shared component across toolbars (same icon, menu, and
  sign-in style — Portal used a different glyph); and toolbar status
  captions truncate to one line instead of wrapping and changing the
  toolbar height.

## [1.3.0] - 2026-06-15

### Added

- **Cube Viewer**: native macOS port of the v-cube 3D FITS cube viewer as
  its own home tile — Metal-rendered volume visualization of spectral
  cubes, with the volume stored as portable UInt16 half-bits so x86_64
  builds work. macOS-only (the iOS target excludes it). Localizable
  strings extracted into the catalog.

## [1.2.5] - 2026-06-07

First public App Store release. This is a large feature release on top of the
`1.2.0` baseline: a cross-platform refactor, an iOS port, a complete AI/MCP
integration surface, and a broad reliability and localization pass.

### Added

#### AI assistant & MCP integration
- In-app MCP server that runs inside the app binary (App-Store-safe — no bundled
  helper executable), exposing the app to Claude and other MCP clients.
- Read tools across Search, Research, VOSpace storage, Sessions, FITS, headless
  jobs, and image discovery.
- Write tools with a proposal strip UI, an applier registry, and per-write agent
  attribution badges plus a persistent activity feed and History tab.
- Autonomous trusted-client mode: agent writes auto-apply by default, with a
  single autonomy toggle (no per-tool granularity).
- Agent-driven UI navigation with an auto-follow toggle.
- `get_preview_image` tool: server-side CAOM-2 preview resolution and
  authenticated fetch, returned as an inline image (kept under the 1 MB MCP
  response limit).
- AI Remote Compute: `run_code` / `run_code_output` tools that execute code on a
  warm contributed CANFAR compute session, gated behind a validation step.
- Compute lifecycle tools and an in-app **AI Guide** (off by default).
- Settings: discover and configure Claude Desktop and Claude Code as MCP clients,
  plus MCP integration diagnostics and config repair.

#### Search
- Rich CAOM2 observation detail viewer (replaces the old result detail sheet).
- CADC Advanced Search (CCDA) parity: coordinate precision, time defaults,
  operator filters, HMS/DMS for RA/Dec, and spectral cross-conversion across
  14 units with full unit-switching.
- Quick-search archive links.
- Spotlight indexing of downloaded observations.

#### FITS viewer
- Full zenithal WCS projections (TAN, SIN, STG, ZEA).
- `FITSRenderEngine` and CAOM2/FITS parsers hoisted into the shared
  `VerbinalKit` package.

#### Image discovery
- Probe-job-driven discovery of session container images with a locally cached
  manifest, rolling-tag freshness, Rediscover, and cache controls.
- Dashboard "Canfar Images" widget with type tabs and Inspect handoff to the
  launch form.

#### Headless jobs
- Headless launch path matching the `opencadc/canfar` Python client, surfaced as
  a launch-form tab and as MCP tools.

#### Storage
- GRDB-backed (pinned 7.11.0) in-app database: `AppDatabase` pool + migrator,
  v1 schema, and FTS5 full-text search over observation notes.
- Research filtering now matches note text and tags via FTS.
- Versioned envelope for on-disk persistence; corrupt stores are quarantined and
  write success is reported.

#### Platform & packaging
- iOS port (iPhone/iPad) with cross-platform groundwork.
- `VerbinalKit` Swift package: shared services, parsers, networking, Keychain,
  and an addon protocol.
- Localization: English + French String Catalog across the app.
- Terms of Use acceptance gate with no-warranties / liability disclaimers
  (BC governing law, free-app liability cap), fully bilingual.

### Changed
- Reworked landing tiles with Sign In / profile button and auth-gated locked
  tiles; app-wide cinematic motion.
- Networking resiliency: `NetworkPathMonitor` integration, 401 handler, retry
  policy with backoff, and extraction of `AuthLifecycleController` from app state.
- Credentials: optional password persistence under "Remember me" with silent
  re-login on token expiry (Keychain, device-only).

### Fixed
- Research notes no longer cross-contaminate across observations.
- Numerous correctness, accessibility, and UX fixes from a 64-ticket
  code-quality and reliability sweep (force-unwrap hardening, explicit failure
  surfacing, isolation/concurrency correctness, dead-code removal, added tests).
- App Store sandbox fixes: App Groups population (MAS 2.4.5) and a POSIX
  `AF_UNIX` MCP transport that works inside the sandbox.
- Build portability: the MetricKit metric-payload handler is gated to iOS
  (`MXMetricPayload` is unavailable on macOS in older SDKs), so the project
  builds on every Xcode toolchain, not just the latest. macOS keeps the
  MetricKit diagnostic (crash/hang) reporting.

### Security
- No secrets, keys, or credentials in source; credentials are stored only in the
  Keychain (device-only) and never logged.
- Bearer tokens are restricted to an allowlist of trusted CANFAR hosts and are
  not forwarded on redirects to partner archives (SSRF / downgrade defense).
- DataLink results that are not HTTPS are rejected.
- Shipping app is sandboxed with least-privilege entitlements (network client +
  user-selected / downloads file access only; no JIT, no disabled library
  validation in the shipping target).
- Dependency pinned to an exact version (GRDB 7.11.0).

## [1.2.0] - 2025

- Baseline release prior to the cross-platform refactor and AI integration.

[1.2.5]: https://github.com/szautkin/canfar-macos/releases/tag/v1.2.5
[1.2.0]: https://github.com/szautkin/canfar-macos/releases/tag/v1.2.0-baseline
