# Changelog

All notable changes to Verbinal for macOS (and the new iOS port) are documented
in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.5] - 2026-06-07

First public App Store release. This is a large feature release on top of the
`1.2.0` baseline: a cross-platform refactor, an iOS port, a complete AI/MCP
integration surface, and a broad reliability and localization pass.

### Added

#### AI assistant & MCP integration
- In-app MCP server that runs inside the app binary (App-Store-safe — no bundled
  helper executable), exposing the app to Claude and other MCP clients.
- Read tools across Search, Research, VOSpace storage, Sessions, FITS, headless
  jobs, and image discovery.
- Write tools with a proposal strip UI, an applier registry, and per-write agent
  attribution badges plus a persistent activity feed and History tab.
- Autonomous trusted-client mode: agent writes auto-apply by default, with a
  single autonomy toggle (no per-tool granularity).
- Agent-driven UI navigation with an auto-follow toggle.
- `get_preview_image` tool: server-side CAOM-2 preview resolution and
  authenticated fetch, returned as an inline image (kept under the 1 MB MCP
  response limit).
- AI Remote Compute: `run_code` / `run_code_output` tools that execute code on a
  warm contributed CANFAR compute session, gated behind a validation step.
- Compute lifecycle tools and an in-app **AI Guide** (off by default).
- Settings: discover and configure Claude Desktop and Claude Code as MCP clients,
  plus MCP integration diagnostics and config repair.

#### Search
- Rich CAOM2 observation detail viewer (replaces the old result detail sheet).
- CADC Advanced Search (CCDA) parity: coordinate precision, time defaults,
  operator filters, HMS/DMS for RA/Dec, and spectral cross-conversion across
  14 units with full unit-switching.
- Quick-search archive links.
- Spotlight indexing of downloaded observations.

#### FITS viewer
- Full zenithal WCS projections (TAN, SIN, STG, ZEA).
- `FITSRenderEngine` and CAOM2/FITS parsers hoisted into the shared
  `VerbinalKit` package.

#### Image discovery
- Probe-job-driven discovery of session container images with a locally cached
  manifest, rolling-tag freshness, Rediscover, and cache controls.
- Dashboard "Canfar Images" widget with type tabs and Inspect handoff to the
  launch form.

#### Headless jobs
- Headless launch path matching the `opencadc/canfar` Python client, surfaced as
  a launch-form tab and as MCP tools.

#### Storage
- GRDB-backed (pinned 7.11.0) in-app database: `AppDatabase` pool + migrator,
  v1 schema, and FTS5 full-text search over observation notes.
- Research filtering now matches note text and tags via FTS.
- Versioned envelope for on-disk persistence; corrupt stores are quarantined and
  write success is reported.

#### Platform & packaging
- iOS port (iPhone/iPad) with cross-platform groundwork.
- `VerbinalKit` Swift package: shared services, parsers, networking, Keychain,
  and an addon protocol.
- Localization: English + French String Catalog across the app.
- Terms of Use acceptance gate with no-warranties / liability disclaimers
  (BC governing law, free-app liability cap), fully bilingual.

### Changed
- Reworked landing tiles with Sign In / profile button and auth-gated locked
  tiles; app-wide cinematic motion.
- Networking resiliency: `NetworkPathMonitor` integration, 401 handler, retry
  policy with backoff, and extraction of `AuthLifecycleController` from app state.
- Credentials: optional password persistence under "Remember me" with silent
  re-login on token expiry (Keychain, device-only).

### Fixed
- Research notes no longer cross-contaminate across observations.
- Numerous correctness, accessibility, and UX fixes from a 64-ticket
  code-quality and reliability sweep (force-unwrap hardening, explicit failure
  surfacing, isolation/concurrency correctness, dead-code removal, added tests).
- App Store sandbox fixes: App Groups population (MAS 2.4.5) and a POSIX
  `AF_UNIX` MCP transport that works inside the sandbox.

### Security
- No secrets, keys, or credentials in source; credentials are stored only in the
  Keychain (device-only) and never logged.
- Bearer tokens are restricted to an allowlist of trusted CANFAR hosts and are
  not forwarded on redirects to partner archives (SSRF / downgrade defense).
- DataLink results that are not HTTPS are rejected.
- Shipping app is sandboxed with least-privilege entitlements (network client +
  user-selected / downloads file access only; no JIT, no disabled library
  validation in the shipping target).
- Dependency pinned to an exact version (GRDB 7.11.0).

## [1.2.0] - 2025

- Baseline release prior to the cross-platform refactor and AI integration.

[1.2.5]: https://github.com/szautkin/canfar-macos/releases/tag/v1.2.5
[1.2.0]: https://github.com/szautkin/canfar-macos/releases/tag/v1.2.0-baseline
