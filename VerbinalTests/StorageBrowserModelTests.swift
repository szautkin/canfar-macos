// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

final class VOSpaceNodeTests: XCTestCase {

    func testIsContainerTrue() {
        let node = VOSpaceNode(name: "folder", path: "folder", type: .container)
        XCTAssertTrue(node.isContainer)
    }

    func testIsContainerFalse() {
        let node = VOSpaceNode(name: "file.fits", path: "file.fits", type: .dataNode)
        XCTAssertFalse(node.isContainer)
    }

    func testIsFITS() {
        let node = VOSpaceNode(name: "obs.fits", path: "obs.fits", type: .dataNode)
        XCTAssertTrue(node.isFITS)
    }

    func testIsFITSVariants() {
        for ext in ["fit", "fts", "fz"] {
            let node = VOSpaceNode(name: "obs.\(ext)", path: "obs.\(ext)", type: .dataNode)
            XCTAssertTrue(node.isFITS, "\(ext) should be FITS")
        }
    }

    func testIsNotFITS() {
        let node = VOSpaceNode(name: "data.csv", path: "data.csv", type: .dataNode)
        XCTAssertFalse(node.isFITS)
    }

    func testFormattedSize() {
        let node = VOSpaceNode(name: "big.fits", path: "big.fits", type: .dataNode, sizeBytes: 5_242_880)
        XCTAssertTrue(node.formattedSize.contains("MB") || node.formattedSize.contains("5"))
    }

    func testFormattedSizeNil() {
        let node = VOSpaceNode(name: "x", path: "x", type: .dataNode)
        XCTAssertEqual(node.formattedSize, "")
    }

    func testIconForFolder() {
        let node = VOSpaceNode(name: "dir", path: "dir", type: .container)
        XCTAssertEqual(node.icon, "folder.fill")
    }

    func testIconForFITS() {
        let node = VOSpaceNode(name: "img.fits", path: "img.fits", type: .dataNode)
        XCTAssertEqual(node.icon, "star.circle")
    }

    func testIconForPython() {
        let node = VOSpaceNode(name: "run.py", path: "run.py", type: .dataNode)
        XCTAssertEqual(node.icon, "chevron.left.forwardslash.chevron.right")
    }
}

@MainActor
final class StorageBrowserSortTests: XCTestCase {

    func testSortedNodesFoldersFirst() {
        let network = NetworkClient()
        let service = VOSpaceBrowserService(network: network)
        let model = StorageBrowserModel(service: service, username: "testuser")

        model.nodes = [
            VOSpaceNode(name: "file.fits", path: "file.fits", type: .dataNode),
            VOSpaceNode(name: "zeta", path: "zeta", type: .container),
            VOSpaceNode(name: "alpha", path: "alpha", type: .container),
            VOSpaceNode(name: "beta.csv", path: "beta.csv", type: .dataNode),
        ]
        model.sortKey = .name
        model.sortOrder = .ascending

        // Folders first (name-ascending), then files (name-ascending).
        let sorted = model.sortedNodes
        XCTAssertEqual(sorted.map(\.name), ["alpha", "zeta", "beta.csv", "file.fits"])
    }

    func testSortedNodesDescendingExactSequence() {
        let network = NetworkClient()
        let service = VOSpaceBrowserService(network: network)
        let model = StorageBrowserModel(service: service, username: "testuser")

        model.nodes = [
            VOSpaceNode(name: "file.fits", path: "file.fits", type: .dataNode),
            VOSpaceNode(name: "zeta", path: "zeta", type: .container),
            VOSpaceNode(name: "alpha", path: "alpha", type: .container),
            VOSpaceNode(name: "beta.csv", path: "beta.csv", type: .dataNode),
        ]
        model.sortKey = .name
        model.sortOrder = .descending

        // Descending reverses the whole folders-then-files list, so files lead
        // and folders trail. This pins the pre-refactor behaviour exactly.
        let sorted = model.sortedNodes
        XCTAssertEqual(sorted.map(\.name), ["file.fits", "beta.csv", "zeta", "alpha"])
    }

