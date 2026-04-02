// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

// MARK: - Physical Constants (CGS-compatible, from CADC adql-manager)

private let speedOfLight = 2.997925e8       // m/s
private let planckConstant = 6.6262e-27     // erg·s
private let ergPerEV = 1.602192e-12         // 1 eV in ergs

// MARK: - Spectral Unit Factors

private let wavelengthFactors: [String: Double] = [
    "m": 1, "cm": 1e-2, "mm": 1e-3, "um": 1e-6, "nm": 1e-9, "a": 1e-10,
]

private let frequencyFactors: [String: Double] = [
    "hz": 1, "khz": 1e3, "mhz": 1e6, "ghz": 1e9,
]

private let energyFactors: [String: Double] = [
    "ev": 1, "kev": 1e3, "mev": 1e6, "gev": 1e9,
]

// Ordered longest first for greedy match
private let spectralSuffixPattern = try! NSRegularExpression(
    pattern: "(?:GHz|MHz|kHz|GeV|MeV|keV|nm|um|mm|cm|Hz|eV|A|m)$",
    options: .caseInsensitive
)

// MARK: - Time Unit Factors

private let secondsFactors: [String: Double] = [
    "s": 1, "m": 60, "h": 3600, "d": 86400, "y": 31536000,
]

private let daysFactors: [String: Double] = [
    "s": 1.0 / 86400, "m": 1.0 / 1440, "h": 1.0 / 24, "d": 1, "y": 365,
]

private let timeSuffixPattern = try! NSRegularExpression(
    pattern: "[smhdy]$",
    options: .caseInsensitive
)

// MARK: - Spectral Normalization

/// Extract the trailing spectral unit suffix from a value string.
func extractSpectralSuffix(_ input: String) -> (numeric: String, suffix: String?) {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
    if let match = spectralSuffixPattern.firstMatch(in: trimmed, range: range) {
        let matchRange = Range(match.range, in: trimmed)!
        let suffix = String(trimmed[matchRange]).lowercased()
        let numeric = String(trimmed[trimmed.startIndex..<matchRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        return (numeric, suffix)
    }
    return (trimmed, nil)
}

/// Convert a spectral value string (with optional unit suffix) to metres.
/// - Parameters:
///   - input: User input like "800nm", "5GeV", "300GHz", "0.2"
///   - inheritedSuffix: Optional suffix inherited from the other side of a range
/// - Returns: The value in metres
func normalizeToMetres(_ input: String, inheritedSuffix: String? = nil) throws -> Double {
    let (numeric, suffix) = extractSpectralSuffix(input)
    let unit = suffix ?? inheritedSuffix

    guard let value = Double(numeric) else {
        throw SearchError.parseError("Cannot parse spectral value: \"\(input.trimmingCharacters(in: .whitespaces))\"")
    }

    guard let unit else {
        // No unit — assume already in metres
        return value
    }

    // Wavelength → direct factor
    if let factor = wavelengthFactors[unit] {
        return value * factor
    }

    // Frequency → c / freq_in_Hz
    if let factor = frequencyFactors[unit] {
        return speedOfLight / (value * factor)
    }

    // Energy → (h * c) / (eV_to_erg * E_in_eV)
    if let factor = energyFactors[unit] {
        return (planckConstant * speedOfLight) / (ergPerEV * value * factor)
    }

    throw SearchError.parseError("Unknown spectral unit: \"\(unit)\"")
}

// MARK: - Time Normalization

/// Extract the trailing time unit suffix from a value string.
func extractTimeSuffix(_ input: String) -> (numeric: String, suffix: String?) {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
    if let match = timeSuffixPattern.firstMatch(in: trimmed, range: range) {
        let matchRange = Range(match.range, in: trimmed)!
        let suffix = String(trimmed[matchRange]).lowercased()
        let numeric = String(trimmed[trimmed.startIndex..<matchRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        return (numeric, suffix)
    }
    return (trimmed, nil)
}

/// Normalize a time value to the canonical unit (seconds or days).
/// - Parameters:
///   - input: User input like "30", "1m", "2.5h"
///   - defaultUnit: The canonical unit: "s" (seconds) or "d" (days)
///   - inheritedSuffix: Optional suffix inherited from the other side of a range
/// - Returns: The value expressed in the canonical unit
func normalizeTimeValue(_ input: String, defaultUnit: String, inheritedSuffix: String? = nil) throws -> Double {
    let (numeric, suffix) = extractTimeSuffix(input)
    let unit = suffix ?? inheritedSuffix ?? defaultUnit

    guard let value = Double(numeric) else {
        throw SearchError.parseError("Cannot parse time value: \"\(input.trimmingCharacters(in: .whitespaces))\"")
    }

    let factors = defaultUnit == "s" ? secondsFactors : daysFactors
    guard let factor = factors[unit] else {
        throw SearchError.parseError("Unknown time unit: \"\(unit)\"")
    }

    return value * factor
}

// MARK: - Pixel Scale Normalization

/// Normalize pixel scale value to degrees.
/// Pixel scale input may have a unit suffix (arcsec, arcmin, deg).
/// Default unit is arcseconds.
func normalizePixelScaleToDegrees(_ input: String) throws -> Double {
    let trimmed = input.trimmingCharacters(in: .whitespaces)

    for (unitSuffix, factor) in ADQL.pixelScaleFactors {
        if trimmed.lowercased().hasSuffix(unitSuffix) {
            let numeric = String(trimmed.dropLast(unitSuffix.count)).trimmingCharacters(in: .whitespaces)
            guard let value = Double(numeric) else {
                throw SearchError.parseError("Cannot parse pixel scale: \"\(trimmed)\"")
            }
            return (value * factor) / 3600.0
        }
    }

    // No suffix — assume arcseconds
    guard let value = Double(trimmed) else {
        throw SearchError.parseError("Cannot parse pixel scale: \"\(trimmed)\"")
    }
    return value / 3600.0
}

// MARK: - Errors

enum SearchError: LocalizedError {
    case parseError(String)
    case networkError(String)
    case queryError(String)

    var errorDescription: String? {
        switch self {
        case .parseError(let msg): return msg
        case .networkError(let msg): return msg
        case .queryError(let msg): return msg
        }
    }
}
