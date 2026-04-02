// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

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
}
