// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What the MCP bridge tells the session log: a session opened, a call
/// began and ended, the session closed (plan 23 L2). The bridge serves one
/// connection, so one session; the app keeps the log (interface
/// segregation: four calls, nothing more; dependency inversion: the kit
/// declares it, the app implements it).
public protocol AgentSessionRecorder: Sendable {
    /// An assistant connected: `client` is its `name/version`.
    func opened(_ session: UUID, client: String) async
    /// A call arrived.
    func callBegan(_ session: UUID, call: UUID, tool: String) async
    /// A call ended: what came of it, how long it took, the requests it
    /// made. Answers the call's token in the session log, if it has one.
    func callEnded(_ session: UUID, call: UUID, tool: String, traced: AIToolRouter.Traced) async -> Int?
    /// The assistant left, or the connection dropped.
    func closed(_ session: UUID) async
}

/// Whether an assistant may use Verbinal's tools yet: the person allows a
/// session first (plan 25 M). The bridge asks before every call but the
/// few that start a session.
public protocol AgentSessionGate: Sendable {
    /// Whether the person has allowed `session`.
    func isOpen(_ session: UUID) async -> Bool
}

public enum AgentSession {
    /// The tools that work before a session: starting one, and learning how.
    public static let openBeforeSession: Set<String> = ["start_session", "describe_app"]
    /// Every reply names its session in `_meta`, under Verbinal's own key.
    public static let metaKey = "com.codebg.verbinal/session"
}
