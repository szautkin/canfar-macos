// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class BookmarkStoreTests: XCTestCase {

    private func makeStore() -> BookmarkStore {
        BookmarkStore(fileName: "test_bookmarks_\(UUID().uuidString).json")
    }

    private func makeBookmark(label: String = "M31 center", ra: Double = 10.68, dec: Double = 41.27, file: String = "/tmp/test.fits") -> CoordinateBookmark {
        CoordinateBookmark(label: label, ra: ra, dec: dec, sourceFilePath: file)
    }

    override func tearDown() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let dir = appSupport?.appendingPathComponent("Verbinal/Bookmarks") {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("test_bookmarks_") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        super.tearDown()
    }

    func testSaveAndRetrieve() {
        let store = makeStore()
        let bm = makeBookmark()
        store.save(bm)
        XCTAssertEqual(store.bookmarks.count, 1)
        XCTAssertEqual(store.bookmarks[0].label, "M31 center")
        XCTAssertEqual(store.bookmarks[0].ra, 10.68, accuracy: 0.001)
    }

    func testFilterByFile() {
        let store = makeStore()
        store.save(makeBookmark(file: "/a.fits"))
        store.save(makeBookmark(file: "/b.fits"))
        store.save(makeBookmark(file: "/a.fits"))

        XCTAssertEqual(store.bookmarks(for: "/a.fits").count, 2)
        XCTAssertEqual(store.bookmarks(for: "/b.fits").count, 1)
        XCTAssertEqual(store.bookmarks(for: "/c.fits").count, 0)
    }

    func testDelete() {
        let store = makeStore()
        store.save(makeBookmark())
        store.save(makeBookmark(label: "NGC 1234"))
        XCTAssertEqual(store.bookmarks.count, 2)

        store.delete(store.bookmarks[0])
        XCTAssertEqual(store.bookmarks.count, 1)
    }

    func testRename() {
        let store = makeStore()
        store.save(makeBookmark(label: "old"))
        store.rename(store.bookmarks[0], label: "new")
        XCTAssertEqual(store.bookmarks[0].label, "new")
    }

    func testDiskPersistence() {
        let fileName = "test_bookmarks_persist_\(UUID().uuidString).json"
        let store1 = BookmarkStore(fileName: fileName)
        store1.save(makeBookmark(label: "persisted"))

        let store2 = BookmarkStore(fileName: fileName)
        XCTAssertEqual(store2.bookmarks.count, 1)
        XCTAssertEqual(store2.bookmarks[0].label, "persisted")

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let dir = appSupport?.appendingPathComponent("Verbinal/Bookmarks") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName))
        }
    }

    func testFormattedCoords() {
        let bm = makeBookmark(ra: 180.0, dec: 45.0)
        XCTAssertTrue(bm.formattedCoords.contains("12h"), "RA 180° should format as 12h")
        XCTAssertTrue(bm.formattedCoords.contains("+45"), "Dec 45° should format as +45")
    }
}
