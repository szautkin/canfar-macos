// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

@MainActor
final class ToastManagerTests: XCTestCase {

    func testShowSetsMessage() {
        let toast = ToastManager()
        toast.show("Hello")
        XCTAssertEqual(toast.message, "Hello")
        XCTAssertFalse(toast.isError)
    }

    func testShowErrorFlag() {
        let toast = ToastManager()
        toast.show("Failed", isError: true)
        XCTAssertEqual(toast.message, "Failed")
        XCTAssertTrue(toast.isError)
    }

    func testDismissClearsMessage() {
        let toast = ToastManager()
        toast.show("Hello")
        toast.dismiss()
        XCTAssertNil(toast.message)
    }

    func testShowReplacesExisting() {
        let toast = ToastManager()
        toast.show("First")
        toast.show("Second")
        XCTAssertEqual(toast.message, "Second")
    }
}
