// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore
import VerbinalKit

/// The agent connections the server serves now, each with its bridge once
/// it has one: kept so a shutdown closes them promptly, and the person can
/// close one by its session (plan 52 C2).
@MainActor
final class AgentConnectionRoster {
    private var connections: [UUID: (transport: SocketTransport, bridge: MCPBridgeService?)] = [:]

    /// A connection accepted; its token, until it ends.
    func add(_ transport: SocketTransport) -> UUID {
        let token = UUID()
        connections[token] = (transport, nil)
        return token
    }

    /// The bridge serving the connection of `token`.
    func attach(_ bridge: MCPBridgeService, to token: UUID) {
        connections[token]?.bridge = bridge
    }

    func remove(_ token: UUID) {
        connections[token] = nil
    }

    /// Closes the connection serving `session`, its relay told why.
    func close(serving session: UUID, telling reason: String) async {
        var serving: [SocketTransport] = []
        for (transport, bridge) in connections.values {
            if let bridge, await bridge.session == session { serving.append(transport) }
        }
        await Self.close(serving, telling: reason)
    }

    /// Closes every connection — each relay told why, when there is a
    /// reason; without one, relays wait for the next server.
    func closeAll(telling reason: String?) {
        let all = connections.values.map(\.transport)
        connections.removeAll()
        guard !all.isEmpty else { return }
        Task { await Self.close(all, telling: reason) }
    }

    private static func close(_ transports: [SocketTransport], telling reason: String?) async {
        for transport in transports {
            if let reason { try? await transport.send(AgentSession.relayClose(reason: reason)) }
            await transport.close()
        }
    }
}
