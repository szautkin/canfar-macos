# Dev plan — Storage: non-empty folder delete & bulk delete

**Status:** review complete · not started  
**Surface:** Storage browser (macOS) + MCP `delete_vospace_node`  
**Related:** [Global plan](./00-global.md)

## Findings

| Topic | Today |
|--------|--------|
| Delete API | Sync `DELETE {nodesBase}/{user}/{path}` — no UWS/async job, no poll |
| Non-empty folders | UI issues **one** DELETE. Confirm copy implies contents go away; ARC often returns **4xx** if the container is not empty |
| MCP recursive | macOS only: `recursive: true` walks children (cap 100), then deletes the folder |
| Selection | **Single** `selectedNode` — no multi-select, no bulk delete stubs |
| Windows | Same sync DELETE + single select; MCP has **no** recursive flag |

There is **no async VOSpace delete endpoint** in Verbinal or CanfarDesktop. Longevity guidance elsewhere (re-poll listings after timeouts) is for transfers, not delete jobs.

## Goals

1. **Non-empty folder delete** that reliably clears a tree from the Storage UI (and matches user expectation / confirm copy).
2. Clear, localized errors when delete fails (esp. “not empty” / permission).
3. **Bulk delete** (optional phase): multi-select + confirm + progress.

## Approach

### Phase A — Non-empty folder (P0)

1. **Probe ARC behaviour** on a known non-empty folder: capture HTTP status/body for bare DELETE vs recursive need.
2. **Reuse MCP walk in the UI path** (DRY): extract shared `deleteNode(path:recursive:)` / tree walker from `DeleteVOSpaceNodeApplier` into `VOSpaceBrowserService` (or a small `VOSpaceDeleteCoordinator`).
3. **UI:** when deleting a container, pass `recursive: true` (or ask: “Delete folder and all contents?”). Cap + progress in status bar (`StorageTransfer`-style or a simple “Deleting… N items”).
4. **Errors:** map common statuses to strings (“Folder is not empty”, “Permission denied”, “Delete failed (HTTP n)”).
5. **Tests:** mock listing + DELETE sequence; cap exceeded; empty folder still one-shot.

### Phase B — Bulk delete (P1)

1. Multi-select in `FileListView` (⌘/⇧ click or selection set).
2. Toolbar Delete operates on `selectedNodes: Set` / ordered list.
3. Confirm with count; sequential delete with cancel; refresh once at end.
4. Keep Windows parity note: Windows is still single-select — document or port later.

### Out of scope

- Inventing a server-side async delete job (none exists).
- Unlimited recursive wipe of huge trees without a cap / cancel.

## Acceptance

- [ ] Deleting a non-empty folder from Storage succeeds (or shows a clear error with a recursive option).
- [ ] Confirm copy matches behaviour.
- [ ] Status bar shows progress for multi-node deletes; cancel stops further deletes.
- [ ] Unit tests cover recursive walk + cap.
- [ ] (Phase B) Multi-select delete of files/folders works.

## Key files

- `Verbinal/Storage/Services/VOSpaceBrowserService.swift` — `deleteNode`
- `Verbinal/Storage/ViewModels/StorageBrowserModel.swift` — `deleteSelected`
- `Verbinal/MCP/Tools/VOSpaceWriteTools.swift` — recursive applier (extract)
- `Verbinal/Storage/Views/FileListView.swift` / `StorageBrowserRootView.swift`

## Effort

| Phase | Size |
|-------|------|
| A | M (1–2 days) |
| B | M–L (2–3 days) |
