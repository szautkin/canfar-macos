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

    // MARK: - Status Localization

    /// Map a raw backend status string ("Running", "pending", "Failed", …) to
    /// a locale-aware display string routed through the catalog. Unknown
    /// statuses are returned as-is so we don't eat novel server states.
    static func localizedStatus(_ status: String) -> String {
        switch status.lowercased() {
        case "running":     return String(localized: "Running")
        case "pending":     return String(localized: "Pending")
        case "failed",
             "error":       return String(localized: "Failed")
        case "completed":   return String(localized: "Completed")
        case "succeeded":   return String(localized: "Succeeded")
        case "terminated",
             "terminating": return String(localized: "Terminated")
        case "stopped":     return String(localized: "Stopped")
        default:            return status
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
        case "contributed": return "shared.with.you"
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

    // MARK: - Resources

    /// A session card's resources. A fixed session shows what it was given;
    /// a flexible one has no sizes of its own — the platform sends none — so
    /// it shows what it uses now. CPU and RAM always; GPU only for a session
    /// that has one.
    struct Resources: Equatable {
        let cpu: String
        let ram: String
        let gpu: String?
        /// Usage, not a size: a flexible session.
        let inUse: Bool
    }

    static func resources(of session: Session) -> Resources {
        let flexible = !session.isFixedResources
        let gpus = Double(session.gpuAllocated.trimmingCharacters(in: .whitespaces)) ?? 0
        return Resources(
            cpu: cores(flexible ? session.cpuUsage : session.cpuAllocated),
            ram: gigabytes(flexible ? session.memoryUsage : session.memoryAllocated, digits: flexible ? 2 : 0),
            gpu: gpus > 0 ? cores(session.gpuAllocated) : nil,
            inUse: flexible)
    }

    /// "1", "1.53", "<0.01"; "—" when the platform says nothing.
    static func cores(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed) else { return trimmed.isEmpty ? "—" : trimmed }
        if value > 0, value < 0.01 { return "<0.01" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// RAM as the launch form counts it — "2 GB" for the "2.15" the platform
    /// gives back for 2 asked (PlatformMemory.gigabytes reads it); "—" when it
    /// says nothing.
    static func gigabytes(_ raw: String, digits: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let value = PlatformMemory.gigabytes(trimmed) else { return trimmed.isEmpty ? "—" : trimmed }
        if value > 0, value < 0.01 { return String(localized: "<0.01 GB") }
        return String(localized: "\(value.formatted(.number.precision(.fractionLength(0...digits)))) GB")
    }

    // MARK: - Logs / Events Result Display

    /// Converts a logs/events fetch `Result` into text for the events/logs sheet.
    ///
    /// - A `.failure` is rendered as a distinct, user-visible error message so a
    ///   real fetch failure (auth/network/missing endpoint) is no longer
    ///   indistinguishable from "no data yet".
    /// - A `.success` with empty/whitespace content falls back to `emptyFallback`,
    ///   preserving the existing "no events/logs" rendering for genuinely empty
    ///   but successful fetches.
    /// - A `.success` with content passes it through unchanged.
    static func logResultText(_ result: Result<String, Error>, emptyFallback: String) -> String {
        switch result {
        case .success(let content):
            return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? emptyFallback
                : content
        case .failure(let error):
            return String(format: String(localized: "Failed to load: %@"),
                          error.localizedDescription)
        }
    }

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()
}
