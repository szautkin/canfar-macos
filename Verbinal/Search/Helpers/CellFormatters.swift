// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

// MARK: - Formatter contract

/// Converts a raw CSV cell value into a human-readable, locale-aware display string.
///
/// **Preconditions (callers must uphold):**
///  • `raw` is non-empty and whitespace-trimmed (the registry short-circuits
///    empty input — individual formatters need not re-check).
///
/// **Postconditions (implementations must uphold):**
///  1. *Parse-failure passthrough* — when the formatter cannot parse the raw
///     value (non-numeric for a numeric formatter, malformed date, unknown
///     boolean literal), it must return the untouched `raw` string. The UI
///     then shows the server's text instead of `""` or `"nan"`.
///  2. *Domain-rejection empty* — when the value *is* parseable but falls
///     outside the valid domain (negative exposure time, NaN/Infinity for
///     real-valued quantities), the formatter may return `""` to suppress
///     a meaningless display rather than produce garbage.
///  3. Never throw, never block, never mutate external state.
///
/// The distinction between (1) and (2) matters: "5.7foo" → `"5.7foo"` (raw,
/// could be a real datum the server sent), but "-10" seconds → `""` (domain
/// violation — exposures aren't negative).
protocol ColumnFormatter: Sendable {
    func format(_ raw: String) -> String
}

// MARK: - Registry (the façade the rest of the app calls)

/// Registry resolving a cleaned column id to its ``ColumnFormatter``.
///
/// OCP: new column kinds register via ``byID``; the switch-on-key design that
/// lived in `CellFormatters.format` has been replaced so we don't edit a
/// single function every time a new column type arrives.
///
/// `CellFormatters.format(key:raw:)` is preserved as a compatibility wrapper
/// that forwards here — existing call sites (``ResultDetailSheet``, exports,
/// tests) continue to work.
enum CellFormatterRegistry {
    /// Multi-unit columns — the user can switch display units via the
    /// column-header unit menu. Resolution precedence at `format(id:raw:unitID:)`
    /// is: `sets` first (with selected unit), then ``byID``, then passthrough.
    ///
    /// Adding a new column: decide whether unit-switching is meaningful.
    /// If yes, add a ``ColumnFormatSet`` here; if no, add a single
    /// formatter to ``byID``.
    static let sets: [String: ColumnFormatSet] = [
        "ra(j20000)": ColumnFormatSet(
            choices: [
                ColumnFormatChoice(unitID: "hms", label: "H:M:S", formatter: HMSFormatter()),
                ColumnFormatChoice(unitID: "degrees", label: "Degrees",
                                   formatter: CoordinateFormatter(decimals: 6, signMode: .negativeOnly)),
            ],
            defaultUnitID: "hms"
        ),
        "dec(j20000)": ColumnFormatSet(
            choices: [
                ColumnFormatChoice(unitID: "dms", label: "D:M:S", formatter: DMSFormatter()),
                ColumnFormatChoice(unitID: "degrees", label: "Degrees",
                                   formatter: CoordinateFormatter(decimals: 6, signMode: .always)),
            ],
            defaultUnitID: "dms"
        ),
    ]

    /// Single-formatter columns. Keys are cleaned column ids, matching
    /// ``SearchResultColumns`` / ``CSVParser/cleanHeader``.
    ///
    /// Note on `ra(j20000)` / `dec(j20000)`: `cleanHeader` strips dots, so
    /// the CADC header `"RA (J2000.0)"` normalizes to `ra(j20000)` (no second
    /// `0` dropped — the `.0` becomes nothing; the `2000` remains `20000`
    /// because `"J2000.0"` → `"J20000"` after dot-strip).
    static let byID: [String: any ColumnFormatter] = [
        // Dates — always render time-of-day (HH:mm:ss) to match CADC CCDA's
        // default. Observation timestamps carry meaningful sub-day precision.
        "startdate": MJDFormatter(style: .dateAndTime),
        "enddate": MJDFormatter(style: .dateAndTime),
        "provelastexecuted": ISOTimestampFormatter(),
        "datarelease": ISOTimestampFormatter(),
        // Duration
        "inttime": DurationFormatter(),
        // Labels
        "callev": CalLevelFormatter(),
        // Booleans
        "download": BooleanFormatter(),
        "movingtarget": BooleanFormatter(),
        // Spectral wavelengths (metres → nm/μm/mm)
        "minwavelength": WavelengthFormatter(),
        "maxwavelength": WavelengthFormatter(),
        "restframeenergy": WavelengthFormatter(),
        // Angles (degrees → arcsec/arcmin/deg)
        "pixelscale": AngleFormatter(mode: .arcsecPerPixel),
        "fieldofview": AngleFormatter(mode: .arcminOrDegrees),
    ]

