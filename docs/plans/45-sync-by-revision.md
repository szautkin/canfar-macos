# Plan 45 — Sync by revision, not by clock

**Date:** 2026-10-17 · **Branch:** `dev_1_4_1` (at 73fab42e) · **For:** 1.4.1 · **Replaces:** plan 44's A3

The person, on plan 44's A3 (clocks):

> "i do not think that time should be the case; also, the idea is to fetch data into new verbinal, or
> udpate files with the new one; think about it, if we have a conflict we need to have metadata on such
> files and compare the metadata between devices and storage version.... do no cut corners"

**Decided (2026-10-17):**

1. **The same field changed differently on two devices:** the version already in storage stays the
   shared one, being the first to reach it. This Mac's value waits as a conflict, shown to the person
   until they choose. Other fields still sync.
2. **Different fields of the same item changed:** merged by field, with nothing to choose.
3. **Removed on one device, changed on another:** the change wins. The item stays, and the conflict
   list says the other device removed it.

## Why the clock goes

**What decides today.** `CollectionKind` compares `changedAt`, each device's own clock. A Mac whose
clock runs fast wins changes it should lose, and two changes made from the same version are not seen
as a conflict at all: the "older" one is replaced, its copy kept only in `StorageSync/replaced` on the
Mac where it lost. Nothing in an item says which version it was made from, or by whom.

**What sync is for.**
- Bring a new Verbinal everything.
- Bring a device that is behind the newer versions.
- When two devices changed the same thing from the same version, say so, merge what can be merged,
  and let the person choose the rest.

That needs each item's history, compared between this Mac, its last-synced copy, and storage's.

**Compatibility.** Collections in VOSpace are new in 1.4.1, which has not shipped. The files written so
far, during plan 44's tests, are read as revision 0, so nothing is lost and nothing needs moving.

## The metadata

**In every item, in storage (the envelope, beside `key` and `record`):**

| Field | What |
|---|---|
| `rev` | The item's revision: 1 when first written, one more with each write, by any device. |
| `base` | The revision this one was made from (`rev` − 1); for a merge, the storage revision it merged with. |
| `device` | Which Verbinal wrote it: a lasting id for each installation. |
| `deviceName` | That device, as the person reads it: "Serhii's MacBook Pro". |
| `hash` | The hash of what the item says (`SyncItem.content`): it tells a revision's content apart, and spots a write by a client that does not keep `rev`. |
| `changedAt` | Kept to show the person, never to decide. |

**On each Mac, for each item:**
- **its base:** the revision it last synced (`rev`, `hash`), and that revision's whole content, kept in
  `StorageSync/bases/<kind>/` for the three-way merge;
- **while its own write is not yet confirmed by a later sync:** the revision it wrote from (`parent`),
  so a write that lost a race can still be merged.

## The decision, for each item

Call this Mac's copy L, its base B, and storage's copy R. "Changed" means a different `hash` from B's,
or for R a different `rev`.

| L | B | R | What happens |
|---|---|---|---|
| here | none | none | New here: written as `rev` 1. |
| none | none | there | New there: taken. A new Verbinal gets everything this way. |
| here | none | there | Both have it with no common past (two Macs before their first sync): the same content becomes the base; otherwise a merge with an empty base, so every field that differs is a conflict, and storage's stays. |
| unchanged | B | unchanged | Nothing. |
| changed | B | unchanged | Written as `rev` R+1, `base` R. |
| unchanged | B | changed | Taken. |
| changed | B | changed | Three-way merge of B, L and R, field by field (below). |
| removed here | B | unchanged | A removal mark is written (`removedAt`, a new `rev`). |
| removed here | B | changed | **Decided 3:** the change wins: R is taken back here, and the list says so. |
| unchanged | B | removed | Removed here. |
| changed | B | removed | **Decided 3:** the change wins: L is written again as a new `rev`, and the list says the other device removed it. |
| here | B | gone from storage | Someone deleted the file: written again (Verbinal never deletes). |

**The merge (decided 2).**
- It works on each item's JSON, without the envelope.
- Objects are merged key by key, recursively. A value or a list is one field: a note's text, or its
  tags.
- A field only one side changed takes that side; a field both changed to the same value is that value.
- A field both changed differently is a **conflict (decided 1)**: R's value stays in the merged item,
  and L's waits.
- The result is written as `rev` R+1 and applied here. When it equals R, R is simply taken.

## Writing, checked (VOSpace has no "write only if unchanged")

1. **Read again just before writing.** If `rev` moved since this sync looked, decide again with the new
   R.
2. **Write** with `rev`, `base`, `device`, `deviceName` and `hash`.
3. **Read back.** If it is not this device's write (another device's landed after it), this Mac's change
   is still to come: its base is not moved, and the next pass merges.
4. **A write that lost a race unseen.** Both devices read `rev` n and both wrote n+1, and the other
   device's write landed last. At the next sync this device sees R at n+1 with a hash that is not its
   own. That is a sibling: a merge of the parent (n), this Mac's version and R, written as n+2. Nothing
   is lost without a conflict to show.

## Conflicts, shown

- **Store.** Each one is the item, the field, this Mac's value and storage's, which device and when,
  kept on this Mac with the sync's state (`StorageSyncState.conflicts`).
- **Settings ▸ Storage ▸ Conflicts:** one row each, with **Keep This Mac's** (written as a new
  revision) and **Keep the Other's** (nothing to write: storage's is already shared). A removal notice has
  **OK** and **Remove It**.
- **The bar.** A sync that left conflicts ends "N to choose in Settings ▸ Storage".
- **Assistants:**
  - `list_sync_conflicts` (read);
  - `resolve_sync_conflict`, a proposal of the kind of what it does: "Notes and saved things on this
    Mac", "Remove notes and saved things on this Mac" for the choice that removes, and "What every
    assistant is told" for a guide, which always waits. Applied only while the conflict still waits and
    the choice still does what it did when asked.
- **`list_storage_kinds`** counts each kind's conflicts.

## Steps (each one commit, tests failing first)

| Step | What | Tests |
|---|---|---|
| F1 | `SyncMerge`: the three-way JSON merge, pure | Disjoint fields merge; the same change; conflicting fields keep R; nested objects; lists whole; added and removed keys; empty base. |
| F2 | Revision metadata in the envelope; `DeviceIdentity`; `SyncBases` (base and parent on this Mac); the decision table in `CollectionKind`, replacing `changedAt` and `replaced` | Every row of the table, on the fake VOSpace, with two and three devices; **wrong clocks change nothing** (B's clock an hour ahead); a new device takes everything; plan 44's files (no `rev`) read as revision 0. |
| F3 | Checked writes: re-read, read back, siblings | A write overtaken before and after its read-back; two devices writing the same `rev`; no change lost without a conflict. |
| F4 | `SyncConflicts`: the store, Settings ▸ Storage, the bar, the two tools, `list_storage_kinds` | On screen (AX): the section and its buttons; resolving both ways; the tools; French. **Done:** `SyncConflictsTests` (8), `StorageSettingsOnScreenTests.testConflictsAreShownWithTheirChoices`, each failing first with the feature off. |
| F5 | The manual (03, 12, 14, 16, in English and French), AGENTS.md, the parity table; handout section | Words checked against the screen. **Done:** the manual's button and bar words are the app's, English and French; the live cases are plan 44's part F. |
| F6 | Live: plan 44's B4–B8 again with the metadata; part C on a second macOS account | Plan 44's tables. |
