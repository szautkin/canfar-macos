# Plan 40 — Image package lists on a new device

**Date:** 2026-10-15 · **Branch:** `dev_1_4_1` (from `ba14ce93`) · **Release:** 1.4.1

The person's question: Verbinal starts on a new device, or a new installation, and the image manifests
the person's probes made are in their storage. How is that handled properly?

Then, two more requests:

- **Track progress.** Show work like this in the activity bar at the bottom of the window, with how far
  it has got, and let assistants read the same through the MCP tools.
- **Pause it.** The person, or an assistant, can pause such activity.

Plan 34 V's promise: a package list this device does not have is imported, whichever device probed the
image. Every step here completes that promise, or fixes a bug, as 1.4.1 allows.

## How it works today

1. **After sign-in, the storage sync imports them.**
   - The sync reads `.verbinal/manifest.json`. If it declares `imagePackages`, the sync lists
     `.verbinal/manifests` and hands each `.json` to `ImageDiscoveryCoordinator.importManifest`.
   - `importManifest` keeps a list when this device has none for that image, or an older one, and never
     keeps a stub.
   - The discovery sheet, `get_image_manifest`, `describe_image` and `find_images_with_packages` then see
     the list. No job runs.
2. **With no `manifest.json` yet,** the first sync writes one (`firstManifest`). It declares every kind
   whose folder it finds, image package lists among them.
3. **Discover reads storage before probing.** For an image with no list on this device, Discover reads
   `.verbinal/manifests/<image>.json` and uses it if it is current. A job runs only when nothing usable is
   there.

**The person's account is covered.** Its manifest declares `imagePackages`. This Mac's last sync saw
288 lists, and 299 are cached here.

## What is wrong

| | What | Where | Who it reaches |
|---|---|---|---|
| A | Image package lists are declared only when `manifest.json` is first written (`firstManifest`); `setDeclared` is called only by the person's switches for their collections. If the manifest was written before `.verbinal/manifests` existed, it never declares it. | `StorageSync.currentManifest` | A new 1.4.1 user who turns on Research before probing an image. On their second device: "Discovered 0 of N", package search finds nothing, and only Discover recovers each image. The same holds for Remote Compute runs, batch-job scripts and exports. |
| B | The discovery sheet reads the cache only when it opens (`refreshFromCache` in `onAppear`). | `ImageDiscoveryModel` | On a new device the first sync imports about 300 lists in the background, after sign-in. A sheet opened meanwhile stays at "Discovered 0 of N" until it is reopened. |
| C | A list from an older probe imports and shows as discovered. Discover counts it as out of date (`isCurrent`) and probes again. | `importManifest`, the row, `get_image_manifest`, `describe_image` | Lists another device probed with an older Verbinal: they are incomplete, with nothing to say so. |
| D | Discover uploads the probe script before it reads storage for a list that is already there. | `runDiscovery` | Every Discover on an image probed elsewhere: a needless write in the person's storage. |
| E | Tests leave their stores' files behind. | `DiskPersistence` and eight other places that open Application Support | About 9,400 files in `~/Library/Application Support/Verbinal`, written by command-line runs, and 198 in the app's own container, written by runs from Xcode. At least 15 tests' files. |
| F | The storage sync runs unseen and cannot be paused. It is the only long work Verbinal starts by itself that is not in the activity bar (`StorageSync` reports nothing to `TaskRegistry`). A task says where it has got to only in words (`stage`), never "N of M". A kind's items are recorded only when the whole kind finishes, so an import stopped halfway by a quit, a failure or a pause starts over. | `StorageSync`, `TaskRegistry`, `TrackedTask`, `list_activity`, `list_storage_kinds` | A new device's first import, about 300 lists: nothing in the bar, nothing for an assistant to read, nothing to pause, and a quit partway downloads them all again. |

## Steps

One commit per step. After each step: `xcodegen generate`; the gates (macOS tests, package tests, iOS
build); and the string catalogue back to `HEAD` plus the step's own strings, in English and French.

