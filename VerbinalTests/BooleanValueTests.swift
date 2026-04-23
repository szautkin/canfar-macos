// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class BooleanValueTests: XCTestCase {

    func testTrueLiterals() {
        for literal in ["true", "TRUE", "True", "1", "t", "T", "yes", "Yes", "YES", "y", "Y"] {
            XCTAssertEqual(BooleanValue.parse(literal), true, "Expected true from \(literal)")
        }
    }

    func testFalseLiterals() {
        for literal in ["false", "FALSE", "False", "0", "f", "F", "no", "No", "NO", "n", "N"] {
            XCTAssertEqual(BooleanValue.parse(literal), false, "Expected false from \(literal)")
        }
    }

    func testUnknownLiteralsReturnNil() {
        for literal in ["", "maybe", "null", "null", "2", "tru", "fals", "yep"] {
            XCTAssertNil(BooleanValue.parse(literal), "Expected nil from \(literal)")
        }
    }

    func testLooksBoolean() {
        XCTAssertTrue(BooleanValue.looksBoolean("true"))
        XCTAssertTrue(BooleanValue.looksBoolean("FALSE"))
        XCTAssertTrue(BooleanValue.looksBoolean("0"))
        XCTAssertFalse(BooleanValue.looksBoolean("unknown"))
        XCTAssertFalse(BooleanValue.looksBoolean(""))
    }
}
