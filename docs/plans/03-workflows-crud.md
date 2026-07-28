# Dev plan — Workflows: user Edit / Delete (and Add discoverability)

**Status:** Phase A+B done on `release/1.3.4` (VOSpace still deferred)  
**Surface:** Workflows module (macOS)  
**Related:** [Global plan](./00-global.md)

## Findings

| Action | UI today | Store / MCP |
|--------|----------|-------------|
| Browse templates | Yes | Yes |
| Use → local copy | Yes | `use_workflow` |
| Check-off steps | Yes (local) | `set_workflow_step` |
| **Add** | Yes — toolbar `+` opens markdown skeleton → Save (`saveNew`) | `save_workflow` |
| **Edit** raw markdown | **Missing** | `updateText` / `update_workflow` ready |
| **Delete** local | **Missing** | `delete` / `delete_workflow` ready |
| VOSpace publish / list | Missing (Windows has it) | Mac MCP rejects `location: vospace` |

So “no add” is likely **discoverability** (only a `+` icon). Edit and Delete are real functional gaps. Backend already supports both.

## Goals

1. Local workflows: **Edit** and **Delete** in the UI (Windows parity for local CRUD).
2. Make **Add** obvious (label / menu, not icon-only).
3. Defer VOSpace publish to a later plan unless needed for 1.3.x.

## Approach

### Phase A — Edit + Delete (P0)

1. **Edit** on local detail toolbar: open same `TextEditor` as New, seed `item.rawText`; Save → `store.updateText`; Cancel restores detail.
2. **Delete** on local detail: confirm sheet → `store.delete` → clear selection; remove attribution sidecar with the file (store should already).
3. Disable Edit/Delete for built-in templates (Use remains).
4. FR strings for Edit / Delete / confirm.
5. UI tests or store tests for update/delete from the same APIs the view calls.

### Phase B — Add polish (P1)

1. Toolbar: `Label("New Workflow", systemImage: "plus")` or menu “New Workflow…”.
2. Optional: duplicate local workflow (“Duplicate”) via saveNew with renamed title.

### Phase C — VOSpace (later)

1. Port Windows list + publish when ready; keep `.workflow.md` bytes compatible.

## Acceptance

- [ ] User can create (clear control), edit, and delete a local workflow end-to-end.
- [ ] Built-ins remain read-only except Use.
- [ ] Agent tools continue to work; no format break for Windows.
- [ ] French strings for new chrome.

## Key files

- `Verbinal/Workflows/Views/WorkflowsView.swift`
- `Verbinal/Workflows/Services/WorkflowStore.swift`
- `Verbinal/MCP/Tools/WorkflowTools.swift`
- `Verbinal/Resources/Localizable.xcstrings` (`Wf_*`)

## Effort

| Phase | Size |
|-------|------|
| A | S–M (½–1 day) |
| B | S |
| C | L (separate) |
