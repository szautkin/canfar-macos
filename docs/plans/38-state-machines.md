# Plan 38 — State machines: one pattern, every area

**Date:** 2026-10-13 · **Branch:** `dev_1_4_1` (from `cb1f3d73`) · **Release:** 1.4.1 (the person's decision, 2026-10-13)

The person's request: plan a state machine for each part of the app, with one common pattern that is
DRY and orthogonal.

## Why

The app keeps its state as loose flags. A FITS tab, for example, is five separate values: `file`,
`isLoading`, `loadError`, `renderedImage` and `table`. That makes 32 combinations, and about five of
them mean anything. Every view re-derives which one it is looking at. The bugs of 2026-10-13 came
from those derivations:

- **The controls panel beside no file.** The view keyed on "a tab exists", not on "a file is open".
- **The spinner turned off early.** An older render cleared `isRendering` while a newer one still ran.
- **Two canvas modes armed at once.** `selectingArea` and the marks' `drawArmed` can both be on, and
  the canvas settles it by precedence.

**Count today (the baseline).** 47 such flags in the app's models: `isLoading` 14,
`errorMessage` 11, `hasError` 9, `loadError` 4, `lastError` 4, `statusMessage` 3, `isBusy` 2.

**Already the right shape** (each a single enum): `AppMode`, `ActiveSheet`, `ComputeState`,
`DownloadState`, `ImageDiscoveryModel.RowState`, `ResearchFiles.State`, `ResearchRecords.Place`,
`TaskProgress`, `SessionApprovals.Decision`.

**Already the pattern, but each written its own way:** `ObservationDetailModel.LoadState`,
`RegistrySearchModel.Phase`, `CutoutEditorModel.Phase`, `RefreshState`, `ResolverStatus` and
`DataState`.

## Rules

- **No app-wide FSM.** Navigation (`AppMode`, `ActiveSheet`) is already one small enum each.
  Gathering every screen's transitions into one table would make the app heavier without preventing
  any bug we have seen.
- **One machine per concern, not per screen.** A screen is the product of small, independent machines,
  its *orthogonal regions*. Each region is one enum. The product is never enumerated.
- **Plain Swift.** Enums, a pure transition function and a small observable holder. No framework
  (TCA, XState): the code base stays legible to anyone who reads Swift.
- **Effects stay in the models.** A machine decides what state follows an event. Network calls, file
  reads and renders stay where they are, and send events when they finish.
- **One commit after each step**, each through the gates (the person, 2026-10-13).
- **Behaviour is unchanged by the plan itself.** Each step moves state into a machine with the same
  UI and tool answers. Fixes the machine makes possible come as separate, named items.

## The common pattern (P0 — written once)

Everything below lives in `Verbinal/Helpers/State/`, which both the macOS and iOS targets compile.

### 1. `Phase<Value>`: anything fetched, loaded or computed

```swift
enum Phase<Value> {
    case idle                                   // not asked for yet
    case working(Attempt, last: Value?)         // under way; the last good value can stay on screen
    case ready(Value)
    case failed(Problem, last: Value?)          // what went wrong; the last good value is kept
}
```

- **What it replaces.** The `isLoading` + `errorMessage` + `hasError` triples, and the six enums of
  the same shape listed above.
- **`last:`** gives "refreshing", and "failed but still showing the old list", without extra flags.
- **Helpers, written once and tested once:** `value`, `isWorking`, `problem`, and
  `dataState(isEmpty:)`. That last one maps to the existing `DataState`, so `DataStateContainer` draws
  every phase the same way.

### 2. `Problem`: what went wrong, separate from when

```swift
struct Problem: Equatable, Sendable {
    enum Kind: Sendable { case signInRequired, notFound, offline, refused, cancelled, other }
    let kind: Kind
    let message: String       // as the person reads it, localized
    var retry: Bool = true
}
```

- One mapping from errors to problems (`Problem(error)`), from `NetworkError`, `URLError`,
  `CancellationError` and the app's own errors. It replaces the ad-hoc `error.localizedDescription`
  strings.
- **Already in the code:** `LoadState`'s `.authRequired` and `.notFound` become `Problem.Kind` values.

### 3. `Attempt`: drop results that come too late

```swift
struct Attempt: Equatable, Sendable { let number: Int; let started: Date }
```

- **Start:** a transition that begins work creates the next attempt.
- **Finish:** a result is applied only if its attempt is the current one.
- **Replaces:** `FITSViewerModel.renderGeneration` (2026-10-13), and the cancellation checks scattered
  through the code.

### 4. `StateMachine`: one way to define a machine

```swift
protocol StateMachine {
    associatedtype State: Equatable & Sendable
    associatedtype Event: Sendable
    /// The state after `event`; nil when the event means nothing in `state`.
    static func next(_ state: State, on event: Event) -> State?
}

@Observable @MainActor
final class Machine<M: StateMachine> {
    private(set) var state: M.State
    func send(_ event: M.Event)   // applies `next`; a refused event is logged, never crashes
}
```

- **Pure `next`:** tested as a table, with no UI and no network.
- **`Machine`, written once:**
  - holds the state for SwiftUI;
  - logs refused events (OSLog, and the session log when an assistant caused them);
  - offers `until(_ predicate:)` for assistants' tools. Today `agentOpenWait` polls.
- **Optional activity reporting:** a machine can post its work to the activity bar (`TaskRegistry`),
  so services stop calling `tasks.begin`, `succeed` and `fail` by hand.

### 5. What screens and tools share

- **One `PhaseView`** over `DataStateContainer`. It gives each screen the same loading, empty, failed
  (with **Try Again** when `retry`) and content views.
- **One encoding for assistants.** Every machine's state is `Codable` as `{ "state": "…", … }`, so
  each `get_*` tool reports `state` the same way. During the move, the old fields stay as derived
  values.

## Orthogonal regions, area by area

| Area | Regions (one enum each) | Replaces | Notes |
|---|---|---|---|
| **App** (`AppState`) | Screen (`AppMode`), Sheet (`ActiveSheet`): unchanged · **Hand-off** `none / openFITS(URL) / openCube(URL) / searchAt(coord) / loadSearch(…) / chooseViewer(URL)` | `pendingFITSURL`, `pendingCubeURL`, `pendingSearchCoordinate`, `pendingSearchLoad`, `pendingViewerChoiceURL` | One pending hand-off at a time, consumed by the screen it targets. |
| **Account** (cross-cutting) | **Auth** `signedOut / checking / signedIn(user) / renewing(user) / offline(user) / ended(reason)` | `isAuthenticated`, `isLoading`, `statusMessage` on `AppState` and `AuthLifecycleController` | Toolbars, tiles and the sign-in sheet read one value. Largest blast radius: P3. |
| **FITS Viewer** (per tab) | **Document** `empty / loading(URL, stage) / failed(URL, Problem) / image / table` · **Render** `idle / drawing(Attempt)` · **Canvas tool** `pan / selectArea / draw(kind)` · (host) **Blink** `off / running / paused` | `file`, `isLoading`, `loadError`, `loadStage`, `renderedImage` (as a flag), `table` (as a flag), `isRendering`, `renderGeneration`, `selectingArea`, `drawArmed`, `isBlinking`, `isBlinkPaused` | The controls panel shows for `image` and `table` only. Select Area and drawing exclude each other by construction. |
| **Cube Viewer** (per tab) | **Document** (the same as FITS) · **Slice render** `Phase<CGImage>` · **Playback** and **Volume path**: each already one value (`isPlaying`; `volumeRenderError`, nil when healthy), kept · **Canvas tool** (shared with FITS) | `isLoading`, `loadError`, `loadProgress`, `loadStage`, `isRendering`, `volumeRenderError`, `isPlaying` | `ViewerDocument<Content>` and `CanvasTool` are written once for both viewers. |
| **Search** | **Query** `Phase<Results>` · **Resolver** `Phase<Coordinate>` · **Data train** `Phase<DataTrain>` · **Detail** `Phase<CAOM2>` | `isSearching`, `searchError`, `ResolverStatus`, `DataTrainModel.{isLoading, isRefreshing, errorMessage, hasError}`, `ObservationDetailModel.LoadState` | `Phase.working(last:)` keeps the results on screen while a new search runs. |
| **Research** | **Records place**: kept as is · **File transfer** (per file) `idle / sending / fetching / removing(from)` · **Downloads**: `DownloadState`, kept | `ResearchFileTransfer.busy`, `ResearchModel.lastError` | The badge's spinner and menu read the file's transfer state. |
| **Portal** | **Sessions** `Phase<[Session]>` + **Polling** `off / on(interval)` · **Platform load** `Phase` · **Quota** `Phase` · **Launch** `editing / launching(Attempt) / launched(id) / failed(Problem)` · **Headless** monitor `Phase` + launch (same as Launch) | `SessionListModel`, `PlatformLoadModel`, `StorageModel`, `SessionLaunchModel`, `HeadlessMonitorModel`, `HeadlessLaunchModel`: all their `isLoading`, `isLaunching`, `errorMessage`, `hasError`, `isPolling` | Mechanical; this is where most of the 47 flags are. |
| **Storage** | **Listing** `Phase<Folder>` · **Operation** `none / deleting(paths) / transferring(progress) / failed(Problem)` | `StorageBrowserModel.{isLoading, isBusy, isDeleting, isTransferring, errorMessage, hasError, statusMessage}` | The listing and the operation are independent: you can browse while an upload runs. |
| **Remote Compute** | **Compute**: `ComputeState`, kept, gains its events · **Change** `idle / changing(Attempt) / failed(Problem)` | `RemoteComputeModel.{isBusy, isChanging, message}` | |
| **Image Discovery / CANFAR Images** | **Rows**: `RowState`, kept · **Catalogue** `Phase<[Image]>` | `isDiscoveryRunning`, `bannerMessage`, `CanfarImagesModel.isLoading` | The Portal's CANFAR Images widget has no **Reload** (the person, 2026-10-13), and a failed load's banner is never cleared by a later success. It gets a reload button like the other Portal widgets, and is the first `Phase` conversion. |
| **Export** | **Export** `idle / exporting(progress) / done(URL) / failed(Problem)` | `ExportService.{isExporting, lastError, coordinatorError, copyError}` | |
| **Storage Sync** | **Sync** `off / idle(lastSync) / syncing(collection) / failed(Problem)` per collection | the reasons and dates scattered across `StorageSync` | Settings ▸ Storage reads it per collection. |
| **AI agents** | **Server** `off / starting / listening / failed(Problem)` · **Session**: `SessionApprovals.Decision` and `Ending`, made one machine `none / asking / active / ended(Ending)` | `AgentsService.{isEnabled, isRunning, lastError}` | |
| **AI Guide, Workflows, Landing** | `Phase` wherever they load; otherwise derived | — | Little state of their own. |
| **Activity** | `TaskProgress`, kept | — | Remains the log of work. Machines can report into it (pattern item 4). |

## Phases of the work (one release; no intermediate tags)

| Phase | What | Gate |
|---|---|---|
| **P0** | The vocabulary: `Phase`, `Problem`, `Attempt`, `StateMachine`, `Machine`, `PhaseView` and the state encoding for assistants. Table tests for each. **Guardrail:** a ratchet in `CodeQualityGuardrailTests` counting the loose flags (47 today) that may only go down, and a new `@Observable` model may not add any. | No behaviour change; every test green. |
| **P1** | The viewers: FITS and Cube `ViewerDocument`, `Render`, `CanvasTool`, Blink and Playback. | `ViewerLayoutTests`, `FITSRenderDebounceTests` and `FITSAreaSelectionTests` pass unchanged; a new transition table per machine; `get_fits_view` and `get_cube_view` report `state`. |
| **P1½** | The Portal's CANFAR Images widget: `Phase`, a **Reload** button in its header, **Try Again** on failure. | Its own commit, first of the loaders. |
| **P2** | The loaders: Portal, Storage, Search, Image Discovery, CANFAR Images, Export, through `Phase`. | The ratchet down by about 35; `PhaseView` on each screen; the same strings. |
| **P3** | Account (Auth) and AI agents (Server, Session). | The sign-in tests and the plan 25 handshake tests unchanged; the toolbar reads one value. |
| **P4** | Research file transfer, Remote Compute changes, Storage Sync, App hand-offs. | The ratchet at 0, or each remaining flag listed with its reason. |

Each phase follows the plan 36 method:
- a failing test first;
- one green commit per region through the gates;
- the parity matrix updated where a tool's answer gains `state`.

The manual changes only where the screen does: **Try Again** on a failed load, which several screens
lack today.

## Tests

- **Per machine:** a table of `(state, event) → state or refused`, covering every case. The
  compiler's exhaustive `switch` checks the rest.
- **`Attempt`:** a late result never overwrites a newer one. This generalises the
  render-generation test.
- **Guardrail:** the flag ratchet (P0), and every `Machine` in an `@Observable` model is reachable
  from a tool's `state` (the parity matrix's rule, extended).
