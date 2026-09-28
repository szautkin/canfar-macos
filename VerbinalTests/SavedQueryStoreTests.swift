// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import os
import VerbinalKit
@testable import Verbinal

@MainActor
final class SavedQueryStoreTests: XCTestCase {

    private func makeStore() -> SavedQueryStore {
        let fileName = "test_saved_queries_\(UUID().uuidString).json"
        return SavedQueryStore(fileName: fileName)
    }

    private func makeQuery(name: String = "Test Query", adql: String = "SELECT * FROM caom2.Plane") -> SavedQuery {
        SavedQuery(name: name, adql: adql)
    }

    override func tearDown() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let dir = appSupport?.appendingPathComponent("Verbinal") {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("test_saved_queries_") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        super.tearDown()
    }

    func testSaveAndRetrieve() {
        let store = makeStore()
        let query = makeQuery(name: "JWST Search", adql: "SELECT * FROM caom2.Plane WHERE Observation.collection = 'JWST'")
        store.save(query)

        XCTAssertEqual(store.queries.count, 1)
        XCTAssertEqual(store.queries[0].name, "JWST Search")
        XCTAssertTrue(store.queries[0].adql.contains("JWST"))
    }

    func testMaxEntries() {
        let store = makeStore()
        for i in 0..<25 {
            store.save(makeQuery(name: "Query \(i)", adql: "SELECT \(i)"))
        }
        XCTAssertEqual(store.queries.count, 20)
    }

    func testRemove() {
        let store = makeStore()
        store.save(makeQuery(name: "A"))
        store.save(makeQuery(name: "B"))
        store.save(makeQuery(name: "C"))
        XCTAssertEqual(store.queries.count, 3)

        store.remove(store.queries[1]) // remove B
        XCTAssertEqual(store.queries.count, 2)
        XCTAssertEqual(store.queries[0].name, "C")
        XCTAssertEqual(store.queries[1].name, "A")
    }

    func testRename() {
        let store = makeStore()
        store.save(makeQuery(name: "Old Name"))

        store.rename(store.queries[0], to: "New Name")
        XCTAssertEqual(store.queries[0].name, "New Name")
    }

    func testDiskPersistence() {
        let fileName = "test_saved_queries_persist_\(UUID().uuidString).json"

        let store1 = SavedQueryStore(fileName: fileName)
        store1.save(makeQuery(name: "Persisted", adql: "SELECT 1"))
        XCTAssertEqual(store1.queries.count, 1)

        let store2 = SavedQueryStore(fileName: fileName)
        XCTAssertEqual(store2.queries.count, 1)
        XCTAssertEqual(store2.queries[0].name, "Persisted")
        XCTAssertEqual(store2.queries[0].adql, "SELECT 1")

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let dir = appSupport?.appendingPathComponent("Verbinal") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName))
        }
    }

    func testClear() {
        let store = makeStore()
        store.save(makeQuery())
        store.save(makeQuery(name: "Q2"))
        store.clear()
        XCTAssertEqual(store.queries.count, 0)
    }

    func testNewestFirst() {
        let store = makeStore()
        store.save(makeQuery(name: "First"))
        store.save(makeQuery(name: "Second"))

        XCTAssertEqual(store.queries[0].name, "Second")
        XCTAssertEqual(store.queries[1].name, "First")
    }
    // MARK: - One row per query (plan 15 F4, QA H3 and L19)

    func testUpdatingAQueryReplacesItsRow() {
        let store = makeStore()
        var query = makeQuery(name: "SN 2023ixf")
        store.save(query)
        store.save(makeQuery(name: "Other"))
        query.tags = ["stis"]
        store.save(query)

        XCTAssertEqual(store.queries.filter { $0.id == query.id }.count, 1)
        XCTAssertEqual(store.queries.map(\.name), ["SN 2023ixf", "Other"], "the updated query comes first")
        XCTAssertEqual(store.queries[0].tags, ["stis"])
    }

    func testAnOlderFileKeepsTheNewestRowPerQueryAndItsAmpersands() throws {
        let fileName = "test_saved_queries_legacy_\(UUID().uuidString).json"
        let id = UUID()
        let old = SavedQuery(id: id, name: "Probe", adql: "SELECT 1", savedAt: Date(timeIntervalSince1970: 100))
        let new = SavedQuery(id: id, name: "Probe (validated)", adql: "SELECT 1", savedAt: Date(timeIntervalSince1970: 200))
        let escaped = SavedQuery(name: "Trumbo &amp; Brown 2023", adql: "SELECT 2", savedAt: Date(timeIntervalSince1970: 150),
                                 description: "Trumbo &amp; Brown", tags: ["a&amp;b"])
        DiskPersistence<[SavedQuery]>(subdirectory: "Verbinal", fileName: fileName, logger: .init())
            .write([old, escaped, new])

        let store = SavedQueryStore(fileName: fileName)
        XCTAssertEqual(store.queries.map(\.name), ["Probe (validated)", "Trumbo & Brown 2023"])
        XCTAssertEqual(store.queries[1].description, "Trumbo & Brown")
        XCTAssertEqual(store.queries[1].tags, ["a&b"])

        store.rename(store.queries[1], to: "Rock &amp; roll")
        XCTAssertEqual(SavedQueryStore(fileName: fileName).queries[1].name, "Rock &amp; roll",
                       "the clean-up ran once; a name typed since is kept as typed")
    }
}
