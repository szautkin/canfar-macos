// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A bidirectional byte-oriented transport carrying MCP JSON-RPC envelopes.
///
/// Implementations frame and de-frame on the caller's behalf — `send`
/// accepts a raw payload (one JSON document) and `incoming` yields raw
/// payloads (one JSON document each). The framing rule lives in the
/// transport, not in the bridge service that consumes it.
///
/// Implementations are expected to be safe to share across concurrent
/// tasks. Each conformance documents its concurrency model in its header.
public protocol MCPTransport: AnyObject, Sendable {
    /// A stream of incoming payloads. Each element is one complete JSON-RPC
    /// document body (no framing). The stream finishes when the peer closes
    /// the connection cleanly; it throws if framing breaks or I/O fails.
    ///
    /// Consume this stream from exactly one task. Calling `incoming`
    /// multiple times on the same transport instance is undefined.
    var incoming: AsyncThrowingStream<Data, Error> { get }

    /// Send one JSON-RPC document. The transport adds framing and writes
    /// the bytes atomically — concurrent `send` calls will not interleave
    /// frame bytes (each call writes one complete frame).
    func send(_ payload: Data) async throws

    /// Tear the transport down. Idempotent. After `close`, `incoming`
    /// finishes and `send` throws.
    func close() async
}

/// Surface error type for transports. Bridges between `Errno`/POSIX and
/// the higher-level "the link broke" outcome consumers care about.
public enum MCPTransportError: Error, Sendable, Equatable, LocalizedError {
    /// Local end was already closed when the operation was attempted.
    case closed
    /// Peer closed the connection (clean EOF / FIN).
    case peerClosed
    /// Underlying I/O failure with a POSIX-style error code.
    case io(Int32, String)
    /// Wire-level frame parsing failure.
    case framing(String)

    public static func == (lhs: MCPTransportError, rhs: MCPTransportError) -> Bool {
        switch (lhs, rhs) {
        case (.closed, .closed), (.peerClosed, .peerClosed): return true
        case (.io(let l, _), .io(let r, _)): return l == r
        case (.framing(let l), .framing(let r)): return l == r
        default: return false
        }
    }

    /// Human-readable description used by `Error.localizedDescription`
    /// — so SwiftUI surfaces ("Listener start failed: …") show the real
    /// failure reason, not the bare type name.
    public var errorDescription: String? {
        switch self {
        case .closed:           return "Transport is closed."
        case .peerClosed:       return "Peer closed the connection."
        case .io(let code, let msg):
            return "I/O error (errno \(code)): \(msg)"
        case .framing(let msg): return "Framing error: \(msg)"
        }
    }
}
