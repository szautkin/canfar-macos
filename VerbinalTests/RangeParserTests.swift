// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class RangeParserTests: XCTestCase {

    func testParseEquals() {
        let result = parseRange("25")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.value, 25.0)
        XCTAssertEqual(result?.operand, .equals)
    }

    func testParseRange() {
        let result = parseRange("20..30")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.lower, 20.0)
        XCTAssertEqual(result?.upper, 30.0)
        XCTAssertEqual(result?.operand, .range)
    }

    func testParseLessThan() {
        let result = parseRange("< 25")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.upper, 25.0)
        XCTAssertEqual(result?.operand, .lessThan)
        XCTAssertNil(result?.lower)
    }

    func testParseLessThanEquals() {
        let result = parseRange("<= 100")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.upper, 100.0)
        XCTAssertEqual(result?.operand, .lessThanEquals)
    }

    func testParseGreaterThan() {
        let result = parseRange("> 50")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.lower, 50.0)
        XCTAssertEqual(result?.operand, .greaterThan)
        XCTAssertNil(result?.upper)
    }

    func testParseGreaterThanEquals() {
        let result = parseRange(">= 10")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.lower, 10.0)
        XCTAssertEqual(result?.operand, .greaterThanEquals)
    }

    func testParseEmpty() {
        XCTAssertNil(parseRange(""))
    }

    func testParseWhitespace() {
        XCTAssertNil(parseRange("   "))
    }

    func testParseRawRange() {
        let raw = parseRangeRaw("2018-01..2019-06")
        XCTAssertNotNil(raw)
        XCTAssertEqual(raw?.lowerRaw, "2018-01")
        XCTAssertEqual(raw?.upperRaw, "2019-06")
        XCTAssertEqual(raw?.operand, .range)
    }

    func testParseDecimalValue() {
        let result = parseRange("3.14")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.value!, 3.14, accuracy: 0.001)
        XCTAssertEqual(result?.operand, .equals)
    }

    func testParseNegativeValue() {
        let result = parseRange("-12.5")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.value, -12.5)
        XCTAssertEqual(result?.operand, .equals)
    }
}
