// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Darwin

/// MCP transport over a unix-domain socket, Content-Length framing.
///
/// **Why POSIX, not Network.framework:** under the macOS App Sandbox an
/// `NWListener` configured with `NWParameters.tcp` and a
/// `requiredLocalEndpoint = .unix(path:)` still reports as a TCP-style
/// "definite, server" endpoint to the sandbox network policy daemon and
/// is rejected unless the app holds `com.apple.security.network.server`.
/// Real-world symptom (April 2026 dev session, MAS-style sandbox):
///
/// ```
/// nw_listener_socket_inbox_create_socket bind(5, ::.0) tcp,
///   local: ::.0, definite, attribution: developer, server failed
///   [1: Operation not permitted]
/// ```
///
/// Plain `socket(AF_UNIX, SOCK_STREAM, 0)` + `bind()` to a path inside
/// the app's own Application Support container is purely a filesystem
/// operation and is permitted by the default sandbox profile. So we use
/// POSIX directly, both client and server side.
///
/// **Concurrency model:** the transport spawns one detached read task
/// per connection that blocks in `read(2)` and pushes frames into the
/// `incoming` stream. Sends serialise behind an `NSLock` so concurrent
/// `send` calls never interleave bytes within a single frame. Close is
/// idempotent and safe to call from any task.
public final class SocketTransport: MCPTransport, @unchecked Sendable {

    /// File descriptor for the (potentially-unconnected) endpoint. -1
    /// before `start()` for the client path; valid throughout the
    /// transport's lifetime for the server-accepted path. Mutating
    /// requires `stateLock`.
    private var fd: Int32

    /// Path to connect to, set on the client constructor. `nil` means
    /// the transport already owns a connected fd (server-accepted).
    private let connectingPath: String?

    private let decoder: FrameCodec.Decoder
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var closed: Bool = false
    private var started: Bool = false
    private var readTask: Task<Void, Never>?

    public let incoming: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    // MARK: - Constructors

    /// Wrap a fd that is already connected (server-side after `accept`).
    /// `start()` will begin the read loop on first call; you can also
    /// skip it and the loop will start on first send if needed.
    public init(connectedFD: Int32) {
        self.fd = connectedFD
        self.connectingPath = nil
        self.decoder = FrameCodec.Decoder(mode: .contentLength)

        var c: AsyncThrowingStream<Data, Error>.Continuation!
        self.incoming = AsyncThrowingStream { c = $0 }
        self.continuation = c

        continuation.onTermination = { [weak self] _ in
            self?.tearDown()
        }
    }

    /// Internal init used by the client factory.
    fileprivate init(connectingTo path: String) {
        self.fd = -1
        self.connectingPath = path
        self.decoder = FrameCodec.Decoder(mode: .contentLength)

        var c: AsyncThrowingStream<Data, Error>.Continuation!
        self.incoming = AsyncThrowingStream { c = $0 }
        self.continuation = c

        continuation.onTermination = { [weak self] _ in
            self?.tearDown()
        }
    }

    /// Convenience factory: a transport that will dial `socketPath` on
    /// `start()`.
    public static func client(socketPath: String) -> SocketTransport {
        SocketTransport(connectingTo: socketPath)
    }

    // MARK: - Lifecycle

    /// Begin the connection (if needed) and the read loop. Idempotent.
    public func start() async throws {
        try checkOpen()
        if !markStarted() { return }

        if let path = connectingPath {
            try await connect(to: path)
        }
        beginReceive()
    }

    public func send(_ payload: Data) async throws {
        try checkOpen()
        let framed = FrameCodec.encode(payload, mode: .contentLength)
        try writeAll(framed)
    }

    public func close() async {
        tearDown()
    }

    // MARK: - Connect

    private func connect(to path: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let cfd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard cfd >= 0 else {
                    cont.resume(throwing: MCPTransportError.io(errno, posixMessage()))
                    return
                }
                do {
                    try withUnixAddr(path: path) { addr, len in
                        try ptr(of: &addr) { sptr in
                            let r = Darwin.connect(cfd, sptr, len)
                            if r != 0 {
                                let err = errno
                                Darwin.close(cfd)
                                throw MCPTransportError.io(err, posixMessage(err))
                            }
                        }
                    }
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                self.stateLock.lock()
                self.fd = cfd
                self.stateLock.unlock()
                cont.resume()
            }
        }
    }

    // MARK: - Read loop

    private func beginReceive() {
        readTask = Task.detached(priority: .utility) { [weak self] in
            self?.readLoop()
        }
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            stateLock.lock()
            let isClosed = closed
            let currentFD = fd
            stateLock.unlock()
            if isClosed || currentFD < 0 { return }

            let n: Int = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                return Darwin.read(currentFD, ptr.baseAddress, ptr.count)
            }
            if n == 0 {
                finishStream(with: nil) // clean EOF
                return
            }
            if n < 0 {
                let err = errno
                if err == EINTR { continue }
                finishStream(with: MCPTransportError.io(err, posixMessage(err)))
                return
            }

            let chunk = Data(bytes: buf, count: n)
            do {
                let frames = try feedDecoder(chunk)
                for frame in frames {
                    continuation.yield(frame)
                }
            } catch {
                finishStream(with: MCPTransportError.framing("\(error)"))
                return
            }
        }
    }

    /// Decoder access guarded by `stateLock`; the decoder is a class
    /// with mutable state. Lock is never held across an `await` since
    /// `feed` is synchronous.
    private func feedDecoder(_ chunk: Data) throws -> [Data] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try decoder.feed(chunk)
    }

    // MARK: - Write

    private func writeAll(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        stateLock.lock()
        let writeFD = fd
        stateLock.unlock()
        guard writeFD >= 0 else {
            throw MCPTransportError.closed
        }

        // Linearise; write() can return short — keep going until the
        // whole framed payload has been delivered.
        let total = data.count
        var sent = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw MCPTransportError.io(EINVAL, "empty buffer")
            }
            while sent < total {
                let n = Darwin.write(writeFD, base.advanced(by: sent), total - sent)
                if n < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    throw MCPTransportError.io(err, posixMessage(err))
                }
                sent += n
            }
        }
    }

    // MARK: - Close

    private func tearDown() {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        let closingFD = fd
        fd = -1
        stateLock.unlock()
        readTask?.cancel()
        readTask = nil
        if closingFD >= 0 { _ = Darwin.close(closingFD) }
        continuation.finish()
    }

    private func finishStream(with error: Error?) {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        let closingFD = fd
        fd = -1
        stateLock.unlock()
        if closingFD >= 0 { _ = Darwin.close(closingFD) }
        if let error = error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    // MARK: - State helpers (sync; never held across `await`)

    private func checkOpen() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if closed { throw MCPTransportError.closed }
    }

    private func markStarted() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if started { return false }
        started = true
        return true
    }
}

