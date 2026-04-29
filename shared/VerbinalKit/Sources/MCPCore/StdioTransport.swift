// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// MCP transport over standard input / standard output, ndjson framing.
///
/// Used by the `canfar-mcp` helper executable when spawned as a subprocess
/// by an MCP client (Claude Desktop, etc.). Writes are serialised against
/// an internal lock so concurrent senders never interleave bytes mid-frame;
/// reads are driven from `FileHandle.readabilityHandler` on a background
/// queue and pushed into an `AsyncThrowingStream`.
///
/// The transport finishes its `incoming` stream when stdin reports EOF —
/// that's the host's signal that the client disconnected. After that all
/// `send` calls throw `.closed`.
public final class StdioTransport: MCPTransport, @unchecked Sendable {
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let decoder: FrameCodec.Decoder
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var closed: Bool = false

    public let incoming: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    /// Create a stdio transport. Defaults to the process's stdin/stdout;
    /// inject other handles for unit tests.
    public init(
        stdin: FileHandle = .standardInput,
        stdout: FileHandle = .standardOutput
    ) {
        self.stdin = stdin
        self.stdout = stdout
        self.decoder = FrameCodec.Decoder(mode: .ndjson)

        var c: AsyncThrowingStream<Data, Error>.Continuation!
        self.incoming = AsyncThrowingStream { c = $0 }
        self.continuation = c

        startReading()
    }

    private func startReading() {
        // FileHandle.readabilityHandler runs the closure on a private
        // dispatch queue — chunks may arrive concurrently with sends.
        // The decoder is mutable state; serialise via the state lock.
        stdin.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                self.finishStream(with: nil) // clean EOF
                return
            }
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
            }
        }

        continuation.onTermination = { [weak self] _ in
            self?.detachReader()
        }
    }

    private func detachReader() {
        // Drop the readabilityHandler so the FileHandle stops feeding data.
        stdin.readabilityHandler = nil
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
        detachReader()
    }

    public func send(_ payload: Data) async throws {
        try checkOpen()
        let framed = FrameCodec.encode(payload, mode: .ndjson)
        try writeFramed(framed)
    }

    public func close() async {
        finishStream(with: nil)
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
}