    func testSortedNodesBySizeFoldersFirst() {
        let network = NetworkClient()
        let service = VOSpaceBrowserService(network: network)
        let model = StorageBrowserModel(service: service, username: "testuser")

        model.nodes = [
            VOSpaceNode(name: "big.fits", path: "big.fits", type: .dataNode, sizeBytes: 9000),
            VOSpaceNode(name: "dirB", path: "dirB", type: .container, sizeBytes: 5000),
            VOSpaceNode(name: "small.csv", path: "small.csv", type: .dataNode, sizeBytes: 100),
            VOSpaceNode(name: "dirA", path: "dirA", type: .container, sizeBytes: 200),
        ]
        model.sortKey = .size
        model.sortOrder = .ascending

        // Folders first (size-ascending), then files (size-ascending).
        let sorted = model.sortedNodes
        XCTAssertEqual(sorted.map(\.name), ["dirA", "dirB", "small.csv", "big.fits"])
    }

    func testSortedNodesByDateFoldersFirst() {
        let network = NetworkClient()
        let service = VOSpaceBrowserService(network: network)
        let model = StorageBrowserModel(service: service, username: "testuser")

        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)
        let t2 = Date(timeIntervalSince1970: 3_000)
        let t3 = Date(timeIntervalSince1970: 4_000)

        model.nodes = [
            VOSpaceNode(name: "newFile", path: "newFile", type: .dataNode, lastModified: t3),
            VOSpaceNode(name: "newDir", path: "newDir", type: .container, lastModified: t2),
            VOSpaceNode(name: "oldFile", path: "oldFile", type: .dataNode, lastModified: t1),
            VOSpaceNode(name: "oldDir", path: "oldDir", type: .container, lastModified: t0),
        ]
        model.sortKey = .date
        model.sortOrder = .ascending

        // Folders first (date-ascending), then files (date-ascending).
        let sorted = model.sortedNodes
        XCTAssertEqual(sorted.map(\.name), ["oldDir", "newDir", "oldFile", "newFile"])
    }

    func testToggleSortChangesOrder() {
        let network = NetworkClient()
        let service = VOSpaceBrowserService(network: network)
        let model = StorageBrowserModel(service: service, username: "testuser")

        model.sortKey = .name
        model.sortOrder = .ascending
        model.toggleSort(.name)
        XCTAssertEqual(model.sortOrder, .descending)
    }

    func testToggleSortChangesKey() {
        let network = NetworkClient()
        let service = VOSpaceBrowserService(network: network)
        let model = StorageBrowserModel(service: service, username: "testuser")

        model.sortKey = .name
        model.toggleSort(.size)
        XCTAssertEqual(model.sortKey, .size)
        XCTAssertEqual(model.sortOrder, .ascending)
    }

    func testVospaceURI() {
        let network = NetworkClient()
        let service = VOSpaceBrowserService(network: network)
        let model = StorageBrowserModel(service: service, username: "testuser")
        model.nodes = [VOSpaceNode(name: "file.fits", path: "file.fits", type: .dataNode)]

        let uri = model.vospaceURI(for: model.nodes[0])
        XCTAssertEqual(uri, "vos://cadc.nrc.ca~arc/home/testuser/file.fits")
    }

    func testVospaceURIWithPath() {
        let network = NetworkClient()
        let service = VOSpaceBrowserService(network: network)
        let model = StorageBrowserModel(service: service, username: "testuser")
        model.nodes = [VOSpaceNode(name: "obs.fits", path: "obs.fits", type: .dataNode)]

        // Navigate into a subdirectory first
        model.nodes = [VOSpaceNode(name: "obs.fits", path: "sub/obs.fits", type: .dataNode)]
        // Simulate being in "sub" directory
        let prevPath = model.currentPath
        model.nodes[0] = VOSpaceNode(name: "obs.fits", path: "obs.fits", type: .dataNode)
        // currentPath is still empty at root
        let uri = model.vospaceURI(for: model.nodes[0])
        XCTAssertTrue(uri.contains("testuser"))
    }
}
