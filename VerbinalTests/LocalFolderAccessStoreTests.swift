// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class LocalFolderAccessStoreTests: XCTestCase {

    func testUserFacingAndContainerDownloadsRoundTripWhenTheyDiffer() {
        let user = LocalFolderAccessStore.userFacingDownloadsRoot
        let container = LocalFolderAccessStore.downloadsRoot
        guard user.standardizedFileURL.path != container.standardizedFileURL.path else {
            // Not sandboxed in this test host — mapping is a no-op.
            let nested = user.appendingPathComponent("verbinal-test.fits")
            XCTAssertEqual(
                LocalFolderAccessStore.resolveSandboxPath(nested).standardizedFileURL.path,
                nested.standardizedFileURL.path)
            XCTAssertEqual(LocalFolderAccessStore.userFacingPath(for: nested), nested.standardizedFileURL.path)
            return
        }
        let nestedUser = user.appendingPathComponent("shot.fits")
        let resolved = LocalFolderAccessStore.resolveSandboxPath(nestedUser)
        XCTAssertTrue(
            resolved.path.hasPrefix(container.standardizedFileURL.path),
            "user-facing Downloads must map onto the container path; got \(resolved.path)")
        XCTAssertEqual(
            LocalFolderAccessStore.userFacingPath(for: resolved),
            nestedUser.standardizedFileURL.path)
    }

    func testNonDownloadsPathsPassThrough() {
        let other = URL(fileURLWithPath: "/tmp/verbinal-not-downloads")
        XCTAssertEqual(
            LocalFolderAccessStore.resolveSandboxPath(other).standardizedFileURL.path,
            other.standardizedFileURL.path)
        XCTAssertEqual(
            LocalFolderAccessStore.userFacingPath(for: other),
            other.standardizedFileURL.path)
    }

    func testExpandedTildeDownloadsIsUserFacingHome() {
        XCTAssertEqual(
            LocalFolderAccessStore.expandedPath("~/Downloads"),
            LocalFolderAccessStore.userFacingDownloadsRoot.path)
        XCTAssertEqual(
            LocalFolderAccessStore.expandedPath("~"),
            LocalFolderAccessStore.realUserHome().path)
    }

    func testCandidateURLsForTildeDownloadsIncludeUserFacingRoot() {
        let candidates = LocalFolderAccessStore.candidateURLs(for: "~/Downloads", isDirectory: true)
        let user = LocalFolderAccessStore.userFacingDownloadsRoot.standardizedFileURL.path
        XCTAssertTrue(
            candidates.contains { $0.standardizedFileURL.path == user },
            "~/Downloads must resolve to the real user Downloads, not a relative '~/Downloads' path")
    }

    func testReadableURLFindsExistingTempFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbinal-readable-\(UUID().uuidString).dat")
        FileManager.default.createFile(atPath: url.path, contents: Data([1, 2, 3]), attributes: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(
            LocalFolderAccessStore.readableURL(for: url.path, directory: false)?.standardizedFileURL.path,
            url.standardizedFileURL.path)
        XCTAssertNil(LocalFolderAccessStore.readableURL(for: url.path, directory: true))
    }
}
