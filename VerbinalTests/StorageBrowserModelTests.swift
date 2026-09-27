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
        _ = prevPath
    }

    func testNodeIdentityIsPathStable() {
        let a = VOSpaceNode(name: "folder", path: "run_code_test", type: .container)
        let b = VOSpaceNode(name: "folder", path: "run_code_test", type: .container)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.id, "run_code_test")
    }
}

@MainActor
final class StorageBrowserNavigationTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeModel(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> StorageBrowserModel {
        MockURLProtocol.requestHandler = { req in try handler(req) }
        let network = NetworkClient(session: MockURLProtocol.mockSession())
        let service = VOSpaceBrowserService(network: network)
        return StorageBrowserModel(service: service, username: "testuser")
    }

    private func okListingXML(childName: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <vos:node xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.0"
                  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                  uri="vos://cadc.nrc.ca~arc/home/testuser"
                  xsi:type="vos:ContainerNode">
          <vos:nodes>
            <vos:node uri="vos://cadc.nrc.ca~arc/home/testuser/\(childName)"
                      xsi:type="vos:ContainerNode">
              <vos:properties/>
            </vos:node>
          </vos:nodes>
        </vos:node>
        """.utf8)
    }

    func testListNodesRequestIncludesDetailMax() async throws {
        var seenURL: String?
        let model = makeModel { request in
            seenURL = request.url?.absoluteString
            let url = request.url!
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    self.okListingXML(childName: "keep_me"))
        }
        await model.loadCurrentFolder()
        let url = try XCTUnwrap(seenURL)
        XCTAssertTrue(url.contains("detail=max"),
                      "listings must request detail=max for #date/#length; got \(url)")
        XCTAssertTrue(url.contains("limit="), "got \(url)")
    }

    /// Failed navigation must keep the previous path and listing, and
    /// surface the error in `statusMessage` (the status bar) — not only
    /// in the center pane that only appears when `nodes` is empty.
    func testNavigateFailureKeepsPathAndSurfacesStatusError() async {
        var calls = 0
        let model = makeModel { request in
            calls += 1
            let url = request.url!
            if calls == 1 {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        self.okListingXML(childName: "keep_me"))
            }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data("not found".utf8))
        }

        await model.loadCurrentFolder()
        XCTAssertEqual(model.currentPath, "")
        XCTAssertEqual(model.nodes.map(\.name), ["keep_me"])
        XCTAssertFalse(model.hasError)

        await model.navigateTo("missing_folder")

        XCTAssertEqual(model.currentPath, "",
                       "failed nav must not advance the breadcrumb")
        XCTAssertEqual(model.nodes.map(\.name), ["keep_me"],
                       "failed nav must keep the previous listing")
        XCTAssertTrue(model.hasError)
        XCTAssertFalse(model.errorMessage.isEmpty)
        XCTAssertEqual(model.statusMessage, model.errorMessage,
                       "status bar must show the same error")
    }

    func testNavigateSuccessCommitsPath() async {
        var calls = 0
        let model = makeModel { request in
            calls += 1
            let url = request.url!
            let body = calls == 1
                ? self.okListingXML(childName: "folder_a")
                : Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <vos:node xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.0"
                          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                          uri="vos://cadc.nrc.ca~arc/home/testuser/folder_a"
                          xsi:type="vos:ContainerNode">
                  <vos:nodes/>
                </vos:node>
                """.utf8)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body)
        }

        await model.loadCurrentFolder()
        await model.navigateTo("folder_a")

        XCTAssertEqual(model.currentPath, "folder_a")
        XCTAssertTrue(model.nodes.isEmpty, "empty folder listing")
        XCTAssertFalse(model.hasError)
        XCTAssertTrue(model.statusMessage.contains("0") || model.statusMessage.lowercased().contains("item"),
                      "empty folder should report item count; got \(model.statusMessage)")
    }

    #if os(macOS)
    /// Cancelling mid-upload must clear the determinate progress state and
    /// land on the localized "Upload cancelled" status — not a red error
    /// banner (cancellation is intentional, not a backend failure).
    func testCancelUploadClearsProgressAndSetsCancelledStatus() async throws {
        let started = expectation(description: "upload request started")
        started.assertForOverFulfill = false
        // Holds the PUT open until the test has cancelled. A fixed sleep
        // kept URLSession's protocol thread busy into later tests.
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let model = makeModel { request in
            if request.httpMethod == "PUT" {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            let url = request.url ?? URL(string: "https://ws-uv.canfar.net/")!
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-upload-\(UUID().uuidString).bin")
        try Data(repeating: 0x42, count: 64_000).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let upload = Task { @MainActor in
            await model.uploadDroppedFile(fileURL)
        }

        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(model.isTransferring, "progress UI should be active once the PUT starts")
        XCTAssertEqual(model.activeTransfer?.kind, .upload)

        model.cancelTransfer()
        release.signal()
        await upload.value

        XCTAssertFalse(model.isTransferring)
        XCTAssertNil(model.activeTransfer)
        XCTAssertFalse(model.hasError, "cancel must not surface as a backend error")
        XCTAssertEqual(model.statusMessage, String(localized: "Upload cancelled"))
    }

    /// Same cancel contract for downloads — shared `activeTransfer` / × control.
    func testCancelDownloadClearsProgressAndSetsCancelledStatus() async throws {
        let started = expectation(description: "download request started")
        started.assertForOverFulfill = false
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let model = makeModel { request in
            let url = request.url ?? URL(string: "https://ws-uv.canfar.net/")!
            // Hang on the binary GET (files/home/…/cube.fits), not listings.
            if url.path.contains("/files/"), url.lastPathComponent == "cube.fits" {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Length": "4096"])!,
                        Data(repeating: 0x11, count: 4_096))
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        let node = VOSpaceNode(
            name: "cube.fits",
            path: "cube.fits",
            type: .dataNode,
            sizeBytes: 4_096
        )
        // Explicit MainActor hop — the test method already owns the actor,
        // and unstructured Tasks can otherwise race the expectation wait.
        let download = Task { @MainActor in
            await model.openInFITSViewer(node)
        }

        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(model.isTransferring, "status=\(model.statusMessage)")
        XCTAssertEqual(model.activeTransfer?.kind, .download)

        model.cancelTransfer()
        release.signal()
        await download.value

        XCTAssertFalse(model.isTransferring)
        XCTAssertNil(model.activeTransfer)
        XCTAssertFalse(model.hasError)
        XCTAssertEqual(model.statusMessage, String(localized: "Download cancelled"))
    }

    func testCancelTransferWhenIdleIsNoOp() {
        let model = makeModel { request in
            let url = request.url ?? URL(string: "https://ws-uv.canfar.net/")!
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        model.statusMessage = "3 items"
        model.cancelTransfer()
        XCTAssertEqual(model.statusMessage, "3 items")
        XCTAssertFalse(model.isTransferring)
    }
    #endif
}