### Step 1 — The sync declares the kinds it finds

- **The rule.** Every sync looks for a folder for each kind that is declared when found
  (`declaredWhenFound`) and is missing from the manifest:
  - image package lists, `.verbinal/manifests`;
  - Remote Compute runs, `.verbinal/exec`;
  - batch-job scripts, `.verbinal-scripts`;
  - exports, `Verbinal-Exports`.

  The kinds the person chooses are never touched: their collections, and results (both
  `declaredWhenFound: false`).
- **The write.** Whatever it finds is declared in one write, starting from the manifest as it is now
  (`latestManifest`), so another device's kinds are kept. The write's `why`: Verbinal declares the kinds
  of its data it found in storage, for every device. The kind then syncs in the same run, so a new
  device imports at once.
- **The cost.** The two folders under `.verbinal/` cost nothing, because the sync already lists
  `.verbinal`. Each of the other two costs one listing per sync, only while it is undeclared.
- **Tests** (`StorageSyncTests`, with a fake remote):
  - a manifest declaring only `research`, with `.verbinal/manifests/a.json` there: afterwards it
    declares both, and `a.json` is imported;
  - a second sync writes nothing;
  - no folders, no write;
  - a kind the person chooses is never declared this way.

### Step 2 — Work says how far it has got, and some can be paused

This step is for every task, in the activity registry; step 3 uses it for the sync.

- **The count.** `TrackedTask` gains a count, `done` of `total`. The owner sets it through
  `TaskHandle.count(done:total:)`, and the registry keeps at most four changes a second.
- **Paused.** `TaskProgress` gains `paused`. A paused task is neither running nor finished: the bar does
  not count it as running, and Clear Finished leaves it.
- **Pausing.** A task can offer to pause and resume. Its owner gives the two actions when it begins the
  task; the registry runs them and records who paused, from `Initiator` (you, your assistant or
  Verbinal), with the `Cause`.
- **The bar.**
  - The line reads "Bringing package lists from your storage — 120 of 288".
  - The open list shows a determinate progress bar, and Pause or Resume on a task that offers them.
  - A paused task reads "Paused by you" or "Paused by your assistant", with Resume.
  - With nothing else under way, the line reads "Storage sync paused". It is never "Idle" while
    something is paused.
- **For assistants.**
  - `list_activity` gives each task `done` and `total` when known, `pausable`, `paused` and `pausedBy`.
    `get_session_log`'s `now` names a paused task.
  - Two new tools, `pause_activity` and `resume_activity`, take a task's `id` from `list_activity` and a
    `why`. They are live and reversible: no proposal, recorded in the session log with the `why`, and
    the bar says who paused. A task that offers no pause answers so, by name.
- **Docs and tests.**
  - The parity matrix (`docs/agent-ui-parity.md`) pairs the bar's Pause and Resume with the two tools,
    and `AgentToolCatalogParityTests` holds that.
  - Registry tests: the count, its four-a-second limit, pause and resume, who paused, and Clear Finished
    leaving a paused task.
  - `ActivitySummary` tests: the line with a count, and with a paused task.
  - Tool-shape tests.

### Step 3 — The storage sync is seen, counted and can be paused

- **A task when it moves something.** A sync that brings or sends items is one task in the bar:
  - kind `storage`, started by Verbinal, with its reason (after sign-in, Verbinal came back, a change,
    or asked);
  - its stage names the kind, "Image package lists — 120 of 288";
  - it finishes saying what moved, "288 package lists brought", or why it failed.

  A sync that finds nothing to move shows nothing: there is no line every 15 minutes.
- **The count from the kinds.** `StorageKindContext` gains `progress(done:total:)`. `ImagePackagesKind`
  and `CollectionKind` call it per item.
- **Each item recorded as it lands.** The sync keeps an item's stamp as soon as its kind has taken it, not
  when the whole kind ends. A pause, a quit, a failure or a crash then continues where it stopped. The
  state file is written at most every five seconds or every 25 items, and at the end; one write per item
  would be 300 rewrites of a 110 KB file.
