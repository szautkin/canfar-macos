// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Process entry point. Branches BEFORE any SwiftUI/AppKit initialization so
/// that, when an MCP client (Claude Desktop, etc.) launches the app binary
/// as `Verbinal mcp`, we run a headless stdio↔socket bridge instead of the
/// GUI — no window, no Dock icon. This is the App-Store-safe replacement for
/// the old bundled `canfar-mcp` helper; see `MCPStdioBridge` for why the
/// bridge must run in the main app binary rather than a separate tool.
@main
struct VerbinalMain {
    static func main() {
        #if os(macOS)
        if CommandLine.arguments.dropFirst().contains("mcp") {
            MCPStdioBridge.runAndExit() // never returns
        }
        #endif
        VerbinalApp.main()
    }
}
