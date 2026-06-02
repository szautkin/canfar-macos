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

    /// Mirrors DiskPersistence's private envelope shape so tests can author
    /// legacy/newer on-disk files by hand.
    private struct Env: Codable {
        let schemaVersion: Int
        let value: Box
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

    func testCorruptFileIsQuarantinedAndReadStartsFresh() throws {
        let store = makeStore()
        let url = try XCTUnwrap(store.fileURL)
        let dir = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("{ broken".utf8).write(to: url)

        // readResult reports corruption + the quarantine location.
        guard case .corrupt(let quarantinedTo) = store.readResult() else {
            return XCTFail("expected .corrupt")
        }
        let quarantined = try XCTUnwrap(quarantinedTo, "corrupt file should be quarantined")
        XCTAssertTrue(quarantined.lastPathComponent.contains(".corrupt-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.path), "bytes preserved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "original moved aside")

        // The store now starts clean instead of failing forever.
        if case .missing = store.readResult() {} else { XCTFail("expected .missing after quarantine") }
        XCTAssertNil(store.read())
    }

    func testReadResultDistinguishesMissingValueCorrupt() throws {
        let store = makeStore()
        let dir = try XCTUnwrap(store.fileURL).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        if case .missing = store.readResult() {} else { XCTFail("expected .missing") }

        let box = Box(name: "obs", when: Date(timeIntervalSince1970: 1_700_000_000), count: 3)
        XCTAssertTrue(store.write(box), "write should report success")
        guard case .value(let v) = store.readResult() else { return XCTFail("expected .value") }
        XCTAssertEqual(v, box)
    }

    func testWriteReturnsTrueOnSuccess() {
        let store = makeStore()
        defer { store.delete() }
        XCTAssertTrue(store.write(Box(name: "x", when: Date(timeIntervalSince1970: 0), count: 1)))
    }

    // MARK: - Schema versioning (S02)

    func testLegacyBareValueIsStillReadable() throws {
        let store = makeStore()
        defer { store.delete() }
        let url = try XCTUnwrap(store.fileURL)
        let box = Box(name: "legacy", when: Date(timeIntervalSince1970: 1_700_000_000), count: 2)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(box).write(to: url)   // bare value, no envelope (pre-versioning)
        XCTAssertEqual(store.read(), box)
    }

    func testWriteProducesVersionedEnvelope() throws {
        let store = makeStore()   // schemaVersion defaults to 1
        defer { store.delete() }
        let box = Box(name: "v", when: Date(timeIntervalSince1970: 1_700_000_000), count: 1)
        XCTAssertTrue(store.write(box))
        let url = try XCTUnwrap(store.fileURL)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("schemaVersion"), "writes a versioned envelope")
        XCTAssertEqual(store.read(), box, "round-trips through the envelope")
    }

    func testNewerSchemaVersionIsNotLoadedNorQuarantined() throws {
        let store = makeStore()   // supports v1
        defer { store.delete() }
        let url = try XCTUnwrap(store.fileURL)
        let box = Box(name: "future", when: Date(timeIntervalSince1970: 1_700_000_000), count: 7)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(Env(schemaVersion: 99, value: box)).write(to: url)

        guard case .unsupported(let found) = store.readResult() else {
            return XCTFail("expected .unsupported for a newer-version file")
        }
        XCTAssertEqual(found, 99)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "a newer-version file must NOT be quarantined or clobbered")
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