// MARK: - Listener (server side)

/// Listens on a unix-domain socket path and yields one `SocketTransport`
/// per accepted connection. Plain POSIX `accept(2)` loop on a background
/// queue — no Network.framework, no `network.server` entitlement.
public final class SocketServer: @unchecked Sendable {
    public let socketPath: String
    private var listenFD: Int32 = -1
    private var stopped: Bool = false
    private let stateLock = NSLock()
    private let queue: DispatchQueue

    public let connections: AsyncStream<SocketTransport>
    private let continuation: AsyncStream<SocketTransport>.Continuation

    public init(socketPath: String,
                queue: DispatchQueue = DispatchQueue(label: "MCPCore.SocketServer", qos: .utility)) {
        self.socketPath = socketPath
        self.queue = queue
        var c: AsyncStream<SocketTransport>.Continuation!
        self.connections = AsyncStream { c = $0 }
        self.continuation = c
    }

    /// Bind + listen + spawn the accept loop. Removes any stale socket
    /// file at `socketPath` first.
    public func start() throws {
        stateLock.lock()
        if stopped { stateLock.unlock(); throw MCPTransportError.closed }
        stateLock.unlock()

        try? FileManager.default.removeItem(atPath: socketPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MCPTransportError.io(errno, "socket(): \(posixMessage())")
        }

        do {
            try withUnixAddr(path: socketPath) { addr, len in
                try ptr(of: &addr) { sptr in
                    if Darwin.bind(fd, sptr, len) != 0 {
                        let err = errno
                        Darwin.close(fd)
                        throw MCPTransportError.io(err, "bind(): \(posixMessage(err))")
                    }
                }
            }
        } catch {
            throw error
        }

        if Darwin.listen(fd, 4) != 0 {
            let err = errno
            Darwin.close(fd)
            throw MCPTransportError.io(err, "listen(): \(posixMessage(err))")
        }

        stateLock.lock()
        listenFD = fd
        stateLock.unlock()

        queue.async { [weak self] in
            self?.acceptLoop(fd: fd)
        }
    }

    private func acceptLoop(fd: Int32) {
        while true {
            stateLock.lock()
            let isStopped = stopped
            stateLock.unlock()
            if isStopped { return }

            let cfd = Darwin.accept(fd, nil, nil)
            if cfd < 0 {
                let err = errno
                if err == EINTR { continue }
                // Listener was closed (EBADF) or other terminal error.
                continuation.finish()
                return
            }
            let transport = SocketTransport(connectedFD: cfd)
            // Server-accepted transports begin reading on `start()`;
            // start them here so the consumer (bridge) can drive
            // `serve(on:)` directly without an extra step.
            Task.detached { try? await transport.start() }
            continuation.yield(transport)
        }
    }

    public func stop() {
        stateLock.lock()
        guard !stopped else { stateLock.unlock(); return }
        stopped = true
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()
        if fd >= 0 { _ = Darwin.close(fd) }
        try? FileManager.default.removeItem(atPath: socketPath)
        continuation.finish()
    }
}

// MARK: - Free helpers (file-private to MCPCore)

/// Build a `sockaddr_un` for the given filesystem path. `sun_path` is a
/// fixed 104-byte array on Darwin; reject paths that don't fit (ENAMETOOLONG)
/// rather than silently truncating.
func withUnixAddr(path: String, body: (inout sockaddr_un, socklen_t) throws -> Void) throws {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
    guard pathBytes.count <= maxPathLen else {
        throw MCPTransportError.io(ENAMETOOLONG, "socket path too long: \(path)")
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
        tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxPathLen + 1) { cptr in
            for (i, byte) in pathBytes.enumerated() {
                cptr[i] = CChar(bitPattern: byte)
            }
            cptr[pathBytes.count] = 0
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    try body(&addr, len)
}

func ptr(of addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>) throws -> Void) throws {
    try withUnsafePointer(to: &addr) { (aptr: UnsafePointer<sockaddr_un>) in
        try aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { (sptr: UnsafePointer<sockaddr>) in
            try body(sptr)
        }
    }
}

func posixMessage(_ code: Int32 = errno) -> String {
    String(cString: strerror(code))
}
