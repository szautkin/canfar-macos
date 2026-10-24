// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What a ranged read got.
public struct RangeRead: Sendable, Equatable {
    /// The bytes asked for; fewer at the end of the file, none past it.
    public let data: Data
    /// The whole file's size, when the server said.
    public let totalBytes: Int?
    /// False when the server answered with the whole file (200) instead of the
    /// range: `data` is then the file's start, and only when the read began at 0.
    public let honoredRange: Bool

    public init(data: Data, totalBytes: Int?, honoredRange: Bool) {
        self.data = data
        self.totalBytes = totalBytes
        self.honoredRange = honoredRange
    }
}

extension NetworkClient {
    /// `length` bytes from `offset`, streamed, so no more than that is ever
    /// held (plan 47 3.1). ARC answers some paths with 200 and the whole file
    /// whatever `Range` said: then only the file's start up to `length` is
    /// read, and the transfer is cancelled — a 3 GB cube never lands in a
    /// phone's memory. Past the end (416), no bytes.
    public func getRange(_ urlString: String, offset: Int, length: Int,
                         timeout: TimeInterval = RequestTimeout.standard) async throws -> RangeRead {
        precondition(offset >= 0 && length > 0, "a range starts at 0 or later and asks for at least a byte")
        var request = try makeRequest(urlString, method: "GET", timeout: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        return try await retryUnauthorized(original: request) { try await self.getRangeOnce($0, offset: offset, length: length) }
    }

    private func getRangeOnce(_ request: URLRequest, offset: Int, length: Int) async throws -> RangeRead {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.recordedBytes(for: request, in: ledger)
        } catch {
            throw mapTransferCancellation(error)
        }
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
        defer { bytes.task.cancel() }
        switch http.statusCode {
        case 206:
            return RangeRead(data: try await Self.read(bytes, upTo: length),
                             totalBytes: Self.contentRangeTotal(http), honoredRange: true)
        case 200:
            let total = http.expectedContentLength > 0 ? Int(http.expectedContentLength) : nil
            // The whole file: its start is the range only when the range began there.
            let data = offset == 0 ? try await Self.read(bytes, upTo: length) : Data()
            return RangeRead(data: data, totalBytes: total, honoredRange: false)
        case 416:
            return RangeRead(data: Data(), totalBytes: Self.contentRangeTotal(http), honoredRange: true)
        case 401:
            throw NetworkError.unauthorized
        default:
            let body = String(data: try await Self.read(bytes, upTo: 500), encoding: .utf8) ?? ""
            throw NetworkError.httpError(http.statusCode, body)
        }
    }

    /// Up to `limit` bytes of the body; reading stops there.
    private static func read(_ bytes: URLSession.AsyncBytes, upTo limit: Int) async throws -> Data {
        var data = Data()
        data.reserveCapacity(min(limit, 1 << 20))
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }

    /// `Content-Range: bytes 0-99/1000` → 1000; nil for `*` or none.
    static func contentRangeTotal(_ response: HTTPURLResponse) -> Int? {
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
              let slash = header.lastIndex(of: "/") else { return nil }
        return Int(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}
