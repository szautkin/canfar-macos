// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class VOSpaceRelativePathTests: XCTestCase {

    func testEmptyAndRelativePassThrough() throws {
        XCTAssertEqual(try VOSpaceRelativePath.normalize("", username: "me"), "")
        XCTAssertEqual(try VOSpaceRelativePath.normalize("folder/file.txt", username: "me"), "folder/file.txt")
        XCTAssertEqual(try VOSpaceRelativePath.normalize("/folder/file.txt", username: "me"), "folder/file.txt")
    }

    func testStripsHomePrefixes() throws {
        XCTAssertEqual(try VOSpaceRelativePath.normalize("/home/me", username: "me"), "")
        XCTAssertEqual(try VOSpaceRelativePath.normalize("/home/me/", username: "me"), "")
        XCTAssertEqual(try VOSpaceRelativePath.normalize("/home/me/folder/file", username: "me"), "folder/file")
        XCTAssertEqual(try VOSpaceRelativePath.normalize("home/me/folder", username: "me"), "folder")
        XCTAssertEqual(try VOSpaceRelativePath.normalize("/arc/home/me/a/b", username: "me"), "a/b")
        XCTAssertEqual(try VOSpaceRelativePath.normalize("arc/home/me", username: "me"), "")
    }

    func testDoesNotStripADifferentUsersHomeOrUsernamePrefix() throws {
        XCTAssertEqual(
            try VOSpaceRelativePath.normalize("/home/other/file", username: "me"),
            "home/other/file")
        // `home/me` must not match `home/me2/…`.
        XCTAssertEqual(
            try VOSpaceRelativePath.normalize("home/me2/secret", username: "me"),
            "home/me2/secret")
    }

    func testRejectsTraversal() {
        XCTAssertThrowsError(try VOSpaceRelativePath.normalize("a/../b", username: "me")) { err in
            XCTAssertEqual(err as? VOSpaceRelativePath.Error, .traversal)
        }
        XCTAssertThrowsError(try VOSpaceRelativePath.normalize("/home/me/../escape", username: "me")) { err in
            XCTAssertEqual(err as? VOSpaceRelativePath.Error, .traversal)
        }
    }
}
