// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A random-access byte source for a spectral cube: local (memory-mapped) or
/// remote (HTTP range reads). Mirrors the `DataSource` abstraction in the
/// v-cube web viewer so the same streaming ingest works whether the cube lives
/// on disk or behind a URL — we never need the whole file resident in RAM.
public protocol CubeDataSource: Sendable {
    var name: String { get }
    var size: Int { get }
    /// Read up to `length` bytes at `offset` (fewer only at EOF).
    func read(offset: Int, length: Int) async throws -> Data
}

/// Local file source backed by a memory-mapped `Data`. Plane reads page in on
/// demand, so even multi-GB cubes never fully materialize in physical memory.
public struct LocalFileCubeSource: CubeDataSource {
    public let name: String
    private let data: Data

    public init(url: URL) throws {
        let mapped = try Data(contentsOf: url, options: .mappedIfSafe)
        guard mapped.count <= FITSLimits.maxFileSize else {
            throw FITSError.invalidFile("File too large: \(mapped.count) bytes exceeds 4 GB cap")
        }
        self.data = mapped
        self.name = url.lastPathComponent
    }

    public var size: Int { data.count }

    public func read(offset: Int, length: Int) async throws -> Data {
        guard offset >= 0, length >= 0, offset <= data.count else {
            throw FITSError.invalidFile("Read out of bounds at offset \(offset)")
        }
        let end = Swift.min(offset + length, data.count)
        // subdata copies just the requested pages out of the mmap.
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))
    }
}

/// Remote source backed by HTTP range reads. The transport is injected so
/// `VerbinalKit` stays free of the app's `NetworkClient`: the app supplies a
/// closure that issues `Range: bytes=…` GETs. `size` comes from a prior HEAD /
/// Content-Length probe.
public struct RemoteCubeSource: CubeDataSource {
    public let name: String
    public let size: Int
    private let rangeReader: @Sendable (_ offset: Int, _ length: Int) async throws -> Data

    public init(
        name: String,
        size: Int,
        rangeReader: @escaping @Sendable (_ offset: Int, _ length: Int) async throws -> Data
    ) {
        self.name = name
        self.size = size
        self.rangeReader = rangeReader
    }

    public func read(offset: Int, length: Int) async throws -> Data {
        guard offset >= 0, length >= 0, offset <= size else {
            throw FITSError.invalidFile("Read out of bounds at offset \(offset)")
        }
        let clamped = Swift.min(length, size - offset)
        return try await rangeReader(offset, clamped)
    }
}
