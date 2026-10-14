// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Ticket 038: the debounced render's `Task.sleep` is the deliberate
/// cancellation point. A superseding call must cancel the earlier debounce so
/// it never fires a stale render, and a single call must produce exactly one
/// render after the debounce interval elapses.
@MainActor
final class FITSRenderDebounceTests: XCTestCase {

    func testSingleDebouncedCallRendersExactlyOnce() async {
        let model = FITSViewerModel()
        model.renderDebounceMs = 5  // short interval for the test
        var renderCount = 0
        model.renderImageOverride = { renderCount += 1 }

        model.renderImageDebounced()
        await model.awaitDebounceForTesting()

        XCTAssertEqual(renderCount, 1, "one debounced call fires exactly one render")
    }

    func testSupersedingCallCancelsEarlierDebounce() async {
        let model = FITSViewerModel()
        model.renderDebounceMs = 50  // long enough that the first call is still pending
        var renderedDelay: Int?
        model.renderImageOverride = { [weak model] in
            renderedDelay = model?.renderDebounceMs
        }

        // First (slow) debounce, then immediately supersede with a fast one.
        model.renderImageDebounced()
        model.renderDebounceMs = 5
        model.renderImageDebounced()

        // Await only the surviving (latest) debounce task.
        await model.awaitDebounceForTesting()

        // The cancelled 50ms task must not have fired; only the 5ms one did.
        XCTAssertEqual(renderedDelay, 5,
                       "the superseded debounce must not produce a render after cancellation")
    }

    func testSupersedingCallProducesOnlyOneRender() async {
        let model = FITSViewerModel()
        model.renderDebounceMs = 50
        var renderCount = 0
        model.renderImageOverride = { renderCount += 1 }

        model.renderImageDebounced()  // pending — should be cancelled
        model.renderDebounceMs = 5
        model.renderImageDebounced()  // supersedes the first
        await model.awaitDebounceForTesting()

        // Give the (cancelled) longer task more than its full interval to prove
        // it stays cancelled and never fires a second, stale render.
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(renderCount, 1,
                       "a superseding debounce yields exactly one render, not two")
    }

    // MARK: - Busy while it draws (the person's ask, 2026-10-13)

    /// Waits until the image is drawn, or fails after `seconds`.
    private func drawn(_ model: FITSViewerModel, within seconds: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while model.isRendering {
            guard Date() < deadline else { return XCTFail("still rendering") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testARenderIsBusyFromTheClickUntilTheNewestIsDrawn() async throws {
        let model = FITSViewerModel()
        FITSTestFixtures.loadRamp(into: model)
        model.renderParams.colormap = .heat
        model.renderImage()
        XCTAssertTrue(model.isRendering, "busy at once")
        model.renderParams.colormap = .viridis
        model.renderImage()  // supersedes the first
        try await drawn(model)

        let alone = FITSViewerModel()
        FITSTestFixtures.loadRamp(into: alone)
        alone.renderParams = model.renderParams
        alone.renderImage()
        try await drawn(alone)
        XCTAssertEqual(model.renderedImage?.dataProvider?.data, alone.renderedImage?.dataProvider?.data,
                       "the newest colour map is what is drawn")
    }

    func testASliderIsBusyDuringItsWaitToo() async throws {
        let model = FITSViewerModel()
        FITSTestFixtures.loadRamp(into: model)
        model.renderDebounceMs = 30
        model.renderImageDebounced()
        XCTAssertTrue(model.isRendering, "busy while the debounce waits, not only once it draws")
        await model.awaitDebounceForTesting()
        try await drawn(model)
        XCTAssertNotNil(model.renderedImage)
    }

    func testNothingToDrawIsNotBusy() {
        let model = FITSViewerModel()
        model.renderImageDebounced()
        XCTAssertFalse(model.isRendering)
        model.renderImage()
        XCTAssertFalse(model.isRendering)
    }
}
