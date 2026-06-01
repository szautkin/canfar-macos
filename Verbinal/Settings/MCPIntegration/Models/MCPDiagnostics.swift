// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import Foundation
import SwiftUI

/// Pass / warn / fail / in-progress state for one diagnostic row.
enum DiagnosticStatus: Sendable {
    case pass, warn, fail, running

    var symbol: String {
        switch self {
        case .pass:    "checkmark.circle.fill"
        case .warn:    "exclamationmark.triangle.fill"
        case .fail:    "xmark.octagon.fill"
        case .running: "circle.dotted"
        }
    }

    var tint: Color {
        switch self {
        case .pass:    .green
        case .warn:    .orange
        case .fail:    .red
        case .running: .secondary
        }
    }
}

/// An auto-repair a diagnostic row can offer. The view renders a button
/// titled `fix.title`; `MCPDiagnosticsModel.applyFix(_:)` dispatches it.
enum FixAction: Sendable, Equatable {
    case enableServer
    case restartServer
    case grantConfigAccess
    case updateConfig
    case revealHelper
    case openClaude

    var title: String {
        switch self {
        case .enableServer:     "Enable"
        case .restartServer:    "Restart"
        case .grantConfigAccess: "Grant Access…"
        case .updateConfig:     "Update Config"
        case .revealHelper:     "Reveal"
        case .openClaude:       "Open Claude"
        }
    }
}

/// One row in the diagnostics list.
struct DiagnosticCheck: Identifiable, Sendable {
    let id: String
    let title: String
    var status: DiagnosticStatus
    var detail: String
    var fix: FixAction?
}

/// Result of probing Claude Desktop's config file for our `verbinal-canfar`
/// server entry.
enum ClaudeConfigProbe: Sendable, Equatable {
    case noAccess                  // no folder bookmark granted yet
    case unreadable(String)        // granted but read/parse failed
    case fileMissing               // folder reachable, config file absent
    case noEntry                   // file readable, no verbinal-canfar key
    case entry(command: String)    // current command path on disk
}

/// Outcome of the helper launch self-test (spawn — "Mode A" — or socket
/// loopback — "Mode B"). `Sendable` so it can cross the detached-task
/// boundary the blocking spawn I/O runs on.
enum SelfTestOutcome: Sendable, Equatable {
    case ok(serverInfo: String)        // initialize round-trip succeeded
    case sigtrap                       // killed by SIGTRAP → code-sign / missing Info.plist
    case signal(Int32)                 // some other fatal signal
    case spawnDenied(String)           // sandbox refused Process.run() → triggers Mode B
    case exited(code: Int32, stderr: String)
    case timeout
    case helperMissing(String)
}
#endif