- **Layout:** `ViewerLayoutTests` grows to every screen's empty and failed states in a short window.

## Risks

- **Heavy values in enums.** Pixel arrays and image lists must not be copied on every transition.
  The state holds references (a class box) or IDs, and SwiftUI observes the small enum.
- **Observation granularity.** One enum per region, not one per screen, so a render does not redraw
  the panel.
- **Tool compatibility.** Assistants' fields stay as derived values for one release; the description
  says `state` is the one to read.
- **Big-bang temptation.** Every step is one region, so any commit can be reverted alone.

## Decided (the person, 2026-10-13)

1. **It ships in 1.4.1**, on `dev_1_4_1`, one commit per step.
2. **Try Again** on every load that fails: yes.
3. The CANFAR Images widget gets **Reload** (P1½).

4. **Assistant answers keep their old fields**, computed from the state, each marked
   **Deprecated, to be deleted** in the code and in its tool's description; `state` (or the region's
   own field) is the one to read. The list below is what a later release deletes.

## Deprecated answer fields (to delete)

| Tool | Field | Read instead | Since |
|---|---|---|---|
| `get_fits_view` | `selectingArea` | `canvasTool` | P1a |
| `get_fits_view` | `isOpen` | `state` | P1b |
| `get_cube_view` | `isOpen` | `state` | P1b |
| `blink_fits_tabs` | `isBlinking`, `paused` | `state` | P1d — Windows answers the same two; delete them together |

## Done

| Step | Commit | What |
|---|---|---|
| Plan | `5a706c12` | This plan, with the decisions above. |
| P0 | `a7544e84` | The vocabulary, its tests, the ratchet (47). |
| P1½ | `60e589e6` | The Canfar Images card: `Phase`, Reload, Try Again (46). |
| P1a | `e47e477e` | One `CanvasTool` per viewer: pan, select an area, or draw. |
| P1b | `a5a04180` | `DocumentState` for the FITS and cube tabs; `state` in their view tools (isLoading 10, loadError 1). |
| P1c | `871a5636` | A FITS tab's picture is a `Phase<CGImage>`; `Attempt` replaces the render generation. |
| P1d | `fa1d63ef` | Blink: one state, off / running / paused; `state` in `blink_fits_tabs`. |
| P1e | `e15b71ae` | The cube's slice is a `Phase<CGImage>`; playback and volume path already one value each. |
| P2a | `b2f16513` | The Portal's cards: `load: Phase<Date>`, Try Again; `InlineErrorLabel` takes Try Again (isLoading 6, errorMessage 7, hasError 5). |
| P2b | `9a208521` | The launch forms: `options` and `launchPhase` (isLoading 5, errorMessage 5, hasError 3). |