- **Pause.**
  - It stops after the current item and records how far it got.
  - It is kept with the sync's state for this account on this device, with who paused and when, so a
    relaunch does not resume it.
  - While paused, no automatic sync runs: after sign-in, on coming back, or after a change. The changes
    wait.
  - `sync_storage` answers that the sync is paused, and by whom, and points to `resume_activity`. It
    does not override the person.
- **Resume** syncs at once, with what is left.
- **Settings ▸ Storage** shows the same: "Syncing… 120 of 288" with Pause, or "Paused by …" with Resume.
- **For assistants.**
  - `list_storage_kinds` gives `paused`, `pausedBy` and `pausedAt`, and the syncing kind's `done` and
    `total`.
  - While package lists are still to come or paused, `find_images_with_packages`, `search_packages`,
    `get_image_manifest` and `describe_image` say so in a `note`: "120 of 288 package lists are here;
    the rest are still coming from storage, so results may be incomplete". This stops an assistant
    concluding that an image lacks a package.
- **Tests** (`StorageSyncTests`):
  - a sync that moves items is a task with a count; one that moves nothing is none;
  - a pause after 3 of 10 items resumes with the other 7, and so does a new `StorageSync` over the
    same state file, as after a relaunch;
  - a paused sync skips automatic runs, and `sync_storage` says paused;
  - the state is written at most as often as above;
  - the image tools' note while lists are coming.

### Step 4 — The discovery sheet hears what arrives, cheaply

**The cost to avoid.** The filter pane is a SwiftUI `List` of about 7,200 checkboxes: on the person's
account, 3,633 dpkg names, 1,793 rpm and 1,768 Python, from 160,877 package entries in 299 lists.
Each change to `allPackages` re-sorts every name and diffs every row. Updating it once a second through
an import would repeat the Batch Jobs freeze, where a `List` of 10,000 rows took about 2 s a poll.

- **The coordinator's stream.** It announces each image whose list it stores, from an import, a recovery
  or a probe: `manifestChanges()`, a stream of image ids like `inFlightCountChanges()`. The list is
  already in the store's memory, so reading it back costs nothing.
- **The model listens only while the sheet is open.** It starts listening in `onAppear` and stops in
  `onDisappear`. A closed sheet does nothing; opening it reads the cache once, as today.
- **Rows in batches.** The ids that arrive are collected, and `rowStates` changes once a second at most,
  in one assignment. That list has about 435 rows.
- **Filters once.** Each list's packages are merged into a private copy as it arrives. `allPackages` is
  set when the import ends, and only if the copy gained names.
- **The sheet's header** reads the sync's task from step 3: "Bringing package lists from your storage —
  120 of 288", or "Paused by …", beside "Discovered N of M images".
- **Tests:**
  - with the sheet open, a list imported through the coordinator turns its row to discovered without a
    reopen, and its packages are among the filters once the import ends;
  - importing 300 lists sets `allPackages` once, and `rowStates` no more than once a second;
  - on screen, in a real window, the header's count goes from "Discovered 0 of 2 images" to "Discovered
    1 of 2 images" as a list arrives.

### Step 5 — A list from an older probe says so

- **The row.** A discovered row whose list is not current (`ImageDiscoveryCoordinator.isCurrent`) shows a
  badge, in the same way a rolling tag's stale list does. Its help text: "From an older probe: Re-run
  for the full package list". English and French.
- **The tools.** `get_image_manifest` and `describe_image` answer `outdated: true` for such a list, with
  the same words in their `note`.
- **Tests:** an older list's row and both tools' answers. A current list carries neither the badge nor
  `outdated`.

### Step 6 — Storage first, then the script

- **The order.** `runDiscovery` reads `.verbinal/manifests/<image>.json` before
  `ensureProbeScript` / `ensureInspectorScript`. A current list ends the run there, with nothing written.
  `force` (Re-run) still skips the read.
- **Test** (`ImageDiscoveryCoordinatorTests`): with a current list in the fake storage, Discover answers
  it with no upload and no job.

