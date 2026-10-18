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
| C3 | The same note edited on A and on B, neither synced; then sync A, then B. | Plan 45: different parts of the note both stay; the same part keeps the one A sent, and B's waits in **Settings ▸ Storage ▸ Conflicts** on B (F3, F9). |
| C4 | **During a sync (risk 1),** after A2's fix. While A's Research first sync runs (B12), change a note on B and sync B. Also edit the same saved query on both, and click **Sync Now** on both within a second. | B's note reaches A at A's next sync. Of the saved query, the newer wins on both, and the older is kept in `replaced`. |
| C5 | Remove a saved query on A; sync both. Then, on a third sign-in that never had it (or after a fresh install of B), sync. | It goes from B. A device that never had it marks nothing. |
| C6 | Marks on a file opened from storage on both Macs; marks on a file of A alone. | The first reach B; the second stay on A. |
| C7 | Turn a collection off on B. | A stops syncing it at its next sync; the files stay. |
| C8 | Clocks: B's clock set 5 minutes fast, the same note edited on A after B. | Plan 45: the clock decides nothing — as C3 (F7). |

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

## A3 — Clocks: the choice, prepared for the person

**Today.** "Newer" compares each Mac's own clock. Every item's `changedAt` is the time its device
stamped it: a Research note's `modifiedAt`, a saved query's `changedAt` or `savedAt`. So a Mac whose
clock is 5 minutes fast wins every conflict with an edit made up to 5 minutes later. macOS sets its clock
from the network, so on a normal Mac the error is under a second. It matters only for a Mac with
automatic time turned off.

**Option 1: accept it, and say so.**
- The manual, 14-settings ▸ Storage, says: "Keep each Mac's date and time set automatically (System
  Settings ▸ General ▸ Date & Time): the newer change wins by each Mac's clock."
- A test names today's behaviour.
- Cost: an hour.

**Option 2: measure each Mac's clock against storage's.**
- After a write, the sync lists the folder again anyway. The file it wrote has storage's date for that
  moment, which gives this Mac's offset from storage.
- A sync keeps the offset, adds it to each `changedAt` it sends (the envelope only, never the record),
  and compares its own items with it added.
