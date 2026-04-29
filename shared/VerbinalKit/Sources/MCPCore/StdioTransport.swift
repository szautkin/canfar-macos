// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Darwin

/// MCP transport over standard input / standard output, ndjson framing.
///
/// Used by the `canfar-mcp` helper executable when spawned as a subprocess
/// by an MCP client (Claude Desktop, etc.).
///
/// **Read path:** direct `Darwin.read(fd:buf:len:)` on a detached worker.
/// We do **not** use `FileHandle.readabilityHandler` / `availableData`
/// because, against a parent-inherited pipe (what Claude Desktop hands us
/// as stdin), those don't reliably wake up on data arrival — short
/// messages like MCP `initialize` are buffered until the client times out
/// and closes stdin (the verbinal-thought project caught this as a
/// 60-second stall in real usage). The fix is to call `read(2)` directly
/// from a `Task.detached(priority: .utility)` so the cooperative thread
/// pool isn't pinned by a blocking syscall and the kernel wakes us as
/// soon as bytes arrive.
///
/// **Write path:** linearised by an `NSLock` so concurrent senders never
/// interleave bytes within a frame. Closes are idempotent.
///
/// **EOF handling:** stream finishes cleanly on `read` returning 0
/// (writer end of the pipe closed) — that's the conventional "client
/// disconnected" signal. After that all `send` calls throw `.closed`.
public final class StdioTransport: MCPTransport, @unchecked Sendable {
    private let stdinFD: Int32
    private let stdout: FileHandle
    private let decoder: FrameCodec.Decoder
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var closed: Bool = false
    private var readTask: Task<Void, Never>?

    public let incoming: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    /// Create a stdio transport. Defaults to the process's stdin/stdout;
    /// inject other handles for unit tests.
    public init(
        stdin: FileHandle = .standardInput,
        stdout: FileHandle = .standardOutput
    ) {
        self.stdinFD = stdin.fileDescriptor
        self.stdout = stdout
        self.decoder = FrameCodec.Decoder(mode: .ndjson)

        var c: AsyncThrowingStream<Data, Error>.Continuation!
        self.incoming = AsyncThrowingStream { c = $0 }
        self.continuation = c

        continuation.onTermination = { [weak self] _ in
            self?.tearDown()
        }

        beginReceive()
    }

    // MARK: - Read loop

    private func beginReceive() {
        readTask = Task.detached(priority: .utility) { [weak self] in
            self?.readLoop()
        }
    }

    /// Direct-syscall read loop. Runs on a detached worker thread so the
    /// blocking read never starves the cooperative pool.
    private func readLoop() {
        let chunkSize = 4096
        var buf = [UInt8](repeating: 0, count: chunkSize)
        while true {
            stateLock.lock()
            let isClosed = closed
            stateLock.unlock()
            if isClosed { return }

            let n: Int = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(stdinFD, ptr.baseAddress, ptr.count)
            }
            if n == 0 {
                finishStream(with: nil) // EOF — clean disconnect
                return
            }
            if n < 0 {
                let err = errno
                if err == EINTR { continue }
                finishStream(with: MCPTransportError.io(err, String(cString: strerror(err))))
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

    private func feedDecoder(_ chunk: Data) throws -> [Data] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try decoder.feed(chunk)
    }

    // MARK: - Send / close

    public func send(_ payload: Data) async throws {
        try checkOpen()
        let framed = FrameCodec.encode(payload, mode: .ndjson)
        try writeFramed(framed)
    }

    public func close() async {
        tearDown()
    }

    // MARK: - Sync helpers (locks confined here so they're never held
    // across an `await` suspension point)

    private func writeFramed(_ framed: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try stdout.write(contentsOf: framed)
        } catch {
            let nsErr = error as NSError
            throw MCPTransportError.io(Int32(nsErr.code), nsErr.localizedDescription)
        }
    }

    private func checkOpen() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if closed { throw MCPTransportError.closed }
    }

    private func tearDown() {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        stateLock.unlock()
        readTask?.cancel()
        readTask = nil
        continuation.finish()
    }

    private func finishStream(with error: Error?) {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        stateLock.unlock()
        readTask?.cancel()
        readTask = nil
        if let error = error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
