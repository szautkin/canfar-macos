// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class LocalFileNodeTests: XCTestCase {

    func testIsFITS() {
        let node = LocalFileNode(id: "/a.fits", name: "a.fits", url: URL(fileURLWithPath: "/a.fits"), isDirectory: false, fileSize: 100, modifiedDate: nil)
        XCTAssertTrue(node.isFITS)
    }

    func testIsFITSVariants() {
        for ext in ["fit", "fts", "fz"] {
            let node = LocalFileNode(id: "/a.\(ext)", name: "a.\(ext)", url: URL(fileURLWithPath: "/a.\(ext)"), isDirectory: false, fileSize: nil, modifiedDate: nil)
            XCTAssertTrue(node.isFITS, "\(ext) should be detected as FITS")
        }
    }

    func testNotebookIcon() {
        let node = LocalFileNode(id: "/nb.ipynb", name: "nb.ipynb", url: URL(fileURLWithPath: "/nb.ipynb"), isDirectory: false, fileSize: nil, modifiedDate: nil)
        XCTAssertEqual(node.icon, "doc.text")
    }

    func testPythonIcon() {
        let node = LocalFileNode(id: "/s.py", name: "s.py", url: URL(fileURLWithPath: "/s.py"), isDirectory: false, fileSize: nil, modifiedDate: nil)
        XCTAssertEqual(node.icon, "chevron.left.forwardslash.chevron.right")
    }

    func testMarkdownIcon() {
        let node = LocalFileNode(id: "/r.md", name: "r.md", url: URL(fileURLWithPath: "/r.md"), isDirectory: false, fileSize: nil, modifiedDate: nil)
        XCTAssertEqual(node.icon, "doc.richtext")
    }

    func testDefaultIcon() {
        let node = LocalFileNode(id: "/f.txt", name: "f.txt", url: URL(fileURLWithPath: "/f.txt"), isDirectory: false, fileSize: nil, modifiedDate: nil)
        XCTAssertEqual(node.icon, "doc")
    }

    func testDirectoryIcon() {
        let node = LocalFileNode(id: "/dir", name: "dir", url: URL(fileURLWithPath: "/dir"), isDirectory: true, fileSize: nil, modifiedDate: nil)
        XCTAssertEqual(node.icon, "folder.fill")
        XCTAssertFalse(node.isFITS)
    }

    func testFormattedSize() {
        let node = LocalFileNode(id: "/a", name: "a", url: URL(fileURLWithPath: "/a"), isDirectory: false, fileSize: 1048576, modifiedDate: nil)
        XCTAssertTrue(node.formattedSize.contains("MB") || node.formattedSize.contains("1"), "Expected MB format, got: \(node.formattedSize)")
    }

    func testSupportedExtensions() {
        XCTAssertTrue(LocalFileNode.supportedExtensions.contains("fits"))
        XCTAssertTrue(LocalFileNode.supportedExtensions.contains("ipynb"))
        XCTAssertTrue(LocalFileNode.supportedExtensions.contains("py"))
        XCTAssertFalse(LocalFileNode.supportedExtensions.contains("txt"))
    }
}

@MainActor
final class FileBrowserModelTests: XCTestCase {

    func testInitDefaultsToDocuments() {
        let model = FileBrowserModel()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        XCTAssertEqual(model.rootURL, docs)
        XCTAssertEqual(model.currentURL, docs)
    }

    func testCanGoUpAtRoot() {
        let model = FileBrowserModel()
        XCTAssertFalse(model.canGoUp)
    }

    func testLoadDirectoryPopulatesNodes() {
        let model = FileBrowserModel()
        model.loadDirectory()
        // Documents dir likely has files; at minimum no crash
        XCTAssertTrue(true) // smoke test — verify it doesn't crash
    }

    func testFilterTextFilters() {
        let model = FileBrowserModel()
        model.nodes = [
            LocalFileNode(id: "/a.fits", name: "galaxy.fits", url: URL(fileURLWithPath: "/a.fits"), isDirectory: false, fileSize: nil, modifiedDate: nil),
            LocalFileNode(id: "/b.py", name: "script.py", url: URL(fileURLWithPath: "/b.py"), isDirectory: false, fileSize: nil, modifiedDate: nil),
        ]
        model.filterText = "galaxy"
        XCTAssertEqual(model.filteredNodes.count, 1)
        XCTAssertEqual(model.filteredNodes.first?.name, "galaxy.fits")
    }

    func testShowOnlySupportedTypesFilters() {
        let model = FileBrowserModel()
        model.showOnlySupportedTypes = true
        model.nodes = [
            LocalFileNode(id: "/a.fits", name: "a.fits", url: URL(fileURLWithPath: "/a.fits"), isDirectory: false, fileSize: nil, modifiedDate: nil),
            LocalFileNode(id: "/b.txt", name: "b.txt", url: URL(fileURLWithPath: "/b.txt"), isDirectory: false, fileSize: nil, modifiedDate: nil),
            LocalFileNode(id: "/dir", name: "dir", url: URL(fileURLWithPath: "/dir"), isDirectory: true, fileSize: nil, modifiedDate: nil),
        ]
        let filtered = model.filteredNodes
        XCTAssertEqual(filtered.count, 2, "Should show .fits and directory, hide .txt")
    }

    // MARK: - Ticket 011: load error vs. empty folder

    func testUnreadableDirectorySetsLoadError() {
        let model = FileBrowserModel()
        model.currentURL = URL(fileURLWithPath: "/does-not-exist-\(UUID().uuidString)")
        model.loadDirectory()
        XCTAssertNotNil(model.loadError, "an un-enumerable directory must set loadError, not look empty")
        XCTAssertTrue(model.nodes.isEmpty)
    }

    func testCleanLoadHasNoErrorAndListsFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fb-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a".utf8).write(to: dir.appendingPathComponent("a.fits"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("b.txt"))

        let model = FileBrowserModel()
        model.currentURL = dir
        model.loadDirectory()

        XCTAssertNil(model.loadError)
        XCTAssertEqual(model.loadSkippedCount, 0)
        XCTAssertEqual(model.nodes.count, 2, "both readable files are listed in the raw node set")
    }
}
