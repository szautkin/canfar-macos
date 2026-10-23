// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A FITS file read where it is, over HTTP ranges (plan 47 3.2, and the remote
/// cubes of 5.1). The parser reads headers a 2880-byte block at a time, so
/// small reads are served from aligned chunks read ahead and kept a while: a
/// whole header costs one request. A read larger than a chunk — a cube's
/// plane — goes as it is, and is not kept.
public actor RemoteCubeDataSource: CubeDataSource {
    public nonisolated let name: String
    public nonisolated let size: Int

    /// Reads exactly `length` bytes at `offset` (fewer only at the end).
    public typealias Fetch = @Sendable (_ offset: Int, _ length: Int) async throws -> Data

    private let fetch: Fetch
    private let chunkSize: Int
    private let keptChunks: Int
    /// Chunks by index, and their order of use (most recent last).
    private var chunks: [Int: Data] = [:]
    private var used: [Int] = []

    public init(name: String, size: Int, chunkSize: Int = 256 * 1024, keptChunks: Int = 16, fetch: @escaping Fetch) {
        self.name = name
        self.size = size
        self.chunkSize = chunkSize
        self.keptChunks = keptChunks
        self.fetch = fetch
    }

    public func read(offset: Int, length: Int) async throws -> Data {
        guard offset >= 0, length >= 0, offset <= size else {
            throw FITSError.invalidFile("Read out of bounds at offset \(offset)")
        }
        let end = min(offset + length, size)
        guard end > offset else { return Data() }
        guard end - offset <= chunkSize else { return try await fetch(offset, end - offset) }

        var result = Data()
        result.reserveCapacity(end - offset)
        var position = offset
        while position < end {
            let index = position / chunkSize
            let chunk = try await self.chunk(index)
            let start = position - index * chunkSize
            let stop = min(chunk.count, end - index * chunkSize)
            guard start < stop else { break }
            result.append(chunk[chunk.startIndex + start ..< chunk.startIndex + stop])
            position = index * chunkSize + stop
        }
        return result
    }

    private func chunk(_ index: Int) async throws -> Data {
        if let kept = chunks[index] {
            used.removeAll { $0 == index }
            used.append(index)
            return kept
        }
        let start = index * chunkSize
        let data = try await fetch(start, min(chunkSize, size - start))
        chunks[index] = data
        used.append(index)
        while used.count > keptChunks {
            chunks[used.removeFirst()] = nil
        }
        return data
    }
}

/// A server that answered with the whole file where part of it was asked for.
public struct RangeNotSupported: LocalizedError, Equatable {
    public init() {}
    public var errorDescription: String? {
        String(localized: "The server sends this file only whole, so it cannot be read where it is. Download it to look at it.")
    }
}
