# Plan 47 — Verbinal on iPhone and iPad: check, review, verify

The person (2026-10-22), after the iOS review (`dev_info/ios-review-2026-10-22.md`, branch `1_4_1_ios`):

1. "I think also, to add fits and cube viewer but a bit improved design and using ios device accelerators
   and sensors, maybe, even like find you fits image on the sky? think it and let's build a comprehensive
   plan for development"
2. Then, on the first draft of this plan (a five-tab port with Search, Research, Storage, Sync and Sky):
   "no, portal, fits viewr and cube viewer, remote compute; we do not need to copy functionality from
   macos, we need to make it as a quick check, review, and verify ios/ipad app; review the vision, and the
   plan"

## The vision

**Verbinal on iPhone and iPad is where you check on your CANFAR work, review what it made, and verify that
it is right, away from your desk. The Mac is where you do the work.**

| The person asks | The place | It answers |
|---|---|---|
| Is everything all right? | **Portal** | sessions, batch jobs, the compute session, platform load, storage quota; what needs attention first |
| What did it make? | **FITS** and **Cube** | the image or cube, looked at properly: display, probe, compare, channels, spectrum |
| Is it right? | inside the viewers, and **Compute** | header, checksum, statistics, WCS, spectral axis; a check run on CANFAR, where the data is |

What the person does from the phone is small, and either reversible or confirmed:
- renew, delete or open a session;
- relaunch a recent session;
- start or stop the compute session, and run or rerun a snippet;
- share a picture of what they see.

Everything else waits for the Mac.

**What it is not:** a port of the Mac app. No Mac feature comes over because it exists. The Mac's Search,
Research, Storage browser, sync, Image Discovery, AI Guide, Workflows and MCP stay on the Mac.

### What changed from the first draft

| First draft | Now |
|---|---|
| A port: five tabs, Search and Research, the Storage browser, sync | Four places: Portal, FITS, Cube, Compute |
| Storage as a feature | Storage only as a **source of files**: read-only, to open what a job or a run wrote |
| Sync to bring notes, marks and runs across | No sync. Compute's run history is read straight from `/arc` (`.verbinal/exec/done` and `out`), which already holds every run, the Mac assistant's included |
| A Metal 2D renderer up front | Measure first: today's vDSP path, then Metal only if a budget is missed |
| Sky, plate solving, AR cube, widgets, Live Activities | Parked; widgets and notifications kept, small, at the end |

## Where we start

**Today's iOS app** is the Portal alone (Sessions, Launch, Monitor, Account), with the review's two store
blockers, five bugs and French gaps. CI builds no iOS.

**The probe.** On 2026-10-22 a throwaway iOS target (in the scratchpad; the repo was not touched) took in
FITSViewer, CubeViewer, Storage, RemoteCompute and RecentFiles, with every `MCP/` and `Sync/` left out as
today:

| Pass | Included | Errors |
|---|---|---|
| 1 | everything, RecentFiles still out | 3: RecentFiles missing; `AppState.fitsTabHost` Mac-only; `HSplitView` in RemoteComputeView |
| 3 | the same, without the four modules' `Views/` and with RecentFiles in | 4: all from one coupling (`FITSFigureRegion` sits in `FITSFigure.swift`, which needs the Mac-only `FigureFile`), plus one in `FITSMarkCommands` to look at |

So, below the views:
- Storage's service and model compile for iOS.
- Remote Compute's service, model and view model compile.
- The cube models compile.
- RecentFiles compiles.
- The FITS model compiles once the figure export is split.

The cube renderer and its shader are portable, but the renderer is wrapped in `#if os(macOS)` with its
`NSViewRepresentable`, so iOS needs its own wrapper. The viewer and compute state lives in `AppState`'s
`#if os(macOS)` blocks (lines 89–107, 666–686): `fitsTabHost`, `cubeTabHost`, `remoteComputeModel`.

**This is view work, not a port of the models.**

**Already there, and useful for verify:**
- `FITSChecksum` (DATASUM/CHECKSUM);
- `CubeModel` statistics (min, max, median, NaN fraction);
- `LinearCut`;
- WCS both ways, `skyCorners`, `SpectralWCS`;
- `CubeModel.open(source:)` over the `CubeDataSource` protocol;
- `VOSpaceBrowserService.fetchBytes(offset:maxBytes:)`, a ranged read;
- viewer routing (`fitsIsCube`).

## The four places

### Portal: check

A status-first screen. What needs attention comes first, and only when there is something:

| Needs attention when | It offers |
|---|---|
| a batch job failed since the person last looked | its logs and events |
| a session expires within an hour, has failed, or has been Pending for over 10 minutes | Renew, Logs, Delete… |
| the compute session cannot start, or the last run failed | Compute |
| storage is 90 % full or more | the numbers |
| the sign-in has ended | Sign In |

Below it, in this order:
- **Sessions:** cards with status, "expires in 38 min", Renew, Open (Safari), Logs, Delete (confirmed).
- **Batch jobs:** counts; failed ones first, with why.
- **Compute:** state, and the last run's outcome.
- **Platform load** and **storage quota**, compact.

