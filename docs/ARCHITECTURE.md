# How Verbinal is put together

For whoever works on Verbinal's code (plan 36 tier 6). The person's guide is the [manual](manual/); how
an assistant connects is [AGENTS.md](../AGENTS.md).

## The project

- **XcodeGen.** `project.yml` describes the targets; `xcodegen generate` makes the project. Never edit
  the `.pbxproj`, and never commit `Verbinal.xcodeproj`.
- **Two targets.** `Verbinal` (macOS) and `VerbinalIOS`. The iOS one leaves out what needs the Mac:
  every `MCP/` and `Sync/` folder, and the macOS-only areas listed in `project.yml`.
- **`shared/VerbinalKit`**, a Swift package:
  - `VerbinalKit`: networking, the agent kit (tools, proposals, the change log), FITS readers.
  - `MCPCore`: the MCP transport, the relay, the sidecar.

## Areas

Each feature is an area: one folder under `Verbinal/`, owning its code.

| Folder | Holds |
|---|---|
| `Models/` | Its data: `Codable`, `Sendable` values |
| `Services/` | Its stores and clients: the one owner of each kind of data |
| `ViewModels/` | Its screens' state |
| `Views/` | Its SwiftUI |
| `MCP/` | Its tools for assistants, and the `AppState+…` extension that makes them |
| `Sync/` | Its adapter for the storage sync |
| `Helpers/` | What only it uses |

Some areas have a README: Research, Search, Storage, StorageSync, BatchJobs, FITSViewer, CubeViewer,
Marks, AIGuide. What every area shares is in `Helpers/`, `Services/`, `Models/` and `Views/` at the top.

`AppState` composes the areas and navigates between them. It grows no more:
- what an area needs of it is an `AppState+…` extension in that area's `MCP/` or `Sync/`;
- what is the app's own is in `ViewModels/AppState+…` (sign-in, sign-out, routing a file to a viewer).

## Rules the tests hold

`VerbinalTests/CodeQualityGuardrailTests.swift` keeps the code's shape. Its lists may only shrink.

- **Tools live in their area.** A tool's catalogue category (`AIGuideCatalog`) names the folders it may
  be defined in.
- **600 lines.** A file over 600 lines fails. The few still over have ceilings that only go down: split a
  file by job before it grows.
- **Every store is synced, or the device's.** Each JSON file or database table says which.
- **Every result goes through `ResultDestination`.** A place that keeps a result on the Mac tells it, so
  the result reaches the person's storage when they choose (plan 36 4.1).

Other tests hold other rules: every presentation registered (`PresentationsTests`), every tool mapped
(`ToolMapTests`), every manual item covered (`scripts/manual-coverage.py` in CI).

## The person's work in storage

`StorageSync/` is the one engine.
- **The manifest.** `.verbinal/manifest.json`, in the person's VOSpace, declares the kinds kept there.
- **One rule for every collection.** `CollectionKind` applies it:
  - each item is a file;
  - the newer change wins, and the one replaced is kept on the Mac;
  - a removal is a mark, and a device marks only what it had;
  - unknown fields are kept;
  - nothing moves while `.verbinal` is public.
- **Adapters.** An area brings a `SyncCollection` in its `Sync/` folder; a list's adapter is a
  `RecordCollection`. The area's store knows nothing of the sync.
- **The person chooses.** Each collection is their choice in Settings ▸ Storage, off until turned on. An
  account without CANFAR storage is not synced at all.
- **What stays on the device.** Sign-ins, secrets, paths, approvals, session logs and proposals.

A file is known by `FileOrigins`: `vos:` for one from storage, `caom:` for a Research file, else its path.
Marks and bookmarks follow that identity. See [vospace-layout.md](vospace-layout.md).

## Assistants (MCP)

- **The connection.** An assistant launches `Verbinal mcp`, a stdio relay (`MCPStdioBridge`,
  `ResilientBridge`). It reaches the running app through a socket that the sidecar file names; the
  app's `SidecarKeeper` keeps that file right.
- **The router and proposals.** `AgentsService` runs the server; `AIToolRouter` routes each call. A write
  is a proposal: it applies at once when the person allows that kind, or waits in Pending. Destructive
  kinds, and "What every assistant is told", always wait.
- **The session log.** Every change is recorded with its cause in the change log. The session log holds
  a session's calls, their requests to CADC and CANFAR, and their timing.

The tool map for assistants: `describe_app`, `list_apps`; [agent-ui-parity.md](agent-ui-parity.md)
pairs each control with its tool.
