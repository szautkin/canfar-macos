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

    // MARK: - Side panels keep to their width (2026-10-15)

    /// The controls that reach past `host`'s edges — the segmented pickers,
    /// sliders, steppers and buttons AppKit draws: content that will not shrink
    /// to its pane is centred and cut at both edges.
    private func controlsOutside(_ host: NSView) -> [String] {
        var found: [String] = []
        func walk(_ view: NSView) {
            if view is NSControl, !view.isHiddenOrHasHiddenAncestor {
                let frame = view.convert(view.bounds, to: host)
                // A point and a half for a control that fills its pane exactly,
                // settling after a screen's transition; a spill is tens.
                if frame.minX < -1.5 || frame.maxX > host.bounds.width + 1.5 {
                    found.append("\(type(of: view)) from \(frame.minX) to \(frame.maxX) of \(host.bounds.width)")
                }
            }
            view.subviews.forEach(walk)
        }
        walk(host)
        return found
    }

    /// The controls in each split view's panes that reach past their pane.
    private func controlsOutsideTheirPanes(_ host: NSView) -> [String] {
        var found: [String] = []
        for split in splitViews(in: host) {
            for (index, pane) in split.arrangedSubviews.enumerated() {
                found += controlsOutside(pane).map { "pane \(index): \($0)" }
            }
        }
        return found
    }

    private func spin(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// A real cube on its tab, with a mark on it, as a person has one.
    private func cubeWithAMark(in state: AppState) async throws {
        await state.cubeViewer.open(url: try FITSTestFixtures.writeCube())
        let target = try XCTUnwrap(state.cubeViewer.markTarget)
        try state.marks.add(Mark(id: "m1", kind: .circle, anchor: .init(space: .data, x: 1, y: 0.5, z: 2),
                                 extent: .square(1), author: .user, createdAt: Date()), to: target)
    }

    /// The Cube Viewer's panel, at the narrowest, ideal and widest its split
    /// allows, with a cube and a mark, in both modes, keeps to its width. The
    /// person's screenshot (2026-10-15): "nsions", "inear", "kground" — cut at
    /// both edges by a five-segment Stretch picker and a Marks row wider than
    /// it. The layout tests asked heights, never widths.
    func testTheCubePanelKeepsToItsWidth() async throws {
        let state = AppState()
        try await cubeWithAMark(in: state)
        for mode in [CubeViewMode.slice, .volume] {
            state.cubeViewer.viewMode = mode
            for width in [240.0, 270.0, 340.0] {
                let panel = CubeRenderControlsView(model: state.cubeViewer, marks: state.cubeMarkEditor, markCommands: nil)
                laidOut(panel.frame(width: width), in: CGSize(width: width, height: 1200)) { host in
                    XCTAssertEqual(controlsOutside(host), [], "\(mode) at \(Int(width)) points: wider than the panel")
                }
            }
        }
    }

    /// The FITS Viewer's panel, from its narrowest to its widest, keeps to its width.
    func testTheFITSPanelKeepsToItsWidth() {
        let state = AppState()
        let tab = state.fitsTabHost.addTab()
        FITSTestFixtures.loadRamp(into: tab, path: "/tmp/panel.fits")
        for width in [220.0, 270.0, 320.0] {
            let panel = FITSRenderControlsView(model: tab, marks: state.marks, canvas: state.fitsMarkEditor)
            laidOut(panel.frame(width: width), in: CGSize(width: width, height: 1400)) { host in
                XCTAssertEqual(controlsOutside(host), [], "at \(Int(width)) points: wider than the panel")
            }
        }
    }

    /// Both viewers, in a window of the person's size and a smaller one: the
    /// side panel keeps every control inside its pane, on first showing and
    /// after a trip to another screen and back — the person's steps
    /// (2026-10-16): to Storage and back, and the Cube Viewer's panel spilled.
    func testTheViewersPanelsStayInTheirPanesAfterAScreenAndBack() async throws {
        let state = AppState()
        state.auth.apply(username: "qa-person", userInfo: nil)
        state.storageSync.signedOut()
        try await cubeWithAMark(in: state)
        let tab = state.fitsTabHost.addTab()
        FITSTestFixtures.loadRamp(into: tab, path: "/tmp/round-trip.fits")
        tab.renderedImage = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)?.makeImage()
        for viewer in [AppMode.cubeViewer, .fitsViewer] {
            for size in [CGSize(width: 1178, height: 685), CGSize(width: 900, height: 600)] {
                state.currentMode = viewer
                laidOut(ContentView().environment(state), in: size) { host in
                    XCTAssertFalse(splitViews(in: host).isEmpty, "\(viewer): its panel is there")
                    XCTAssertEqual(controlsOutsideTheirPanes(host), [], "\(viewer) at \(Int(size.width)): on first showing")
                    state.navigateTo(.storage)
                    spin(0.8)
                    state.navigateTo(viewer)
                    spin(1.2)
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(controlsOutsideTheirPanes(host), [], "\(viewer) at \(Int(size.width)): after Storage and back")
                }
            }
        }
    }

    /// Every screen, with a cube and a FITS file open and signed in: what its
    /// panes hold stays inside them, on first showing and after another
    /// screen and back — the trip that spilled the Cube Viewer's panel
    /// (2026-10-16) while its first showing fitted.
    func testEveryScreensPanesHoldTheirControlsAfterAnotherScreenAndBack() async throws {
        let state = AppState()
        state.auth.apply(username: "qa-person", userInfo: nil)
        state.storageSync.signedOut()
        try await cubeWithAMark(in: state)
        let tab = state.fitsTabHost.addTab()
        FITSTestFixtures.loadRamp(into: tab, path: "/tmp/every-screen.fits")
        tab.renderedImage = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)?.makeImage()
        for mode in AppMode.allCases {
            state.currentMode = mode
            let elsewhere: AppMode = mode == .landing ? .storage : .landing
            laidOut(ContentView().environment(state), in: CGSize(width: 1178, height: 685)) { host in
                XCTAssertEqual(controlsOutsideTheirPanes(host), [], "\(mode): on first showing")
                state.navigateTo(elsewhere)
                spin(0.8)
                state.navigateTo(mode)
                spin(1.2)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(controlsOutsideTheirPanes(host), [], "\(mode): after \(elsewhere) and back")
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

    // MARK: - Every screen (plan 38's tests)

    /// Every screen, signed in where it needs it, fits a short window: no
    /// split view's panes taller than their room, nothing pushed out.
    func testEveryScreenFitsAShortWindow() {
        for mode in AppMode.allCases {
            let state = AppState()
            if mode.requiresAuthentication { state.auth.apply(username: "qa-person", userInfo: nil) }
            state.currentMode = mode
            for size in [CGSize(width: 900, height: 420)] {
                // What the screen takes when offered the window: more is pushed out of it.
                // (fittingSize is the ideal size: a scroll view's whole content.)
                let taken = NSHostingController(rootView: ContentView().environment(state)).sizeThatFits(in: size)
                XCTAssertLessThanOrEqual(taken.height, size.height + 0.5, "\(mode): taller than a \(Int(size.height))-point window")
                laidOut(ContentView().environment(state), in: size) { host in
                    for split in splitViews(in: host) {
                        XCTAssertLessThanOrEqual(split.frame.height, (split.superview?.bounds.height ?? 0) + 0.5,
                                                 "\(mode): panes taller than their room")
                    }
                }
            }
        }
    }

    /// Every screen keeps to Verbinal's own toolbar: none brings the window a
    /// native one. Workflows' NavigationSplitView did, and this macOS lays a
    /// native toolbar over the screen — the workflow's title blurred under
    /// it, the sidebar's heading cut (the person, 2026-10-15). Sizes and
    /// names never showed it; the window's toolbar does.
    func testNoScreenBringsTheWindowAToolbarOfItsOwn() {
        for mode in AppMode.allCases {
            let state = AppState()
            if mode.requiresAuthentication { state.auth.apply(username: "qa-person", userInfo: nil) }
            state.currentMode = mode
            laidOut(ContentView().environment(state), in: CGSize(width: 1200, height: 700)) { host in
                let items = host.window?.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
                XCTAssertNil(host.window?.toolbar, "\(mode) gives the window a native toolbar: \(items)")
            }
        }
    }

    func testAFITSTabWhoseOpenFailedFitsAndShowsNoControls() {
        let state = AppState()
        let tab = state.fitsTabHost.addTab()
        tab.document.send(.begin)
        tab.document.send(.failed(Problem(.other, "not a FITS file")))
        for size in windows {
            laidOut(FITSViewerRootView().environment(state), in: size) { host in
                XCTAssertTrue(splitViews(in: host).isEmpty, "no controls beside a failed open")
                XCTAssertLessThanOrEqual(NSHostingController(rootView: FITSViewerRootView().environment(state)).sizeThatFits(in: size).height,
                                         size.height + 0.5)
            }
        }
    }
}

