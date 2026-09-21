# Dev plan — MCP tool-surface fixes (2026-08-28 QA audit)

**Date:** 2026-08-28  
**Baseline:** Verbinal **1.3.4** (`verbinal-canfar` MCP surface)  
**Sources:** `~/Documents/Default Project/` — `qa-report-verbinal-canfar-2026-08-28.md` + 16 `dev-task-*.md` tickets  
**Related:** [Global plan](./00-global.md) · [Research local import](./04-research-local-import.md)

The QA pass exercised ~90 of ~120 tools: **~75 PASS, 15 BUG, 3 LIMITATION**. Destructive tools (session launch, ACLs, mass deletes) were intentionally skipped and need a sign-off pass later. This plan sequences the 16 filed tickets into four phases.

---

## Summary

| Phase | Theme | Tickets | Effort |
|---|---|---|---|
| **P0** | Agent-blocking data paths | VOSpace upload timeout · 0-byte downloads · VizieR 400 · stale FITS ids | M–L |
| **P1** | Correctness / agent chaining | save_query id · bulk filename collision · export current results · preview `ivo://` form · VOSpace path normalize | M |
| **P2** | Sandbox + local files | list_local_folder · open_local_file · request_folder_access | M |
| **P3** | Docs / surface consistency | delete_saved_query · save_workflow checklist · cube error text · resolve_target caveat | S |

---

## P0 — agent-blocking (fix first)

### 1. `upload_file_to_vospace` times out on ~128 KB binaries
*Ticket:* `dev-task-vospace-upload-timeout.md` — **High**  
*Code:* `Verbinal/MCP/Tools/VOSpaceWriteTools.swift`, `Verbinal/MCP/MCPStdioBridge.swift`

- Bug: `-32001` transport timeout far below the documented ≳100 MB threshold. UI upload of the same file works (direct streaming HTTPS PUT to `ws-uv.canfar.net`).
- Root cause: file bytes are inlined into a single MCP message across the stdio/socket bridge, hitting a message-size/per-call ceiling.
- Fix:
  - [x] Pass the app a **local file path** and let the app perform the streaming PUT (mirror the UI path) instead of buffering bytes in the MCP message. **Follow-up:** auto-apply must not wait on the PUT — Cursor `-32001` cancelled the in-flight transfer (0-byte node). Applier accepts the path and `Task.detached` streams app-side; poll `list_vospace_path`.
  - [x] Typed `payloadTooLarge` / timeout error with guidance instead of bare `-32001`.
  - [x] Silent VOSpace re-auth on 401 during writes (credential lapse compounded the failure).
- Unblocks: workflow `betelgeuse-rsg-inner-atmosphere-cadc-replication` step 9 (Hα figure PNG is staged as 5 base64 chunks awaiting this fix).

### 2. `download_observation` writes 0-byte `pkg-*.txt` for package-fallback observations
*Ticket:* `dev-task-download-observation-0byte-pkg.md` — **High**  
*Code:* `Verbinal/MCP/Tools/DownloadWriteTools.swift`, `Verbinal/MCP/Tools/GetDataLinksTool.swift`

- Bug: ESPaDOnS (and other package-fallback products) yield an empty `pkg-*.txt` instead of the real FITS. `get_data_links` for the same id already returns working direct `caom2Artifacts[].downloadURL`s (e.g. `1525350i.fits`, 10 MB).
- Fix:
  - [x] When `files[]` is empty, iterate `caom2Artifacts[]` with `productType: science` and download each `downloadURL` directly.
  - [x] Assert size > 0; typed error when nothing downloadable exists.

### 3. `vizier_cone_search` HTTP 400 for every catalogue
*Ticket:* `dev-task-vizier-cone-search-http400.md` — **High**  
*Code:* `Verbinal/MCP/Tools/VizierConeSearchTool.swift` (tests: `VerbinalTests/VizierFallbackTests.swift`)

