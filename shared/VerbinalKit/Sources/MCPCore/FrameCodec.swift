// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Wire framing for MCP transports.
///
/// MCP carries JSON-RPC envelopes over two distinct framings depending on
/// the transport:
///
///   * **`.ndjson`** — newline-delimited JSON. One JSON document per line,
///     terminated by a single `\n`. This is what stdio uses (Claude Desktop,
///     other agent runtimes that spawn the helper as a subprocess).
///   * **`.contentLength`** — LSP-style headers: `Content-Length: N\r\n\r\n`
///     followed by exactly N body bytes. Used over local sockets where the
///     receiver can preallocate buffers.
///
/// Encoding is a one-shot pure function. Decoding is streaming: the caller
/// feeds chunks of bytes as they arrive and receives complete payloads.
public enum FrameCodec {
    public enum Mode: Sendable, Equatable {
        case ndjson
        case contentLength
    }

    /// Hard cap on a single frame's body size (16 MB). Defends against a
    /// malicious or buggy peer that announces an outrageous Content-Length.
    public static let maxFrameBytes: Int = 16 * 1024 * 1024

    /// Hard cap on the decoder's internal buffer (32 MB). If a peer sends
    /// data that never resolves into a complete frame (no newline, no
    /// header terminator) we error out rather than growing forever.
    public static let maxBufferBytes: Int = 32 * 1024 * 1024

    public enum DecodeError: Error, Equatable {
        case invalidHeader
        case missingContentLength
        case bodyTooLarge(declared: Int, max: Int)
        case bufferOverflow(have: Int, max: Int)
    }

    // MARK: - Encoding

    /// Frame a single payload. `payload` is the raw JSON-RPC document bytes.
    public static func encode(_ payload: Data, mode: Mode) -> Data {
        switch mode {
        case .ndjson:
            var out = Data(capacity: payload.count + 1)
            out.append(payload)
            out.append(0x0A) // LF
            return out
        case .contentLength:
            let header = "Content-Length: \(payload.count)\r\n\r\n"
            var out = Data(capacity: header.utf8.count + payload.count)
            out.append(contentsOf: header.utf8)
            out.append(payload)
            return out
        }
    }

    // MARK: - Streaming decoder

    /// Streaming decoder: feed bytes as they arrive, receive zero or more
    /// complete payloads back. Internally buffers partial frames.
    ///
    /// The decoder is a class (not a struct) because it owns mutable state
    /// across many calls. Not Sendable — wrap accesses in a lock or actor
    /// if you need cross-task safety.
    public final class Decoder {
        public let mode: Mode
        public let maxFrameBytes: Int
        public let maxBufferBytes: Int

        private var buffer: [UInt8] = []
        /// In `.contentLength` mode: once we've parsed the header, the body
        /// length is staged here until enough body bytes have arrived.
        private var pendingBodyLength: Int?

        public init(
            mode: Mode,
            maxFrameBytes: Int = FrameCodec.maxFrameBytes,
            maxBufferBytes: Int = FrameCodec.maxBufferBytes
        ) {
            self.mode = mode
            self.maxFrameBytes = maxFrameBytes
            self.maxBufferBytes = maxBufferBytes
            buffer.reserveCapacity(4096)
        }

        /// Feed an incoming chunk. Returns every complete frame that became
        /// extractable as a result. Throws on malformed input or budget
        /// violation; thereafter the decoder's state is undefined and the
        /// caller should discard it.
        public func feed(_ chunk: Data) throws -> [Data] {
            buffer.append(contentsOf: chunk)
            if buffer.count > maxBufferBytes {
                throw DecodeError.bufferOverflow(have: buffer.count, max: maxBufferBytes)
            }
            var out: [Data] = []
            while let frame = try extractOne() {
                out.append(frame)
            }
            return out
        }

        // MARK: Private

        private func extractOne() throws -> Data? {
            switch mode {
            case .ndjson:
                return try extractNdjson()
            case .contentLength:
                return try extractContentLength()
            }
        }

        private func extractNdjson() throws -> Data? {
            guard let nlIdx = buffer.firstIndex(of: 0x0A) else { return nil }
            // Skip empty lines (some peers send keep-alive newlines).
            if nlIdx == 0 {
                buffer.removeFirst(1)
                return Data()  // empty payload, but well-formed
            }
            // CR before LF? strip it (tolerate \r\n line endings)
            var bodyEnd = nlIdx
            if bodyEnd > 0 && buffer[bodyEnd - 1] == 0x0D {
                bodyEnd -= 1
            }
            if bodyEnd > maxFrameBytes {
                throw DecodeError.bodyTooLarge(declared: bodyEnd, max: maxFrameBytes)
            }
            let payload = Data(buffer[..<bodyEnd])
            buffer.removeFirst(nlIdx + 1)
            return payload
        }

        private func extractContentLength() throws -> Data? {
            // If a body length is staged, try to satisfy it.
            if let length = pendingBodyLength {
                guard buffer.count >= length else { return nil }
                let payload = Data(buffer.prefix(length))
                buffer.removeFirst(length)
                pendingBodyLength = nil
                return payload
            }
            // Otherwise, look for the header terminator (\r\n\r\n).
            guard let endIdx = findHeaderEnd() else { return nil }
            let headerBytes = buffer[..<endIdx]
            guard let header = String(bytes: headerBytes, encoding: .utf8) else {
                throw DecodeError.invalidHeader
            }
            buffer.removeFirst(endIdx + 4) // 4 = \r\n\r\n

            // Parse header lines (case-insensitive key matching).
            var declaredLength: Int?
            for line in header.split(separator: "\r\n", omittingEmptySubsequences: true) {
                guard let colonOffset = line.firstIndex(of: ":") else { continue }
                let key = line[..<colonOffset]
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                let value = line[line.index(after: colonOffset)...]
                    .trimmingCharacters(in: .whitespaces)
                if key == "content-length" {
                    declaredLength = Int(value)
                }
            }
            guard let length = declaredLength, length >= 0 else {
                throw DecodeError.missingContentLength
            }
            if length > maxFrameBytes {
                throw DecodeError.bodyTooLarge(declared: length, max: maxFrameBytes)
            }
            pendingBodyLength = length
            return try extractContentLength() // tail-call to satisfy now if buffer has it
        }

        /// Locate the four-byte sequence `\r\n\r\n`.
        private func findHeaderEnd() -> Int? {
            let pattern: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
            guard buffer.count >= pattern.count else { return nil }
            outer: for i in 0...(buffer.count - pattern.count) {
                for j in 0..<pattern.count where buffer[i + j] != pattern[j] {
                    continue outer
                }
                return i
            }
            return nil
        }
    }
}
