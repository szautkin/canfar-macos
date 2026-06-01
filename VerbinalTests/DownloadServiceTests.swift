// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Ticket 005: DownloadService's actor-isolated file helpers (`fileSize`,
/// `deleteFile`). (Ticket 006 extends this suite with DataLink-fallback and
/// filename-extraction tests.)
final class DownloadServiceTests: XCTestCase {

    func testFileSizeReturnsByteCount() async throws {
        let service = DownloadService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-size-\(UUID().uuidString).bin")
        try Data(repeating: 0x41, count: 1234).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let size = await service.fileSize(at: url)
        XCTAssertEqual(size, 1234)
    }

    func testFileSizeNilForMissingFile() async {
        let service = DownloadService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-missing-\(UUID().uuidString).bin")
        let size = await service.fileSize(at: url)
        XCTAssertNil(size)
    }

    func testDeleteFileRemovesThenIsIdempotent() async throws {
        let service = DownloadService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-del-\(UUID().uuidString).bin")
        try Data("x".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try await service.deleteFile(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // A second delete on a now-missing file must not throw.
        try await service.deleteFile(at: url)
    }
}