**Launch** is a sheet: **Relaunch** from recent launches, and the Standard form. Whether the Advanced form
(custom image, registry secret) stays on iOS is D3.

What "since the person last looked" means is kept on the device: a failed job seen once stops being news.

```
┌ Portal ────────────────────── (SZ) ┐
│ Needs attention                     │
│ ✗ reduce-0412 failed · 12 min ago ›│
│ ⏱ notebook-1 expires in 38 min      │
│                           [Renew]   │
│ Sessions (2)                        │
│ ┌ notebook-1 · Running ──────────┐  │
│ │ 2 cores · 8 GB · expires 14:02 │  │
│ │ [Open] [Renew] [Logs]   [⋯]    │  │
│ └────────────────────────────────┘  │
│ Batch jobs  ● 3 running  ● 1 failed │
│ Compute     ● Running · last run ✓  │
│ Load ▂▃▅▃  ·  Storage 82 % of 2 TB  │
└─────────────────────────────────────┘
  Portal    FITS    Cube    Compute
```

### FITS: review and verify an image

- **The canvas:**
  - the image edge to edge; a tap hides the chrome;
  - pinch zoom anchored at the fingers, pan, double-tap Fit ⇄ 1:1;
  - a long press brings the **loupe** (pixels magnified, value, RA/Dec, a light haptic tick per pixel);
    drag it to probe;
  - on iPads with Pencil hover or a pointer, hovering probes too.
- **The sheet,** which leaves the image usable (peek / half / full; on iPad an `.inspector` column):
  - **Display:** autocut presets (zscale, 99.5 %, min–max), stretch, colormap, a histogram with draggable
    black and white points.
  - **Verify:**
    - Intact: DATASUM and CHECKSUM checked, or "no checksum";
    - size, BITPIX, bytes;
    - values: min, max, median, σ, NaN and blank count, and how many pixels reach `SATURATE` when the
      header gives it;
    - sky: centre, pixel scale, size on the sky, rotation from north;
    - time: DATE-OBS, EXPTIME, FILTER, OBJECT.
  - **Header:** searchable, with the cards that matter pinned on top.
  - **HDUs.**
- **Compare:** **hold to blink.** Press and hold to see the other open image, aligned by WCS
  (`BlinkAligner`).
