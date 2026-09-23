// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// `parseRangeRaw` is the single range parser behind every Search
/// constraint builder (spatial, spectral, temporal, misc).
final class RangeParserTests: XCTestCase {

    func testParseEquals() {
        let result = parseRangeRaw("25")
        XCTAssertEqual(result?.valueRaw, "25")
        XCTAssertEqual(result?.operand, .equals)
    }

    func testParseRange() {
        let result = parseRangeRaw("20..30")
        XCTAssertEqual(result?.lowerRaw, "20")
        XCTAssertEqual(result?.upperRaw, "30")
        XCTAssertEqual(result?.operand, .range)
    }

    func testParseLessThan() {
        let result = parseRangeRaw("< 25")
        XCTAssertEqual(result?.upperRaw, "25")
        XCTAssertEqual(result?.operand, .lessThan)
        XCTAssertNil(result?.lowerRaw)
    }

    func testParseLessThanEquals() {
        let result = parseRangeRaw("<= 100")
        XCTAssertEqual(result?.upperRaw, "100")
        XCTAssertEqual(result?.operand, .lessThanEquals)
    }

    func testParseGreaterThan() {
        let result = parseRangeRaw("> 50")
        XCTAssertEqual(result?.lowerRaw, "50")
        XCTAssertEqual(result?.operand, .greaterThan)
        XCTAssertNil(result?.upperRaw)
    }

    func testParseGreaterThanEquals() {
        let result = parseRangeRaw(">= 10")
        XCTAssertEqual(result?.lowerRaw, "10")
        XCTAssertEqual(result?.operand, .greaterThanEquals)
    }

    func testParseEmpty() {
        XCTAssertNil(parseRangeRaw(""))
    }

    func testParseWhitespace() {
        XCTAssertNil(parseRangeRaw("   "))
    }

    func testParseRawRange() {
        let raw = parseRangeRaw("2018-01..2019-06")
        XCTAssertNotNil(raw)
        XCTAssertEqual(raw?.lowerRaw, "2018-01")
        XCTAssertEqual(raw?.upperRaw, "2019-06")
        XCTAssertEqual(raw?.operand, .range)
    }

    func testParseDecimalValue() {
        let result = parseRangeRaw("3.14")
        XCTAssertEqual(result?.valueRaw, "3.14")
        XCTAssertEqual(result?.operand, .equals)
    }

    func testParseNegativeValueIsNotARange() {
        // A leading minus must stay a value, not an operator or separator.
        let result = parseRangeRaw("-12.5")
        XCTAssertEqual(result?.valueRaw, "-12.5")
        XCTAssertEqual(result?.operand, .equals)
    }
}
