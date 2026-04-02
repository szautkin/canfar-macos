// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class RecentSearchStoreTests: XCTestCase {

    private func makeStore() -> RecentSearchStore {
        // Use a unique temp filename to avoid cross-test interference
        let fileName = "test_recent_searches_\(UUID().uuidString).json"
        return RecentSearchStore(fileName: fileName)
    }

    private func makeSearch(target: String = "M31", collection: String = "JWST") -> RecentSearch {
        var snapshot = SearchFormSnapshot()
        snapshot.target = target
        snapshot.selectedCollections = collection.isEmpty ? [] : [collection]
        return RecentSearch(name: snapshot.autoName(), formSnapshot: snapshot)
    }

    override func tearDown() {
        // Clean up any test files
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let dir = appSupport?.appendingPathComponent("Verbinal") {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("test_recent_searches_") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        super.tearDown()
    }

    func testSaveAndRetrieve() {
        let store = makeStore()
        let search = makeSearch()
        store.save(search)

        XCTAssertEqual(store.searches.count, 1)
        XCTAssertEqual(store.searches[0].formSnapshot.target, "M31")
        XCTAssertEqual(store.searches[0].formSnapshot.selectedCollections, ["JWST"])
    }

    func testMaxEntries() {
        let store = makeStore()
        for i in 0..<25 {
            store.save(makeSearch(target: "Target\(i)", collection: "Col\(i)"))
        }
        XCTAssertEqual(store.searches.count, 20)
    }

    func testRemove() {
        let store = makeStore()
        let s1 = makeSearch(target: "A", collection: "C1")
        let s2 = makeSearch(target: "B", collection: "C2")
        let s3 = makeSearch(target: "C", collection: "C3")
        store.save(s1)
        store.save(s2)
        store.save(s3)
        XCTAssertEqual(store.searches.count, 3)

        store.remove(store.searches[1]) // remove middle
        XCTAssertEqual(store.searches.count, 2)
        XCTAssertEqual(store.searches[0].formSnapshot.target, "C")
        XCTAssertEqual(store.searches[1].formSnapshot.target, "A")
    }

    func testClear() {
        let store = makeStore()
        store.save(makeSearch())
        store.save(makeSearch(target: "M51"))
        XCTAssertEqual(store.searches.count, 2)

        store.clear()
        XCTAssertEqual(store.searches.count, 0)
    }

    func testRename() {
        let store = makeStore()
        let search = makeSearch()
        store.save(search)

        store.rename(store.searches[0], to: "My Favorite Search")
        XCTAssertEqual(store.searches[0].name, "My Favorite Search")
    }

    func testNewestFirst() {
        let store = makeStore()
        store.save(makeSearch(target: "A", collection: "C1"))
        store.save(makeSearch(target: "B", collection: "C2"))

        XCTAssertEqual(store.searches[0].formSnapshot.target, "B")
        XCTAssertEqual(store.searches[1].formSnapshot.target, "A")
    }

    func testDiskPersistence() {
        let fileName = "test_recent_searches_persist_\(UUID().uuidString).json"

        // Save with one instance
        let store1 = RecentSearchStore(fileName: fileName)
        store1.save(makeSearch(target: "Persisted"))
        XCTAssertEqual(store1.searches.count, 1)

        // Read with a new instance
        let store2 = RecentSearchStore(fileName: fileName)
        XCTAssertEqual(store2.searches.count, 1)
        XCTAssertEqual(store2.searches[0].formSnapshot.target, "Persisted")

        // Cleanup
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let dir = appSupport?.appendingPathComponent("Verbinal") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName))
        }
    }

    func testDeduplicateBySnapshot() {
        let store = makeStore()
        let s1 = makeSearch(target: "M31", collection: "JWST")
        var s2 = makeSearch(target: "M31", collection: "JWST")
        s2.name = "Different Name"

        store.save(s1)
        store.save(s2)

        // Same snapshot → deduplicated to 1 entry
        XCTAssertEqual(store.searches.count, 1)
        XCTAssertEqual(store.searches[0].name, "Different Name")
    }
}