- **Share:** a picture of what is on screen, with its readout, through `ShareLink` (an iOS `ImageRenderer`;
  the Mac's `FigureFile` stays Mac-only).

```
┌──────────────────────────────────┐
│ ‹ FITS     reduced_r.fits      ⋯ │  glass bar; a tap hides it
│                              N   │
│      (the image, edge to     ↑   │
│       edge)               E ←┘   │
│             ┌─────┐              │
│             │ ▦▦▦ │  1834.2      │  loupe: 13h29m52.7s +47°11′43″
│             └─────┘              │
├──────────────────────────────────┤
│ Display   Verify   Header   HDUs │
│ ✓ Intact (DATASUM, CHECKSUM)     │
│ 4096 × 4096 · −32 · 64 MB        │
│ min −12.4 · max 61 203 · med 1834│
│ 0 NaN · 14 at SATURATE           │
│ 0.187″/px · 12.8′ × 12.8′ · −0.4°│
└──────────────────────────────────┘
```

### Cube: review and verify a cube

- **The slice and the channel scrubber:** a wide scrubber along the bottom with the spectrum drawn behind
  it, a haptic detent per channel, and the readout (`SpectralWCS`: velocity, frequency or wavelength).
- **Tap a pixel** for its spectrum in the sheet (Swift Charts); drag along it to move the channel.
- **Verify:**
  - the spectral axis: CTYPE3, range, step, rest frequency;
  - statistics per channel and for the cube;
  - empty and NaN planes;
  - BUNIT and beam, when given.
- **Moment 0,** for "did the line show up": computed plane by plane with Accelerate, so memory stays at
  one plane, for cubes on the device or small enough to read (D4 for big ones).
- **Volume:** the Mac's ray-marcher (`Cube.metal`) in a `UIViewRepresentable`, with steps and render scale
  following `thermalState` and Low Power Mode. iPad first (D5).

### Compute: verify on CANFAR

- **State:** the `verbinal-compute` session, its cores and memory, its image. Start, and Stop (confirmed).
- **Runs:** every run, rebuilt from `/arc`.
  - The watcher writes each result to `.verbinal/exec/out/<id>.json` and moves the request (the code) to
    `done/<id>.json` after it. So the phone shows the code and the result of every run, including those
    the Mac's assistant made.
  - **Review what your assistant ran on your account, from your phone.**
  - Runs this device made are marked as its own.
- **A run:** the code, stdout, stderr, exit code, duration; Run Again; Copy.
- **Run Code:** Python or Bash, a timeout, a monospaced editor. It runs as the person, on their session.
- **Browse output:** the storage picker opened at the run's folder, so a file it wrote opens in FITS or
  Cube.
- **Setup:** when a compute session is running, iOS uses it as it is: no settings needed to send code. To
  start one, the image, cores, RAM and registry login are in the Account sheet, filled in from the last
  session seen.

## Where files come from

One **Open** sheet, the same from FITS, Cube and Compute:

| Source | How |
|---|---|
| **Recent** | files looked at on this device: storage paths or local files |
| **CANFAR storage** | home and projects, read-only, newest first, FITS only by default; the compute output folder as a shortcut |
| **Files** | `.fileImporter`; and "Open in Verbinal" from Files, Mail and AirDrop (document types for `.fits .fit .fts .fz`) |

The viewer routing sends a cube to Cube and an image to FITS (`fitsIsCube`), whichever tab it was opened
from.

**Reading what stays on CANFAR:**

1. **Header first.** A ranged read of the first 2880-byte blocks, up to END. The header, the HDUs, the
   size and the checksum cards show before any pixels move. The person decides whether to load.
2. **Images:**
   - downloaded into a cache (`Caches/`, LRU, a cap), with progress and Cancel;
   - refused by `FITSMemoryBudget` when too big for the device, saying so;
   - D4 decides whether "make a smaller copy with Compute" is offered.
3. **Cubes:**
   - **`RemoteCubeDataSource`** over ranged reads, with a plane cache: a channel shows without downloading
     the cube;
   - a pixel's spectrum comes from strided small reads with bounded concurrency, drawn as it arrives.
4. **The ranged reader must stream.** Today `fetchBytes` goes through `session.data(for:)`, and ARC answers
   some paths with 200 and the whole file whatever `Range` said (`VOSpaceBrowserService.slice`). On a phone
   a 3 GB cube would arrive in memory. The new reader streams (`bytes(for:)`), stops after `maxBytes`, and
   treats a 200 as "no ranges here".

## Principles

1. **Glance first.** The Portal answers within seconds of opening: everything loads at once, and what is
   wrong comes first.
2. **The data stays on CANFAR.** Read what is needed (headers, planes); compute where the data is. The
   phone shows.
3. **Read-mostly.** Few actions; destructive ones confirmed, in the Mac's words.
4. **iOS-native, not ported.** Gestures, sheets and the inspector; no Mac feature comes over because it
   exists.
5. **Honest readouts.** Values from the file. A check says what it checked. Binned or approximate is
   labelled.
6. **A lean target.** The iOS app compiles what its four places need, and nothing else.
7. **Measure before accelerating.** The vDSP render, Accelerate statistics and the existing Metal volume
   first. A Metal 2D path only where a budget below is missed.

## Phases

| Phase | What | Size | Needs |
|---|---|---|---|
| 0 | Fix and trim | M | — |
| 1 | Check: the Portal | M | 0 |
| 2 | Compute | M | 0 |
| 3 | Open: files from storage, Files, recents | M | 0 |
| 4 | FITS | L | 3 |
| 5 | Cube | L | 3 |
| 6 | Beyond the app | S–M | 1, 2 |
| 7 | Release | M | the agreed scope |

Compute comes before the viewers: it is small, its models already compile, and it needs no file viewing.
Phases 1 and 2 can run side by side.

### Phase 0 — Fix and trim

| # | Step |
|---|---|
| 0.1 | An iOS privacy manifest: CA92.1 and C617.1, the same data types as the Mac. Correct the swapped comments in the Mac manifest. |
| 0.2 | The keychain family group on macOS only. iOS uses its own app-ID group; a group shared with an extension comes with the widget (6.1). |
| 0.3 | Remove Close App, Close and `AppLifecycle` (the private `-suspend`). |
| 0.4 | The signed-out screen shows "Validating session…" and the offline status. |
| 0.5 | The username field: no autocapitalization or autocorrection. |
| 0.6 | No notification request at launch (1.4 asks in context). |
| 0.7 | French: the missing keys; the iPad sidebar and "No data available" made localizable; "Sign Out". |
| 0.8 | CI: an iOS Simulator build, and the VerbinalKit tests on iOS Simulator. |
| 0.9 | **Trim:** take Search, Research, Image Discovery, AI Guide and Workflows out of the iOS target. `AppState`'s hoisted `searchModel`/`researchModel` and their bridges go behind `#if os(macOS)`. Measure the binary before and after. The Mac's tests stay green. |
| 0.10 | **Un-guard** what the four places need from `AppState`: `fitsTabHost`, `cubeTabHost`, `remoteCompute`, `remoteComputeModel`. Split `FITSFigureRegion` from the Mac's figure file. |

Done when the Portal works signed in on a **device** across relaunches, and CI builds iOS.

#### Phase 0, as built (2026-10-22, branch `1_4_1_ios`, uncommitted)

All ten steps are in.

- **0.1:** `Verbinal/iOS/PrivacyInfo.xcprivacy`. Its sources were checked against the iOS file list (the
  Storage upload sizes, VerbinalKit `NetworkClient` and `AppSupport`). It is at the root of the built app;
  the Mac target leaves `iOS/**` out.
- **0.9 (trim):** besides the five modules, these went too: what only they use (Cutouts, Canfar Images,
  Settings ▸ Image Discovery's views, `ObservationFacts`, `VOSpaceResearchStorage`) and the Mac's landing,
  dashboard and launch form. `CopyErrorButton` moved to `Helpers/`, because shared views use it.
- **0.10:** only the agent's `FITSFigureRequest` stays Mac-only (it needs `FigureFile`).
- **Guardrail:** `AppState.swift` and `ContentView.swift` went over their file-size ceilings. They were
  split, not raised:
  - the hand-off types went to `AppState+HandOff.swift`;
  - the iOS sign-in check and Mac-only placeholder went to `Views/iOS/iOSStateViews.swift`;
  - the ceilings were lowered to 795 and 680.
- **Size:**

  | | Before | After |
  |---|---|---|
  | Files compiled for iOS | 343 (~54k lines) | 234 (~34k), with the four places' models added |
  | iOS Release binary | 20.1 MB | 14.6 MB (−27 %) |
  | App | 20.5 MB | 15.1 MB |
- **0.8 found two iOS-only bugs in VerbinalKit, both fixed:**
  - `FITSMemoryBudget.availableBytes()` read 0 in the Simulator (`os_proc_available_memory`), which capped
    every image at the 256 MB floor. It now falls back to the host's free memory when iOS sets no limit.
  - The SAX `nestedElements` path returned one entry for a `<node>` inside a `<node>`, where the Mac path
    returns two. Now both platforms give every parent in document order, and with a wrapper, only its direct
    children.
- **The CI iOS test step** runs only the core the iOS app uses: 18 classes, with `-only-testing`, on scheme
  `VerbinalKit-Package`. Never the Mac tests, MCP, agents, proposals, hints, addons or cutouts.

**Checked:**
- iOS Debug (Simulator) and Release (device) builds pass.
- The 18 classes on an iPhone simulator: 127 tests, 0 failures, 5 Keychain tests skipped (-34018: no
  entitlements without an app host).
- macOS: VerbinalKit `swift test` passes. `VerbinalTests`: 2,370 tests; the guardrail passes.

**Known local failures, the same on unchanged `main` (fresh builds compared):**
- `UIHintToolsTests` × 3: 36 controls counted against more than 40, locally on Xcode 27.
- `ToolMapTests.testDescribeAppGivesOneAreasTools`, on incremental builds only. The commit-stamp script
  edits the built `Info.plist`, so the next build processes the plist again, unordered against the
  script, and the stamp is lost. A fresh build stamps it and passes. The cure: give the script phase the
  plist as an input.

**Still open:**
- Signing in on a **device** and relaunching (the keychain fix; the Simulator cannot show it).
- The new CI steps on GitHub's Xcode 16.4.

### Phase 1 — Check: the Portal

| # | Step |
|---|---|
| 1.1 | The four-tab shell, Portal · FITS · Cube · Compute (TabView on iPhone, sidebar on iPad, `AdaptiveLayout` as today), and the Account sheet behind the initials button: profile, AI Compute, About, Terms, Sign Out. |
| 1.2 | The status-first Portal: the Needs attention rules above; Sessions, Batch jobs, Compute, Load and Quota. One shared session card and one events sheet, ending today's copies. Delete confirmed; Renew and Delete say their result. |
| 1.3 | The "last looked" state on the device, so news is news once. |
| 1.4 | **Expiry reminders:** a local notification 30 minutes before a session expires, scheduled from its `expiresTime` and moved on every load or renew. They need no background running. The permission is asked when the person first turns them on. |
| 1.5 | Launch as a sheet: Relaunch, and the Standard form (D3 for Advanced). |

#### Phase 1, as built (2026-10-22, uncommitted)

- **The shell** (`Verbinal/iOS/Shell/iOSShell.swift`): Portal · FITS · Cube · Compute, as a TabView on
  iPhone and a sidebar on iPad, over `AppState.iOSDashboardTab` (now `portal, fits, cube, compute`). The
  Account button, with the person's initials, opens `iOSAccountSheet`: profile, the reminders, About,
  Terms, Sign Out. FITS, Cube and Compute are empty states until their phases.
- **The Portal** (`iOS/Portal/Views/iOSPortalView.swift`), from top to bottom:
  - a load problem, with Try Again;
  - **Needs attention** (`PortalAttention`): sign-in; failed sessions; sessions ending within the hour,
    soonest first, with Renew; sessions Pending over 10 minutes; failed batch jobs not yet seen; Remote
    Compute's problem; storage 90 % full or more;
  - Sessions (`iOSSessionRow`: "Expires in 38 min · 14:02", Open, Renew, Logs, ⋯ ▸ Delete…; swipe to
    Renew or Delete);
  - Batch Jobs (counts; opens the Mac's jobs sheet);
  - Remote Compute (its state; opens Compute).
- **The rings, first** (the person, 2026-10-22, after a look in the Simulator): CPU, RAM, GPU and
  Storage as donuts (`iOSPlatformDonuts`, the Mac's ring colours and numbers): one widget pinned above
  the list, never two. At the top it is large, each ring with its percentage and numbers inside, and the
  list starts below it (`contentMargins`). Scrolled down 40 pt, it goes to half size and the list passes
  under it; a tap shows it large, the next scroll half size again. The scroll position comes from
  `onScrollGeometryChange` (iOS 18); on iOS 17 the widget stays large. Two earlier tries failed in the
  Simulator: a List row's `onDisappear` never fired, and a second, pinned copy showed beside the first.
- **Buttons** on the session rows and under Needs attention: large icons, no text; VoiceOver reads
  their names.
- **Actions:** Delete asks first, in the Mac's words. Renew and Delete say their result in a capsule, with
  a haptic. One logs sheet replaces the two copies.
- **1.3:** `PortalSeenStore`. Opening Batch Jobs, or swiping Seen, makes failed jobs seen; only jobs
  still failed are kept.
- **1.4:** `ExpiryReminderPlan` and `ExpiryReminderScheduler`: off until turned on in Account, which is
  when iOS asks. One reminder per running session, 30 minutes before it ends, rescheduled whenever the
  sessions change. `NotificationPresenter` shows them while Verbinal is in front too.
- **1.5:** `iOSLaunchSheet`: Recent Launches with Relaunch, and the Standard form; Advanced stays on the
  Mac (D3).
- `ComputeState.title` moved from the Mac's Remote Compute view to `ComputeState.swift`, for both
  platforms.
- **Tests:** `VerbinalIOSTests`, a hostless iOS bundle compiled from the Portal's model sources: 14
  tests of the attention rules, the reminder schedule, session times and the seen store, in the
  VerbinalIOS scheme and CI.
- **French:** 34 new keys.

**Still open:** the person's look in the Simulator; the Mac compiled with the shared edits
(`AppState`'s enum, `AuthenticatedRootView`, `VerbinalApp`, `ComputeState`).

### Phase 2 — Compute

| # | Step |
|---|---|
| 2.1 | An iOS Compute screen over `RemoteComputeModel`: state, Start, Stop (confirmed), the problem and drift banners. |
| 2.2 | Runs from `/arc`: list `done/` and `out/`, pair them by id, newest first; this device's own runs marked; pull to refresh. |
| 2.3 | A run's page: code, stdout, stderr, exit code, duration; Run Again; Copy. |
| 2.4 | Run Code: language, timeout, editor; the result polled as the Mac does. |
| 2.5 | Setup when nothing is running: AI Compute in the Account sheet, prefilled from the last session seen. |
| 2.6 | Browse output, once Phase 3's picker exists. |

#### Phase 2, as built (2026-10-22, uncommitted)

- **`iOS/Compute/Views/iOSComputeView.swift`**, over `RemoteComputeModel` as on the Mac:
  - the state, size and image;
  - Start, and Stop (confirmed, in the Mac's words);
  - the problem, message, not-ready and drift banners (Restart with New Settings, confirmed);
  - a 10-second tick while something changes;
  - pull to refresh;
  - Run Code in the toolbar;
  - Set up remote compute when nothing is configured and no session runs.
- **2.2:** `ComputeRunHistory` lists `.verbinal/exec/out`, `done` and `inbox`, then reads the newest 25
  runs' requests and results, 6 at a time. `ComputeRunItems` pairs the files by id (a `.partial` result is
  not whole yet), and merges this device's local runs: marked "this device", and added while not yet on
  /arc. The files do not say who sent a run, so the rest read "Another device or an assistant".
- **2.3:** `iOSComputeRunView` shows status, exit code, duration, when, where from, the code (Copy),
  stdout, stderr, and "cut short". A run still out is read every 5 s until its result is there. Run Again
  sends its code as the person's (`setSnippet` + `runSnippet`).
- **2.4:** `iOSRunCodeSheet`: language, timeout, and `CodeEditor`, a `UITextView` with smart quotes,
  dashes and autocorrection off (SwiftUI's `TextEditor` cannot turn them off, and a curly quote breaks
  Python and Bash).
- **2.5:** `iOSAIComputeSettingsView`, in Account ▸ AI Compute and from the setup. The image (with "Use
  the Running Session's Image" when the settings have none), cores, RAM, the registry login and secret,
  over `AIComputeSettingsService`. The model's rule stays: code runs once an image is set; the running
  session's image is a tap away, not taken silently.
- **2.6:** Browse output waits for Phase 3's picker.
- **Tests:** `ComputeRunItemsTests`, 4 tests. The test bundle also compiles `RunCodeContract.swift` and
  `ComputeRun.swift`.
- **French:** 30 new keys.

### Phase 3 — Open

| # | Step |
|---|---|
| 3.1 | The streaming ranged reader (stops at `maxBytes`, survives a 200), with tests against a 200, a 206 and a 416. |
| 3.2 | `RemoteFITSHeader`: the header and HDU map from ranged reads alone. |
| 3.3 | The storage picker: read-only, over `VOSpaceBrowserService.listNodes`; home, projects, the compute folder; newest first; FITS filter; size and date shown. |
| 3.4 | The download cache: `Caches/`, LRU, a cap, progress, Cancel. |
| 3.5 | Files: `.fileImporter`, document types for FITS, open in place (security-scoped). |
| 3.6 | Recents, and the routing to FITS or Cube. |

#### Phase 3, as built (2026-10-22, uncommitted)

- **3.1:** `NetworkClient.getRange` (VerbinalKit, `NetworkClient+Range.swift`) streams with
  `bytes(for:)` and stops at the length asked.
  - A 200 (the whole file) is read only to that length at offset 0, and gives no bytes at a later offset;
    `honoredRange` says which. A 416 gives none.
  - `NetworkClient.swift` sits at its guardrail ceiling, so the extension is a file of its own; five members
    went from `private` to module-internal for it.
  - `VOSpaceBrowserService.readRange` builds on it. The Mac's `fetchBytes` is unchanged.
  - `RangeReadTests`: 6 tests, on an iPhone simulator, added to CI's iOS list.
- **3.2:** `RemoteCubeDataSource` (VerbinalKit) reads ahead in aligned 256 KB chunks and keeps 16, so the
  parser's 2880-byte header reads cost one request per header; a read larger than a chunk goes as it is.
  `FileInspection` reads the HDUs with `FITSCube.parseStructure` over it (or over the local file), and
  says `RangeNotSupported` when ARC sends only whole files. The same source serves 5.1's remote cubes.
- **3.3:** `iOSOpenSheet` lists Recent, Your Storage ▸ Home and On This Device ▸ Files…. Its
  `iOSStorageFolderView` shows folders first, then files newest first, with size and date; FITS only
  unless the person asks for all; pull to refresh. **Home only:** the storage client knows
  `/arc/home/<user>`, not `/arc/projects` — that is a later change to the client.
- **3.4:** `RemoteFileCache`: `Caches/Verbinal/Remote`, one folder per file and version (a file changed
  in storage is a new entry), capped at 2 GB, the least recently opened going first. A download has
  progress and Cancel.
- **3.5:**
  - `.fileImporter`;
  - Info-iOS.plist declares FITS (`gov.nasa.gsfc.fits`: `.fits .fit .fts .fz`) as a document type, with
    `LSSupportsOpeningDocumentsInPlace` and `UIFileSharingEnabled`;
  - `onOpenURL` hands the file to FITS through `pendingFITSURL`;
  - opened local files are kept as security-scoped bookmarks.
- **3.6:** `iOSRecentFiles` (20, on the device). Until the viewers (Phases 4 and 5), FITS and Cube show the
  opened file's page, `iOSFileView`:
  - where it is, its size, its HDUs (`#1 SCI · IMAGE · 4096 × 4096 · BITPIX -32`);
  - the cards that say what it holds (OBJECT … CHECKSUM, DATASUM), and the whole header, searchable;
  - Download, then Share.
  
  A cube is labelled "it opens in Cube"; routing comes with Phase 5.
- **2.6, done here:** a Compute run's page lists the FITS files its output names in the person's home
  (`/arc/home/<user>/…` or `~/…`); a tap opens one in FITS, header first (`homeFITSPaths`, 2 tests).
- **French:** 27 new keys. iOS unit tests: 20, passing.

### Phase 4 — FITS

| # | Step |
|---|---|
| 4.1 | The iOS viewer views over `FITSViewerModel` and `FITSTabHostModel`: the canvas, gestures, loupe, hover probe. |
| 4.2 | The sheet / inspector: Display, Verify, Header, HDUs. |
| 4.3 | Verify: the checksum (`FITSChecksum`), statistics (Accelerate, on a sample above a size), the WCS summary, the pinned header cards. |
| 4.4 | Hold to blink between two open files. |
| 4.5 | Share a picture of the view, with its readout. |
| 4.6 | **Measure** the render on the floor device. If a stretch change misses its budget, the Metal display path (stretch, cuts and colormap in a shader; the vDSP engine stays as the reference). |

#### Phase 4, as built (2026-10-22, uncommitted)

- **4.1:** `iOS/FITS/Views/iOSFITSCanvas.swift`, over `FITSViewerModel` and the app's `fitsTabHost`, draws
  as the Mac's `FITSImageView` does (one viewport, one mapping). On touch:
  - pinch zooms about the fingers (the image point under them stays);
  - drag pans;
  - two fingers turn it, snapping to North Up within 5°;
  - a double tap goes between Fit and 1:1 about the tap;
  - a tap hides the chrome (bars, tab bar, status bar);
  - **the loupe:** long press, then move. Pixels ×8 beyond the view, value, RA/Dec, a selection haptic
    per pixel; lifting the finger leaves the crosshair;
  - pointer and Apple Pencil hover read the pixel.
  
  Overlays:
  - a compass rose: N and E from the WCS, by mapping a small step on the sky, so it is right however the
    view is turned or flipped;
  - a scale bar: a round number of ″, ′ or °, 60–160 pt;
  - the crosshair.
- **4.2:** `iOSFITSControls` in a sheet (0.45 / large, background interaction on):
  - **Display:** Auto (`FITSParser.autoCut`), 99.5 % and Min–Max presets; a histogram (log counts, the
    values without their extreme 0.1 %, widened to the cuts) whose black and white points move under the
    finger; stretch; a colormap carousel drawn by the image's own renderer;
  - **Verify;**
  - **Header** (searchable);
  - **HDUs.**
- **4.3:** `FITSVerify`, pure and tested:
  - DATASUM (the data's ones' complement sum) and CHECKSUM (the whole HDU sums to all ones), from the file's
    bytes; header starts derived, since the header-only parser does not record them; a tile-compressed
    HDU says its checksums are on its table;
  - statistics: min, max, mean, σ, blank count, count at SATURATE; the median from an even sample of at most
    1 M values, labelled so;
  - the Verify tab adds the WCS summary (centre, pixel, field, north angle, projection) and the
    observation cards.
- **4.4:** hold Compare (two files open): the Mac's blink, `startBlink` + `showBlinkB` while held,
  `stopBlink` on release (which restores the framing); VoiceOver toggles it.
- **4.5:** Share: `iOSFITSPicture`, a `Transferable` PNG made when shared (`ImageRenderer`, 2×): the view as
  on screen, the crosshair, and a caption line (file, RA/Dec, value, stretch · colormap).
- **Opening:** a file already on the device opens straight into the viewer; from storage its page comes
  first, with "Download and View the Image". The file name (the title's menu) switches between open
  images, opens another, or shows the file page; **✕ Close** in the bar closes the image, and the last
  one brings back Open. The first version hid Close in a Files menu, and the person did not find it
  ("no close", 2026-10-23); Cube and a file's page have the same ✕.
- **Touches:** on UIKit's recognizers (`iOSCanvasTouchLayer`): pinch and rotate as one manipulation
  about the fingers, one-finger and scroll pan, double tap, tap (it waits for the double), long press,
  and hover. The first version composed SwiftUI gestures (a long press "exclusively before" a drag,
  beside a magnify), and the person found that zoom did nothing in the Simulator (2026-10-23).
- **4.6 not done:** the render's speed on a device. The vDSP render is debounced as on the Mac; measure on
  the floor device before deciding on Metal.
- **Tests:** `FITSVerifyTests`, 4 tests (an intact file, a changed byte caught, values, percentiles and
  histogram); the iOS test bundle now links VerbinalKit. **French:** 36 new keys.

### Phase 5 — Cube

| # | Step |
|---|---|
| 5.1 | `RemoteCubeDataSource` with a plane cache; local cubes as today (mmap). |
| 5.2 | Slice, scrubber with the spectrum behind it, haptics, readout. |
| 5.3 | Tap for the spectrum; drag along it to move the channel. |
| 5.4 | Verify: spectral axis, statistics, empty and NaN planes. |
| 5.5 | Moment 0, plane by plane (D4 for big remote cubes). |
| 5.6 | Volume: the Metal view on iOS, adaptive quality; where D5 says. |

#### Phase 5, as built (2026-10-23, uncommitted)

- **Routing (3.6 finished):**
  - a local file is checked for NAXIS ≥ 3 (`AppState.fitsIsCube`) and opens in Cube or FITS, from either
    tab;
  - a file page says "View the Cube" or "View the Image";
  - the cube tab host's first empty tab is reused.
- **5.1 deferred (remote cubes read where they are):** `CubeModel.ingest` builds the WCS and the
  statistics by reading every plane, and `CubeViewerModel.swift` is 3 lines under its ceiling. Remote
  cubes are downloaded first ("Download and View the Cube"), from the header-first page that already
  shows their size. A quick look over `RemoteCubeDataSource` needs a split of the model and a
  `CubeModel` path without the full ingest: later.
- **5.2:**
  - `iOSCubeSliceCanvas` over `CubeSliceFrame`, on the same UIKit touches as FITS: pinch about the fingers,
    pan, double tap back to the whole slice, tap hides the chrome; a long press reads the spaxel, and
    lifting opens its spectrum.
  - `iOSChannelScrubber`: the cube's mean spectrum behind a wide scrubber, a selection haptic per channel
    and a medium impact on a peak; the `SpectralWCS` readout; Play/Pause; adjustable for VoiceOver.
- **5.3:** the Spectrum tab, in Swift Charts: a step line of the spaxel's spectrum, a rule at the
  channel; drag along it to move the channel. A streamed cube says why it has none.
- **5.4:** the Verify tab:
  - the cube's size and cards;
  - the spectral axis (CTYPE3, CUNIT3, first and last values, CDELT3, RESTFRQ);
  - values (min, max, median — sampled for a streamed cube — blank %), and blank channels.
- **5.5:** Moment 0 (`CubeMoment0`, pure, 2 tests): summed a plane at a time (finite values only, times
  |CDELT3|), with progress, then drawn with the cube's colormap and a first-look cut, as a third mode.
- **5.6:** the Mac's `CubeVolumeRenderer` and `Cube.metal`, now `#if canImport(MetalKit)`, in an
  `MTKView` on iOS (`iOSCubeVolumeView`): one finger orbits, a pinch zooms, a tap picks the channel.
  - Steps follow `thermalState` and Low Power Mode (×0.75 fair, ×0.5 serious or saving).
  - The volume texture is 256 per side on iOS (`CubeViewerModel.volumeEdge`; 512 on the Mac), set
    through a one-line change to the model.
  - Shown on iPad, and on iPhones with 6 GB or more (D5).
- **Share:** a picture of the slice or moment map, with its channel readout.
- **Not done:** MetalFX upscaling — not needed until the volume is measured on a device.
- **Tests:** iOS unit tests 26, passing. **French:** 20 new keys.

### Phase 6 — Beyond the app (small, optional)

| # | Step |
|---|---|
| 6.1 | A widget: sessions, jobs and the compute state, at a glance from the home screen. It needs the app group and the keychain group shared with the extension. |
| 6.2 | `BGAppRefreshTask` for batch jobs: a notification when one ends. Best effort; iOS decides when. |
| 6.3 | Handoff from the Mac: a FITS or cube open from storage on the Mac continues on the iPad, at the same file. |

### Phase 7 — Release

- TestFlight after each phase: internal, then a few CANFAR astronomers.
- One App Store release when the agreed scope is done (D6, D7).
- App Review notes:
  - a demo CADC account;
  - that Compute runs the person's code on their own CANFAR session, never on the device (2.5.2);
  - the purpose strings.
- iPhone and iPad screenshots. Manual chapters in English and French.

## Across every phase

- **Tests:**
  - the ranged reader and remote header;
  - the run history pairing (`done/` + `out/`);
  - the Needs attention rules and the "last looked" state;
  - the expiry-reminder schedule;
  - statistics and the checksum against fixtures;
  - layout at 320, 375, 393 and 440 pt and on iPad.
  
  The person checks on the device and the Simulator.
- **Budgets,** on the floor device (D8):

  | What | Budget |
  |---|---|
  | Portal, from launch to status | < 3 s on a good network |
  | a remote header | < 1 s |
  | open a 4k×4k float image (cached) | < 1.5 s |
  | a stretch or colormap change | < 100 ms (else 4.6) |
  | one remote cube channel | < 2 s |
  | memory | under the device budget, never terminated for memory |
- **Localization:** every new string in English and French when it is written.
- **Accessibility:** VoiceOver reads the loupe, the readouts and Verify; Dynamic Type; Reduce Motion;
  haptics can be turned off.
- **Battery and network:** polling only while on screen; remote reads cancelled when the view goes;
  nothing large downloaded on its own.

## Decisions

The person (2026-10-22): "go with your recommendations, start phase 0". Every decision below is taken as
recommended.

| # | Decision | Taken | Not taken |
|---|---|---|---|
| D1 | Phase order | **0 → 1 and 2 → 3 → 4 → 5** | viewers before Compute |
| D2 | Minimum iOS | **stay at 17** (the four-tab layout already works on it) | 18 |
| D3 | Launch on iOS | **Relaunch + Standard**; Advanced (custom image, registry secret) stays on the Mac | keep Advanced |
| D4 | Too big for the device | **say so; later a "smaller copy with Compute" template** (needs numpy/astropy in the person's compute image; the watcher image only promises python3 and bash) | refuse only |
| D5 | Cube volume on iOS | **iPad first**, then iPhones with ≥ 6 GB | everywhere; not at all |
| D6 | Store record | **Universal Purchase on the Mac's record** (same bundle ID, as set up) | a separate app |
| D7 | First release | **Phases 0–5** | Portal + Compute first |
| D8 | Floor device | **iPhone 12 (A14, 4 GB)** | iPhone 13 / 6 GB |
| D9 | Trim the iOS target (0.9) | **yes** | leave the unreachable code in |

## Risks

- **The ranged read:** ARC's 200 for a range, on a phone (3.1 handles it). Latency of many small reads for
  a spectrum (bounded concurrency, drawn as it arrives).
- **Memory:** budgets, cache caps, header-first reading.
- **Compute:** it needs the watcher image set up, a Mac-side step today. iOS uses a running session as it
  is. Run ids pair `done/` and `out/`; a run still in `inbox/` shows as waiting.
- **Shared code:** 0.9 and 0.10 touch `AppState`, which the shipped Mac app runs on. The Mac's tests and
  CI must stay green at every step.
- **App Review:** a demo account; remote code execution explained.

## Parked

- Search, Research and the Storage browser beyond the picker.
- Sync.
- Sky ("find your FITS image on the sky"), plate solving, the AR cube.
- Live Activities, App Intents, Quick Look extensions.
- Marks on iOS.
- MCP: impossible on iOS.

Kept here, not deleted, in case a later plan wants them.
