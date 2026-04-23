// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class FilterExpressionTests: XCTestCase {

    // MARK: - Numeric parsing

    func testPlainNumberParsesAsEqualComparison() {
        XCTAssertEqual(FilterExpression.parse("42", numericEligible: true),
                       .numeric(.equal, 42))
    }

    func testLessThan() {
        XCTAssertEqual(FilterExpression.parse("<5", numericEligible: true),
                       .numeric(.less, 5))
    }

    func testLessOrEqual() {
        XCTAssertEqual(FilterExpression.parse("<=10", numericEligible: true),
                       .numeric(.lessOrEqual, 10))
    }

    func testGreaterThan() {
        XCTAssertEqual(FilterExpression.parse(">3600", numericEligible: true),
                       .numeric(.greater, 3600))
    }

    func testGreaterOrEqual() {
        XCTAssertEqual(FilterExpression.parse(">= 100", numericEligible: true),
                       .numeric(.greaterOrEqual, 100))
    }

    func testEqualsExplicit() {
        XCTAssertEqual(FilterExpression.parse("=7", numericEligible: true),
                       .numeric(.equal, 7))
    }

    func testNegativeAndScientific() {
        XCTAssertEqual(FilterExpression.parse(">-1.5e-3", numericEligible: true),
                       .numeric(.greater, -0.0015))
    }

    func testWhitespaceAroundOperator() {
        XCTAssertEqual(FilterExpression.parse("  <  42  ", numericEligible: true),
                       .numeric(.less, 42))
    }

    // MARK: - Substring fallback

    func testTextInputFallsBackToSubstring() {
        XCTAssertEqual(FilterExpression.parse("NGC1234", numericEligible: true),
                       .substring("ngc1234"))
    }

    func testNumericEligibleFalseAlwaysSubstring() {
        XCTAssertEqual(FilterExpression.parse("<5", numericEligible: false),
                       .substring("<5"))
        XCTAssertEqual(FilterExpression.parse("42", numericEligible: false),
                       .substring("42"))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(FilterExpression.parse("", numericEligible: true))
        XCTAssertNil(FilterExpression.parse("   ", numericEligible: true))
    }

    // MARK: - Comparison semantics

    func testComparisonMatches() {
        XCTAssertTrue(FilterExpression.Comparison.less.matches(3, against: 5))
        XCTAssertFalse(FilterExpression.Comparison.less.matches(5, against: 5))
        XCTAssertTrue(FilterExpression.Comparison.lessOrEqual.matches(5, against: 5))
        XCTAssertTrue(FilterExpression.Comparison.greater.matches(5, against: 3))
        XCTAssertTrue(FilterExpression.Comparison.greaterOrEqual.matches(5, against: 5))
        XCTAssertTrue(FilterExpression.Comparison.equal.matches(5, against: 5))
    }
}
