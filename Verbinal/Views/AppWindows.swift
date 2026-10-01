// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import AppKit

/// The app's windows go with its main window. Settings is a window of its
/// own, and closing the main window does not quit the app — so without
/// this, Settings, the hints over it, or a session request would stay on
/// screen with nothing behind them. When the last main window closes, the
/// app's other windows are closed with it.
@MainActor
final class AppWindows {
    private let places: UIWindowPlaces
    private var observer: NSObjectProtocol?

    init(places: UIWindowPlaces = .shared, lastMainWindowClosed: @escaping @MainActor () -> Void) {
        self.places = places
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                                          queue: .main) { [places] note in
            MainActor.assumeIsolated {
                guard let closing = note.object as? NSWindow, places.place(of: closing) == .main,
                      !places.windows(.main).contains(where: { $0 !== closing }) else { return }
                lastMainWindowClosed()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
#endif
