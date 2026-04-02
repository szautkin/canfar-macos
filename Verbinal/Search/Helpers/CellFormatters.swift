// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Formats raw TAP cell values for display.
/// Applies type-specific formatting based on the column key.
enum CellFormatters {

    /// Format a raw cell value for display based on its column key.
    static func format(key: String, raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }

        switch key {
        case "startdate", "enddate", "provelastexecuted":
            return formatMJDDate(trimmed)
        case "ra(j20000)":
            return formatCoordinate(trimmed, decimalPlaces: 5)
        case "dec(j20000)":
            return formatCoordinate(trimmed, decimalPlaces: 5)
        case "inttime":
            return formatIntegrationTime(trimmed)
        case "callev":
            return formatCalibrationLevel(trimmed)
        case "download":
            return formatBoolean(trimmed)
        case "movingtarget":
            return formatBoolean(trimmed)
        case "minwavelength", "maxwavelength", "restframeenergy":
            return formatWavelength(trimmed)
        case "pixelscale":
            return formatScientific(trimmed, decimalPlaces: 4)
        case "fieldofview":
            return formatScientific(trimmed, decimalPlaces: 6)
        case "datarelease":
            return formatTimestamp(trimmed)
        default:
            return trimmed
        }
    }

    // MARK: - MJD Date

    /// Convert MJD float to ISO date string "YYYY-MM-DD".
    static func formatMJDDate(_ raw: String) -> String {
        guard let mjd = Double(raw) else { return raw }
        let unixSeconds = (mjd - 40587.0) * 86400.0
        let date = Date(timeIntervalSince1970: unixSeconds)
        return mjdDateFormatter.string(from: date)
    }

    private static let mjdDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - Coordinates

    /// Format a coordinate value to a fixed number of decimal places.
    static func formatCoordinate(_ raw: String, decimalPlaces: Int) -> String {
        guard let value = Double(raw) else { return raw }
        return String(format: "%.\(decimalPlaces)f", value)
    }

    // MARK: - Integration Time

    /// Format seconds to human-readable: "30m", "1h", "45.0s".
    static func formatIntegrationTime(_ raw: String) -> String {
        guard let seconds = Double(raw) else { return raw }
        if seconds >= 3600 {
            let hours = seconds / 3600.0
            if hours == hours.rounded() {
                return "\(Int(hours))h"
            }
            return String(format: "%.1fh", hours)
        }
        if seconds >= 60 {
            let minutes = seconds / 60.0
            if minutes == minutes.rounded() {
                return "\(Int(minutes))m"
            }
            return String(format: "%.1fm", minutes)
        }
        if seconds == seconds.rounded() {
            return "\(Int(seconds))s"
        }
        return String(format: "%.1fs", seconds)
    }

    // MARK: - Calibration Level

    private static let calLevelLabels: [String: String] = [
        "0": "Raw",
        "1": "Cal",
        "2": "Product",
        "3": "Composite",
    ]

    /// Map calibration level number to label.
    static func formatCalibrationLevel(_ raw: String) -> String {
        calLevelLabels[raw] ?? raw
    }

    // MARK: - Boolean

    static let checkmark = "\u{2713}"

    /// Format boolean: "true"/"1" → checkmark, else empty.
    static func formatBoolean(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower == "true" || lower == "1" {
            return checkmark
        }
        return ""
    }

    // MARK: - Wavelength / Scientific

    /// Format small float values in scientific notation.
    static func formatWavelength(_ raw: String) -> String {
        guard let value = Double(raw) else { return raw }
        if abs(value) < 0.001 || abs(value) > 1e6 {
            return String(format: "%.3E", value)
        }
        return String(format: "%.6g", value)
    }

    /// Format a value in scientific notation with specific decimal places.
    static func formatScientific(_ raw: String, decimalPlaces: Int) -> String {
        guard let value = Double(raw) else { return raw }
        if abs(value) < 0.001 || abs(value) > 1e6 {
            return String(format: "%.\(decimalPlaces)E", value)
        }
        return String(format: "%.\(decimalPlaces)g", value)
    }

    // MARK: - Timestamp

    /// Format a timestamp string, cleaning up T/Z separators.
    static func formatTimestamp(_ raw: String) -> String {
        // If it looks like an ISO timestamp, clean it up
        if raw.contains("T") || raw.contains(" ") {
            let cleaned = raw
                .replacingOccurrences(of: "T", with: " ")
                .replacingOccurrences(of: "Z", with: "")
            // Trim milliseconds if present
            if let dotRange = cleaned.range(of: ".", range: cleaned.index(cleaned.startIndex, offsetBy: min(10, cleaned.count))..<cleaned.endIndex) {
                return String(cleaned[cleaned.startIndex..<dotRange.lowerBound])
            }
            return cleaned
        }
        return raw
    }
}
