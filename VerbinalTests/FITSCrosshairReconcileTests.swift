// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import CoreGraphics
@testable import Verbinal

/// Ticket 010: switching HDU must clear a stale out-of-bounds RA/Dec readout
/// when the crosshair is valid for the new HDU, and still clear the crosshair
/// entirely when it falls outside the new bounds.
@MainActor
final class FITSCrosshairReconcileTests: XCTestCase {

    func testInBoundsCrosshairClearsStaleOutOfBoundsReadout() {
        let model = FITSViewerModel()
        model.crosshairPixel = CGPoint(x: 5, y: 5)
        model.crosshairOutOfBounds = true
        model.outOfBoundsRA = "12:00:00"
        model.outOfBoundsDec = "+41:00:00"

        model.reconcileCrosshair(naxis1: 10, naxis2: 10)

        XCTAssertFalse(model.crosshairOutOfBounds)
        XCTAssertEqual(model.outOfBoundsRA, "")
        XCTAssertEqual(model.outOfBoundsDec, "")
        XCTAssertEqual(model.crosshairPixel, CGPoint(x: 5, y: 5), "a valid crosshair is kept")
    }

    func testOutOfBoundsCrosshairIsCleared() {
        let model = FITSViewerModel()
        model.crosshairPixel = CGPoint(x: 50, y: 5)   // x outside 10-wide HDU
        model.crosshairOutOfBounds = true
        model.outOfBoundsRA = "12:00:00"

        model.reconcileCrosshair(naxis1: 10, naxis2: 10)

        XCTAssertNil(model.crosshairPixel, "an out-of-bounds crosshair is cleared entirely")
        XCTAssertFalse(model.crosshairOutOfBounds)
        XCTAssertEqual(model.outOfBoundsRA, "")
    }

    func testNoCrosshairStillClearsStaleReadout() {
        let model = FITSViewerModel()
        model.crosshairPixel = nil
        model.crosshairOutOfBounds = true
        model.outOfBoundsRA = "12:00:00"

        model.reconcileCrosshair(naxis1: 10, naxis2: 10)

        XCTAssertFalse(model.crosshairOutOfBounds)
        XCTAssertEqual(model.outOfBoundsRA, "")
    }
}
