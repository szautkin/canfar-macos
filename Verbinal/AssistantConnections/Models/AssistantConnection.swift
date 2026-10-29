// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore

/// An assistant connected now (plan 52 C1): its client, its session, the
/// relay it came through, and how it has been calling.
struct AssistantConnection: Identifiable, Equatable, Sendable {
    let session: UUID
    var id: UUID { session }
    /// As its `initialize` names it: "claude-code/2.1".
    var client: String
    /// Who its relay is; nil from a relay older than Verbinal 1.4.2.
    var relay: RelayIdentity?
    let connected: Date
    var lastCall: Date?
    var calls = 0

    /// The client's name without its version: "codex-mcp-client".
    var clientName: String {
        String(client.split(separator: "/", maxSplits: 1).first ?? Substring(client))
    }
}
