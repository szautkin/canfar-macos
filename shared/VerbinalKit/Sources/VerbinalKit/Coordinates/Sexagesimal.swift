// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The one place sky positions are written as, and read from, sexagesimal.
///
/// Formatting rounds to a whole number of the smallest printed unit first and
/// derives every field from that integer, so a carry propagates: 59.996″ is
/// `00.00` of the next minute, never `60.00` (Windows 1.4.0 shipped that bug;
/// the viewer here had it too). Right ascension wraps into [0h, 24h).
public enum Sexagesimal {

    /// How the fields are separated.
    public enum Style: Sendable {
        /// `12h34m56.78s` / `+12°34'56.7"` — viewer read-outs and figures.
        case letters
        /// `12:34:56.78` / `+12:34:56.7` — tables, the form Search reads.
        case colons
    }

    // MARK: - Formatting

    /// Right ascension (or any longitude) given in degrees, as hours.
    /// - Returns: nil when `degrees` is not finite.
    public static func formatHMS(degrees: Double, secondDigits: Int = 2, style: Style = .letters) -> String? {
        guard degrees.isFinite else { return nil }
        var hours = (degrees / 15).truncatingRemainder(dividingBy: 24)
        if hours < 0 { hours += 24 }
        let perSecond = scale(secondDigits)
        let day = 24 * 3600 * perSecond
        let total = Int((hours * 3600 * Double(perSecond)).rounded()) % day
        let f = fields(total, perSecond: perSecond)
        let seconds = secondsText(f.s, f.fraction, digits: secondDigits)
        switch style {
        case .letters: return String(format: "%02dh%02dm", f.major, f.minutes) + seconds + "s"
        case .colons:  return String(format: "%02d:%02d:", f.major, f.minutes) + seconds
        }
    }

    /// Declination (or any latitude) in degrees, signed.
    /// - Returns: nil when `degrees` is not finite or lies outside ±90°.
    public static func formatDMS(degrees: Double, secondDigits: Int = 1, style: Style = .letters) -> String? {
        guard degrees.isFinite, (-90.0...90.0).contains(degrees) else { return nil }
        let perSecond = scale(secondDigits)
        let total = Int((abs(degrees) * 3600 * Double(perSecond)).rounded())
        let f = fields(total, perSecond: perSecond)
        // A value that rounds to zero prints without a minus sign.
        let sign = degrees < 0 && total > 0 ? "-" : "+"
        let seconds = secondsText(f.s, f.fraction, digits: secondDigits)
        switch style {
        case .letters: return sign + String(format: "%02d\u{00B0}%02d'", f.major, f.minutes) + seconds + "\""
        case .colons:  return sign + String(format: "%02d:%02d:", f.major, f.minutes) + seconds
        }
    }

    /// Viewer read-out of a right ascension: letters style, or a dashed
    /// placeholder when there is no value.
    public static func readoutHMS(degrees: Double) -> String {
        formatHMS(degrees: degrees) ?? "--h--m--.--s"
    }

    /// Viewer read-out of a declination: letters style, or a dashed placeholder.
    public static func readoutDMS(degrees: Double) -> String {
        formatDMS(degrees: degrees) ?? "--\u{00B0}--'--.-\""
    }

    // MARK: - Parsing

    /// Right ascension typed by a person or returned by a service: decimal
    /// degrees (a point or a comma), or sexagesimal hours. Degrees, in
    /// [0, 360).
    public static func rightAscension(_ text: String) -> Double? {
        if let degrees = decimal(text) {
            return (0..<360).contains(degrees) ? degrees : nil
        }
        return parseHMS(text)
    }

    /// Declination typed by a person or returned by a service: decimal
    /// degrees (a point or a comma), or sexagesimal degrees. In [-90, 90].
    public static func declination(_ text: String) -> Double? {
        if let degrees = decimal(text) {
            return (-90...90).contains(degrees) ? degrees : nil
        }
        return parseDMS(text)
    }

    /// Strict sexagesimal hours (`HH:MM:SS.ss`, `HH MM SS`, `HHhMMmSSs`), at
    /// least hours and minutes. Degrees.
    public static func parseHMS(_ text: String) -> Double? {
        guard let parts = components(text), parts.count >= 2 else { return nil }
        let (h, m, s) = (parts[0], parts[1], parts.count > 2 ? parts[2] : 0)
        guard h >= 0, h < 24, m >= 0, m < 60, s >= 0, s < 60 else { return nil }
        return (h + m / 60 + s / 3600) * 15
    }

    /// Strict sexagesimal degrees (`±DD:MM:SS.s`, `±DD MM SS`,
    /// `±DD°MM'SS"`), at least degrees and minutes. Degrees.
    public static func parseDMS(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let negative = trimmed.hasPrefix("-") || trimmed.hasPrefix("\u{2212}")
        let unsigned = trimmed.drop { "+-\u{2212}".contains($0) }
        guard let parts = components(String(unsigned)), parts.count >= 2 else { return nil }
        let (d, m, s) = (parts[0], parts[1], parts.count > 2 ? parts[2] : 0)
        guard d >= 0, d <= 90, m >= 0, m < 60, s >= 0, s < 60 else { return nil }
        let value = d + m / 60 + s / 3600
        guard value <= 90 else { return nil }
        return negative ? -value : value
    }

    // MARK: - Internals

    private static func scale(_ digits: Int) -> Int {
        (0..<max(0, digits)).reduce(1) { acc, _ in acc * 10 }
    }

    /// Splits a count of 1/`perSecond` seconds into its fields.
    private static func fields(_ total: Int, perSecond: Int) -> (major: Int, minutes: Int, s: Int, fraction: Int) {
        let wholeSeconds = total / perSecond
        return (wholeSeconds / 3600, (wholeSeconds / 60) % 60, wholeSeconds % 60, total % perSecond)
    }

    private static func secondsText(_ s: Int, _ fraction: Int, digits: Int) -> String {
        let whole = String(format: "%02d", s)
        guard digits > 0 else { return whole }
        return whole + "." + String(format: "%0\(digits)d", fraction)
    }

    /// A single decimal number, with a point or a comma; nil for anything
    /// with more than one field.
    private static func decimal(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.range(of: #"^[+-]?(\d+([.,]\d*)?|[.,]\d+)$"#, options: .regularExpression) != nil
        else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    /// Numeric fields separated by spaces, colons, or unit letters/marks.
    private static func components(_ text: String) -> [Double]? {
        let separators = CharacterSet(charactersIn: ": hmsd\u{00B0}'\"\u{2032}\u{2033}")
        let tokens = text.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty, tokens.count <= 3 else { return nil }
        let values = tokens.compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        return values.count == tokens.count ? values : nil
    }
}
