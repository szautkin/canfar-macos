// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Shared display helpers for session status, type colors, icons, and time formatting.
enum SessionDisplay {

    // MARK: - Status Color

    static func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "running": return .green
        case "pending": return .orange
        case "failed", "error": return .red
        case "terminating": return .gray
        default: return .gray
        }
    }

    // MARK: - Type Color

    static func typeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "notebook": return .blue
        case "desktop": return .purple
        case "carta": return .teal
        case "contributed": return Color(.systemOrange)
        case "firefly": return .orange
        default: return .secondary
        }
    }

    // MARK: - Type Image Asset

    static func typeImageAsset(_ type: String) -> String? {
        switch type.lowercased() {
        case "notebook": return "session-notebook"
        case "desktop": return "session-desktop"
        case "carta": return "session-carta"
        case "contributed": return "session-contributed"
        case "firefly": return "session-firefly"
        default: return nil
        }
    }

    // MARK: - Type System Icon

    static func typeIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "notebook": return "book.pages"
        case "desktop": return "desktopcomputer"
        case "carta": return "map"
        case "contributed": return "shippingbox"
        case "firefly": return "flame"
        default: return "questionmark.square"
        }
    }

    // MARK: - Time Formatting

    static func formatTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            return displayFormatter.string(from: date)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoString) {
            return displayFormatter.string(from: date)
        }
        return isoString
    }

    // MARK: - Short Image Label

    static func shortImageLabel(_ image: String) -> String {
        String(image.split(separator: "/").last ?? Substring(image))
    }

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()
}
