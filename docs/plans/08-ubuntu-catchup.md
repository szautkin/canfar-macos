# Dev plan — Ubuntu catch-up (1.4.x line)

**Date:** 2026-09-20
**Baseline:** Verbinal macOS **1.3.4** (`release/1.3.4`, post–QA-audit commits) vs Verbinal Ubuntu **1.4.4**
**Sources:** `CanfarDesktopUbuntu` CHANGELOG 1.3.3→1.4.4 + `PARITY_REVIEW.md`; verified against this tree
**Related:** [Global plan](./00-global.md) · [MCP tool fixes](./07-mcp-tool-fixes.md)
**Status (2026-09-26):** Phase 1 shipped in 1.3.4. Phases 2–4 and the hygiene
track are superseded by [10 Windows catch-up](./10-windows-catchup.md) —
Windows 1.4.1 is the newer superset.

Ubuntu shipped nine releases between Aug 14 and Sep 4 (1.3.3→1.4.4). We are
**not** behind everywhere — macOS already has Image Discovery, ~120 MCP tools
with the agent↔UI parity matrix, IVOA `/availability` health probes,
auto-apply/proposals/attribution, and streaming storage transfers. The deltas
below are verified against the code, not assumed.

Branching: work lands on `release/1.4.0`, cut from the tested tip of
`release/1.3.4` after it ships. Fast-forward merges only on the release line;
`main` is fast-forwarded after each release (it is currently stale at v1.3.0).

Out of scope: Notebook (stays in the VerbinalPi addon by decision, 2026-09-20).

---

## Verified gaps

| # | Gap | Evidence | Severity |
|---|---|---|---|
| 1 | **WCS PC-matrix missing** — JWST i2d headers (PC + CDELT) get zero rotation; sky coords off 40–90″ far from CRPIX | `shared/VerbinalKit/Sources/VerbinalKit/FITS/FITSWCSTransform.swift` reads only `CD1_1…` else `CDELT+CROTA2` | high (correctness) |
| 2 | Marks/annotations subsystem + 8 MCP tools | no `annotate_fits`/`annotate_cube` anywhere | high (feature) |
| 3 | Agent visual context `get_fits_image` / `get_cube_image` | no matches | high (agent) |
| 4 | Tool-surface map `list_apps` / `search_tools` / `man` | only `describe_app` exists | medium (agent) |
| 5 | Pending proposals do not survive restart | `ProposalStore.swift` is in-memory; no persistence | medium |
| 6 | Fixed 15 s session poll; no adaptive cadence | `SessionListModel.swift` `pollInterval = 15` | medium |
| 7 | No schema-backed ADQL editor checker / `describe_tap_schema` | no editor validation path | medium |
| 8 | Registry search + merged image catalogue + `search_packages` / `describe_image` | ImageDiscovery exists; these extensions don't | medium |
| 9 | Sexagesimal/RA-Dec formatting duplicated across 7+ files | `CubeWCS`, `FITSWCSTransform`, `FITSExportView`, `FITSViewerModel`, `FITSTabHostModel`, `CoordinateBookmark`, `AppState+AgentTools` | DRY debt |

---

## Phase 1 — correctness (first milestone on `release/1.4.0`)

1. **WCS PC-matrix support** in `FITSWCSTransform`: `CDi_j = CDELTi × PCi_j`,
   CD wins when both present. Name the three pixel conventions (FITS 1-based
   centre / display corner / 0-based array) as typed conversions, each paired
   with its inverse. Tighten astropy-reference test tolerances; add far-corner
   cases (rotation error is largest there).
2. **Proposal journaling**: persist pending proposals; rehydrate under
   original ids on restart; tombstone TTL so a resolved id cannot apply twice;
   a failed apply is distinguishable from a rejection.
3. **Notification & polling correctness**: adaptive cadence (≈5 s after a
   change, easing to current ceilings) replacing fixed 15 s; never announce a
   session that failed before app start; queue toasts instead of dropping
   bursts.
4. **Agent honesty audit**: router enforces `additionalProperties: false`
   (refuse unknown args by name); `open_fits_file`/`open_cube`/
   `open_local_file` report the real outcome; cross-check Ubuntu's download
   fixes (zero-byte refusal, DataLink fault surfacing, JWST `#this`
   multi-product pick, record enrichment via publisherID) against plan 07.
