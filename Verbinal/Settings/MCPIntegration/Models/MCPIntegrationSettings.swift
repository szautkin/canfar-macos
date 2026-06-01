// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import Foundation

/// Persisted state for the MCP / Claude Desktop integration settings tab.
///
/// Currently this is just a security-scoped bookmark to Claude Desktop's
/// configuration *folder* (`~/Library/Application Support/Claude/`). Folder
/// scope — not file scope — is deliberate: the auto-merge writer creates a
/// `.bak` sibling and writes atomically via a temp file + `replaceItemAt`,
/// both of which need write access to the directory, not just the one file.
struct MCPIntegrationSettings: Equatable, Sendable {
    /// Security-scoped bookmark to the Claude config folder. `nil` until the
    /// user grants access via the open panel. Stored as raw `Data` (the
    /// `JSONEncoder`/`UserDefaults` round-trip handles binary natively, no
    /// base64 needed — mirrors `DownloadedObservation.bookmarkData`).
    var claudeConfigBookmark: Data?

    var hasConfigAccess: Bool { claudeConfigBookmark != nil }
    var isAllDefaults: Bool { claudeConfigBookmark == nil }
}
#endif
