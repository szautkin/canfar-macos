// SPDX-License-Identifier: MPL-2.0

import Foundation
@testable import MCPCore

/// In-process pair of stub transports: anything one side sends, the other
/// side receives. Drives `MCPBridgeService.serve` through a real-shape
/// JSON-RPC conversation without sockets.
final class PairTransport: MCPTransport, @unchecked Sendable {
    let incoming: AsyncThrowingStream<Data, Error>
    let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation
    var peer: PairTransport?
    private let stateLock = NSLock()
    private var closed = false

    init() {
        var c: AsyncThrowingStream<Data, Error>.Continuation!
        self.incoming = AsyncThrowingStream { c = $0 }
        self.inboundContinuation = c
    }

    /// Two transports wired to each other.
    static func makePair() -> (PairTransport, PairTransport) {
        let a = PairTransport()
        let b = PairTransport()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    func send(_ payload: Data) async throws {
        if stateLock.withLock({ closed }) { throw MCPTransportError.closed }
        peer?.inboundContinuation.yield(payload)
    }

    func close() async {
        let wasOpen = stateLock.withLock {
            defer { closed = true }
            return !closed
        }
        if wasOpen { inboundContinuation.finish() }
    }
}