5. **Self-validating manifest**: test that every advertised `inputSchema` is a
   valid object schema (one malformed schema can make a client reject the
   whole server).

## Phase 2 — agent experience

1. Tool-surface map: `list_apps`, `search_tools`, `man(tool)`.
2. `describe_tap_schema` (fetched once, cached) + CAOM2 column guidance and
   ADQL dialect notes (TOP not LIMIT, no UDFs, geometry `= 1`) in tool docs.
3. ADQL editor checker: underline unknown tables/columns/functions, grey out
   Execute; reuses the `describe_tap_schema` cache.
4. `get_fits_image` / `get_cube_image`: return the on-screen view (zoom, pan,
   colormap, crosshair, marks) + inverse transform for pointing; settings cap
   size in pixels and MB.
5. Tab lifecycle: `close_fits_tab` / `close_cube_tab`; `cubeTabs[].path` is a
   real path; enrich `get_cube_view`; advertise `rowsPerPageOptions` and
   per-column `units` in results-view reads.

## Phase 3 — marks (annotations)

- **One renderer** shared by FITS canvas, cube volume, cube slice — a shape
  must not look different per surface. Circles + boxes, label with leader.
- Click to place, drag to size, grips to resize, click to open, drag to move.
  A cube mark lives on one channel; the list navigates to it.
- Persist with the file; included in `export_fits_figure` /
  `export_cube_figure` output (grips are not).
- MCP: `annotate_fits`, `annotate_cube`, `update_annotation`,
  `select_annotation`, `remove_annotation`, `clear_annotations` + two
  listings; register in `AIGuideCatalog` + parity matrix.

## Phase 4 — images & Portal UX

- CANFAR images card filtered to launchable images (session type + project;
  drop `desktop-app`-only). On-demand registry search merging into one
  catalogue read by the card, package search, and launch form. Package browser
  (OS, capabilities, packages by ecosystem, filter). `search_packages` +
  `describe_image` MCP tools on the existing `Verbinal/ImageDiscovery`.
- Probe hardening (Ubuntu's five root causes): RAM floor, longer poll ceiling,
  `python3` fallback, syft scratch location, diagnostics preserved when Skaha
  returns nothing for a killed container.
- Portal/viewer polish: single launch entry; FITS opens fit-to-viewport (never
  enlarging, once per file); FITS empty state offers recents (reuse the cube
  viewer's component/store); cube slice opens at the size the volume shows it.

## Hygiene track — DRY / SOLID (runs alongside every phase)

1. **DRY sweep**: one VerbinalKit sexagesimal helper with a test that no file
   regrows a private copy; audit for duplicated streaming-download and
   atomic-write implementations (Ubuntu's duplicate download had silently
   missed cancellation; two atomic writers clobbered each other's temp file).
2. **Pinned toolchain**: pin Xcode/Swift for CI and local (`.xcode-version`),
   README/CONTRIBUTING quote the exact gate commands, drift test.
3. **Invariant tests** (extend `AgentToolCatalogParityTests`): every
   advertised argument is read; settable ↔ readable; applier keys ⊆ proposer
   keys; every user-visible string through the catalog with an FR pair; no
   dead xcstrings keys.
4. **Exhaustiveness over if-chains** where a modelled case can silently fall
   through; decode enum arguments by name, never by position. Burn down the
   Swift 6 concurrency warnings surfaced in the 1.3.4 build.

---

## Sequencing

```mermaid
flowchart LR
  p1[Phase 1 correctness] --> p2[Phase 2 agent experience]
  p2 --> p3[Phase 3 marks]
  p3 --> p4[Phase 4 images and portal]
  hygiene[Hygiene track] -.alongside every phase.-> p1
```

Phases 1–2 are mostly S/M items with outsized payoff — ship fast, mirroring
Ubuntu's 1.3.5–1.3.7 cadence. Phase 3 is the one large greenfield build.
Phase 4 extends existing Image Discovery code. Hygiene items land
continuously, each with its guard test.
