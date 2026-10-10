// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 36 4.2: marks and bookmarks follow their file — one of the
/// person's storage or of Research — to every device, by an identity they
/// share; those of a file of this Mac alone stay, and the marks kept under
/// a path before are still found.
@MainActor
final class FileIdentitySyncTests: XCTestCase {
    typealias FakeVOSpace = StorageSyncTests.FakeVOSpace

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("identity-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func file(_ name: String, in sub: String) -> URL {
        let folder = directory.appendingPathComponent(sub, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("SIMPLE".utf8))
        return url
    }

    private func mark(_ id: String) -> Mark {
        Mark(id: id, kind: .text, anchor: .init(space: .imagePixel, x: 10, y: 20), text: "here", author: .user, createdAt: Date())
    }

    func testMarksOnAStorageFileReachAnotherDeviceThatOpensIt() async throws {
        let here = file("m31.fits", in: "a"), there = file("m31.fits", in: "b")
        FileOrigins.shared.noteFromStorage(here, path: "data/m31.fits")
        FileOrigins.shared.noteFromStorage(there, path: "data/m31.fits")
        let mine = MarkStore(persistence: nil), theirs = MarkStore(persistence: nil)
        let target = MarkStore.Target(file: here, hdu: 1)
        XCTAssertEqual(target.key, "vos:data/m31.fits#1")
        try mine.add(mark("m1"), to: target)

        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, Data(#"{ "format": "verbinal.vospace-manifest", "version": 1, "kinds": { "marks": { "folder": ".verbinal/marks", "format": 1, "since": "2026-10-09T12:00:00Z" } } }"#.utf8))
        await StorageSync(remote: remote, catalog: StorageKindCatalog(kinds: [mine.syncCollection().kind]),
                          stateFile: directory.appendingPathComponent("state-a.json")).sync(.signedIn)
        await StorageSync(remote: remote, catalog: StorageKindCatalog(kinds: [theirs.syncCollection().kind]),
                          stateFile: directory.appendingPathComponent("state-b.json")).sync(.signedIn)
        XCTAssertEqual(theirs.marks(on: MarkStore.Target(file: there, hdu: 1)).map(\.id), ["m1"])
    }

    func testMarksOfAFileOfThisMacAloneStay() throws {
        let store = MarkStore(persistence: nil)
        try store.add(mark("m1"), to: MarkStore.Target(file: file("local.fits", in: "c"), hdu: 0))
        XCTAssertTrue(store.portableSets.isEmpty)
    }

    func testMarksKeptUnderAPathBeforeAreFoundAndMoveOnTheirFirstChange() throws {
        let url = file("ngc300.fits", in: "d")
        let store = MarkStore(persistence: nil)
        try store.add(mark("m1"), to: MarkStore.Target(file: url, hdu: 0))
        XCTAssertEqual(store.marksByKey.keys.first, FileIdentity.key(url) + "#0", "a file of this Mac: its path")

        FileOrigins.shared.noteFromStorage(url, path: "survey/ngc300.fits")
        let target = MarkStore.Target(file: url, hdu: 0)
        XCTAssertEqual(store.marks(on: target).map(\.id), ["m1"], "found where they were")
        XCTAssertEqual(store.targets(of: url).map(\.key), ["vos:survey/ngc300.fits#0"])
        try store.add(mark("m2"), to: target)
        XCTAssertEqual(Array(store.marksByKey.keys), ["vos:survey/ngc300.fits#0"], "moved to its identity")
        XCTAssertEqual(store.marks(on: target).map(\.id), ["m1", "m2"])
    }

    func testAResearchFileIsKnownByItsRecord() {
        let url = file("1525350p.fits.fz", in: "e")
        let store = ObservationStore(fileName: "test-identity-\(UUID().uuidString).json", spotlight: nil)
        let record = store.save(DownloadedObservation(publisherID: "ivo://cadc.nrc.ca/CFHT?1525350/1525350p", collection: "CFHT",
                                                      observationID: "1525350", targetName: "M31", instrument: "", filter: "",
                                                      ra: "", dec: "", startDate: "", calLevel: "", localPath: url.path))
        XCTAssertEqual(store.portableIdentity(of: url), "caom:\(record.recordKey)/1525350p.fits.fz")
        XCTAssertNil(store.portableIdentity(of: file("other.fits", in: "e")))
    }

    func testBookmarksFollowTheirFileAndThoseOfThisMacStay() {
        let store = BookmarkStore(fileName: "test-identity-bookmarks-\(UUID().uuidString).json")
        let fromStorage = file("m51.fits", in: "f"), local = file("mine.fits", in: "f")
        FileOrigins.shared.noteFromStorage(fromStorage, path: "data/m51.fits")
        store.save(CoordinateBookmark(label: "core", ra: 202.47, dec: 47.19, sourceFilePath: FileOrigins.shared.identity(of: fromStorage)))
        store.save(CoordinateBookmark(label: "here only", ra: 1, dec: 2, sourceFilePath: FileOrigins.shared.identity(of: local)))
        store.save(CoordinateBookmark(label: "anywhere", ra: 3, dec: 4, sourceFilePath: ""))
        XCTAssertEqual(store.bookmarks(for: fromStorage).map(\.label), ["core"])
        XCTAssertEqual(store.bookmarks(for: local).map(\.label), ["here only"], "by its path, as before")
        XCTAssertEqual(Set(store.portable.map(\.label)), ["core", "anywhere"])
    }
}
