// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Network

/// MCP transport over a unix-domain socket, Content-Length framing.
///
/// Used at both ends of the helper↔app channel:
///
///   * The helper creates a `client(socketPath:)` connection to the app's
///     listener path (read from the sidecar file).
///   * The app's `SocketServer` creates one `SocketTransport` per accepted
///     `NWConnection`.
///
/// Concurrency: wraps `NWConnection`, which is documented thread-safe.
/// The receive loop runs on a private dispatch queue and pushes payloads
/// into `incoming`. Sends serialise via the connection's own internal queue
/// — Network framework guarantees ordering for back-to-back `send` calls.
public final class SocketTransport: MCPTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let decoder: FrameCodec.Decoder
    private let stateLock = NSLock()
    private var closed: Bool = false
    private var started: Bool = false

    public let incoming: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    /// Create a transport wrapping an existing connection.
    /// The caller must invoke `start()` before sending or receiving.
    public init(connection: NWConnection,
                queue: DispatchQueue = DispatchQueue(label: "MCPCore.SocketTransport")) {
        self.connection = connection
        self.queue = queue
        self.decoder = FrameCodec.Decoder(mode: .contentLength)

        var c: AsyncThrowingStream<Data, Error>.Continuation!
        self.incoming = AsyncThrowingStream { c = $0 }
        self.continuation = c

        continuation.onTermination = { [weak self] _ in
            self?.tearDown()
        }
    }

    /// Convenience factory: create a *client* transport that will connect
    /// to the listener at `socketPath`.
    public static func client(socketPath: String,
                              queue: DispatchQueue = DispatchQueue(label: "MCPCore.SocketTransport.client")) -> SocketTransport {
        let endpoint = NWEndpoint.unix(path: socketPath)
        // `NWParameters.tcp` selects a stream-style protocol stack — over a
        // unix endpoint that means SOCK_STREAM, not TCP/IP.
        let params = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: params)
        return SocketTransport(connection: connection, queue: queue)
    }

    /// Begin the connection. Idempotent; subsequent calls no-op. Throws if
    /// the connection fails before becoming ready.
    public func start() async throws {
        try checkOpen()
        if !markStarted() { return }

        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    if once.tryFire() { cont.resume() }
                    self.beginReceive()
                case .failed(let err):
                    let mapped = MCPTransportError.io(Int32(err.errorCode), "\(err)")
                    if once.tryFire() {
                        cont.resume(throwing: mapped)
                    } else {
                        self.finishStream(with: mapped)
                    }
                case .cancelled:
                    if once.tryFire() {
                        cont.resume(throwing: MCPTransportError.closed)
                    } else {
                        self.finishStream(with: nil)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func beginReceive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                self.finishStream(with: MCPTransportError.io(Int32(error.errorCode), "\(error)"))
                return
            }
            if let chunk = chunk, !chunk.isEmpty {
                self.stateLock.lock()
                let alreadyClosed = self.closed
                self.stateLock.unlock()
                if alreadyClosed { return }

                do {
                    self.stateLock.lock()
                    let frames = try self.decoder.feed(chunk)
                    self.stateLock.unlock()
                    for frame in frames {
                        self.continuation.yield(frame)
                    }
                } catch {
                    self.stateLock.unlock()
                    self.finishStream(with: MCPTransportError.framing("\(error)"))
                    return
                }
            }
            if isComplete {
                self.finishStream(with: nil)
                return
            }
            self.beginReceive() // continue reading
        }
    }

    public func send(_ payload: Data) async throws {
        try checkOpen()
        let framed = FrameCodec.encode(payload, mode: .contentLength)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error = error {
                    cont.resume(throwing: MCPTransportError.io(Int32(error.errorCode), "\(error)"))
                } else {
                    cont.resume()
                }
            })
        }
    }

    public func close() async {
        tearDown()
    }

    // MARK: - Internals

    private func tearDown() {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        stateLock.unlock()
        connection.cancel()
        continuation.finish()
    }

    private func finishStream(with error: Error?) {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        stateLock.unlock()
        if let error = error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        connection.cancel()
    }

    private func checkOpen() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if closed { throw MCPTransportError.closed }
    }

    /// Atomically transition the transport from "not started" to
    /// "started". Returns `true` on the first call, `false` thereafter
    /// so subsequent calls are silent no-ops.
    private func markStarted() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if started { return false }
        started = true
        return true
    }
}

// MARK: - OnceFlag

/// Reference-typed "fire once" guard. Replaces a captured `var Bool` in
/// closure-heavy code paths so we don't trip Swift 6's
/// `SendableClosureCaptures` diagnostic.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func tryFire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

// MARK: - Listener (server side)

/// Listens on a unix-domain socket path and yields one `SocketTransport`
/// per accepted connection.
///
/// Used by the host app: it starts a `SocketServer`, writes its socket
/// path through `SocketSidecar`, and serves each incoming transport with
/// the MCP bridge.
public final class SocketServer: @unchecked Sendable {
    public let socketPath: String
    private let queue: DispatchQueue
    private var listener: NWListener?
    private let stateLock = NSLock()
    private var stopped: Bool = false

    public let connections: AsyncStream<SocketTransport>
    private let continuation: AsyncStream<SocketTransport>.Continuation

    public init(socketPath: String,
                queue: DispatchQueue = DispatchQueue(label: "MCPCore.SocketServer")) {
        self.socketPath = socketPath
        self.queue = queue
        var c: AsyncStream<SocketTransport>.Continuation!
        self.connections = AsyncStream { c = $0 }
        self.continuation = c
    }

    /// Begin listening. Removes any stale socket file at the path first.
    /// Throws if listener creation or start fails.
    public func start() throws {
        stateLock.lock()
        if stopped { stateLock.unlock(); throw MCPTransportError.closed }
        stateLock.unlock()

        // Remove any stale socket file before binding.
        try? FileManager.default.removeItem(atPath: socketPath)

        let endpoint = NWEndpoint.unix(path: socketPath)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = endpoint
        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            let transport = SocketTransport(connection: conn, queue: self.queue)
            // Start the connection on its own task so the server keeps
            // accepting peers while individual handshakes proceed.
            Task.detached {
                try? await transport.start()
            }
            self.continuation.yield(transport)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed:
                self?.stop()
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    /// Stop accepting connections and remove the socket file. Idempotent.
    public func stop() {
        stateLock.lock()
        guard !stopped else { stateLock.unlock(); return }
        stopped = true
        stateLock.unlock()
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(atPath: socketPath)
        continuation.finish()
    }
}
