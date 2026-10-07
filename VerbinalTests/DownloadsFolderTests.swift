// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// One Downloads, one way of writing where it is (plan 19 F2, QA L9:
/// figure exports read as landing in the container's Downloads, other
/// files in ~/Downloads — the same folder through a link).
final class DownloadsFolderTests: XCTestCase {

    func testDownloadsIsWrittenWithoutTheContainersLink() {
        let url = DownloadsFolder.url
        XCTAssertEqual(url, url.resolvingSymlinksInPath())
        XCTAssertFalse(url.path.contains("/Library/Containers/"), url.path)
        XCTAssertEqual(url.lastPathComponent, "Downloads")
        let export = DownloadsFolder.timestampedURL(stem: "figure", ext: "pdf", at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(export.deletingLastPathComponent(), url)
        XCTAssertTrue(export.lastPathComponent.hasPrefix("figure-") && export.pathExtension == "pdf")
    }

    /// A path kept through the container's link reads as the folder it is.
    func testAPathKeptThroughALinkReadsAsTheFolderItIs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("Downloads")
        let container = root.appendingPathComponent("Container")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: container.appendingPathComponent("Downloads").path,
                                                   withDestinationPath: "../Downloads")
        try Data("x".utf8).write(to: real.appendingPathComponent("fig.pdf"))
        XCTAssertEqual(DownloadsFolder.displayPath(container.appendingPathComponent("Downloads/fig.pdf").path),
                       real.appendingPathComponent("fig.pdf").path)
        XCTAssertEqual(DownloadsFolder.displayPath(""), "")
    }

    /// A file already there is the person's: kept, and the new one takes a
    /// timestamp — a VOSpace download replaced it (handout 31).
    func testAFileAlreadyThereIsKept() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("theirs".utf8).write(to: folder.appendingPathComponent("results.csv"))
        let incoming = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        try Data("new".utf8).write(to: incoming)

        let landed = try DownloadsFolder.move(incoming, named: "results.csv", into: folder)
        XCTAssertNotEqual(landed.lastPathComponent, "results.csv")
        XCTAssertTrue(landed.lastPathComponent.hasPrefix("results-") && landed.pathExtension == "csv", landed.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("results.csv"), encoding: .utf8), "theirs")
        XCTAssertEqual(try String(contentsOf: landed, encoding: .utf8), "new")
    }
}
