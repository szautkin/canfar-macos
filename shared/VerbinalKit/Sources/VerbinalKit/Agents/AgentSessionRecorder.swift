// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore

/// What the MCP bridge tells the session log: a session opened, a call
/// began and ended, the session closed (plan 23 L2). The bridge serves one
/// connection, so one session; the app keeps the log (interface
/// segregation: four calls, nothing more; dependency inversion: the kit
/// declares it, the app implements it).
public protocol AgentSessionRecorder: Sendable {
    /// An assistant connected: `client` is its `name/version`; `relay` who
    /// its relay is, when it said (plan 52 A6).
    func opened(_ session: UUID, client: String, relay: RelayIdentity?) async
    /// A call arrived.
    func callBegan(_ session: UUID, call: UUID, tool: String) async
    /// A call ended: what came of it, how long it took, the requests it
    /// made. Answers the call's token in the session log, if it has one.
    func callEnded(_ session: UUID, call: UUID, tool: String, traced: AIToolRouter.Traced) async -> Int?
    /// The assistant left, or the connection dropped.
    func closed(_ session: UUID) async
}

/// Several recorders as one (plan 52 C): the session log and the list of
/// connected assistants hear the same bridge, which knows of neither.
public struct AgentSessionRecorders: AgentSessionRecorder {
    private let recorders: [any AgentSessionRecorder]

    public init(_ recorders: [any AgentSessionRecorder]) { self.recorders = recorders }

    public func opened(_ session: UUID, client: String, relay: RelayIdentity?) async {
        for recorder in recorders { await recorder.opened(session, client: client, relay: relay) }
    }

    public func callBegan(_ session: UUID, call: UUID, tool: String) async {
        for recorder in recorders { await recorder.callBegan(session, call: call, tool: tool) }
    }

    /// The first token any of them answers: the session log's.
    public func callEnded(_ session: UUID, call: UUID, tool: String, traced: AIToolRouter.Traced) async -> Int? {
        var token: Int?
        for recorder in recorders {
            let answered = await recorder.callEnded(session, call: call, tool: tool, traced: traced)
            token = token ?? answered
        }
        return token
    }

    public func closed(_ session: UUID) async {
        for recorder in recorders { await recorder.closed(session) }
    }
}

/// Whether an assistant may use Verbinal's tools yet: the person allows a
/// session first (plan 25 M). The bridge asks before every call but the
/// few that start a session.
public protocol AgentSessionGate: Sendable {
    /// Whether the person has allowed `session`. A call it lets through
    /// counts as the session's use.
    func isOpen(_ session: UUID) async -> Bool
    /// Why `session`, once allowed, is not any more — said to the assistant
    /// (plan 34 S); nil when it was never allowed.
    func endedBecause(_ session: UUID) async -> String?
}

public extension AgentSessionGate {
    func endedBecause(_ session: UUID) async -> String? { nil }
}

/// Which session a connection continues (plan 34 S): the relay an assistant
/// launched introduces itself with a secret, and a reconnection of the same
/// relay — after Verbinal restarts — is the same session, with its log and
/// the person's answer.
public protocol AgentSessionContinuity: Sendable {
    /// The session the relay of `fingerprint` had; `fresh`, now the relay's,
    /// when it had none.
    func session(forRelay fingerprint: String, fresh: UUID) async -> UUID
}