    /// Format a cell value by column id. Trims whitespace, short-circuits on empty,
    /// otherwise dispatches to the unit-set (with selected unit) or the
    /// single formatter, falling back to passthrough.
    static func format(id: String, raw: String, unitID: String? = nil) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }

        if let set = sets[id] {
            let target = unitID ?? set.defaultUnitID
            let choice = set.choice(for: target) ?? set.defaultChoice
            return choice.formatter.format(trimmed)
        }
        if let formatter = byID[id] {
            return formatter.format(trimmed)
        }
        return trimmed
    }

    /// Available unit choices for a column, or `nil` if it has no multi-unit set.
    static func availableUnits(for id: String) -> [ColumnFormatChoice]? {
        sets[id]?.choices
    }

    /// Default unit id for a column, or `nil` if not a multi-unit column.
    static func defaultUnitID(for id: String) -> String? {
        sets[id]?.defaultUnitID
    }
}

// MARK: - Passthrough

struct PassthroughFormatter: ColumnFormatter {
    func format(_ raw: String) -> String { raw }
}

// MARK: - Numeric guard helper (DRY for finite-double parsing)

/// Parse a string to a finite `Double`, returning `nil` on non-numeric,
/// `NaN`, or infinity. All numeric formatters funnel through this so every
/// pathway has consistent defensive behaviour.
@inline(__always)
func finiteDouble(_ raw: String) -> Double? {
    guard let v = Double(raw), v.isFinite else { return nil }
    return v
}

// MARK: - MJD date

/// Modified Julian Date → ISO date string.
///
/// MJD 0 = 1858-11-17, MJD 40587 = 1970-01-01 (Unix epoch).
///
/// Three render styles:
///  • `.dateOnly` — `yyyy-MM-dd`
///  • `.dateAndTime` — `yyyy-MM-dd HH:mm:ss` (matches CADC CCDA default)
///  • `.auto` — date-only when the MJD is integer-aligned, date+time otherwise
/// All timestamps are rendered in UTC.
struct MJDFormatter: ColumnFormatter {
    enum Style: Sendable {
        case dateOnly
        case dateAndTime
        case auto
    }

    let style: Style

    init(style: Style = .dateAndTime) {
        self.style = style
    }

