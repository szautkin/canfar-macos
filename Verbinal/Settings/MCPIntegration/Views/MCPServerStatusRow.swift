// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI

/// Single authoritative MCP server-status row, derived from
/// `AgentsService.isRunning` + `socketPath` (+ `lastError`).
///
/// Lives in one place so the AI Agent tab (the server's home) and the
/// MCP Clients tab can't drift in wording: previously the same state
/// rendered as "Listening"/"Stopped" on one tab and "MCP server
/// listening"/"MCP server stopped" on the other. The AI Agent tab uses
/// the full row; the MCP Clients tab uses the same row in `.compact`
/// form (one line, no socket path), pointing back here.
struct MCPServerStatusRow: View {
    let isRunning: Bool
    let socketPath: String?
    let lastError: String?
    /// `.compact` collapses to a single status line with an "manage in
    /// the AI Agent tab" pointer (used on the MCP Clients tab where the
    /// AI Agent tab owns the controls).
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isRunning ? "checkmark.circle.fill" : "moon.zzz.fill")
                .foregroundStyle(isRunning ? Color.green : Color.secondary)
                .accessibilityLabel(isRunning ? "Server running" : "Server stopped")
            VStack(alignment: .leading, spacing: 2) {
                if compact {
                    Text(isRunning
                         ? "Server: Listening — manage in the AI Agent tab"
                         : "Server: Stopped — manage in the AI Agent tab")
                        .font(.callout)
                } else {
                    Text(isRunning ? "Listening" : "Stopped")
                        .font(.callout)
                    if let socketPath {
                        Text(socketPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                            .lineLimit(1)
                    }
                    if let lastError {
                        Text(lastError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
            Spacer()
        }
    }
}
#endif
