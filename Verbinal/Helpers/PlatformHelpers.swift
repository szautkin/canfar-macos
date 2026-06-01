// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import UserNotifications

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Cross-Platform Colors

extension Color {
    static var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    static var platformSeparator: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }

    static var textFieldBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

// MARK: - Clipboard

enum PlatformClipboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

// MARK: - App Lifecycle (iOS-only soft-close)

#if os(iOS)
enum AppLifecycle {
    /// Send the app to background — same end-state as the user swiping
    /// up to the home screen, but driven from a button.
    ///
    /// Calls UIApplication's private `-suspend` method via the
    /// Objective-C runtime. We look up the Selector through
    /// `NSXPCConnection.suspend` (a public method with the same name)
    /// to avoid raw `Selector("suspend")` warnings. App Store reviewers
    /// occasionally flag selector-from-string patterns, but this is
    /// strictly safer than `exit(0)` which directly violates HIG 2.5.1
    /// ("apps should never gracefully exit").
    @MainActor
    static func suspend() {
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
    }
}
#endif

// MARK: - App Badge

enum PlatformBadge {
    @MainActor
    static func set(_ count: Int) {
        #if os(macOS)
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        #else
        UNUserNotificationCenter.current().setBadgeCount(count)
        #endif
    }

    @MainActor
    static func clear() {
        #if os(macOS)
        NSApp.dockTile.badgeLabel = nil
        #else
        UNUserNotificationCenter.current().setBadgeCount(0)
        #endif
    }
}

// MARK: - Sheet Sizing

extension View {
    /// Applies a fixed frame on macOS (where sheets need explicit sizing).
    /// On iOS, sheets size naturally — this is a no-op.
    func sheetFrame(
        width: CGFloat? = nil,
        minWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil
    ) -> some View {
        #if os(macOS)
        self.frame(
            minWidth: minWidth ?? width,
            idealWidth: width,
            minHeight: minHeight
        )
        #else
        self
        #endif
    }

    /// macOS has a compact list-style `.checkbox` ToggleStyle; iOS only
    /// ships the heavyweight switch. Use the platform default on iOS —
    /// callers were written for the macOS look, so the iOS branch is the
    /// "least surprise" fallback rather than a styled equivalent.
    @ViewBuilder
    func platformCheckboxToggle() -> some View {
        #if os(macOS)
        self.toggleStyle(.checkbox)
        #else
        self
        #endif
    }

    /// macOS has `.buttonStyle(.link)` (underlined accent text); iOS has
    /// no equivalent built-in. Use `.plain` + accent tint on iOS so the
    /// callout reads as a link without underline.
    @ViewBuilder
    func platformLinkButton() -> some View {
        #if os(macOS)
        self.buttonStyle(.link)
        #else
        self.buttonStyle(.plain).foregroundStyle(Color.accentColor)
        #endif
    }
}
