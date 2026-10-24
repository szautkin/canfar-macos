// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest

/// The files Verbinal holds on the device (plan 48), in a temporary folder:
/// each kind listed, deleted, kept and given back; the backup flag; the cap
/// trimming Downloads alone; the Inbox read and never written.
final class DeviceFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func files(cap: Int64 = 1 << 30) -> DeviceFiles {
        DeviceFiles(cache: RemoteFileCache(directory: root.appendingPathComponent("Caches/Remote"), cap: { cap }),
                    documents: root.appendingPathComponent("Documents"))
    }

    private func ref(_ path: String, size: Int64) -> FileRef {
        FileRef(place: .storage(path: path), name: (path as NSString).lastPathComponent, size: size,
                modified: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Downloads `path` from "storage": `size` bytes into the cache.
    @discardableResult
    private func download(_ path: String, size: Int = 8, into files: DeviceFiles) throws -> URL {
        let temporary = root.appendingPathComponent(UUID().uuidString)
        try Data(count: size).write(to: temporary)
        return try files.cache.store(temporary, as: ref(path, size: Int64(size)))
    }

    /// A file another app sent: iOS puts it in Documents/Inbox.
    @discardableResult
    private func receive(_ name: String, into files: DeviceFiles) throws -> URL {
        try FileManager.default.createDirectory(at: files.received, withIntermediateDirectories: true)
        let url = files.received.appendingPathComponent(name)
        try Data(count: 4).write(to: url)
        return url
    }

    func testEachKindIsListedWithWhereItCameFrom() throws {
        let files = files()
        try download("out/m31.fits", into: files)
        try receive("mail.fits", into: files)

        let downloads = files.list(.downloads), received = files.list(.received)
        XCTAssertEqual(downloads.map(\.name), ["m31.fits"])
        XCTAssertEqual(downloads.first?.origin?.storagePath, "out/m31.fits")
        XCTAssertEqual(downloads.first?.storageFolder, "out/")
        XCTAssertTrue(downloads.first?.isInStorage ?? false)
        XCTAssertEqual(received.map(\.name), ["mail.fits"])
        XCTAssertNil(received.first?.origin)
        XCTAssertEqual(files.list(.kept), [])
        XCTAssertEqual(files.list().count, 2)
    }

    func testKeepingMovesAFileOutOfTheCacheAndOutOfBackup() throws {
        let files = files()
        try download("out/m31.fits", into: files)
        let kept = try files.keep(try XCTUnwrap(files.list(.downloads).first))

        XCTAssertEqual(kept.kind, .kept)
        XCTAssertEqual(kept.url.deletingLastPathComponent().lastPathComponent, "Kept")
        XCTAssertEqual(try kept.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(files.list(.downloads), [])
        let cacheEntries = try FileManager.default.contentsOfDirectory(atPath: files.cache.directory.path)
        XCTAssertEqual(cacheEntries, [], "the download's folder goes with it")
        XCTAssertEqual(files.list(.kept).first?.origin?.storagePath, "out/m31.fits", "its origin moves with it")
        XCTAssertEqual(files.localCopy(of: ref("out/m31.fits", size: 8))?.lastPathComponent, "m31.fits",
                       "opening the storage file finds the kept copy")
    }

    func testDontKeepGivesAStorageFileBackToDownloads() throws {
        let files = files()
        try download("out/m31.fits", into: files)
        let kept = try files.keep(try XCTUnwrap(files.list(.downloads).first))
        let back = try files.unkeep(kept)

        XCTAssertEqual(back.kind, .downloads)
        XCTAssertEqual(back.url.path, files.cache.location(of: ref("out/m31.fits", size: 8)).path)
        XCTAssertEqual(files.list(.kept), [])
        XCTAssertNotNil(files.localCopy(of: ref("out/m31.fits", size: 8)))
    }

    func testAFileNotInStorageCannotGoBackToTheCache() throws {
        let files = files()
        try receive("mail.fits", into: files)
        let kept = try files.keep(try XCTUnwrap(files.list(.received).first))
        XCTAssertEqual(files.list(.received), [], "kept, it leaves the Inbox")
        XCTAssertThrowsError(try files.unkeep(kept), "it could not be downloaded again")
        XCTAssertEqual(files.list(.kept).count, 1)
    }

    func testTheCapTrimsDownloadsAloneLeastRecentFirst() throws {
        let files = files(cap: 20)
        try download("kept.fits", size: 100, into: files)
        try files.keep(try XCTUnwrap(files.list(.downloads).first))
        try receive("mail.fits", into: files)
        try download("old.fits", size: 12, into: files)
        let old = try XCTUnwrap(files.list(.downloads).first)
        FileOrigin.markOpened(old.url, at: Date(timeIntervalSince1970: 1))

        try download("new.fits", size: 12, into: files)

        XCTAssertEqual(files.list(.downloads).map(\.name), ["new.fits"], "the least recently opened went")
        XCTAssertEqual(files.list(.kept).map(\.name), ["kept.fits"], "kept files are out of the cap's reach")
        XCTAssertEqual(files.list(.received).map(\.name), ["mail.fits"])
    }

    func testDeletingRemovesADownloadsFolderAndAReceivedFile() throws {
        let files = files()
        try download("out/m31.fits", into: files)
        try receive("mail.fits", into: files)
        try files.remove(files.list())

        XCTAssertEqual(files.list(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: files.cache.directory.path), [])
    }

    func testADeletionInStorageIsForgottenByTheCopiesHere() throws {
        let files = files()
        try download("out/a.fits", into: files)
        try download("out/sub/b.fits", into: files)
        try files.keep(try XCTUnwrap(files.list(.downloads).first { $0.name == "b.fits" }))

        files.forgetStorage(under: "out/sub")

        XCTAssertEqual(files.list(.kept).first?.isInStorage, false)
        XCTAssertEqual(files.list(.downloads).first?.origin?.storagePath, "out/a.fits")
        files.forgetStorage(under: "out/a.fits")
        XCTAssertEqual(files.list(.downloads).first?.isInStorage, false)
    }

    func testOpeningNotesTheDateOnVerbinalsFilesOnly() throws {
        let files = files()
        let elsewhere = root.appendingPathComponent("Elsewhere/theirs.fits")
        try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 4).write(to: elsewhere)
        let inbox = try receive("mail.fits", into: files)
        try download("out/m31.fits", into: files)
        let kept = try files.keep(try XCTUnwrap(files.list(.downloads).first))

        files.noteOpened(elsewhere)
        files.noteOpened(inbox)
        files.noteOpened(kept.url)

        XCTAssertNil(FileOrigin.read(from: elsewhere), "the person's own files are never written to")
        XCTAssertNil(FileOrigin.read(from: inbox), "nor is the system's Inbox")
        XCTAssertNotNil(FileOrigin.read(from: kept.url)?.opened)
        XCTAssertEqual(files.kind(of: elsewhere), nil)
        XCTAssertEqual(files.kind(of: inbox), .received)
    }

    /// Plan 49: Open asks whether a storage file is here, signed out, without
    /// counting it as opened; opening it does count.
    func testAskingWhetherAFileIsHereDoesNotOpenIt() throws {
        let files = files()
        let url = try download("out/m31.fits", into: files)
        FileOrigin.markOpened(url, at: Date(timeIntervalSince1970: 1))

        XCTAssertTrue(files.has(ref("out/m31.fits", size: 8)))
        XCTAssertFalse(files.has(ref("out/m31.fits", size: 9)), "another version is not here")
        XCTAssertFalse(files.has(ref("out/other.fits", size: 8)))
        XCTAssertEqual(FileOrigin.read(from: url)?.opened, Date(timeIntervalSince1970: 1))

        XCTAssertEqual(files.localCopy(of: ref("out/m31.fits", size: 8))?.lastPathComponent, "m31.fits")
        XCTAssertNotEqual(FileOrigin.read(from: url)?.opened, Date(timeIntervalSince1970: 1))
    }

    func testAKeptNameThatIsTakenGetsANumber() throws {
        let folder = root.appendingPathComponent("Kept")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(DeviceFiles.unique("x.fits.fz", in: folder).lastPathComponent, "x.fits.fz")
        try Data().write(to: folder.appendingPathComponent("x.fits.fz"))
        XCTAssertEqual(DeviceFiles.unique("x.fits.fz", in: folder).lastPathComponent, "x 2.fits.fz")
        try Data().write(to: folder.appendingPathComponent("x 2.fits.fz"))
        XCTAssertEqual(DeviceFiles.unique("x.fits.fz", in: folder).lastPathComponent, "x 3.fits.fz")
    }

    func testAnOriginRoundTripsOnTheFile() throws {
        let url = root.appendingPathComponent("f.fits")
        try Data(count: 4).write(to: url)
        let origin = FileOrigin(storagePath: "a/f.fits", size: 4, modified: Date(timeIntervalSince1970: 5), opened: Date(timeIntervalSince1970: 9))
        try origin.write(to: url)
        XCTAssertEqual(FileOrigin.read(from: url), origin)
    }
}
