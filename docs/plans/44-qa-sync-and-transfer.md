# Plan 44 — Testing sync and transfer, thoroughly

**Date:** 2026-10-17 · **Branch:** `dev_1_4_1` (at `ac4f3614`) · **For:** 1.4.1 · **Kind:** a QA handout,
with the tests still to write

The person: "plan a data sync/transfer test that feature we implemented before, but I do not remember
whether we thoroughly tested it".

## What there is to test

**Your Work in VOSpace** (plans 34 V, 36 tier 3; Settings ▸ Storage)

- **What it covers.** Twelve collections of the person's work, each off until the person turns it on:
  - Research
  - Marks on images
  - Sky bookmarks
  - Workflows
  - Saved queries
  - Recent searches
  - Guides for assistants
  - Remote Compute history
  - Batch job history
  - Your added images
  - Recent launches
  - Portal launch defaults

  There is also **Results**: downloads, cutouts, search exports and figures, sent to `Verbinal-Results`.
- **Where it is kept.** Each item is one JSON file in `.verbinal/<folder>/`, named by a hash of its key.
  `.verbinal/manifest.json` says which collections are kept. A choice made on one device holds for
  every device.
- **The rules** (`CollectionKind`):
  - The newer change wins. The one it replaced is kept on the Mac where it lost, in `StorageSync/replaced`.
  - A removal travels as a mark. A device marks only what it had.
  - Fields this build does not know are kept. A newer format of an item is left as it is.
  - Nothing moves while `.verbinal` is readable by anyone.
  - Nothing is ever deleted.
- **When it syncs** (`StorageSyncModel`):
  - right after sign-in;
  - when Verbinal comes back to the front, if the last sync is over 15 minutes old;
  - 5 s after a kept collection changes here (that collection only);
  - on **Sync Now** or `sync_storage`.

  There is no timer. A change made on another Mac arrives at the next of these.
- **Verbinal's own data**, kept anyway: image package lists, Remote Compute runs, batch job scripts,
  exports. Pause and Resume come from plan 40.

**Research files between this Mac and storage** (2026-10-13, handout 37 P). The badge and its menu:
- **Send a Copy to Storage**
- **Get from Storage**
- **Move to Storage…**, **Move to This Mac…**
- **Remove from This Mac…**, **Remove from Storage…**

The tools: `send_research_file_to_storage`, `get_research_file_from_storage`,
`remove_research_file_from_mac` and `remove_research_file_from_storage`.

## How far it has been tested

**In unit tests: 41**, on a fake VOSpace shared by two `StorageSync`s.

| File | What it holds |
|---|---|
| `StorageSyncTests` (21) | The manifest; one device to another; newer wins and the other is kept; removal marks; unknown fields and newer formats; public folder; pause and resume; progress; failures wait; nothing after sign-out. |
| `WorkSyncTests` (11) | Saved queries, recent searches, workflows, guides, session instructions, job history, recent launches, Portal defaults; only the chosen collections; no CANFAR storage. |
| `FileIdentitySyncTests` (5) | Marks and bookmarks follow a storage file; a file of this Mac alone keeps them. |
| `ResultDestinationTests` (3) | Results stay unless kept; they wait; the sync sends them. |
| `StorageSettingsOnScreenTests` (1) | A paused sync on screen. |

**Live:**
- **D1:** all thirteen collections off, `hasStorage: true`. Passed on 2026-10-09.
- **N1–N4:** package lists on a new device, with pause and resume. Passed on 2026-10-16.
- **Never run:** D2–D9 (two devices, conflicts, removals, results, the public folder, a switch turned
  off) and **all of P** (Research files).

Today (2026-10-17), `list_storage_kinds` shows every collection of the person's still off. **Nothing of
their work has ever been synced on the real service.**

**Gaps in the unit tests:**
- Your added images and Remote Compute history have no two-device test.
- No test of another device writing while this one syncs (risk 1, below).
- No test of a device whose clock is wrong.
- No test of a change that keeps a file's size.
- No test of a switch turned off on another device.

## What could go wrong on the real service, and the fake would not show

1. **Another device's change during this one's sync is taken for this one's own.** This is found in the
   code, `StorageSync.sync(_:declared:)`.
   - **What the code does.** After sending, the sync lists the folder again "so the next sync does not
     take its own writes for someone else's". It then remembers every file's size and date as seen, not
     only those it wrote.
   - **The window.** Any file another device wrote in that folder while this sync ran (one file, or any
     of them) counts as seen without being brought here. The window lasts as long as the sync of that
     folder: seconds for a note, minutes for Research's first sync.
   - **What follows:**
     - That change never arrives here, until the file changes again.
     - When this Mac next edits the same item, it writes over the other change, with no copy in
       `replaced`.
     - Two Macs syncing the same item at once is the same thing, in its smallest form.
   - **For 1.4.1.** A2 shows it. The fix: remember the new date only for the files this sync wrote, so
     anything else that changed is still to come.
