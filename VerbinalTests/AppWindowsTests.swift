// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal

/// Closing the main window takes the app's other windows with it.
@MainActor
final class AppWindowsTests: XCTestCase {

    private func window(_ place: PointableID.Window, in places: UIWindowPlaces, x: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: x, y: 200, width: 300, height: 200), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Text(place.rawValue))
        window.orderFrontRegardless()
        places.set(place, for: window)
        return window
    }

    /// Only the last main window's close counts: another may still be open.
    func testTheLastMainWindowsCloseIsHeard() {
        let places = UIWindowPlaces()
        var heard = 0
        let watcher = AppWindows(places: places) { heard += 1 }
        let first = window(.main, in: places, x: 100)
        let second = window(.main, in: places, x: 420)
        let settings = window(.settings, in: places, x: 740)
        defer { settings.close() }
        first.close()
        XCTAssertEqual(heard, 0, "another main window is still open")
        settings.orderFrontRegardless()
        second.close()
        XCTAssertEqual(heard, 1)
        _ = watcher
    }

    /// What goes: Settings, and every hint.
    func testSettingsAndHintsGoWhenTheMainWindowCloses() {
        let state = AppState()
        let settings = window(.settings, in: .shared, x: 740)
        defer { settings.close() }
        _ = state.uiHints.show([UIHint(id: "a", set: "", style: .ring, title: nil, text: nil, number: nil,
                                       frame: .init(x: 0, y: 0, width: 20, height: 20), kind: .button,
                                       screen: "landing", window: 1)],
                               numbered: false, dim: false, seconds: nil, replace: true)
        state.mainWindowClosed()
        XCTAssertFalse(settings.isVisible)
        XCTAssertTrue(state.uiHints.isEmpty)
    }
}