    func format(_ raw: String) -> String {
        guard let mjd = finiteDouble(raw) else { return raw }
        let unixSeconds = (mjd - 40_587.0) * 86_400.0
        let date = Date(timeIntervalSince1970: unixSeconds)

        let includeTime: Bool
        switch style {
        case .dateOnly:    includeTime = false
        case .dateAndTime: includeTime = true
        case .auto:
            let fractional = mjd - mjd.rounded(.towardZero)
            includeTime = abs(fractional) > 1e-6
        }
        return (includeTime ? Self.dateTimeFormatter : Self.dateOnlyFormatter).string(from: date)
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

// MARK: - ISO-8601 timestamp

/// Clean an ISO-8601-ish timestamp for display: strip `T` and `Z`, normalize
/// fractional seconds away. Uses a regex rather than offset-10 slicing, so
/// short / unusual inputs don't produce weird substrings.
struct ISOTimestampFormatter: ColumnFormatter {
    func format(_ raw: String) -> String {
        // Heuristic: only touch strings that look date-ish (have `T` or a space + digits).
        let looksLikeTimestamp = raw.contains("T") || (raw.contains(" ") && raw.first?.isNumber == true)
        guard looksLikeTimestamp else { return raw }

        // Drop fractional seconds: `.123`, `.123456` → ``.
        let noFraction = Self.fractionalSecondsRegex.stringByReplacingMatches(
            in: raw,
            range: NSRange(raw.startIndex..., in: raw),
            withTemplate: ""
        )
        return noFraction
            .replacingOccurrences(of: "T", with: " ")
            .replacingOccurrences(of: "Z", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // swiftlint:disable:next force_try
    private static let fractionalSecondsRegex = try! NSRegularExpression(
        pattern: #"\.\d+(?=Z|[+-]\d{2}:?\d{2}|\s|$)"#
    )
}

// MARK: - Coordinate

/// Fixed-decimal formatting for celestial coordinates.
struct CoordinateFormatter: ColumnFormatter {
    enum SignMode {
        case always        // RA/Dec declination: always show `+` for positive values
        case negativeOnly  // standard: only `-` for negatives
    }

    let decimals: Int
    let signMode: SignMode

    func format(_ raw: String) -> String {
        guard let v = finiteDouble(raw) else { return raw }
        switch signMode {
        case .always:
            return String(format: "%+.\(decimals)f", v)
        case .negativeOnly:
            return String(format: "%.\(decimals)f", v)
        }
    }
}

/// Right-ascension in hours/minutes/seconds (HH:MM:SS.ss).
///
/// Input is degrees; divides by 15°/h and wraps into `[0, 24)` hours. Rollover
/// artefacts are avoided by working in integer centiseconds, so a value
/// of 359.999999° formats as `23:59:59.99`, not `24:00:00.00`.
struct HMSFormatter: ColumnFormatter {
    func format(_ raw: String) -> String {
        guard let deg = finiteDouble(raw) else { return raw }
        // Wrap into [0, 24) hours.
        let hours = (deg / 15.0).truncatingRemainder(dividingBy: 24)
        let positive = hours < 0 ? hours + 24 : hours
        let dayInCentiseconds = 24 * 3600 * 100
        var totalCs = Int((positive * 3600 * 100).rounded())
        totalCs = ((totalCs % dayInCentiseconds) + dayInCentiseconds) % dayInCentiseconds
        let h = totalCs / (3600 * 100)
        let m = (totalCs / (60 * 100)) % 60
        let s = (totalCs / 100) % 60
        let cs = totalCs % 100
        return String(format: "%02d:%02d:%02d.%02d", h, m, s, cs)
    }
}

/// Declination in degrees/arcminutes/arcseconds (±DD:MM:SS.s).
///
/// Pass-through for values outside the valid Dec range [-90°, +90°] — we
/// never render nonsense like `DD > 90` DMS. Integer deciseconds-of-arc
/// internally avoid the `59.95 → 60.0` rollover bug.
struct DMSFormatter: ColumnFormatter {
    func format(_ raw: String) -> String {
        guard let deg = finiteDouble(raw), (-90.0...90.0).contains(deg) else { return raw }
        let sign = deg < 0 ? "-" : "+"
        let totalDs = Int((abs(deg) * 3600 * 10).rounded())
        let d = totalDs / (3600 * 10)
        let m = (totalDs / (60 * 10)) % 60
        let s = (totalDs / 10) % 60
        let ds = totalDs % 10
        return String(format: "%@%02d:%02d:%02d.%d", sign, d, m, s, ds)
    }
}

// MARK: - Duration (integration time)

/// Seconds → localized short-unit duration string.
///
/// Uses `Duration.FormatStyle.units` so the unit suffixes ("h"/"m"/"s") are
/// auto-localized by the OS. For sub-second values, falls back to
/// `"%.2f s"` so a 0.05 s exposure doesn't round to `"0.1s"`.
///
/// Negative or zero seconds return empty — exposure time must be positive.
struct DurationFormatter: ColumnFormatter {
    func format(_ raw: String) -> String {
        // Non-numeric → passthrough (defensive: caller may surface whatever the
        // server sent, e.g. "N/A"); only zero / negative reject silently.
        guard let seconds = finiteDouble(raw) else { return raw }
        guard seconds > 0 else { return "" }

        if seconds < 1.0 {
            let formatted = String(format: "%.2f", seconds)
            return "\(formatted) s"
        }

        // Bias towards the biggest sensible unit.
        let duration = Duration.seconds(seconds)
        if seconds >= 3600 {
            return duration.formatted(.units(allowed: [.hours, .minutes], width: .narrow))
        }
        if seconds >= 60 {
            return duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
        }
        return duration.formatted(.units(allowed: [.seconds], width: .narrow))
    }
}

// MARK: - Calibration level

/// Map CAOM2 calibration levels to localized labels (0=Raw … 4=Analysis).
///
/// Unknown levels pass through unchanged — defensive against future schema
/// additions so the UI doesn't show empty cells.
struct CalLevelFormatter: ColumnFormatter {
    func format(_ raw: String) -> String {
        switch raw {
        case "0": return String(localized: "Raw", comment: "CAOM2 calibration level 0")
        case "1": return String(localized: "Cal", comment: "CAOM2 calibration level 1 (calibrated)")
        case "2": return String(localized: "Product", comment: "CAOM2 calibration level 2")
        case "3": return String(localized: "Composite", comment: "CAOM2 calibration level 3")
        case "4": return String(localized: "Analysis", comment: "CAOM2 calibration level 4")
        default: return raw
        }
    }
}

// MARK: - Boolean

/// Accept whatever ``BooleanValue`` recognises as true/false. True →
/// checkmark glyph; false → em-dash (explicit, visible to VoiceOver, and
/// distinguishable from a NULL/empty cell). Anything else passes through.
struct BooleanFormatter: ColumnFormatter {
    func format(_ raw: String) -> String {
        switch BooleanValue.parse(raw) {
        case true?: return "\u{2713}"     // ✓
        case false?: return "\u{2014}"    // — (em-dash)
        case nil: return raw
        }
    }
}

// MARK: - Wavelength (metres → nm/μm/mm/m)

/// CAOM2 `minwavelength`/`maxwavelength` are in metres. Raw scientific
/// notation (e.g., `5.0E-7`) is unreadable; convert to the most readable
/// SI prefix based on magnitude.
struct WavelengthFormatter: ColumnFormatter {
    func format(_ raw: String) -> String {
        guard let metres = finiteDouble(raw), metres > 0 else { return raw }

        // Pick the unit where the value is between 1 and 1000 if possible.
        let candidates: [(divisor: Double, suffix: String)] = [
            (1e-10, " Å"),
            (1e-9, " nm"),
            (1e-6, " \u{03BC}m"),   // μm
            (1e-3, " mm"),
            (1, " m"),
        ]
        // Walk largest-divisor-first (longest wavelengths first); pick the
        // first unit where magnitude drops below 1000, but default to the
        // smallest unit if the value is tiny.
        for (divisor, suffix) in candidates.reversed() {
            let scaled = metres / divisor
            if scaled >= 1 && scaled < 1000 {
                return formatScaled(scaled) + suffix
            }
        }
        // Below 1 Å — use Å anyway with scientific notation.
        let scaled = metres / 1e-10
        return String(format: "%.3g", scaled) + " Å"
    }

    private func formatScaled(_ v: Double) -> String {
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}

// MARK: - Angle (degrees → arcsec / arcmin / deg)

/// Angular values come from CADC in degrees. For pixel scale and field of
/// view, degrees are the worst unit to show — convert to arcseconds or
/// arcminutes based on the intended semantics.
struct AngleFormatter: ColumnFormatter {
    enum Mode {
        case arcsecPerPixel       // pixel scale: always arcseconds, "″/px"
        case arcminOrDegrees      // field of view: arcmin below 1°, degrees otherwise
    }

    let mode: Mode

    func format(_ raw: String) -> String {
        guard let degrees = finiteDouble(raw) else { return raw }

        switch mode {
        case .arcsecPerPixel:
            let arcsec = degrees * 3600.0
            if arcsec >= 10 { return String(format: "%.1f\u{2033}/px", arcsec) }
            if arcsec >= 1 { return String(format: "%.2f\u{2033}/px", arcsec) }
            return String(format: "%.3f\u{2033}/px", arcsec)

        case .arcminOrDegrees:
            if abs(degrees) >= 1 {
                return String(format: "%.3g\u{00B0}", degrees)
            }
            let arcmin = degrees * 60.0
            if abs(arcmin) >= 1 {
                return String(format: "%.2f\u{2032}", arcmin)
            }
            let arcsec = degrees * 3600.0
            return String(format: "%.1f\u{2033}", arcsec)
        }
    }
}

// MARK: - Legacy wrapper (CellFormatters)

/// Legacy entry point. New call sites should use ``CellFormatterRegistry/format(id:raw:)``
/// directly. Retained so existing views, exports, and tests compile unchanged.
enum CellFormatters {
    /// Format a raw cell value using the registry.
    ///
    /// For multi-unit columns this uses the registry's default unit. Views that
    /// need to honour a user-selected unit should call
    /// ``CellFormatterRegistry/format(id:raw:unitID:)`` directly.
    static func format(key: String, raw: String) -> String {
        CellFormatterRegistry.format(id: key, raw: raw, unitID: nil)
    }

    /// The checkmark glyph boolean-true cells render as. Preserved for tests.
    static let checkmark = "\u{2713}"

    // MARK: - Legacy type-level helpers (kept for test API compat)

    static func formatMJDDate(_ raw: String) -> String {
        MJDFormatter().format(raw.trimmingCharacters(in: .whitespaces))
    }

    static func formatCoordinate(_ raw: String, decimalPlaces: Int) -> String {
        let f = CoordinateFormatter(decimals: decimalPlaces, signMode: .negativeOnly)
        return f.format(raw.trimmingCharacters(in: .whitespaces))
    }

    static func formatIntegrationTime(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        return DurationFormatter().format(trimmed)
    }

    static func formatCalibrationLevel(_ raw: String) -> String {
        CalLevelFormatter().format(raw.trimmingCharacters(in: .whitespaces))
    }

    static func formatBoolean(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        return BooleanFormatter().format(trimmed)
    }

    static func formatWavelength(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        return WavelengthFormatter().format(trimmed)
    }

    static func formatScientific(_ raw: String, decimalPlaces: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let value = finiteDouble(trimmed) else { return trimmed }
        if abs(value) < 0.001 || abs(value) > 1e6 {
            return String(format: "%.\(decimalPlaces)E", value)
        }
        return String(format: "%.\(decimalPlaces)g", value)
    }

    static func formatTimestamp(_ raw: String) -> String {
        ISOTimestampFormatter().format(raw.trimmingCharacters(in: .whitespaces))
    }
}
