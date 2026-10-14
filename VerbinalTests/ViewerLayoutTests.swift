// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import SwiftUI
@testable import Verbinal

/// The viewers fit their window (seen 2026-10-13): with no file open, the
/// FITS viewer's empty state wanted 1,320 points of height and pushed the
/// toolbar, the tabs and the activity bar off an 826-point window — and it
/// showed the image controls beside nothing. Laid out in a real window,
/// with the recent files the test host has.
@MainActor
final class ViewerLayoutTests: XCTestCase {

    /// `view` in a window of `size`, laid out; `body` reads it before it closes.
    private func laidOut<V: View>(_ view: V, in size: CGSize, _ body: (NSView) throws -> Void) rethrows {
        let host = NSHostingView(rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        let settled = Date().addingTimeInterval(0.6)
        while Date() < settled { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        host.layoutSubtreeIfNeeded()
        try body(host)
    }

    private func splitViews(in view: NSView) -> [NSSplitView] {
        (view as? NSSplitView).map { [$0] } ?? view.subviews.flatMap(splitViews)
    }

    /// A split view's panes are no taller than the room it has — the
    /// overflow hid there: SwiftUI saw a 51-point view, AppKit a 1,320-point
    /// split view in a 775-point space.
    private func assertSplitsFit(in host: NSView, _ size: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        for split in splitViews(in: host) {
            XCTAssertLessThanOrEqual(split.frame.height, (split.superview?.bounds.height ?? 0) + 0.5,
                                     "panes taller than their room in a \(Int(size.height))-point window", file: file, line: line)
        }
    }

    private let windows = [CGSize(width: 1457, height: 826), CGSize(width: 900, height: 420)]

    func testWithNoFileOpenTheFITSViewerFitsAndShowsNoControls() {
        let state = AppState()
        _ = state.fitsTabHost.addTab()
        for size in windows {
            laidOut(FITSViewerRootView().environment(state), in: size) { host in
                XCTAssertLessThanOrEqual(host.fittingSize.height, size.height, "taller than a \(Int(size.height))-point window")
                XCTAssertTrue(splitViews(in: host).isEmpty, "no image controls beside nothing")
                assertSplitsFit(in: host, size)
            }
        }
    }

    func testWithAFileOpenTheControlsAreBesideItAndFit() {
        let state = AppState()
        let tab = state.fitsTabHost.addTab()
        FITSTestFixtures.loadRamp(into: tab, path: "/tmp/layout.fits")
        tab.renderedImage = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)?.makeImage()
        for size in windows {
            laidOut(FITSViewerRootView().environment(state), in: size) { host in
                let split = splitViews(in: host)
                XCTAssertEqual(split.count, 1, "the controls beside the image")
                assertSplitsFit(in: host, size)
            }
        }
    }

    func testWithNoCubeOpenTheCubeViewerFits() {
        let state = AppState()
        for size in windows {
            laidOut(CubeViewerRootView().environment(state), in: size) { host in
                XCTAssertLessThanOrEqual(host.fittingSize.height, size.height, "taller than a \(Int(size.height))-point window")
                assertSplitsFit(in: host, size)
            }
        }
    }
}
