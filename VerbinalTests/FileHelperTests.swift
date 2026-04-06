// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class FileHelperTests: XCTestCase {

    func testMoveReplacingNewFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let src = tempDir.appendingPathComponent("fh_test_src_\(UUID().uuidString).txt")
        let dst = tempDir.appendingPathComponent("fh_test_dst_\(UUID().uuidString).txt")

        try "hello".write(to: src, atomically: true, encoding: .utf8)
        try FileHelper.moveReplacing(from: src, to: dst)

        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "hello")

        try? FileManager.default.removeItem(at: dst)
    }

    func testMoveReplacingOverwrites() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let src = tempDir.appendingPathComponent("fh_test_src2_\(UUID().uuidString).txt")
        let dst = tempDir.appendingPathComponent("fh_test_dst2_\(UUID().uuidString).txt")

        try "old".write(to: dst, atomically: true, encoding: .utf8)
        try "new".write(to: src, atomically: true, encoding: .utf8)
        try FileHelper.moveReplacing(from: src, to: dst)

        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "new")

        try? FileManager.default.removeItem(at: dst)
    }
}