2. **Clocks.** "Newer" is each Mac's own clock (`changedAt`). A Mac a few minutes fast wins changes it
   should lose.
3. **Change detection.** A changed file is found by its size and date in the listing. A one-character
   edit keeps the size, so its date alone must show it.
4. **Many items.**
   - Research's first sync writes one file per record, one request each.
   - A large Research is slow, and is on the activity bar only past 5 items.
   - The person's storage is 79 % full (158 of 200 GB), and Results send whole files.
5. **What VOSpace answers that the fake does not:**
   - folder creation (409);
   - an expired sign-in partway through;
   - a write refused for quota.

## The test

### Ground rules

- **The person turns collections on.** It is their choice, and it puts their work in their storage. An
  assistant cannot.
- **Test with marked items first.** Saved queries and workflows named `qa44 …`, before the person's
  own Research.
- **Writing over a file in storage asks the person.** An assistant playing "another device" changes
  files in `.verbinal`. Writing over one is **Remove or replace in your CANFAR storage**: it waits in
  Pending, and the person applies it.
- **Before Research is turned on, a backup.** **Export All**, or a copy of Verbinal's folder, by the
  person. The sync deletes nothing, but a newer change replaces an older one.
- **What a second Mac can be:** another Mac, or a second macOS user account on this Mac. Each account
  has its own Verbinal container. The iOS app has no sync.

### A — Tests to write first (automated, fail-first)

| Case | Test |
|---|---|
| A1 | Every collection, by one table-driven test over `StorageSyncModel.catalog`'s kinds. Each kind goes through the full round on two devices: made on A, brought to B, edited on B, brought back to A, removed on A, removed on B. This covers Your added images and Remote Compute history, which have no test yet. |
| A2 | While A sends its changes (the fake holding its writes), B writes a change to another item of the same folder, and to the same item. Expected: A's next sync brings B's change to the other item, and keeps the newer change of the same item, with the older in `replaced`. Today's code fails this (risk 1): fix it, so the dates remembered after a send are only those of the files this sync wrote. |
| A3 | Device B's clock 10 minutes ahead: say what happens, in the test's name. Either accept it, and the manual says clocks must be right, or compare against storage's own dates. **The person decides.** |
| A4 | A same-size edit, at the same listed second as the last sync, is still found. |
| A5 | A switch turned off on A: B stops sending that collection at its next sync, and the files stay. |

### B — One Mac, live: an assistant over MCP, the person at the switches

| Case | Steps | PASS if |
|---|---|---|
| B1 | Before: `list_storage_kinds`; note each local count (saved queries, workflows, Research records). | All twelve collections and Results are `off`; `hasStorage: true`. |
| B2 | The person turns on **Saved queries**. An assistant saves `qa44 one` (`save_query`). | `.verbinal/manifest.json` declares `savedQueries`. `.verbinal/queries/` has one file per saved query, each readable (`read_vospace_file`), with its `key`, `changedAt` and `record`. `list_storage_kinds` shows the count, with `sent` equal to it. |
| B3 | Edit `qa44 one` on this Mac. Wait 10 s. | The file in storage changed, without **Sync Now**. The bar does not show a 1-item sync; Settings ▸ Storage says when. |
| B4 | **As another device:** an assistant writes a newer version of `qa44 one`'s file, with a new name in `record` and `changedAt` a minute ahead. The person applies it in Pending. Then `sync_storage`. | The saved query is renamed here. No copy in `replaced`, because this Mac had not changed it since. |
| B5 | Edit `qa44 one` here, then (before 5 s pass) write an older `changedAt` version into storage as another device. | This Mac's version wins and goes back to storage. The other is kept in `StorageSync/replaced/savedQueries/`. |
| B6 | Write the file with `removedAt` set. `sync_storage`. | `qa44 one` is gone here. The file stays in storage, with its mark. |
| B7 | Add a field `"qa44Future": 1` to another item's file. Then edit that saved query here. | The file keeps `qa44Future` after this Mac's write. |
| B8 | A one-character change (same size) written as another device. | It arrives (A4, live). |
| B9 | The person makes `.verbinal` readable by anyone (Storage, sharing), edits a saved query, and clicks **Sync Now**. Then makes it private again. | While public, nothing moves, and Settings ▸ Storage and `list_storage_kinds` say why. Once private, the edit goes. |
| B10 | The person turns **Saved queries** off. Edit one here. | The files stay in storage; nothing is sent; the manifest no longer declares it. |
| B11 | **Workflows**, **Recent searches**, **Guides for assistants**, the same way as B2 and B4 (one item each). | The same. A guide an assistant proposes goes only after the person applies it. |
| B12 | **Research.** The person backs up, then turns it on. | The first sync counts up on the bar ("N of M") once it moves 5 or more. Pause and Resume work, as in N2 and N3. Every record has its file. Time how long it takes for the person's number of records. |
| B13 | **Results.** The person turns it on. Download a small observation, and export a figure. | Both reach `Verbinal-Results/research/` and `figures/`. `list_downloaded_observations` has the `storagePath`. With Wi-Fi off they wait, and they go once it is back. |
| B14 | Sign out during B12's sync. | Nothing moves after sign-out. At the next sign-in it goes on. |

