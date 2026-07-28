# Dev plan — Research: import local FITS / .fz into collections

**Status:** review complete · not started  
**Surface:** Research (Downloads archive)  
**Related:** [Global plan](./00-global.md)

## Findings

- Research today is a **CADC download archive**, grouped by metadata **`collection`** (no user “project” entity).
- Ingest paths: Search download + agent `download_observation` → `ObservationStore.save`.
- Local FITS open exists in FileBrowser / FITS / Cube but **does not** create Research rows.
- Dedup / notes key on `publisherID` — awkward for ad-hoc local files.
- Reusable pieces: `LocalFolderAccessStore`, `FileHelper.fitsExtensions` (`.fits/.fit/.fts/.fz`), security-scoped bookmarks (already on `DownloadedObservation`).

## Goals

1. Import **one or many** local `.fits` / `.fz` (and fit/fts) into Research.
2. Import a **folder** (non-recursive first, optional recursive later).
3. Place imports under a **collection** (and optionally a user label / project) consistent with today’s sidebar grouping.
4. Open imported files in FITS/Cube from Research as today.

## Approach

### Phase A — Data model (P0)

1. Extend `DownloadedObservation` (or companion fields):
   - `source: .cadc | .localImport`
   - Stable id for locals: e.g. `local:<uuid>` or hash of bookmark + filename
   - `publisherID` optional / synthetic for locals
   - Keep `collection` as the sidebar group key
2. Migration: existing JSON rows default to `.cadc`.
3. Notes: key notes by `id` (or support both) so locals can have notes without IVOA IDs.

### Phase B — Import UX (P0)

1. Research toolbar / empty-state actions:
   - **Add Files…** — `NSOpenPanel` multi-select, FITS extensions
   - **Add Folder…** — directory picker; enumerate immediate children matching FITS ext
2. **Assign collection** sheet: pick existing collection from archive or type a new name (acts as project/collection bucket).
3. For each file: security-scoped bookmark → `ObservationStore.save` with best-effort metadata (filename as `targetName` / `observationID`; size from disk; empty sky coords OK).
4. Skip duplicates (same bookmark URL / inode+path).
5. FR strings + progress for large folders (“Importing 12 of 40…”).

### Phase C — Optional project layer (P1)

1. If “project” ≠ CADC collection: add optional `project` / `userLabel` and group UI by project with collection as subtitle — **only if** product wants two levels.
2. Default recommendation: **reuse `collection` as the user-facing bucket** for v1 (“My CFHT reduction”, “JWST locals”) to avoid a second hierarchy.

### Phase D — Agent / MCP (P1)

1. Tool e.g. `import_local_observations` (folder or paths + collection) — proposal-gated.
2. Reuse FileBrowser grant if sandbox blocks the path.

## Acceptance

- [ ] User can add individual FITS/fz files into a named collection and see them in Research.
- [ ] User can add a folder of FITS/fz into a collection.
- [ ] Files open in FITS/Cube; bookmarks survive relaunch.
- [ ] CADC downloads unchanged.
- [ ] French chrome for import flows.

## Key files

- `Verbinal/Research/Models/DownloadedObservation.swift`
- `Verbinal/Research/Services/ObservationStore.swift`
- `Verbinal/Research/ViewModels/ResearchModel.swift`
- `Verbinal/Research/Views/ResearchRootView.swift` / `DownloadedFilesView.swift`
- `Verbinal/FileBrowser/Services/LocalFolderAccessStore.swift`
- `Verbinal/Helpers/FileHelper.swift`

## Effort

| Phase | Size |
|-------|------|
| A | M |
| B | M–L |
| C | M (if needed) |
| D | M |
