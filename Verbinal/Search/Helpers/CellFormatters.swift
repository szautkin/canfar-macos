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
        // Coordinates
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
        // Spectral (wavelength / frequency / energy — 14 units, cross-dim convertible).
        "minwavelength":  Self.spectralSet,
        "maxwavelength":  Self.spectralSet,
        "restframeenergy": Self.spectralSet,
        // Integration time (seconds base — CCDA default is Seconds).
        "inttime":        Self.durationSet,
        // Pixel scale and image quality (degrees base; CCDA default arcseconds).
        "pixelscale":         Self.pixelScaleSet,
        "positionresolution": Self.imageQualitySet,
        // Field of view (square-degrees base; CCDA default Sq.deg).
        "fieldofview":    Self.fieldOfViewSet,
        // Observation date-range columns (MJD base; CCDA default Calendar).
        "startdate":      Self.mjdDateSet,
        "enddate":        Self.mjdDateSet,
    ]

    /// Shared spectral-unit set registered on all three wavelength/energy
    /// columns. Declared separately so future spectral columns only need a
    /// one-line entry in `sets`.
    private static let spectralSet: ColumnFormatSet = ColumnFormatSet(
        choices: SpectralUnit.all.map { unit in
            ColumnFormatChoice(unitID: unit.id, label: unit.label,
                               formatter: SpectralFormatter(unit: unit))
        },
        defaultUnitID: SpectralUnit.metres.id
    )

    /// Duration unit set — CCDA-parity for the integration-time column.
    /// Default matches CCDA's "Seconds" selection.
    private static let durationSet: ColumnFormatSet = ColumnFormatSet(
        choices: [
            ColumnFormatChoice(unitID: "seconds", label: "Seconds",
                               formatter: FixedDurationFormatter(unit: .seconds)),
            ColumnFormatChoice(unitID: "minutes", label: "Minutes",
                               formatter: FixedDurationFormatter(unit: .minutes)),
            ColumnFormatChoice(unitID: "hours",   label: "Hours",
                               formatter: FixedDurationFormatter(unit: .hours)),
            ColumnFormatChoice(unitID: "days",    label: "Days",
                               formatter: FixedDurationFormatter(unit: .days)),
        ],
        defaultUnitID: "seconds"
    )

    /// Pixel-scale angular unit set (degrees → mas / arcsec / arcmin / deg).
    /// CCDA default is Arcseconds.
    private static let pixelScaleSet: ColumnFormatSet = ColumnFormatSet(
        choices: [
            ColumnFormatChoice(unitID: "milliarcseconds", label: "Milliarcseconds",
                               formatter: FixedAngleFormatter(unit: .milliarcseconds)),
            ColumnFormatChoice(unitID: "arcseconds", label: "Arcseconds",
                               formatter: FixedAngleFormatter(unit: .arcseconds)),
            ColumnFormatChoice(unitID: "arcminutes", label: "Arcminutes",
                               formatter: FixedAngleFormatter(unit: .arcminutes)),
            ColumnFormatChoice(unitID: "degrees",    label: "Degrees",
                               formatter: FixedAngleFormatter(unit: .degrees)),
        ],
        defaultUnitID: "arcseconds"
    )

    /// Image-quality set — mas / arcsec / arcmin (no Degrees option in CCDA
    /// for this column; IQ is never usefully expressed in degrees).
    private static let imageQualitySet: ColumnFormatSet = ColumnFormatSet(
        choices: [
            ColumnFormatChoice(unitID: "milliarcseconds", label: "Milliarcseconds",
                               formatter: FixedAngleFormatter(unit: .milliarcseconds)),
            ColumnFormatChoice(unitID: "arcseconds", label: "Arcseconds",
                               formatter: FixedAngleFormatter(unit: .arcseconds)),
            ColumnFormatChoice(unitID: "arcminutes", label: "Arcminutes",
                               formatter: FixedAngleFormatter(unit: .arcminutes)),
        ],
        defaultUnitID: "arcseconds"
    )

    /// Field-of-view set — solid angle expressed as sq.arcsec / sq.arcmin /
    /// sq.deg. Default matches CCDA (Sq. deg).
    private static let fieldOfViewSet: ColumnFormatSet = ColumnFormatSet(
        choices: [
            ColumnFormatChoice(unitID: "sq_arcsec", label: "Sq. arcsec",
                               formatter: FixedAreaFormatter(unit: .squareArcseconds)),
            ColumnFormatChoice(unitID: "sq_arcmin", label: "Sq. arcmin",
                               formatter: FixedAreaFormatter(unit: .squareArcminutes)),
            ColumnFormatChoice(unitID: "sq_deg",    label: "Sq. deg",
                               formatter: FixedAreaFormatter(unit: .squareDegrees)),
        ],
        defaultUnitID: "sq_deg"
    )

    /// Date set for observation start/end (MJD base). Default Calendar
    /// matches CCDA; MJD alternative shows the raw numeric value.
    private static let mjdDateSet: ColumnFormatSet = ColumnFormatSet(
        choices: [
            ColumnFormatChoice(unitID: "calendar", label: "Calendar",
                               formatter: MJDFormatter(style: .dateAndTime)),
            ColumnFormatChoice(unitID: "mjd",      label: "MJD",
                               formatter: MJDRawFormatter()),
        ],
        defaultUnitID: "calendar"
    )

    /// Single-formatter columns. Keys are cleaned column ids, matching
    /// ``SearchResultColumns`` / ``CSVParser/cleanHeader``.
    ///
    /// Note on `ra(j20000)` / `dec(j20000)`: `cleanHeader` strips dots, so
    /// the CADC header `"RA (J2000.0)"` normalizes to `ra(j20000)` (no second
    /// `0` dropped — the `.0` becomes nothing; the `2000` remains `20000`
    /// because `"J2000.0"` → `"J20000"` after dot-strip).
    static let byID: [String: any ColumnFormatter] = [
        // Single-format date / timestamp columns (no unit choice in CCDA).
        "provelastexecuted": ISOTimestampFormatter(),
        "datarelease":       ISOTimestampFormatter(),
        // Labels and boolean glyphs — no unit-switch concept.
        "callev":       CalLevelFormatter(),
        "download":     BooleanFormatter(),
        "movingtarget": BooleanFormatter(),
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

/// Adaptive-precision numeric rendering matching CCDA's `scaleUtility.ts`
/// and `areaUtility.ts`: 6 decimals when the magnitude drops below 0.001 so
/// sub-thousandth values aren't collapsed to `"0.000"`, 3 decimals otherwise.
/// Exact zero gets the 3-decimal branch (renders `"0.000"`) rather than
/// jumping to scientific notation for a meaningless "small magnitude".
@inline(__always)
func adaptivePrecisionString(_ v: Double) -> String {
    let mag = abs(v)
    if mag != 0 && mag < 0.001 { return String(format: "%.6f", v) }
    return String(format: "%.3f", v)
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

/// Fixed-unit duration formatter — CCDA parity for user-selectable units on
/// the integration-time column. Input is seconds (the TAP native unit);
/// output is `"%.3f <suffix>"` in the chosen unit, matching CCDA's
/// `secondsUtility.ts` precision policy. Non-finite / non-numeric raws are
/// passed through; negative values are also passed through rather than
/// silently suppressed, since a user-chosen unit implies the user wants to
/// *see* the value.
struct FixedDurationFormatter: ColumnFormatter {
    enum Unit: String, Sendable {
        case seconds, minutes, hours, days

        var label: String {
            switch self {
            case .seconds: return "s"
            case .minutes: return "m"
            case .hours:   return "h"
            case .days:    return "d"
            }
        }

        /// Factor converting this unit *into* seconds (the TAP base).
        var factorToSeconds: Double {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours:   return 3600
            case .days:    return 86_400
            }
        }
    }

    let unit: Unit

    func format(_ raw: String) -> String {
        guard let seconds = finiteDouble(raw) else { return raw }
        let value = seconds / unit.factorToSeconds
        return String(format: "%.3f %@", value, unit.label)
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
/// arcminutes based on the intended semantics. Retained as a single-formatter
/// fallback; per-column unit switching is provided by ``FixedAngleFormatter``.
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

/// Explicit angular-unit formatter used by the pixel-scale / position-
/// resolution unit-switch menu. Input is degrees (CADC's native storage for
/// these columns); output is `"%value <label>"` with CCDA's adaptive
/// precision policy — 6 decimals when the magnitude drops below 0.001,
/// 3 decimals otherwise. Non-finite / non-numeric raws pass through.
struct FixedAngleFormatter: ColumnFormatter {
    enum Unit: String, Sendable {
        case milliarcseconds, arcseconds, arcminutes, degrees

        var label: String {
            switch self {
            case .milliarcseconds: return "mas"
            case .arcseconds:      return "\u{2033}"   // ″
            case .arcminutes:      return "\u{2032}"   // ′
            case .degrees:         return "\u{00B0}"   // °
            }
        }

        /// Factor converting degrees into this unit.
        var factorFromDegrees: Double {
            switch self {
            case .degrees:         return 1
            case .arcminutes:      return 60
            case .arcseconds:      return 3600
            case .milliarcseconds: return 3_600_000
            }
        }
    }

    let unit: Unit

    func format(_ raw: String) -> String {
        guard let degrees = finiteDouble(raw) else { return raw }
        let value = degrees * unit.factorFromDegrees
        return "\(adaptivePrecisionString(value)) \(unit.label)"
    }
}

// MARK: - Area (sq.deg base)

/// Solid-angle (area) formatter for CCDA parity on the field-of-view column.
/// Input is square degrees (CADC's native); output is the value converted
/// into the chosen square-angular unit. Matches CCDA areaUtility.ts's
/// precision policy (6 decimals below 0.001, 3 otherwise).
struct FixedAreaFormatter: ColumnFormatter {
    enum Unit: String, Sendable {
        case squareArcseconds, squareArcminutes, squareDegrees

        var label: String {
            switch self {
            case .squareArcseconds: return "sq arcsec"
            case .squareArcminutes: return "sq arcmin"
            case .squareDegrees:    return "sq deg"
            }
        }

        /// Factor converting sq.deg into this unit.
        ///  • 1 sq.deg = 3600 sq.arcmin  (60² minutes per degree)
        ///  • 1 sq.deg = 12 960 000 sq.arcsec (3600² seconds per degree)
        var factorFromSquareDegrees: Double {
            switch self {
            case .squareDegrees:    return 1
            case .squareArcminutes: return 3600
            case .squareArcseconds: return 12_960_000
            }
        }
    }

    let unit: Unit

    func format(_ raw: String) -> String {
        guard let sqDeg = finiteDouble(raw) else { return raw }
        let value = sqDeg * unit.factorFromSquareDegrees
        return "\(adaptivePrecisionString(value)) \(unit.label)"
    }
}

// MARK: - Raw MJD

/// Pure passthrough of an MJD numeric value. Exists as a named formatter so
/// the unit-switch menu can offer "MJD" as a first-class choice against the
/// calendar-formatted default on date columns.
struct MJDRawFormatter: ColumnFormatter {
    func format(_ raw: String) -> String {
        guard let mjd = finiteDouble(raw) else { return raw }
        // Preserve the input's precision without introducing float drift —
        // we trust the server's representation of the MJD value.
        if mjd == mjd.rounded(.towardZero) {
            return String(format: "%.1f", mjd)
        }
        return String(mjd)
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
