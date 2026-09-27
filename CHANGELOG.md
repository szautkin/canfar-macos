# Changelog

All notable changes to Verbinal for macOS (and the new iOS port) are documented
in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] - Unreleased

Catching up with Verbinal for Windows 1.4.1 (see
`docs/plans/10-windows-catchup.md`).

### Fixed
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
