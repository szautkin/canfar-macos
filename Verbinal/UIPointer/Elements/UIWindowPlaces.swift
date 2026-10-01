// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

#if os(macOS)
import AppKit

/// Which of the app's windows is which — the main window, Settings — as
/// their roots say, without touching the identifiers SwiftUI keeps for
/// itself (plan 27).
@MainActor
final class UIWindowPlaces {
    static let shared = UIWindowPlaces()

    private var places: [ObjectIdentifier: (window: WeakWindow, place: PointableID.Window)] = [:]

    private struct WeakWindow { weak var window: NSWindow? }

    func set(_ place: PointableID.Window, for window: NSWindow) {
        places = places.filter { $0.value.window.window != nil }
        places[ObjectIdentifier(window)] = (WeakWindow(window: window), place)
    }

    /// The windows showing at a place.
    func windows(_ place: PointableID.Window) -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && self.place(of: $0) == place }
    }

    /// The window's place: as its root said, or as Verbinal named the
    /// windows it makes itself.
    func place(of window: NSWindow) -> PointableID.Window? {
        places[ObjectIdentifier(window)]?.place ?? PointableID.Window(identifier: window.identifier?.rawValue)
    }
}

private struct WindowPlaceReader: NSViewRepresentable {
    let place: PointableID.Window

    final class Probe: NSView {
        var place: PointableID.Window = .main
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { UIWindowPlaces.shared.set(place, for: window) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.place = place
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) { probe.place = place }
}
#endif

extension View {
    /// Says which window this root is, for listing what is on screen
    /// (`list_ui_targets`): the main window, Settings.
    func uiWindowPlace(_ place: PointableID.Window) -> some View {
        #if os(macOS)
        background(WindowPlaceReader(place: place).frame(width: 0, height: 0).accessibilityHidden(true))
        #else
        self
        #endif
    }
}
