// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VerbinalKit

/// Ticket 001: `FITSParser.autoCut` must never crash on degenerate pixel
/// arrays — all-non-finite (samples becomes empty) returns the (0,1)
/// fallback, and a single finite value returns a sane, ordered range
/// rather than force-unwrapping `samples.first!`/`.last!`.
final class FITSAutoCutTests: XCTestCase {

    func testAllNonFiniteReturnsFallback() {
        let pixels: [Float] = [.nan, .infinity, -.infinity, .nan]
        let (lo, hi) = FITSParser.autoCut(pixels: pixels)
        XCTAssertEqual(lo, 0)
        XCTAssertEqual(hi, 1)
    }

    func testEmptyInputReturnsFallback() {
        let (lo, hi) = FITSParser.autoCut(pixels: [])
        XCTAssertEqual(lo, 0)
        XCTAssertEqual(hi, 1)
    }

    func testSingleFiniteValueReturnsSaneRange() {
        // One finite value: median == value, sigma == 0, percentile fallback
        // collapses lo==hi, so the (minSample, maxSample) tail returns a
        // valid, non-crashing pair.
        let (lo, hi) = FITSParser.autoCut(pixels: [42])
        XCTAssertTrue(lo.isFinite && hi.isFinite)
        XCTAssertLessThanOrEqual(lo, hi)
    }

    func testNormalDistributionProducesOrderedRange() {
        var pixels: [Float] = []
        for i in 0..<1000 { pixels.append(Float(i % 100)) }
        let (lo, hi) = FITSParser.autoCut(pixels: pixels)
        XCTAssertLessThan(lo, hi)
        XCTAssertGreaterThanOrEqual(lo, 0)
        XCTAssertLessThanOrEqual(hi, 99)
    }
}
