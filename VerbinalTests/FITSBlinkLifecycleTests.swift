// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import CoreGraphics
@testable import Verbinal

/// Ticket 003: the FITS blink fade lifecycle — `tickBlink()` must be a no-op
/// when not blinking/paused, step + bounce correctly, and `stopBlink()` /
/// `closeTab()` must deterministically clear all blink state so a torn-down
/// session can't keep animating.
@MainActor
final class FITSBlinkLifecycleTests: XCTestCase {

    private func onePixelImage() -> CGImage? {
        let cs = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 1, space: cs,
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        return ctx?.makeImage()
    }

    func testTickIsNoOpWhenNotBlinking() {
        let host = FITSTabHostModel()
        host.isBlinking = false
        host.blinkOpacity = 0.3
        host.tickBlink()
        XCTAssertEqual(host.blinkOpacity, 0.3, "tick must not mutate opacity when not blinking")
    }

    func testTickIsNoOpWhenPaused() {
        let host = FITSTabHostModel()
        host.isBlinking = true
        host.isBlinkPaused = true
        host.blinkOpacity = 0.3
        host.tickBlink()
        XCTAssertEqual(host.blinkOpacity, 0.3, "tick must not mutate opacity while paused")
    }

    func testTickStepSize() {
        let host = FITSTabHostModel()
        host.blinkInterval = 1.0           // step = 0.05 / max(1.0, 0.1) = 0.05
        host.isBlinking = true
        host.blinkOpacity = 0
        // blinkFadeDirection defaults to +1 at construction, so the first
        // tick adds one step.
        host.tickBlink()
        XCTAssertEqual(host.blinkOpacity, 0.05, accuracy: 1e-9)
    }

    func testTickBouncesWithinBounds() {
        let host = FITSTabHostModel()
        host.blinkInterval = 1.0           // 20 ticks per transition
        host.isBlinking = true
        host.blinkOpacity = 0

        var hitTop = false
        var cameBackDown = false
        var previous = host.blinkOpacity
        for _ in 0..<60 {                  // 3 transitions worth
            host.tickBlink()
            XCTAssertGreaterThanOrEqual(host.blinkOpacity, 0.0)
            XCTAssertLessThanOrEqual(host.blinkOpacity, 1.0)
            if host.blinkOpacity >= 1.0 { hitTop = true }
            if hitTop && host.blinkOpacity < previous { cameBackDown = true }
            previous = host.blinkOpacity
        }
        XCTAssertTrue(hitTop, "opacity should reach the top of the range")
        XCTAssertTrue(cameBackDown, "opacity should reverse and fade back down")
    }

    func testStopBlinkResetsAllState() {
        let host = FITSTabHostModel()
        host.isBlinking = true
        host.isBlinkPaused = true
        host.blinkOpacity = 0.7
        host.blinkOverlayImage = onePixelImage()

        host.stopBlink()

        XCTAssertFalse(host.isBlinking)
        XCTAssertFalse(host.isBlinkPaused)
        XCTAssertEqual(host.blinkOpacity, 0)
        XCTAssertNil(host.blinkOverlayImage)
        XCTAssertNil(host.blinkTransform)

        // A subsequent tick must not revive opacity.
        host.blinkOpacity = 0
        host.tickBlink()
        XCTAssertEqual(host.blinkOpacity, 0, "tick after stop must be a no-op")
    }

    func testCloseTabStopsBlinkWhenParticipant() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        host.isBlinking = true
        host.blinkTabA = 0
        host.blinkTabB = 1

        host.closeTab(at: 0)   // closing a blink participant

        XCTAssertFalse(host.isBlinking, "closing a blink tab must stop the blink session")
        XCTAssertEqual(host.tabCount, 1)
    }

    func testCloseTabLeavesBlinkAloneForNonParticipant() {
        let host = FITSTabHostModel()
        _ = host.addTab() // 0
        _ = host.addTab() // 1
        _ = host.addTab() // 2
        host.isBlinking = true
        host.blinkTabA = 0
        host.blinkTabB = 1

        host.closeTab(at: 2)   // not part of the blink pair

        XCTAssertTrue(host.isBlinking, "closing an unrelated tab must not stop the blink")
        host.stopBlink()       // cleanup
    }
}
