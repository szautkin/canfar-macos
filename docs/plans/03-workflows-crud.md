# Dev plan — Workflows: user Edit / Delete (and Add discoverability)

**Status:** Phase A+B done on `release/1.3.4` · UX polish in [06-workflows-ux](./06-workflows-ux.md) · VOSpace still deferred  
**Surface:** Workflows module (macOS)  
**Related:** [Global plan](./00-global.md)

## Findings

| Action | UI today | Store / MCP |
|--------|----------|-------------|
| Browse templates | Yes | Yes |
| Use → local copy | Yes | `use_workflow` |
| Check-off steps | Yes (local) | `set_workflow_step` |
| **Add** | Yes — labeled New Workflow + empty-state CTA | `save_workflow` |
| **Edit** raw markdown | Yes (local) | `updateText` / `update_workflow` |
| **Delete** local | Yes | `delete` / `delete_workflow` |
| Format hints / Overview | Yes ([06](./06-workflows-ux.md)) | n/a |
| VOSpace publish / list | Missing (Windows has it) | Mac MCP rejects `location: vospace` |

## Goals

1. Local workflows: **Edit** and **Delete** in the UI (Windows parity for local CRUD). ✅  
2. Make **Add** obvious (label / menu, not icon-only). ✅  
3. Defer VOSpace publish to a later plan unless needed for 1.3.x.

## Approach

### Phase A — Edit + Delete (P0) ✅

1. **Edit** on local detail toolbar: open same `TextEditor` as New, seed `item.rawText`; Save → `store.updateText`; Cancel restores detail.
2. **Delete** on local detail: confirm sheet → `store.delete` → clear selection.
3. Disable Edit/Delete for built-in templates (Use remains).
4. FR strings for Edit / Delete / confirm.
5. Store tests for update/delete.

### Phase B — Add polish (P1) ✅

1. Toolbar: `Label("New Workflow", systemImage: "plus")`.
2. Duplicate still optional / deferred.

### Phase C — VOSpace (later)

1. Port Windows list + publish when ready; keep `.workflow.md` bytes compatible.

### Phase D — UX polish ✅

See [06-workflows-ux.md](./06-workflows-ux.md): empty CTA, Overview clear, editor format hints.

## Acceptance

- [x] User can create (clear control), edit, and delete a local workflow end-to-end.
- [x] Built-ins remain read-only except Use.
- [x] Agent tools continue to work; no format break for Windows.
- [x] French strings for new chrome.

## Key files

- `Verbinal/Workflows/Views/WorkflowsView.swift`
- `Verbinal/Workflows/Services/WorkflowStore.swift`
- `Verbinal/MCP/Tools/WorkflowTools.swift`
- `Verbinal/Resources/Localizable.xcstrings` (`Wf_*`)

## Effort

| Phase | Size |
|-------|------|
| A | S–M ✅ |
| B | S ✅ |
| C | L (separate) |
| D | S ✅ |
