// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// The files a viewer opened lately — one store for the FITS and cube
/// viewers — and what the FITS viewer says while it loads.
@MainActor
final class RecentFilesTests: XCTestCase {

    private var suite = "recents-\(UUID().uuidString)"
    private var files: [URL] = []

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Not in the temporary folder: what is there never enters recents.
    private func file(_ name: String) throws -> URL {
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let url = caches.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data("SIMPLE".utf8).write(to: url)
        files.append(url)
        return url
    }

    func testTheNewestIsFirstOnceEachAndTheListIsKept() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let recents = RecentFiles(key: "fits", defaults: defaults)
        let a = try file("a.fits"), b = try file("b.fits")
        recents.add(a)
        recents.add(b)
        recents.add(a)
        XCTAssertEqual(recents.items.map(\.path), [a.path, b.path])
        for index in 0..<RecentFiles.limit { recents.add(try file("\(index).fits")) }
        XCTAssertEqual(recents.items.count, RecentFiles.limit)
        XCTAssertEqual(RecentFiles(key: "fits", defaults: defaults).items, recents.items, "kept across launches")
    }

    func testAFileThatIsGoneIsForgottenWhenAskedFor() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let recents = RecentFiles(key: "cubes", defaults: defaults)
        let gone = try file("gone.fits")
        recents.add(gone)
        let recent = try XCTUnwrap(recents.items.first)
        XCTAssertEqual(recents.resolve(recent)?.resolvingSymlinksInPath().path, gone.resolvingSymlinksInPath().path)
        try FileManager.default.removeItem(at: gone)
        XCTAssertNil(recents.resolve(recent))
        XCTAssertTrue(recents.items.isEmpty)
    }

    /// Plan 30 N6: listed, the files that are gone are left out and
    /// forgotten; a file in the temporary folder never enters.
    func testListedRecentsAreTheFilesStillThere() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let recents = RecentFiles(key: "cubes", defaults: defaults)
        let kept = try file("kept.fits"), gone = try file("gone.fits")
        recents.add(kept)
        recents.add(gone)
        try FileManager.default.removeItem(at: gone)
        XCTAssertEqual(recents.present().map(\.path), [kept.path])
        XCTAssertEqual(RecentFiles(key: "cubes", defaults: defaults).items.map(\.path), [kept.path], "forgotten for good")

        let figure = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-figure.fits")
        try Data("SIMPLE".utf8).write(to: figure)
        files.append(figure)
        recents.add(figure)
        XCTAssertEqual(recents.items.map(\.path), [kept.path], "a temporary file is not kept")
    }

    /// The cube viewer's recents were kept as {name, path, bookmark} under
    /// this key; they read as they were.
    func testTheCubeViewersOldListReadsAsItWas() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let stored = #"[{"name":"c.fits","path":"/tmp/c.fits","bookmark":"AAEC"}]"#
        defaults.set(Data(stored.utf8), forKey: "cubeViewer.recents")
        XCTAssertEqual(RecentFiles(key: "cubeViewer.recents", defaults: defaults).items.map(\.name), ["c.fits"])
    }

    func testTheLoadingScreenSaysWhatIsBeingRead() {
        var header = FITSHeader()
        for (key, value) in [("NAXIS1", "2048"), ("NAXIS2", "4096")] { header.add(FITSCard(keyword: key, value: value, comment: "")) }
        let plain = FITSHDUnit(id: 0, header: header, dataOffset: 0, dataLength: 0, wcs: nil)
        XCTAssertTrue(FITSViewerModel.readingStage(of: plain).hasPrefix("Reading"))
        XCTAssertTrue(FITSViewerModel.readingStage(of: plain).filter(\.isNumber).hasPrefix("20484096"))
        var table = FITSHeader()
        for (key, value) in [("ZIMAGE", "T"), ("ZCMPTYPE", "'RICE_1'"), ("ZBITPIX", "16"), ("ZNAXIS", "2"),
                             ("ZNAXIS1", "20315"), ("ZNAXIS2", "20475")] {
            table.add(FITSCard(keyword: key, value: value, comment: ""))
        }
        let packed = FITSHDUnit(id: 1, header: TileCompression.imageHeader(fromTable: table), dataOffset: 0, dataLength: 0,
                                wcs: nil, compression: TileCompression.Layout(table: table))
        XCTAssertTrue(FITSViewerModel.readingStage(of: packed).hasPrefix("Uncompressing"))
        XCTAssertTrue(FITSViewerModel.readingStage(of: packed).filter(\.isNumber).hasPrefix("2031520475"))
    }
}