- Bug: tool-wide ADQL-construction failure against `tapvizier.u-strasbg.fr` (reproduced on `I/355/gaiadr3` and `V/97/catalog`). CADC TAP works, so plumbing is fine.
- Fix:
  - [x] Log the exact ADQL sent; validate manually via `curl` to the TAP sync endpoint.
  - [x] Verify `CIRCLE('ICRS', ra, dec, radius_deg)` degree conversion, column qualification, and `TOP`/`maxRec` handling.
  - [x] Include the service's error body in the tool error for diagnosability.

### 4. FITS tools can't resolve prior-session `downloaded_observation_id`s
*Ticket:* `dev-task-fits-header-id-resolution.md` — **High**  
*Code:* `Verbinal/MCP/Tools/FITSReadTools.swift`, `Verbinal/MCP/Tools/ResearchReadTools.swift`

- Bug: `get_fits_header` / `get_fits_wcs` / `open_fits_file` return `unknownTarget` for ids downloaded in a previous app session, even with `fileExists: true` in the research archive. Only fresh in-session ids resolve — the id→path map lives in memory and resets on relaunch.
- Fix:
  - [x] Fall back to the persisted research-archive store (and/or on-disk `localPath`) when the live map misses.
  - [x] Typed `observationNotFound` (with local path) when the file is genuinely gone.

---

## P1 — correctness / agent chaining

| # | Ticket | Code | Fix |
|---|---|---|---|
| 5 | `save_query` returns only `proposalID`, not the new query `id` (`dev-task-save-query-no-id.md`) | `SavedQueryWriteTools.swift` | Return `{ id, … }` so agents can chain `get_saved_query`/`update_saved_query` without re-listing. **Done.** |
| 6 | `download_observations_bulk` collides on fixed `pkg.txt` name, aborts batch (`dev-task-download-observations-bulk-collision.md`) | `DownloadWriteTools.swift` | Unique per-item filenames (obs id + timestamp or artifact name); partial-success envelope `succeeded[]`/`failed[]` instead of first-failure abort. Depends on P0 #2 (shared staging code). **Done.** |
| 7 | `export_search_results` requires `adql` despite documented omit-to-export-current (`dev-task-export-search-results-adql.md`) | `SearchExportTools.swift` | When `adql` omitted, serialize the currently-loaded results table (same data as `get_search_results`). **Done.** |
| 8 | `get_preview_image` rejects `ivo://` publisher form (`dev-task-get-preview-image-ivo-form.md`) | `GetPreviewImageTool.swift` | Normalize `ivo://cadc.nrc.ca/<COLL>/<id>` and `<COLL>?<id>` to internal `caom:<COLL>/<id>`; unit-test all three forms. `search_observations` emits the `ivo://` form, so agents hit this immediately. **Done.** |
| 9 | `get_vospace_node` double-prepends home prefix on absolute paths → 404 (`dev-task-get-vospace-node-absolute-path.md`) | `VOSpaceReadTools.swift` | Strip a leading `/home/<user>` before prepending; align path contract (relative-from-home, absolute accepted) across `get_vospace_node` / `list_vospace_path` / `read_vospace_file` / `download_vospace_file` and their docs. **Done.** |

---

## P2 — local-file sandbox reconciliation

Three tickets share one root cause: the sandbox check doesn't treat the user's real `~/Downloads` and the container `Data/Downloads` as the same granted location.

*Tickets:* `dev-task-list-local-folder-sandbox.md`, `dev-task-open-local-file-sandbox.md`, `dev-task-request-folder-access-timeout.md`  
*Code:* `Verbinal/MCP/Tools/ShellParityTools.swift`, `Verbinal/FileBrowser/Services/LocalFolderAccessStore.swift`

- [x] **10.** Map `/Users/<user>/Downloads` ↔ container `Downloads` so both resolve to the granted location; `open_local_file` should accept the user-facing path the app itself displays (`list_open_tabs` already reports it).
- [x] **11.** `list_local_folder`: default no-path to the user's real Downloads (current default points at an unopenable container path — the tool rejects *every* path variant today); return a typed `notReadable` error instead of a thrown exception.
- [x] **12.** `request_folder_access`: detect the non-interactive agent context and return `granted: false` immediately with guidance ("grant access in the Storage panel") instead of hanging to the `-32001` transport timeout.

