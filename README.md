# Verbinal for macOS

A native macOS desktop companion for the [CANFAR Science Portal](https://www.canfar.net/), built with SwiftUI and XcodeGen.

Project home: **[verbinal.com](https://verbinal.com)**

[![CI](https://github.com/szautkin/canfar-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/szautkin/canfar-macos/actions/workflows/ci.yml)
[![Release](https://github.com/szautkin/canfar-macos/actions/workflows/release.yml/badge.svg)](https://github.com/szautkin/canfar-macos/actions/workflows/release.yml)
[![License: MPL-2.0](https://img.shields.io/badge/license-MPL--2.0-blue)](LICENSE)
[![Mac App Store](https://img.shields.io/badge/Mac%20App%20Store-Verbinal-0D96F6?logo=apple&logoColor=white)](https://apps.apple.com/ca/app/verbinal/id6761290036)
[![Website](https://img.shields.io/badge/web-verbinal.com-2ea44f)](https://verbinal.com)

Available on the **[Mac App Store](https://apps.apple.com/ca/app/verbinal/id6761290036)**,
and as a notarised build from [GitHub Releases](https://github.com/szautkin/canfar-macos/releases).

## Features

- **Sessions** — launch and manage Notebook, Desktop, CARTA, Contributed, and
  Firefly sessions on the CANFAR Skaha platform, no browser required. Auto-refreshing
  status, live CPU/RAM availability, one-click re-launch from history, in-place event
  and container logs, and headless batch jobs with in-app submission and monitoring.
- **CADC archive search** — build queries against the CADC TAP service, review results
  in a sortable table, switch units (RA/Dec HMS·DMS, 14-unit spectral conversion), and
  open rich CAOM2 observation detail — with an ADQL editor for power users.
- **Research assistant** — a workspace that tracks downloaded observations, searches
  across them (full-text over notes and tags), and keeps notes alongside your data.
- **VOSpace storage** — a native file browser to browse, upload, organise, and manage
  your VOSpace files, with quota and usage at a glance.
- **FITS viewer** — hardware-accelerated, Metal-based rendering with pan/zoom, scaling
  modes, WCS-aware pixel readout, and full zenithal projections (TAN/SIN/STG/ZEA).
- **Cube Viewer** — explore FITS spectral cubes in 3D: a GPU ray-marched volume mode and
  a quantitative slice mode with WCS sky coordinates, spectral readout, and click-to-probe
  spectra — plus publication-quality figure export to PNG/PDF.
- **Image content discovery** — find which CANFAR container image carries the Python,
  R, system, and OS-level packages your workflow needs, before you launch.
- **AI assistant integration (MCP)** — a built-in Model Context Protocol server lets
  Claude Desktop and Claude Code search the archive, query sessions, browse storage,
  launch jobs, and start/stop compute or run code on your behalf — with a guided setup
  wizard, an AI Guide to tune what each tool exposes, and permission gates that keep you
  in control. See [docs/MCP-Setup.md](docs/MCP-Setup.md).
- **Privacy first** — no analytics or telemetry; credentials live in the macOS Keychain;
  all traffic goes directly to CANFAR/CADC over HTTPS.
- **Localized** — full English and French interfaces.

## Screenshots

The 3D **Cube Viewer** (new in 1.3) — explore FITS spectral cubes as an interactive, GPU ray-marched volume:

![Verbinal — Cube Viewer 3D volume](assets/screenshot-cube-volume.png)

| Home | CADC archive search |
|------|---------------------|
| ![Verbinal — home](assets/screenshot-home.png) | ![Verbinal — CADC archive search](assets/screenshot-search.png) |

| FITS viewer | AI assistant (MCP) driving Verbinal |
|-------------|-------------------------------------|
| ![Verbinal — FITS viewer](assets/screenshot-fits.png) | ![Verbinal — AI assistant via MCP](assets/screenshot-ai.png) |

## Installation

### Download

Download the latest `.dmg` from [GitHub Releases](https://github.com/szautkin/canfar-macos/releases).

1. Open `Verbinal-macOS.dmg`
2. Drag **Verbinal** to **Applications**
3. On first launch, right-click the app and select **Open** (macOS Gatekeeper requires this for unsigned apps)

A `.zip` archive is also available if you prefer.

Verify your download with the `checksums-sha256.txt` file:

```bash
shasum -a 256 -c checksums-sha256.txt
```

### Build from source

See [Building](#building) below.

## Requirements

### Runtime
- macOS 14 or newer
- A CANFAR account

### Build
- Xcode 16 or newer
- XcodeGen 2.45 or newer

## Building

```bash
# Generate the Xcode project
xcodegen generate

# Debug build
xcodebuild build \
  -project Verbinal.xcodeproj \
  -scheme Verbinal \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO

# Run tests
xcodebuild test \
  -project Verbinal.xcodeproj \
  -scheme Verbinal \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO
```

For local development, you can also open the generated `Verbinal.xcodeproj` in Xcode and run the `Verbinal` scheme directly.

## Running Tests

```bash
xcodebuild test \
  -project Verbinal.xcodeproj \
  -scheme Verbinal \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO
```

## Code Quality

- All source files include MPL-2.0 license headers
- CI runs build and test on every push and pull request
- Unit tests cover URL construction, model mapping, networking, XML parsing, and image parsing
- Strict separation of concerns: views, view models, services, and models
- A single external dependency, pinned to an exact version: [GRDB](https://github.com/groue/GRDB.swift) 7.11.0 (in-app SQLite store); everything else is Apple frameworks

## Project Structure

```text
project.yml           # XcodeGen source of truth
Verbinal/             # Application code, models, services, views
VerbinalTests/        # Unit tests for parsing and other pure logic
```

## Architecture

- SwiftUI for the UI layer
- Observation-based app state and view models
- Async/await networking with `URLSession`
- Clear separation between models, services, view models, and views

## API Endpoints

All communication is with CANFAR services over HTTPS. No telemetry, analytics, or third-party calls are present.

| Service | Base URL | Purpose |
|---------|----------|---------|
| Auth | `ws-cadc.canfar.net/ac` | Login, token validation |
| User info | `ws-uv.canfar.net/ac` | User profile retrieval |
| Sessions | `ws-uv.canfar.net/skaha/v1` | Session CRUD, images, context, stats |
| Storage | `ws-uv.canfar.net/arc` | VOSpace quota |

## License

[Mozilla Public License 2.0](LICENSE)

Copyright (C) 2025-2026 Serhii Zautkin

## Privacy

See [PRIVACY.md](PRIVACY.md). In short: no data collection, no telemetry, and no third-party services. Data stays on your machine or goes directly to CANFAR.

## Related projects

These open-source companions help you get the most out of Verbinal:

- **[verbinal-execution](https://github.com/szautkin/verbinal-execution)** — a
  CANFAR/Skaha contributed-session image that powers Verbinal's AI **remote compute**
  (`run_code`). It is a file-drop watcher that runs agent-supplied Python/bash snippets
  and writes JSON results back — no shell, no inbound network. Run it in a contributed
  session to let your AI assistant execute code on the platform on your behalf.
- **[inspector-image](https://github.com/szautkin/inspector-image)** — a minimal
  Alpine container image with [Anchore syft](https://github.com/anchore/syft) preinstalled,
  used as the Skaha/CANFAR inspector that powers Verbinal's **image content discovery**
  (probing container images for their Python, R, system, and OS-level packages).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
