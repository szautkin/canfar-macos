# Dev plan — Workflows UX polish (overview, New, format hints)

**Status:** Done on `release/1.3.4`  
**Surface:** Workflows module (macOS)  
**Related:** [CRUD plan](./03-workflows-crud.md) · [Global plan](./00-global.md)

## Goals

1. Empty overview explains what to do and offers **New Workflow**.
2. Clear/Overview returns from a selected workflow to the empty workarea.
3. New/Edit editor shows a format cheat sheet + live advisory warnings; still seeds `WorkflowFormat.skeleton`.

## Shipped

- Enriched `ContentUnavailableView` + New CTA.
- List toolbar Overview (disabled when nothing selected / while editing); detail Overview button.
- `startCreating()` clears selection so Cancel returns to overview.
- Editor header: creating/editing title, format hints, localized no-title / no-steps warnings.
- EN + FR `Wf_*` strings.

## Out of scope (still)

- VOSpace publish, Duplicate, format dialect changes.
