// SPDX-License-Identifier: MPL-2.0

import XCTest
import os.log
@testable import VerbinalKit

/// Ticket 025: direct tests for the shared DiskPersistence primitive every
/// store inherits — round-trip incl. ISO8601 Date codec, missing-file nil,
/// corrupt-JSON nil, and idempotent delete.
final class DiskPersistenceTests: XCTestCase {

    private struct Box: Codable, Equatable {
        let name: String
        let when: Date
        let count: Int
    }

    private let logger = Logger(subsystem: "com.codebg.Verbinal.tests", category: "DiskPersistence")

    private func makeStore(file: String = "box.json") -> DiskPersistence<Box> {
        DiskPersistence<Box>(
            subdirectory: "VerbinalDiskPersistenceTests-\(UUID().uuidString)",
            fileName: file,
            logger: logger
        )
    }

    func testWriteReadRoundTripsWithISO8601Date() {
        let store = makeStore()
        defer { store.delete() }
        // Whole-second date so the ISO8601 strategy (no fractional seconds)
        // round-trips exactly.
        let box = Box(name: "obs", when: Date(timeIntervalSince1970: 1_700_000_000), count: 3)
        store.write(box)
        XCTAssertEqual(store.read(), box)
    }

    func testReadReturnsNilWhenFileMissing() {
        XCTAssertNil(makeStore().read())
    }

    func testReadReturnsNilOnCorruptJSON() throws {
        let store = makeStore()
        defer { store.delete() }
        let url = try XCTUnwrap(store.fileURL)
        try Data("not valid json {".utf8).write(to: url)
        XCTAssertNil(store.read())
    }

    func testDeleteRemovesFileAndIsIdempotent() {
        let store = makeStore()
        store.write(Box(name: "x", when: Date(timeIntervalSince1970: 0), count: 1))
        XCTAssertNotNil(store.read())
        store.delete()
        XCTAssertNil(store.read())
        store.delete()   // second delete on an absent file must not throw
        XCTAssertNil(store.read())
    }
}
