// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore
import Observation
import VerbinalKit

/// The assistants connected now, and closing one (plan 52 C). It hears the
/// bridge as the session log does, and closes through the hooks the app
/// sets — a session's end, and its connection's — so it knows neither the
/// server nor the approvals (dependency inversion).
@MainActor
@Observable
final class AssistantConnections {
    /// Oldest first.
    private(set) var connections: [AssistantConnection] = []

    /// What an assistant reads when the person closes its connection.
    static let closedReason = "The person closed this assistant's connection in Verbinal."

    /// Ends a session, as the person ending it would.
    @ObservationIgnored var endSession: (@MainActor (UUID) -> Void)?
    /// Closes the connection serving a session, its relay told why.
    @ObservationIgnored var disconnect: (@MainActor (_ session: UUID, _ reason: String) async -> Void)?
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// The bridge's side: what it tells, told to this list.
    nonisolated var recorder: any AgentSessionRecorder { Recorder(list: self) }

    // MARK: - What the bridge tells

    func opened(_ session: UUID, client: String, relay: RelayIdentity?) {
        if let i = index(of: session) {
            // The same relay, back after Verbinal restarted (plan 34 S).
            connections[i].client = client
            connections[i].relay = relay
        } else {
            connections.append(AssistantConnection(session: session, client: client, relay: relay, connected: now()))
        }
    }

    func called(_ session: UUID) {
        guard let i = index(of: session) else { return }
        connections[i].lastCall = now()
        connections[i].calls += 1
    }

    func closed(_ session: UUID) {
        connections.removeAll { $0.session == session }
    }

    // MARK: - The person's

    /// Closes `session`'s connection: its session ends, and its relay is
    /// told why and exits, so its client sees its server end.
    func close(_ session: UUID) async {
        endSession?(session)
        await disconnect?(session, Self.closedReason)
    }

    func closeAll() async {
        for connection in connections { await close(connection.session) }
    }

    private func index(of session: UUID) -> Int? {
        connections.firstIndex { $0.session == session }
    }

    /// Tells the list, on the main actor, what the bridge tells a recorder.
    private struct Recorder: AgentSessionRecorder {
        let list: AssistantConnections

        func opened(_ session: UUID, client: String, relay: RelayIdentity?) async {
            await list.opened(session, client: client, relay: relay)
        }

        func callBegan(_ session: UUID, call: UUID, tool: String) async {
            await list.called(session)
        }

        func callEnded(_ session: UUID, call: UUID, tool: String, traced: AIToolRouter.Traced) async -> Int? { nil }

        func closed(_ session: UUID) async {
            await list.closed(session)
        }
    }
}
