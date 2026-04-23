// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Physical constants used by the cross-dimension spectral converter.
/// These are the same values CADC CCDA's `convertUtils/constants.ts` uses —
/// keeping them identical means a given TAP row renders to the same numbers
/// in both clients for any supported unit.
enum SpectralConstants {
    /// Speed of light in metres per second.
    static let speedOfLight: Double = 2.997925e8
    /// Planck constant, erg·s (CGS-compatible, matching CCDA).
    static let planckConstant: Double = 6.6262e-27
    /// 1 eV expressed in ergs.
    static let ergPerElectronVolt: Double = 1.602192e-12
}

/// What *kind* of spectral measurement a given unit represents. Same unit id
/// may be unambiguously classified here even though numerically the values
/// cross-convert via the Planck relation / speed-of-light.
enum SpectralDimension: Sendable {
    case wavelength  // base: metres
    case frequency   // base: hertz
    case energy      // base: electron-volts
}

/// A recognised spectral unit with enough information to convert to and from
/// a dimension-native base unit. Identifiers are lowercase so they match the
/// keys already in `UnitConversion.swift` and the CCDA reference tables.
struct SpectralUnit: Sendable, Hashable {
    /// Stable key (lowercase). Persisted in `ColumnUnitStore`.
    let id: String
    /// User-facing label shown in the unit menu. Case-sensitive.
    let label: String
    let dimension: SpectralDimension
    /// Factor converting this unit *into* the dimension's base unit. For
    /// wavelength the base is metres, for frequency hertz, for energy eV.
    /// Example: `SpectralUnit(id: "nm", factorFromBase: 1e-9)` means
    /// `1 nm = 1e-9 m` in the wavelength dimension.
    let factorFromBase: Double

    // Wavelength (base: metres)
    static let metres = SpectralUnit(id: "m", label: "m", dimension: .wavelength, factorFromBase: 1)
    static let centimetres = SpectralUnit(id: "cm", label: "cm", dimension: .wavelength, factorFromBase: 1e-2)
    static let millimetres = SpectralUnit(id: "mm", label: "mm", dimension: .wavelength, factorFromBase: 1e-3)
    static let micrometres = SpectralUnit(id: "um", label: "μm", dimension: .wavelength, factorFromBase: 1e-6)
    static let nanometres  = SpectralUnit(id: "nm", label: "nm", dimension: .wavelength, factorFromBase: 1e-9)
    static let angstroms   = SpectralUnit(id: "a",  label: "Å",  dimension: .wavelength, factorFromBase: 1e-10)

    // Frequency (base: hertz)
    static let hertz      = SpectralUnit(id: "hz",  label: "Hz",  dimension: .frequency, factorFromBase: 1)
    static let kilohertz  = SpectralUnit(id: "khz", label: "kHz", dimension: .frequency, factorFromBase: 1e3)
    static let megahertz  = SpectralUnit(id: "mhz", label: "MHz", dimension: .frequency, factorFromBase: 1e6)
    static let gigahertz  = SpectralUnit(id: "ghz", label: "GHz", dimension: .frequency, factorFromBase: 1e9)

    // Energy (base: electron-volts)
    static let electronVolts      = SpectralUnit(id: "ev",  label: "eV",  dimension: .energy, factorFromBase: 1)
    static let kiloElectronVolts  = SpectralUnit(id: "kev", label: "keV", dimension: .energy, factorFromBase: 1e3)
    static let megaElectronVolts  = SpectralUnit(id: "mev", label: "MeV", dimension: .energy, factorFromBase: 1e6)
    static let gigaElectronVolts  = SpectralUnit(id: "gev", label: "GeV", dimension: .energy, factorFromBase: 1e9)

    /// Ordered, display-ready list of every supported spectral unit.
    static let all: [SpectralUnit] = [
        .metres, .centimetres, .millimetres, .micrometres, .nanometres, .angstroms,
        .hertz, .kilohertz, .megahertz, .gigahertz,
        .electronVolts, .kiloElectronVolts, .megaElectronVolts, .gigaElectronVolts,
    ]

    static func unit(withID id: String) -> SpectralUnit? {
        all.first { $0.id == id.lowercased() }
    }
}

/// Converts a wavelength in metres (TAP's canonical storage for
/// `energy_bounds_lower/upper` and `energy_restwav`) to any other spectral
/// unit — including cross-dimension conversions (λ → ν, λ → E, etc.).
///
/// Uses SI/CGS mixed constants identical to CCDA so the numeric output
/// matches the reference client for any given TAP row.
enum SpectralConverter {

    /// Convert `metres` (wavelength) to the given target unit.
    /// Returns `nil` on non-positive, non-finite, or zero input —
    /// cross-conversions (c/λ, hc/λ) would divide by zero otherwise.
    static func convert(metres: Double, to unit: SpectralUnit) -> Double? {
        guard metres.isFinite, metres > 0 else { return nil }

        switch unit.dimension {
        case .wavelength:
            return metres / unit.factorFromBase

        case .frequency:
            // freq(Hz) = c / λ(m) → divide by dimension factor to scale into target unit.
            let hz = SpectralConstants.speedOfLight / metres
            return hz / unit.factorFromBase

        case .energy:
            // E(eV) = (h·c) / (erg/eV · λ)
            let eV = (SpectralConstants.planckConstant * SpectralConstants.speedOfLight)
                   / (SpectralConstants.ergPerElectronVolt * metres)
            return eV / unit.factorFromBase
        }
    }
}

/// Formatter that converts TAP's metres-stored wavelength into a chosen
/// spectral unit and renders as `"value label"` (e.g. `"500.0 nm"`).
///
/// Numerical precision: 4 significant digits via `%.4g` — compact enough for
/// a table cell, precise enough for typical science use. Values outside that
/// range fall to scientific notation naturally via Swift's `%g` behaviour.
struct SpectralFormatter: ColumnFormatter {
    let unit: SpectralUnit

    func format(_ raw: String) -> String {
        guard let metres = finiteDouble(raw) else { return raw }
        guard let value = SpectralConverter.convert(metres: metres, to: unit) else {
            return raw
        }
        return "\(Self.formatValue(value)) \(unit.label)"
    }

    private static func formatValue(_ v: Double) -> String {
        // Choose a pretty format:
        //  • |v| ≥ 100   → one decimal (enough for "100.0 nm" style)
        //  • 1 ≤ |v| < 100 → two decimals
        //  • 0.001 ≤ |v| < 1 → three decimals
        //  • else → 4 significant digits in scientific form
        let mag = abs(v)
        if mag == 0 { return "0" }
        if mag >= 100 { return String(format: "%.1f", v) }
        if mag >= 1 { return String(format: "%.2f", v) }
        if mag >= 0.001 { return String(format: "%.3f", v) }
        return String(format: "%.4g", v)
    }
}
