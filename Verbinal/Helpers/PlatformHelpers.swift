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
}