### C — Two devices (the person, with a second Mac or a second macOS account)

| Case | Steps | PASS if |
|---|---|---|
| C1 | On Mac B, sign in to the same account. | B shows the same switches on as A, with no choice made on B. Then B's own items of each kept collection go to storage. |
| C2 | A saved query, a workflow step ticked, a note on a Research record, a recent launch: each made on A, then **Sync Now** on B. | Each shows on B. Recent launches and Portal defaults too, if kept. |
| C3 | The same note edited on A and on B, neither synced; then sync A, then B. | The newer wins on both. The other is kept on its Mac in `StorageSync/replaced/research/`. |
| C4 | **During a sync (risk 1),** after A2's fix. While A's Research first sync runs (B12), change a note on B and sync B. Also edit the same saved query on both, and click **Sync Now** on both within a second. | B's note reaches A at A's next sync. Of the saved query, the newer wins on both, and the older is kept in `replaced`. |
| C5 | Remove a saved query on A; sync both. Then, on a third sign-in that never had it (or after a fresh install of B), sync. | It goes from B. A device that never had it marks nothing. |
| C6 | Marks on a file opened from storage on both Macs; marks on a file of A alone. | The first reach B; the second stay on A. |
| C7 | Turn a collection off on B. | A stops syncing it at its next sync; the files stay. |
| C8 | Clocks (A3, if the person wants it checked live): B's clock set 5 minutes fast, the same note edited on A after B. | As A3 decided. |

### D — Research files (handout 37 P, run for the first time)

Run P1–P8 as written in handout 37, on a small observation of the person's choosing. Also:

| Case | Steps | PASS if |
|---|---|---|
| D1 | **Send a Copy to Storage** on a file, then **Pause** on the bar partway, quit, reopen, **Resume**. | It goes on and ends complete: the same size in storage. |
| D2 | **Get from Storage** with Wi-Fi off. | It fails saying why. Nothing half-written stays in the download folder. |
| D3 | With **Results** kept (B13), **Send a Copy to Storage** on a file already sent by Results. | One copy in `Verbinal-Results/research/`. No second, and no "different size" refusal for the same file. |

## Where the results go

- A table, **Live pass, sync and transfer**, at the end of this file: case, PASS or FAIL, notes.
- A FAIL becomes a fix with its test, fail-first, as in plans 41 and 42.
- A2's outcome, and the person's decision on A3, are recorded here.

## Order and time

1. **A1–A5** (tests, and A2's fix if it fails): half a day.
2. **B1–B11:** an hour, with the person at the switches and Pending.
3. **B12–B14 and D:** an hour, depending on Research's size.
4. **C:** when the person has a second Mac or account ready.

## A — Done (2026-10-17)

**Risk 1 was real, and is fixed.** The two A2 tests and a third fail on the code before the fix, each
with the other device's change missing:

- `testAnotherDevicesChangeDuringASyncComesAtTheNext`: B's change to another record during A's sync
  never reached A.
- `testARecordChangedThereBeforeThisDeviceWritesIsNotWrittenOver`: B's change, written after A's
  listing and before A's write, was written over, with no copy kept.
- `testAFileWrittenOverRightAfterThisDeviceWroteItComesAtTheNextSync`: B's write over the file A had
  just written was taken for A's own.

**The fixes:**

- **`StorageSync.known(listed:seen:written:in:)`.** After a sync, this device remembers each file as it
  was listed before the sync. A file the sync wrote is remembered as written, when the size listed
  afterwards is the size it wrote. Anything else that changed while the sync ran is still to come.
  `WriteRecordingRemote` notes the sizes a kind writes.
- **`CollectionKind.settle`.** There is now one rule for a change of theirs. It is used for what the
  listing says changed, and for what the read just before a write finds changed since this device last
  saw it. That change is settled (the newer wins, the other is kept in `replaced`) and never written
  over.
- **What is left.** Two Macs that each read before either writes, within the same second, can still
  both write. Each keeps the other's in `replaced` only when it read it.

**A1, A4, A5, written; each passes on the code as it was:**

- `testAnAddedImageGoesBothWaysAndSoDoesItsRemoval`, with a tag in capitals (`:Oct24`);
- `testARemoteComputeRunGoesBothWaysAndSoDoesItsRemoval`, with its result arriving and its removal;
- `testAChangeThatKeepsTheSizeIsFound`;
- `testACollectionTurnedOffOnOneDeviceStopsOnTheOthersAndItsFilesStay`.

**A3 (clocks)** waits for the person's decision.

Sync tests: 48 pass (StorageSync 24, WorkSync 15, FileIdentity 5, ResultDestination 3, on screen 1).
