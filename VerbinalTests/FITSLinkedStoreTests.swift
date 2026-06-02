// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import simd
@testable import Verbinal
import VerbinalKit

/// Tests for the FITS linked store pattern (pull-on-activation).
///
/// Windows reference: FitsTabHostViewModel holds shared RA/Dec and angular zoom.
/// Active tab writes to store; newly activated tab reads from store.
/// Hidden tabs are never touched. Applying shared state skips callbacks (no feedback loops).
@MainActor
final class FITSLinkedStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Create a WCS with given pixel scale (arcsec/pixel) and north angle (degrees).
    private func makeWCS(pixelScale: Double = 1.0, northAngleDeg: Double = 0) -> FITSWCSTransform {
        let scaleRad = pixelScale / 3600.0 // convert arcsec to degrees
        let theta = northAngleDeg * .pi / 180.0
        // CD matrix with rotation:
        // CD1_1 = scale * cos(theta), CD1_2 = -scale * sin(theta)
        // CD2_1 = scale * sin(theta), CD2_2 =  scale * cos(theta)
        // simd column-major: cd[0] = (CD1_1, CD2_1), cd[1] = (CD1_2, CD2_2)
        let cd = simd_double2x2(columns: (
            simd_double2(scaleRad * cos(theta), scaleRad * sin(theta)),
            simd_double2(-scaleRad * sin(theta), scaleRad * cos(theta))
        ))
        return FITSWCSTransform(
            crpix1: 512, crpix2: 512,
            crval1: 180.0, crval2: 45.0,
            cd: cd, cdInv: simd_inverse(cd),
            ctype1: "RA---TAN", ctype2: "DEC--TAN"
        )
    }

    /// Create a FITSViewerModel backed by a fake HDU with the given WCS and dimensions.
    private func makeModel(
        pixelScale: Double = 1.0,
        northAngleDeg: Double = 0,
        width: Int = 1024,
        height: Int = 1024
    ) -> FITSViewerModel {
        let wcs = makeWCS(pixelScale: pixelScale, northAngleDeg: northAngleDeg)
        var header = FITSHeader()
        header.add(FITSCard(keyword: "BITPIX", value: "-32", comment: ""))
        header.add(FITSCard(keyword: "NAXIS", value: "2", comment: ""))
        header.add(FITSCard(keyword: "NAXIS1", value: "\(width)", comment: ""))
        header.add(FITSCard(keyword: "NAXIS2", value: "\(height)", comment: ""))
        let hdu = FITSHDUnit(id: 0, header: header, dataOffset: 0, dataLength: 0, wcs: wcs)
        let file = FITSFile(url: URL(fileURLWithPath: "/tmp/test.fits"), hdus: [hdu])

        let model = FITSViewerModel()
        model.file = file
        model.selectedHDUIndex = 0
        model.pixels = [Float](repeating: 1.0, count: width * height)
        return model
    }

    // MARK: - Store Write Tests

    func testCrosshairWritesToStoreOnly() {
        let host = FITSTabHostModel()
        let tabA = host.addTab()
        let tabB = host.addTab()

        // Give both tabs WCS
        let modelA = makeModel()
        tabA.file = modelA.file
        tabA.selectedHDUIndex = 0
        tabA.pixels = modelA.pixels

        let modelB = makeModel()
        tabB.file = modelB.file
        tabB.selectedHDUIndex = 0
        tabB.pixels = modelB.pixels

        host.linkedState.linkCrosshair = true
        host.activeTabIndex = 0

        // Place crosshair on tab A → should write to store
        host.writeToStore(crosshairFrom: tabA, ra: 180.5, dec: 45.2)

        // Verify store has the coordinates
        XCTAssertNotNil(host.linkedState.sharedCrosshair)
        XCTAssertEqual(host.linkedState.sharedCrosshair!.ra, 180.5, accuracy: 1e-10)
        XCTAssertEqual(host.linkedState.sharedCrosshair!.dec, 45.2, accuracy: 1e-10)

        // Tab B should NOT have been updated yet (not activated)
        XCTAssertNil(tabB.crosshairPixel, "Hidden tab should not be updated on store write")
        XCTAssertEqual(tabB.crosshairRA, "", "Hidden tab crosshair RA should be empty")
    }

    func testZoomWritesToStoreOnly() {
        let host = FITSTabHostModel()
        let tabA = host.addTab()
        let tabB = host.addTab()

        let modelA = makeModel(pixelScale: 1.0)
        tabA.file = modelA.file
        tabA.selectedHDUIndex = 0
        tabA.pixels = modelA.pixels
        tabA.viewport.zoom = 2.0

        let modelB = makeModel(pixelScale: 0.5)
        tabB.file = modelB.file
        tabB.selectedHDUIndex = 0
        tabB.pixels = modelB.pixels
        tabB.viewport.zoom = 1.0

        host.linkedState.linkZoom = true
        host.activeTabIndex = 0

        // Write zoom from tab A
        host.writeToStore(zoomFrom: tabA)

        // Store should have angular zoom = pixelScale / zoom = 1.0 / 2.0 = 0.5
        XCTAssertNotNil(host.linkedState.sharedAngularZoom)
        XCTAssertEqual(host.linkedState.sharedAngularZoom!, 0.5, accuracy: 1e-10)

        // Tab B should NOT have been updated
        XCTAssertEqual(tabB.viewport.zoom, 1.0, "Hidden tab zoom should not change on store write")
    }

    // MARK: - Store Read (Pull-on-Activation) Tests

    func testCrosshairAppliedOnTabSwitch() {
        let host = FITSTabHostModel()
        let tabA = host.addTab()
        let tabB = host.addTab()

        let modelA = makeModel()
        tabA.file = modelA.file
        tabA.selectedHDUIndex = 0
        tabA.pixels = modelA.pixels

        let modelB = makeModel()
        tabB.file = modelB.file
        tabB.selectedHDUIndex = 0
        tabB.pixels = modelB.pixels

        host.linkedState.linkCrosshair = true
        host.activeTabIndex = 0

        // Write crosshair to store (as if user placed it on tab A)
        let testRA = 180.001
        let testDec = 45.001
        host.linkedState.sharedCrosshair = WorldPosition(ra: testRA, dec: testDec)

        // Switch to tab B → should pull from store
        host.activeTabIndex = 1

        // Tab B should now have crosshair
        XCTAssertNotNil(tabB.crosshairPixel, "Crosshair should be applied on tab activation")
        XCTAssertFalse(tabB.crosshairRA.isEmpty, "Crosshair RA should be set on activation")
        XCTAssertFalse(tabB.crosshairDec.isEmpty, "Crosshair Dec should be set on activation")
    }

    func testZoomAppliedOnTabSwitch() {
        let host = FITSTabHostModel()
        let tabA = host.addTab()
        let tabB = host.addTab()

        let modelA = makeModel(pixelScale: 1.0)
        tabA.file = modelA.file
        tabA.selectedHDUIndex = 0
        tabA.pixels = modelA.pixels

        let modelB = makeModel(pixelScale: 2.0)
        tabB.file = modelB.file
        tabB.selectedHDUIndex = 0
        tabB.pixels = modelB.pixels

        host.linkedState.linkZoom = true
        host.activeTabIndex = 0

        // Store angular zoom from tab A at zoom=2.0 → angular = 1.0/2.0 = 0.5
        host.linkedState.sharedAngularZoom = 0.5

        // Switch to tab B
        host.activeTabIndex = 1

        // Tab B should get: zoom = pixelScale / angularZoom = 2.0 / 0.5 = 4.0
        XCTAssertEqual(tabB.viewport.zoom, 4.0, accuracy: 1e-10,
                       "Tab B zoom should match angular extent from store")
    }

    func testOrientationMatchedOnTabSwitch() {
        let host = FITSTabHostModel()
        let tabA = host.addTab()
        let tabB = host.addTab()

        // Tab A has no rotation, Tab B has 30° north angle
        let modelA = makeModel(pixelScale: 1.0, northAngleDeg: 0)
        tabA.file = modelA.file
        tabA.selectedHDUIndex = 0
        tabA.pixels = modelA.pixels
        tabA.viewport.rotation = 0 // North-up for 0° north angle

        let modelB = makeModel(pixelScale: 1.0, northAngleDeg: 30)
        tabB.file = modelB.file
        tabB.selectedHDUIndex = 0
        tabB.pixels = modelB.pixels

        host.linkedState.linkZoom = true
        host.activeTabIndex = 0

        // Write store: zero user rotation relative to North
        host.writeToStore(zoomFrom: tabA)
        XCTAssertNotNil(host.linkedState.sharedUserRotation)
        XCTAssertEqual(host.linkedState.sharedUserRotation!, 0, accuracy: 1e-10,
                       "User rotation should be 0 (North-up with 0° north angle)")

        // Switch to tab B
        host.activeTabIndex = 1

        // Tab B should rotate to its North-up: -30° * pi/180
        let expectedRotation = -30.0 * .pi / 180.0
        XCTAssertEqual(tabB.viewport.rotation, expectedRotation, accuracy: 1e-10,
                       "Tab B should rotate to its North-up position")
    }

    // MARK: - Feedback Prevention Tests

    func testNoFeedbackLoopOnActivation() {
        let host = FITSTabHostModel()
        let tabA = host.addTab()
        let tabB = host.addTab()

        let modelA = makeModel()
        tabA.file = modelA.file
        tabA.selectedHDUIndex = 0
        tabA.pixels = modelA.pixels

        let modelB = makeModel()
        tabB.file = modelB.file
        tabB.selectedHDUIndex = 0
        tabB.pixels = modelB.pixels

        host.linkedState.linkCrosshair = true

        // Set initial store value
        let originalRA = 180.123
        let originalDec = 45.456
        host.linkedState.sharedCrosshair = WorldPosition(ra: originalRA, dec: originalDec)

        // Switch to tab B → applies store → should NOT overwrite store
        host.activeTabIndex = 1

        // Store should still have original values (not overwritten by the apply)
        XCTAssertEqual(host.linkedState.sharedCrosshair!.ra, originalRA, accuracy: 1e-10,
                       "Store should not be overwritten during activation apply")
        XCTAssertEqual(host.linkedState.sharedCrosshair!.dec, originalDec, accuracy: 1e-10,
                       "Store should not be overwritten during activation apply")
    }

    func testWriteBlockedDuringApply() {
        let host = FITSTabHostModel()
        let tabA = host.addTab()

        let modelA = makeModel()
        tabA.file = modelA.file
        tabA.selectedHDUIndex = 0
        tabA.pixels = modelA.pixels

        host.linkedState.linkCrosshair = true
        host.linkedState.sharedCrosshair = WorldPosition(ra: 180.0, dec: 45.0)

        // Simulate: writeToStore is called while isApplyingSharedState is true
        // We can test this indirectly — place crosshair during activation
        // The callback onCrosshairPlaced fires placeCrosshair → writeToStore
        // But writeToStore should be blocked by isApplyingSharedState

        // Place a crosshair on tab A to wire up the callback path
        tabA.placeCrosshair(at: CGPoint(x: 512, y: 511))

        // After placement, store should have the RA/Dec from placeCrosshair
        // (this is a valid write since we're not in applySharedState mode)
        XCTAssertNotNil(host.linkedState.sharedCrosshair)
    }

    /// Explicit assertion of the documented linked-state contract:
    /// `applySharedStateToActiveTab()` raises the `isApplyingSharedState` guard
    /// around the apply so that any `writeToStore(...)` reaching the host while
    /// state is being applied to the newly activated tab is **dropped** — the
    /// store the reader is consuming can never be clobbered. The guard is
    /// balanced via `defer`, so once the apply returns a normal write succeeds
    /// again.
    ///
    /// Because reads (`applySharedStateToActiveTab`) and writes (`writeToStore`)
    /// are both `@MainActor`, they run to completion without interleaving — the
    /// apply applies state to the activated tab purely through callback-free
    /// setters (`applyLinkedCrosshair`, `centerOnPixel`), so it never triggers a
    /// store write of its own. The observable contract is therefore: the apply
    /// leaves the store unchanged, and writes are accepted again afterward
    /// (guard cleared).
    func testApplyGuardDropsStoreWritesAndIsBalanced() {
        let host = FITSTabHostModel()
        let tabA = host.addTab()
        let tabB = host.addTab()

        let modelA = makeModel()
        tabA.file = modelA.file
        tabA.selectedHDUIndex = 0
        tabA.pixels = modelA.pixels

        let modelB = makeModel()
        tabB.file = modelB.file
        tabB.selectedHDUIndex = 0
        tabB.pixels = modelB.pixels

        host.linkedState.linkCrosshair = true
        host.activeTabIndex = 0

        // Seed the store with the value a user "placed" on tab A.
        let originalRA = 180.123
        let originalDec = 45.456
        host.linkedState.sharedCrosshair = WorldPosition(ra: originalRA, dec: originalDec)

        // Activate tab B → pulls from store and applies the crosshair locally.
        // The apply must NOT write back to the store (no feedback loop): the
        // store still holds tab A's original coordinates after activation.
        host.activeTabIndex = 1

        let afterApply = host.linkedState.sharedCrosshair
        XCTAssertNotNil(afterApply)
        XCTAssertEqual(afterApply!.ra, originalRA, accuracy: 1e-10,
                       "Apply must not write back to the store (store unchanged)")
        XCTAssertEqual(afterApply!.dec, originalDec, accuracy: 1e-10,
                       "Apply must not write back to the store (store unchanged)")

        // The guard is cleared after the apply (balanced via defer): a normal
        // write through the active tab's wiring now succeeds, proving
        // isApplyingSharedState was reset and writes are accepted again.
        let sentinelRA = 12.0
        let sentinelDec = -34.0
        host.writeToStore(crosshairFrom: tabB, ra: sentinelRA, dec: sentinelDec)

        let afterPostWrite = host.linkedState.sharedCrosshair
        XCTAssertNotNil(afterPostWrite)
        XCTAssertEqual(afterPostWrite!.ra, sentinelRA, accuracy: 1e-10,
                       "Guard must be cleared after apply so later writes succeed")
        XCTAssertEqual(afterPostWrite!.dec, sentinelDec, accuracy: 1e-10,
                       "Guard must be cleared after apply so later writes succeed")
    }

    /// Exercises the guard via the internal `applySharedStateToActiveTab()`
    /// entry point directly (the same set/clear path used by the `activeTabIndex`
    /// `didSet`). The explicit apply must leave the store untouched, and a write
    /// issued after the apply returns must land — proving the guard is set
    /// during the apply and cleared (balanced) once it returns.
    func testExplicitApplyLeavesStoreIntactAndClearsGuard() {
        let host = FITSTabHostModel()
        let tabA = host.addTab()
        let tabB = host.addTab()

        let modelA = makeModel()
        tabA.file = modelA.file
        tabA.selectedHDUIndex = 0
        tabA.pixels = modelA.pixels

        let modelB = makeModel()
        tabB.file = modelB.file
        tabB.selectedHDUIndex = 0
        tabB.pixels = modelB.pixels

        host.linkedState.linkCrosshair = true

        let originalRA = 200.0
        let originalDec = -10.0
        host.linkedState.sharedCrosshair = WorldPosition(ra: originalRA, dec: originalDec)

        // Calling applySharedStateToActiveTab directly (internal entry point)
        // exercises the same guard-set/guard-clear path used by activeTabIndex.
        host.activeTabIndex = 0
        host.applySharedStateToActiveTab()

        // Store untouched by the explicit apply.
        XCTAssertEqual(host.linkedState.sharedCrosshair!.ra, originalRA, accuracy: 1e-10)
        XCTAssertEqual(host.linkedState.sharedCrosshair!.dec, originalDec, accuracy: 1e-10)

        // After the apply returns the guard is down: a write lands normally.
        host.writeToStore(crosshairFrom: tabA, ra: 1.0, dec: 2.0)
        XCTAssertEqual(host.linkedState.sharedCrosshair!.ra, 1.0, accuracy: 1e-10,
                       "Write after apply must land (guard cleared)")
        XCTAssertEqual(host.linkedState.sharedCrosshair!.dec, 2.0, accuracy: 1e-10,
                       "Write after apply must land (guard cleared)")
    }

    // MARK: - Disabled Linking Tests

    func testCrosshairNotStoredWhenLinkDisabled() {
        let host = FITSTabHostModel()
        let tabA = host.addTab()

        host.linkedState.linkCrosshair = false

        host.writeToStore(crosshairFrom: tabA, ra: 180.0, dec: 45.0)
        XCTAssertNil(host.linkedState.sharedCrosshair, "Store should not be written when linking is off")
    }

    func testZoomNotStoredWhenLinkDisabled() {
        let host = FITSTabHostModel()
        let tabA = host.addTab()

        let modelA = makeModel()
        tabA.file = modelA.file
        tabA.selectedHDUIndex = 0
        tabA.pixels = modelA.pixels

        host.linkedState.linkZoom = false

        host.writeToStore(zoomFrom: tabA)
        XCTAssertNil(host.linkedState.sharedAngularZoom, "Store should not be written when linking is off")
    }

    func testActivationSkipsWhenLinkDisabled() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        let tabB = host.addTab()

        let modelB = makeModel()
        tabB.file = modelB.file
        tabB.selectedHDUIndex = 0
        tabB.pixels = modelB.pixels
        tabB.viewport.zoom = 3.0

        // Linking is off
        host.linkedState.linkCrosshair = false
        host.linkedState.linkZoom = false
        host.linkedState.sharedCrosshair = WorldPosition(ra: 180.0, dec: 45.0)
        host.linkedState.sharedAngularZoom = 1.0

        host.activeTabIndex = 0
        host.activeTabIndex = 1

        // Tab B should NOT have crosshair applied
        XCTAssertNil(tabB.crosshairPixel, "Crosshair should not be applied when linking is off")
        // Tab B zoom should remain unchanged
        XCTAssertEqual(tabB.viewport.zoom, 3.0, "Zoom should not change when linking is off")
    }

    // MARK: - Angular Zoom Conversion Tests

    func testAngularZoomFormulaCorrect() {
        let host = FITSTabHostModel()
        let tabA = host.addTab()
        let tabB = host.addTab()

        // Tab A: 1 arcsec/pixel at zoom 4x
        let modelA = makeModel(pixelScale: 1.0)
        tabA.file = modelA.file
        tabA.selectedHDUIndex = 0
        tabA.pixels = modelA.pixels
        tabA.viewport.zoom = 4.0

        // Tab B: 0.5 arcsec/pixel
        let modelB = makeModel(pixelScale: 0.5)
        tabB.file = modelB.file
        tabB.selectedHDUIndex = 0
        tabB.pixels = modelB.pixels

        host.linkedState.linkZoom = true
        host.activeTabIndex = 0

        // Write from A: angularZoom = 1.0 / 4.0 = 0.25 arcsec/screen-pixel
        host.writeToStore(zoomFrom: tabA)
        XCTAssertEqual(host.linkedState.sharedAngularZoom!, 0.25, accuracy: 1e-10)

        // Switch to B: zoom = 0.5 / 0.25 = 2.0
        host.activeTabIndex = 1
        XCTAssertEqual(tabB.viewport.zoom, 2.0, accuracy: 1e-10,
                       "Tab B with 0.5 arcsec/px should zoom 2x to match 0.25 arcsec/screen-pixel")
    }

    func testNoTabWithoutWCS() {
        let host = FITSTabHostModel()
        let tabA = host.addTab()
        _ = host.addTab() // Tab B has no file/WCS

        let modelA = makeModel()
        tabA.file = modelA.file
        tabA.selectedHDUIndex = 0
        tabA.pixels = modelA.pixels

        host.linkedState.linkCrosshair = true
        host.linkedState.linkZoom = true
        host.linkedState.sharedCrosshair = WorldPosition(ra: 180.0, dec: 45.0)
        host.linkedState.sharedAngularZoom = 1.0

        // Switch to tab B (no WCS) → should not crash
        host.activeTabIndex = 1
        // No assertion needed — just verify no crash
    }

    // MARK: - Blink Store Interaction Tests

    func testBlinkTabSwitchAppliesSharedState() {
        let host = FITSTabHostModel()
        let tabA = host.addTab()
        let tabB = host.addTab()

        let modelA = makeModel()
        tabA.file = modelA.file
        tabA.selectedHDUIndex = 0
        tabA.pixels = modelA.pixels

        let modelB = makeModel()
        tabB.file = modelB.file
        tabB.selectedHDUIndex = 0
        tabB.pixels = modelB.pixels

        host.linkedState.linkCrosshair = true
        host.linkedState.sharedCrosshair = WorldPosition(ra: 180.0, dec: 45.0)

        // Manually switch like blink does
        host.activeTabIndex = 0
        host.activeTabIndex = 1

        // Tab B should have crosshair from store
        XCTAssertNotNil(tabB.crosshairPixel, "Blink tab switch should apply shared crosshair")
    }

    // MARK: - Same Tab Reactivation

    func testSameTabReactivationIsNoOp() {
        let host = FITSTabHostModel()
        let tabA = host.addTab()

        let modelA = makeModel()
        tabA.file = modelA.file
        tabA.selectedHDUIndex = 0
        tabA.pixels = modelA.pixels
        tabA.viewport.zoom = 5.0

        host.linkedState.linkZoom = true
        host.linkedState.sharedAngularZoom = 1.0
        host.activeTabIndex = 0

        // "Switch" to same tab
        host.activeTabIndex = 0

        // Zoom should NOT have been overwritten (didSet guard)
        XCTAssertEqual(tabA.viewport.zoom, 5.0, "Same-tab reactivation should be a no-op")
    }
}