Cross-cutting: use security-scoped URLs per the global plan's sandbox constraint; keep parity with `04-research-local-import` ingest work.

---

## P3 — docs / surface consistency (small, batchable)

- [x] **13.** `delete_saved_query` advertised in `describe_app` but absent from the surface (`dev-task-delete-saved-query-not-exposed.md`). Expose `delete_saved_query(id)` (preferred) or stop advertising it — `SavedQueryWriteTools.swift` + `DescribeAppTool.swift`. Add a regression test: documented tool list == registered tool list. Cleanup: delete stranded QA probe query `2F5BC98F-0BAB-4906-AD26-51020BEFA104`.
- [x] **14.** `save_workflow` silently requires a `- [ ]` checklist step (`dev-task-save-workflow-checklist-required.md`). Document in `describe_app`/schema, or relax to allow zero-step docs — `WorkflowTools.swift`.
- [x] **15.** Cube viewer error guidance (`dev-task-cube-render-readiness-msgs.md`): `export_cube_figure` should auto-navigate to the Cube Viewer or name the exact remediation (`navigate_to(mode: cubeViewer)`); `probe_cube_spectrum` should document the streamed-cube limitation or offer `loadFullCube: true` — `ExportCubeFigureTool.swift`, `CubeViewerControlTools.swift`.
- [x] **16.** `resolve_target` passes through noisy Simbad classifications (M31 → "AGN") (`dev-task-resolve-target-objecttype-caveat.md`). Prefer canonical main type; add a passthrough-caveat `note` — `ResolveTargetTool.swift`.

---

## Verification

- Re-run the QA matrix for every touched tool (repro steps are in each ticket; all are safe/non-destructive calls).
- Acceptance for P0: (1) 128 KB PNG uploads via `upload_file_to_vospace`; (2) ESPaDOnS `1525350` downloads the real 10 MB FITS; (3) Gaia DR3 cone at M31 returns rows; (4) archive id `3A33CE8A-…` resolves header/WCS/open after app relaunch.
- Unit tests: publisher-id normalization (#8), VOSpace path normalization (#9), doc-vs-registered tool list (#13), bulk filename uniqueness (#6).
- Close out the Betelgeuse replication: after P0 #1 lands, upload `betelgeuse_halpha_epochs.png` properly and remove the staged `.b64` chunk files from VOSpace.

## Re-test follow-up (same day)

Live re-test after the first pass: 9 tickets verified, 5 still broken (including a **regression** on FITS id resolution). Root causes that the first pass missed:

| # | Tool | Actual cause | Fix in this follow-up |
|---|------|----------------|------------------------|
| 1 | `upload_file_to_vospace` | PUT from an unmapped `~/…` / user-facing Downloads path | Expand `~` + sandbox map before `fileExists` / PUT |
| 3 | `vizier_cone_search` | TAP 1.1 requires `REQUEST=doQuery`; `tap.cds.unistra.fr/tap/sync` is DNS-dead; 4xx is not failover-worthy so the chain stopped | Post `REQUEST=doQuery`; primary host `tapvizier.cds.unistra.fr/TAPVizieR/tap/sync`; example table `V/97/variabls` |
| 4 | FITS header/WCS/open | `fileExists` on the stored path ran *before* the bookmark; container ↔ user-facing Downloads twins were ignored — inconsistent ids, not a second store | Bookmark first, then path candidates; unique 8+ hex prefix |
| 11 | `save_workflow` no checklist | Documented requirement | No code change |
| 12 | `list_local_folder` `~/Downloads` | Tilde not expanded (relative `~/Downloads`); listing mapped only to the container | Expand `~` against real user home; enumerate candidates until one lists |

Do **not** treat a raw-string `fileExists` miss as `observationNotFound` when a bookmark or Downloads twin can still open the file.

## Follow-up QA pass (not in this plan)

~30 tools were intentionally not exercised (session/headless lifecycle, `set_vospace_acl`, `upload_to_vospace`, bulk note updates, recent-search mutations, image-package probes, blink aliases). Schedule a supervised pass with explicit user sign-off for the destructive ones; `upload_to_vospace` should be re-tested after P0 #2 since it depends on the download path.
