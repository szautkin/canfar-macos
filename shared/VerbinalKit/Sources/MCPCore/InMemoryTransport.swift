// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Two transports wired to each other in memory: whatever one side sends,
/// the other receives. For in-process wiring and for driving a server or
/// the bridge through a real-shape JSON-RPC conversation in tests.
public final class InMemoryTransport: MCPTransport, @unchecked Sendable {
    public let incoming: AsyncThrowingStream<Data, Error>
    private let inbound: AsyncThrowingStream<Data, Error>.Continuation
    private weak var peer: InMemoryTransport?
    private let stateLock = NSLock()
    private var closed = false

    private init() {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        incoming = AsyncThrowingStream { continuation = $0 }
        inbound = continuation
    }

    /// Two connected ends. Closing either finishes both streams.
    public static func pair() -> (InMemoryTransport, InMemoryTransport) {
        let a = InMemoryTransport()
        let b = InMemoryTransport()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    public func send(_ payload: Data) async throws {
        if stateLock.withLock({ closed }) { throw MCPTransportError.closed }
        peer?.inbound.yield(payload)
    }

    public func close() async {
        let wasOpen = stateLock.withLock {
            defer { closed = true }
            return !closed
        }
        guard wasOpen else { return }
        inbound.finish()
        await peer?.close()
    }
}