### Step 7 — Tests keep their files to themselves

- **One place for the folder.** `AppSupport.directory` (VerbinalKit) gives the Application Support
  folder, as every store reads it today. In a test host, it gives a folder of that run's own instead,
  in the temporary directory. A test host is the process XCTest starts: `XCTestConfigurationFilePath`
  is set, the check `AgentsService.isTestHost` and three other places already make. At start, it removes
  the folders older runs left there.
- **Its users.** All nine places that open Application Support use it:
  - `DiskPersistence`;
  - `SessionLogStore`;
  - `AppDatabase`;
  - `JSONManifestStore`;
  - `DataTrainService`;
  - `EndpointRegistryService`;
  - `StorageSyncState`;
  - `WorkflowStore`;
  - `SocketSidecar`.

  The sidecar's case keeps plan 36 Q2's rule: a test host never touches the live app's sidecar. The
  relay process (`Verbinal mcp`) is no test host, so it still finds the app.
- **Tests:**
  - a guardrail (`CodeQualityGuardrailTests`): no source file asks for `.applicationSupportDirectory`
    but `AppSupport`;
  - in a test host, `AppSupport.directory` is not the user's Application Support;
  - after a full run, nothing new in `~/Library/Application Support/Verbinal` or in the app's container.

### Step 8 — Seen on screen; the manual and the handout

- **On screen,** with Verbinal and its tools, in a session the person allows:
  - the bar's line and count during a sync that moves items;
  - Pause and Resume from the bar, from Settings ▸ Storage and through `pause_activity`;
  - the discovery sheet's header;
  - `list_activity` and `list_storage_kinds` agreeing with the bar.
- **The manual,** in English and French:
  - the activity bar: counts, Pause and Resume, who paused;
  - Settings ▸ Storage: pausing the sync;
  - the AI assistant chapter: the two new tools.
- **A handout section for the tester,** run on a second Mac or a fresh install of the same account:
  1. Sign in. The bar shows "Bringing package lists from your storage — N of M"; Settings ▸ Storage
     agrees.
  2. Pause from the bar, then quit and relaunch: still paused, and nothing syncs. Resume: it continues
     from where it stopped, not from 0.
  3. An assistant pauses and resumes with the tools; the bar says "Paused by your assistant".
  4. Open the discovery sheet during the import: rows fill in, and the header says what is coming.
  5. Discover an image probed on the first Mac: no job, and no new file in `.verbinal/`.
  6. An account whose manifest lacks `imagePackages`: one sync declares it.

## For the person

- **The files tests left.** They are deleted only on the person's word. Once step 5 is in, nothing writes
  them again.
  - `~/Library/Application Support/Verbinal` is used only by command-line test runs; the app itself is
    sandboxed and keeps its data in its container. Before the folder goes, its newest non-test files'
    dates are checked to confirm that.
  - In the app's container, only the `test_*` and `test-*` files go, never the app's own data.

## What it costs

| | Cost |
|---|---|
| A new device's first import (as today) | One download per list: 299 files, 17 MB on the person's account (median 62 KB, largest 256 KB). One at a time, at background priority. Parsed in well under a second, and written once each. |
| Step 1 | The two folders under `.verbinal/` are free, because the sync already lists it. Each of the other two costs one listing per sync, while undeclared. |
| Step 2 | At most four count changes a second per task, on a one-line bar. |
| Step 3 | The sync's state file is written at most every 5 s or every 25 items, not 300 times. A quit or pause no longer downloads everything again. A sync that moves nothing adds nothing to the bar. |
| Step 4 | One row update a second during an import, of a list of about 435 rows. One filter update when it ends. Nothing while the sheet is closed. |
| Step 5 | One comparison per row. |
| Step 6 | Saves a folder check and an upload for each list already in storage. |
| Step 7 | One environment read per launch, kept. Only test runs clean folders. |

## Not doing

- **A switch for image package lists.** They are Verbinal's own data, found and kept as plan 34 V
  decided, unlike the person's collections, which they choose.
