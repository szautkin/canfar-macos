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

    init(places: UIWindowPlaces = .shared, lastMainWindowClosed: @escaping @MainActor (_ closing: NSWindow) -> Void) {
        self.places = places
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                                          queue: .main) { [places] note in
            MainActor.assumeIsolated {
                guard let closing = note.object as? NSWindow, places.place(of: closing) == .main,
                      !places.windows(.main).contains(where: { $0 !== closing }) else { return }
                lastMainWindowClosed(closing)
            }
        }
    }

    /// Brings the main window back for an assistant's open_ui (plan 30 T2):
    /// the app unhidden, a minimized window restored, a closed one opened
    /// again as a click on the Dock icon opens it. One on another desktop
    /// stays there.
    func showMain() {
        if NSApp.isHidden { NSApp.unhide(nil) }
        let mains = NSApp.windows.filter { places.place(of: $0) == .main }
        if let window = mains.first(where: \.isMiniaturized) {
            window.deminiaturize(nil)
        } else if let window = mains.first(where: \.isVisible) {
            window.orderFrontRegardless()
        } else {
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
#endif