- Every device's dates then compare on storage's clock.
- Cost: about a day, with tests (a fake VOSpace whose clock is ahead of the device's). VOSpace's dates
  must be trustworthy to the second, which needs a check of their own.

**Recommendation:** Option 1 for 1.4.1. The case needs a Mac with automatic time off, and option 2
adds a moving part to the sync just fixed. Option 2 can come later if a person ever reports it.

## Live pass, 2026-10-17 (an assistant over MCP, builds f5ef7ce7, then the working tree, production)

| Case | Result | Notes |
|---|---|---|
| B1 | PASS | All off at first. The person's work at the start: 17 saved queries, 31 recent searches, 17 workflows. |
| B2 | PASS | Saved queries on: the manifest declares it, and 17 files went in 17 s, about one a second. Each file is `{changedAt, format, key, record}`. |
| B3 | PASS | A saved query (`qa44 one`) and a workflow (`qa44`) reached storage by themselves, within 10 s. |
| **Switches** | **FAIL, fixed 46446e2c** | "I cannot turn on/off any of them." Three faults: (1) a switch moved only when the collection's first sync ended, and that sync waited behind any sync running, so it snapped back and each further click wrote the opposite choice; (2) a collection turned on during a sync never had its first sync ("Waiting for its first sync"); (3) two choices made at once lost one in the manifest. After the fix, each click was written once, in order, about 3 s apart, and the switches moved at once. |
| B4 | PASS | A newer change written as another device (step One ticked) arrived at Sync Now: "Updated the workflow … because: a change from another device". |
| B5 | PASS | An older change from another device against a newer one here: this Mac's version won and went to storage, and the older was kept ("kept the newer of two changes … StorageSync/replaced"). |
| B6 | PASS | A removal mark from another device: the workflow went from this Mac; its file stays in storage with the mark. |
| B7 | PASS | `"qa44Future": 1` written by another device survived two changes made here. |
| B8 | PASS | A newer edit of exactly the same size (318 bytes, "One" became "Une") arrived. |
| B10 | PASS | Saved queries and Recent searches turned off: their 18 and 31 files stay in storage, and nothing more is sent. |
| B11 | PASS | Workflows, Guides, Batch job history, Marks, Sky bookmarks and added images synced on being turned on. |
| B12 | PASS | Research turned on (by the person's clicks during the switch fault): 52 records, about one a second. |
| Sync Now | PASS | 30 s for everything; nothing moved when nothing had changed. The slowest part is listing Remote Compute runs (482 files, 12–13 s). |
| P2 | PASS | A 43 KB cutout to storage: same bytes, `places: both`. A 60 MB image in 2.8 s, the same size. |
| P6 | PASS | A file of another size at the path: refused, "A different file is in your storage at … already: nothing was written over it." |
| **P8** | **FAIL, fixed 939e84f3** | Removing the copy on this Mac of a file only on this Mac went to Pending as "(it stays in your storage)", and would only have failed once applied. Each of the four tools now refuses at the call, in the transfer's own words. Both proposals were withdrawn before anyone applied them. |
| D1 | N/A | A single file's transfer is not pausable: only the storage sync is. A 60 MB send took 2.8 s. |
| P3 | PASS | Removing the copy on this Mac (applied by the person): `places: storage`, no file in Downloads. |
| P4 | PASS | Brought back from storage: the same name in Downloads, 43,200 bytes, `places: both`. |

Small finding: when a change from another device is brought in, the store change starts a second sync of that collection, which reports `imported: 0` over the first run's count. Harmless, but Sync Now's answer understates what came.

## E — When VOSpace is slow or out of service (the person, 2026-10-17)

"do we consider that vo space might be very slow and sometimes out of order, we might need to re try in a while? we need to take it into account and make manual retries and let user know about it in the bottom system status"

**Today:**
- No request is retried.
- After a failure, the next sync comes only with sign-in, coming back to Verbinal after 15 minutes, a change in a collection, or Sync Now. There is no timer, so a change that failed to go can wait for hours.
- A failed sync is on the activity bar only when it moved 5 or more items; otherwise only Settings ▸ Storage says why. The bar has no Retry.
- The manual says "the next one is tried later", which is true only with a trigger.

| Step | What | Test, fail-first |
|---|---|---|
| E1 | A failed sync of any size goes on the activity bar: "Couldn't reach your CANFAR storage: <why>. Next try in N min", with **Retry now** (the bar, and `list_activity`). | The model with a failing fake VOSpace: a 1-item sync that fails leaves a failed task with its reason and next try. |
| E2 | A timed retry after a failure: 1, 2, 4 … up to 30 minutes while signed in, and at once when the network comes back (`NetworkPathMonitor`). A success clears it. | A fake clock: after a failure, a sync runs at 1 minute, then 2; a success stops them. |
| E3 | Inside a request: one retry after 2 s, then another after 5 s, for a timeout, a 5xx, or a dropped connection. Never for 4xx. Reads, listings and whole-file writes repeat safely. | A fake transport that fails twice, then answers: the sync succeeds; a 403 is not retried. |
| E4 | **Retry** on the bar for a failed Research-file transfer or Results upload. | A failed send leaves a task whose retry sends again. |
| E5 | A sync waiting longer than 10 s goes on the bar ("Waiting for your CANFAR storage…"), whatever its size. | A held listing: the task appears after 10 s. |

## E — Done (2026-10-17, 2960327b)

All five steps are built. Each has its tests, and E1's failed first: a one-item sync that failed left
nothing on the bar.

- **E1.** A failed sync of any size is a failed task on the bar, with the reason, "Verbinal tries
  again in N min." and **Retry**. `list_activity` says `retryable`, and `retry_activity` is the
  assistant's Retry, for a sync only.
- **E2.** `StorageSyncModel` tries again after 1, 2, 4 … 30 minutes (`retryWait`), and at once when
  `NetworkPathMonitor` sees the network come back. A success clears it, and so does signing out.
- **E3.** `RetryingStorageRemote` wraps the sync's VOSpace. It retries a timeout, a dropped
  connection, an unreachable host or a 5xx twice (2 s, 5 s), and never a 4xx.
- **E4.** A failed Research-file transfer offers Retry, which is the person's to press; an assistant
  calls the tool again. Results that could not go now fail the sync (`ResultsKind.ResultsWait`), so
  they are on the bar and retried.
- **E5.** A sync waiting more than 10 s is on the bar: "Waiting for your CANFAR storage…".

The manual (01, 14 and 16, in English and French) and the parity table are updated. 2,304 tests pass.

**To see it live:** on a build from 2960327b, Sync Now takes about 30 s, mostly listing Remote Compute
runs, so the bar should show "Waiting for your CANFAR storage…" after 10 s. Turning Wi-Fi off and
clicking Sync Now should leave a failed task with Retry and the next try. Turning Wi-Fi back on
should sync again by itself.

## E, live (2026-10-17, build 0699a685, Storage pointed at a dead address by the person)

| Case | Result | Notes |
|---|---|---|
| P5 | PASS | Moved back to this Mac: the copy in storage removed (applied by the person); `places: mac`, and nothing of it left in `Verbinal-Results/research/`. |
| P1 | PASS | Each Research row shows a laptop and a cloud, the laptop lit for a file on this Mac; a record without a file keeps its arrow. |
| E5 | PASS | A Sync Now that moved nothing, but took 18 s, was on the bar from about 10 s: "Syncing with your storage … Nothing left to move". |
| E3 | PASS | Storage at `https://127.0.0.1:9`: "CANFAR storage is failing: 3 failures in a row" for one request; the sync failed about 7 s after the launch (2 s + 5 s). |
| E1 | PASS | The bar: "Idle · 2 failed", in red; the task says "Could not connect to the server. Verbinal tries again in 1 min.", `retryable`. The person's **Retry** tried at once (20:46:12, before the timer) and failed with "… in 4 min". |
| E2 | PASS | Unasked, a sync at 20:44:08 (one minute on), its retries at 2 s and 5 s, then "… in 2 min"; then "… in 4 min". |
| **Activity list** | **FAIL, fixed 891218a7** | The person: "we need connect mcp tools to show this items and read them". The list hangs from the bar's button, and a button is not looked inside: `list_ui_targets` never saw its tasks or Retry. Popovers are now read wherever they hang. |
| **Retry, twice** | **fixed 891218a7** | An earlier failed sync kept offering Retry after a later attempt; only the last does now. |
| **Endpoints** | **FAIL, fixed 891218a7** | The person: "I cannot update the storage, it does not pick it up, we do not have save button there". Only Return kept a typed address, and nothing said so. It is now kept on leaving the field or the tab, saying "Not saved yet …" until then. |

`retry_activity` was not tried live: this client's list of tools was made before the tool existed (`man` has it).

## A3 — replaced by plan 45 (the person, 2026-10-17)

"i do not think that time should be the case ... if we have a conflict we need to have metadata on such
files and compare the metadata between devices and storage version.... do no cut corners". The clock
no longer decides anything: revisions, bases and a field-by-field merge do, and conflicts are shown to
the person. See `45-sync-by-revision.md`.

## F — Sync by revision, live (plan 45 F6)

B4–B8 again, now that revisions decide. "As another device" is an assistant writing the item's file
with `upload_text_to_vospace` (over a file: the person approves it in Pending), with `rev` one more than
storage's, `base` storage's `rev`, `device` `"qa-other"` and `deviceName` `"QA other Mac"`. Saved
queries are on (B2); `qa44 one` is the item.

| Case | Steps | PASS if |
|---|---|---|
| F1 | `read_vospace_file` on `qa44 one`'s file. | It has `rev`, `base`, `device`, `deviceName` (this Mac's name) and `hash`. |
| F2 | As another device, change its `description`; here, before a sync, change its ADQL. **Sync Now**. | Both changes stay, here and in storage; storage's `rev` is one more again, written by this Mac. No conflict. |
| F3 | As another device, rename it `qa44 other`; here, before a sync, rename it `qa44 here`. **Sync Now**. | Here it is `qa44 other`. **Settings ▸ Storage ▸ Conflicts** lists it: `name — this Mac: qa44 here · QA other Mac: qa44 other`. The bar ends "1 to choose in Settings ▸ Storage". `list_sync_conflicts` lists it; `list_storage_kinds` counts 1 for `savedQueries`. |
| F4 | The person clicks **Keep This Mac's** on F3's. | It is `qa44 here`, here and in storage, one `rev` more, by this Mac. The conflict is gone. |
| F5 | F3 again; then the assistant proposes `resolve_sync_conflict` with `theirs`; the person approves it in Pending. | Pending showed it as "Notes and saved things on this Mac". Nothing was written (`rev` the same); the conflict is gone. |
| F6 | As another device, write the file with `removedAt`; here, before a sync, change the query. **Sync Now**. Then **Remove It**. | After the sync the query is still here, with this Mac's change, and **Conflicts** says "Removed on QA other Mac, but changed on this Mac". After **Remove It**: gone here; storage's file has `removedAt`, written by this Mac. |
| F7 | As another device, write a change with `changedAt` a day in the past (`rev` and `base` right). **Sync Now**. | It arrives: the clock decides nothing. |
| F8 | Write a file with no `rev` (plan 44's form) as another device. **Sync Now**, then change the query here. | It is read as revision 0; this Mac's write makes it `rev` 1. |
| F9 | Part C with two devices: F3 for real. | As F3 and F4, on both. |

## Still open (2026-10-17, after plan 45 F5, 10d89b99)

| Case | Waits for |
|---|---|
| F1–F8 (plan 45 F6) | A build at 10d89b99 or later running, and `/mcp` reconnected so `list_sync_conflicts` and `resolve_sync_conflict` appear (the running build is 73fab42e). The person approves the writes "as another device" and clicks the conflicts' buttons. |
| F9, C1–C8 | A second Mac or a second macOS account, signed in to the same CANFAR account. |
| B13, D3 | The person turns on **Results** in Settings ▸ Storage (their choice). |
| B14, P7 | The person signs out during a sync. |
| D2, E4 | Wi-Fi off, or Storage pointed at a dead address in Settings ▸ Endpoints, by the person (Wi-Fi could not be turned off here). |
| `retry_activity` live | `/mcp` reconnected (E1's Retry was checked on the bar and with `list_activity`). |
| B9 | Waived by the person: "it is private by default do not worry". |
| A3 | Replaced by plan 45 (the person's decision). |

## F, live (2026-10-17, build 3033594a, production)

| Case | Result | What was seen |
|---|---|---|
| F1 | PASS | `qa44 one`, changed here, was written with `rev` 1, `base` 0, `baseHash`, `device`, `deviceName` "Serhii’s MacBook Pro" and `hash`. |
| F8 | PASS | Its file had no `rev` (plan 44's form): read as revision 0; this Mac's write made it `rev` 1. |
| F2 | PASS (c614f227) | Another device changed the description (rev 2 from 1), this Mac the ADQL: storage `rev` 3 from 2, by this Mac, with both; no conflict; "1 brought, 1 sent", written once. |
| F3 | PASS | Both renamed it: here it read storage's "qa44 other"; Conflicts listed `name — this Mac: qa44 here · QA other Mac: qa44 other` with both buttons (on screen, stable ids); the bar ended "1 to choose in Settings ▸ Storage"; `list_sync_conflicts` and `list_storage_kinds` (1) agreed. |
| F4 | PASS | The person's **Keep This Mac's**: storage `rev` 6, by this Mac, named "qa44 here"; the conflict gone. |
| F5 | PASS | `resolve_sync_conflict` `theirs`: judged "Notes and saved things on this Mac" (allowed, so at once); storage stayed at `rev` 8; the conflict gone; the log said "Resolved Keep the Other's: …". |
| F6 | PASS | Removed on another device (rev 9), changed here: kept, written back as `rev` 10; Conflicts: "Removed on QA other Mac, but changed on this Mac: it stays, with this Mac's change." The person's **Remove It**: `rev` 11 by this Mac with `removedAt`; gone here. |
| F7 | PASS | Another device's next revision dated a day in the past brought the removed query back: it arrived. No clock decided. |
| F9 | — | Needs a second Mac or macOS account (part C). |

**Found, F-1: each change was written three times, at every sync.** The session log showed six uploads
of the one changed file, three in the change's sync and three in Sync Now, each read before and after in
0.0 s. Storage's listings and files were answered from the URL cache (`URLSession.shared`), so the
read-back never saw the write, took it for overtaken, and wrote again. Fixed: every read of the person's
storage skips the local cache (`fresh`), and a write storage does not show yet is not written again in
that sync — the next one settles it. `StorageFreshReadTests` failed first with 3 writes, the live
symptom. The same cache could hand the Storage screen a stale file after a change; that is fixed too.

**Found, F-2 (for the person): overwriting an "assistant-made" file applied at once.** The writes "as
another device" from F3 on did not wait in Pending: the file was first uploaded by an assistant (F2), so
writing over it was "Remove what an assistant made", allowed by default — though the app's sync had
since written the person's own saved query into it. The mark stays on a VOSpace path after someone else
writes there. **Decided by the person (2026-10-17): the original maker counts**, at least for now — "nope,
important the original, I think, at least for now". No change.

**Found and fixed, F-3:** a conflict was named by this Mac's edit ("qa44 here") while the list showed
storage's ("qa44 other"); it is named as it reads here now. **F-4:** a field read `record.name`; it
reads `name`. `SyncConflictsTests.testAConflictIsNamedAsItReadsHereNow` failed first.

## B13, D3, live (2026-10-17, build c614f227)

| Case | Result | What was seen |
|---|---|---|
| B13 | PARTLY | Results on. A search export reached `Verbinal-Results/searches/` 7 s after it was saved; a local cutout reached `Verbinal-Results/research/` 13 s after. **But its Research record still said `places: mac`, with no `storagePath`** (F-5). |
| D3 | PASS | Send a Copy to Storage on that cutout: taken as the same file (same name and size, not rewritten); `places: both`; no second copy, no refusal. |

**Found, F-5: a result sent by Results did not mark its record.** The record keeps the person's path
(`/Users/…/Downloads/…`, `LocalFolderAccessStore.userFacingPath`); the result was queued by the
sandbox's path to the same file (`…/Containers/…/Data/Downloads/…`), and `noteInStorage` compared them
by `FileIdentity` alone. It now compares where each is in the person's Downloads
(`ObservationStore.place`). `ResearchRecordsTests.testTheSandboxsPathAndThePersonsAreOnePlace` failed
first; B13 is checked again on the next build.