- **Deleting a list in storage** that is older than this device's. The sync never deletes.
- **Pausing other work.** A probe job runs on CANFAR, and stopping it is a different, destructive act.
  A launch is one request. A download could resume from its data later; the registry's pause is ready
  for it, but it is not in this plan.
- **Parallel downloads for the first import.** It runs once per device, unseen, and one at a time keeps
  it light on the network and on CANFAR's storage service.

## Where it ended (2026-10-15)

| Step | Commit | What |
|---|---|---|
| Plan | `2e4f2555` | This plan. |
| 1 | `1e81202c` | The sync declares the kinds of Verbinal's data it finds, in one write. Folders in `.verbinal` are seen in its listing; one elsewhere is looked for once a sign-in. |
| 2 | `4b40d02d` | Tasks count ("120 of 288", at most four redraws a second) and can be paused. The bar's list has Pause and Resume. `list_activity` gives `id`, `done`, `total`, `pausable` and `pausedBy`. `pause_activity` and `resume_activity` take a `reason` — not `why`, which only a proposed change takes. The session log says who paused and resumed. The selectable detail text was refreshed for assistive reading, which had kept a running task's first words. |
| 3 | `52560112` | The storage sync is on the bar when a run moves five items or more, counted, and can be paused: from the bar, Settings ▸ Storage or `pause_activity`. The pause is kept through relaunches, and resuming goes on from the next item: package lists are kept as each lands, with the state written every 25 items or 5 s. `list_storage_kinds` gives `paused`, `syncing` and `activityTask`. The four image tools say `arriving`. Each sign-in's sync is numbered, so a stopped one's last words do not reach the next. |
| 4 | `a0776eb8` | The open discovery sheet hears lists arrive. The rows change at most once a second; the filters, about 7,200 rows, change once when the lists stop. The header gives the count, or who paused. The model's filtering and the coordinator's naming helpers moved to files of their own, and both ceilings came down. |
| — | `cea9810e` | **Not in the plan: the person's report that evening.** Workflows (`NavigationSplitView` with `.toolbar`) and Research (`.searchable`) gave the window a native toolbar above Verbinal's own, which this macOS lays over the screen. Both now keep to Verbinal's toolbar, and `testNoScreenBringsTheWindowAToolbarOfItsOwn` lays out every screen in a real window. |
| 5 | `fff76349` | A list from an older probe has a badge on its row, and `outdated: true` with a `note` in `get_image_manifest` and `describe_image`. |
| 6 | `8f1d1b99` | Discover reads storage before it writes the probe script. |
| 7 | `3755165a` | `AppSupport`: a test run keeps its files in a folder of its own. A full run left `~/Library/Application Support/Verbinal` at 9,772 files and the container's test files at 380, as they were. |
| 8 | (this commit) | Manual, English and French: the activity bar, Settings ▸ Storage, the AI assistant and Image Discovery. Handout 37 gains section N. |

**Where it differs from the plan, and why:**
- **Step 3: small syncs are not on the bar.** A sync that moves fewer than five items is not shown there; a note sent five seconds after it was written would fill the list. Settings and the tools still say it.
- **Step 3: collections run again after a pause.** Item-by-item keeping is the package lists'. A collection's memory is kept when the collection ends, so one stopped halfway runs again. Collections are small.
- **Step 7: the sidecar is not moved.** `SocketSidecar` stays outside `AppSupport`: the relay looks for it at fixed paths.

**Verified with the screen unlocked** (2026-10-15, from 20:53): every test that reads the accessibility tree
— the new on-screen ones among them — and `ViewerLayoutTests`, 74 tests, passed. In the first run, 20 s
after unlocking, `SearchablePickerTests.testTheToolsOpenItAndChooseInIt` failed: its popover had not
opened 300 ms after it was asked. It builds its own picker, untouched by this plan. It passed three runs
alone and in the full set again.

**Still to verify:**
- **The live app.** The plan's on-screen check of the live app over MCP needs the person's build of this branch, in a session they allow. It is handout 37's section N.

