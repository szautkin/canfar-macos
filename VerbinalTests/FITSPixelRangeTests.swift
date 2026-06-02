// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Ticket 037: a degenerate pixel range (empty buffer, uniform pixels, or
/// all-NaN data) must fall back to 0...1 AND be surfaced via a model flag so
/// the cut-range controls can explain the condition instead of silently
/// presenting a bogus 0...1 window.
@MainActor
final class FITSPixelRangeTests: XCTestCase {

    // MARK: - scanPixelRange fallback

    func testScanPixelRangeEmptyReturnsFallback() {
        let range = FITSViewerModel.scanPixelRange([])
        XCTAssertEqual(range.min, 0)
        XCTAssertEqual(range.max, 1)
    }

    func testScanPixelRangeUniformReturnsFallback() {
        // Every finite pixel identical → no spread → degenerate fallback.
        let range = FITSViewerModel.scanPixelRange([42, 42, 42, 42])
        XCTAssertEqual(range.min, 0)
        XCTAssertEqual(range.max, 1)
    }

    func testScanPixelRangeAllNaNReturnsFallback() {
        let range = FITSViewerModel.scanPixelRange([.nan, .nan, .nan])
        XCTAssertEqual(range.min, 0)
        XCTAssertEqual(range.max, 1)
    }

    func testScanPixelRangeNormalDataReturnsRealRange() {
        // Mixed finite values (with a NaN that must be ignored) → real range.
        let range = FITSViewerModel.scanPixelRange([3, 1, .nan, 7, 5])
        XCTAssertEqual(range.min, 1)
        XCTAssertEqual(range.max, 7)
        XCTAssertFalse(range.degenerate)
    }

    // MARK: - scan degenerate component

    /// The scan's `degenerate` flag — not a min/max comparison — is the source
    /// of truth. Crucially, the degenerate fallback is a *valid* 0...1 interval
    /// (0 < 1), so any `pixelMin >= pixelMax` derivation would wrongly report it
    /// as a real range. These cases pin that the flag is carried explicitly.
    func testScanDegenerateComponentReflectsData() {
        XCTAssertTrue(FITSViewerModel.scanPixelRange([]).degenerate)
        XCTAssertTrue(FITSViewerModel.scanPixelRange([7, 7, 7]).degenerate)
        XCTAssertTrue(FITSViewerModel.scanPixelRange([.nan, .nan]).degenerate)
        XCTAssertFalse(FITSViewerModel.scanPixelRange([1, 9]).degenerate)
    }

    // MARK: - pixelRangeDegenerate flag on the model

    func testDegenerateFlagSetFromEmptyScan() {
        let model = FITSViewerModel()
        let range = FITSViewerModel.scanPixelRange([])
        model.pixelMin = range.min
        model.pixelMax = range.max
        model.pixelRangeDegenerate = range.degenerate
        XCTAssertTrue(model.pixelRangeDegenerate)
    }

    func testDegenerateFlagSetFromUniformScan() {
        let model = FITSViewerModel()
        let range = FITSViewerModel.scanPixelRange([5, 5, 5])
        model.pixelMin = range.min
        model.pixelMax = range.max
        model.pixelRangeDegenerate = range.degenerate
        XCTAssertTrue(model.pixelRangeDegenerate,
                      "Uniform data falls back to 0...1 but must still be flagged degenerate")
        // The fallback range is a *valid* 0...1 interval — exactly why a
        // pixelMin >= pixelMax derivation would wrongly report non-degenerate.
        XCTAssertLessThan(model.pixelMin, model.pixelMax)
    }

    func testDegenerateFlagClearedFromNormalScan() {
        let model = FITSViewerModel()
        let range = FITSViewerModel.scanPixelRange([1, 2, 3, 4])
        model.pixelMin = range.min
        model.pixelMax = range.max
        model.pixelRangeDegenerate = range.degenerate
        XCTAssertFalse(model.pixelRangeDegenerate)
    }

    func testDefaultModelRangeIsNotDegenerate() {
        // Fresh model defaults to pixelMin = 0, pixelMax = 1 with the flag
        // unset → NOT degenerate, matching the slider's usable default range
        // before any file is loaded.
        let model = FITSViewerModel()
        XCTAssertFalse(model.pixelRangeDegenerate)
    }
}
