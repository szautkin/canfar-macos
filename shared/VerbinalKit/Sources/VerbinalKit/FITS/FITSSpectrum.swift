// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The spectrum a FITS table holds: its wavelength and flux columns, and
/// its error when it has one, found by name. A column of arrays gives one
/// segment per row — an echelle order, as in an HST `_x1d` — a column of
/// numbers one segment of all the rows (a JWST `x1d`, an SDSS coadd).
///
/// An `_x1d` opened as an image was a blank 38946×1 picture of its row's
/// bytes (QA N1).
public struct FITSSpectrum: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public let wavelength: [Double]
        public let flux: [Double]
        public let error: [Double]?
    }

    public let wavelengthColumn: String
    public let wavelengthUnit: String?
    public let fluxColumn: String
    public let fluxUnit: String?
    public let errorColumn: String?
    public let segments: [Segment]

    public var pointCount: Int { segments.reduce(0) { $0 + $1.wavelength.count } }

    public var wavelengthRange: ClosedRange<Double>? { Self.range(segments.flatMap(\.wavelength)) }
    public var fluxRange: ClosedRange<Double>? { Self.range(segments.flatMap(\.flux)) }

    /// How large the error is, when the spectrum has one: the median of
    /// |error ÷ flux|, and the median error as a fraction of the flux's
    /// range — how tall a plot's error band is. A high-S/N spectrum's band
    /// can be thinner than its line, and was taken for missing (plan 21 D4).
    public var errorSize: (ofFlux: Double, ofRange: Double)? {
        var relative: [Double] = [], absolute: [Double] = []
        for segment in segments {
            guard let error = segment.error else { continue }
            for (flux, sigma) in zip(segment.flux, error) where sigma.isFinite && sigma >= 0 {
                absolute.append(sigma)
                if flux != 0 { relative.append(abs(sigma / flux)) }
            }
        }
        guard let range = fluxRange, range.upperBound > range.lowerBound,
              let ofFlux = Self.median(relative), let error = Self.median(absolute) else { return nil }
        return (ofFlux, error / (range.upperBound - range.lowerBound))
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    // MARK: - Finding it

    /// Names a spectrum's columns go by, most telling first.
    static let wavelengthNames = ["WAVELENGTH", "WAVE", "LAMBDA", "WAVELEN", "WAVE_VAC", "WAVE_AIR", "LOGLAM"]
    static let fluxNames = ["FLUX", "FLUX_DENSITY", "FLAM", "FNU", "SURF_BRIGHT", "NET"]
    static let errorNames = ["ERROR", "FLUX_ERROR", "FLUX_ERR", "ERR", "SIGMA", "IVAR"]

    /// The spectrum in `table`, whose rows `data` starts with; nil when it
    /// has no wavelength and flux columns of the same shape.
    public static func read(_ table: FITSBinaryTable, rows data: Data) -> FITSSpectrum? {
        func first(_ names: [String]) -> FITSBinaryTable.Column? {
            names.lazy.compactMap { table.column(named: $0) }.first { $0.isNumeric }
        }
        guard let waveColumn = first(wavelengthNames), let fluxColumn = first(fluxNames),
              waveColumn.count == fluxColumn.count,
              var waves = table.values(of: waveColumn, in: data),
              let fluxes = table.values(of: fluxColumn, in: data) else { return nil }
        var waveUnit = waveColumn.unit
        if waveColumn.name.uppercased() == "LOGLAM" {
            waves = waves.map { $0.map { pow(10, $0) } }
            waveUnit = "Angstrom"
        }
        let errorColumn = first(errorNames).flatMap { $0.count == fluxColumn.count ? $0 : nil }
        var errors = errorColumn.flatMap { table.values(of: $0, in: data) }
        if errorColumn?.name.uppercased() == "IVAR" {
            errors = errors?.map { $0.map { $0 > 0 ? 1 / $0.squareRoot() : .nan } }
        }

        // An array per row is a segment per row; a number per row, one of all.
        let rowsAsSegments = waveColumn.count > 1
        let rowWaves = rowsAsSegments ? waves : [waves.flatMap { $0 }]
        let rowFluxes = rowsAsSegments ? fluxes : [fluxes.flatMap { $0 }]
        let rowErrors = errors.map { rowsAsSegments ? $0 : [$0.flatMap { $0 }] }
        let segments = rowWaves.indices.compactMap { row in
            segment(rowWaves[row], rowFluxes[row], rowErrors?[row])
        }
        guard !segments.isEmpty else { return nil }
        return FITSSpectrum(wavelengthColumn: waveColumn.name, wavelengthUnit: waveUnit, fluxColumn: fluxColumn.name,
                            fluxUnit: fluxColumn.unit, errorColumn: errorColumn?.name, segments: segments)
    }

    /// The points with a real wavelength and flux, in wavelength order; nil when none.
    private static func segment(_ waves: [Double], _ fluxes: [Double], _ errors: [Double]?) -> Segment? {
        let kept = waves.indices.filter { waves[$0].isFinite && waves[$0] > 0 && fluxes[$0].isFinite }
            .sorted { waves[$0] < waves[$1] }
        guard !kept.isEmpty else { return nil }
        return Segment(wavelength: kept.map { waves[$0] }, flux: kept.map { fluxes[$0] },
                       error: errors.map { e in kept.map { e[$0] } })
    }

    // MARK: - Reading it

    public struct Point: Sendable, Equatable {
        public let wavelength: Double
        public let flux: Double
        public let error: Double?
    }

    /// At most `maxPoints` points, each the mean of its stretch of the
    /// spectrum (its error the stretch's mean error over √n), segment by
    /// segment, in wavelength order — for a plot or an answer.
    public func binned(maxPoints: Int) -> [[Point]] {
        let total = max(pointCount, 1)
        return segments.map { segment in
            let share = max(1, Int((Double(maxPoints) * Double(segment.wavelength.count) / Double(total)).rounded(.down)))
            let size = max(1, Int((Double(segment.wavelength.count) / Double(share)).rounded(.up)))
            return stride(from: 0, to: segment.wavelength.count, by: size).map { start in
                let range = start..<min(start + size, segment.wavelength.count)
                let n = Double(range.count)
                let error = segment.error.map { e -> Double in
                    let finite = range.map { e[$0] }.filter(\.isFinite)
                    guard !finite.isEmpty else { return .nan }
                    return finite.reduce(0, +) / Double(finite.count) / Double(finite.count).squareRoot()
                }
                return Point(wavelength: range.reduce(0) { $0 + segment.wavelength[$1] } / n,
                             flux: range.reduce(0) { $0 + segment.flux[$1] } / n,
                             error: error.flatMap { $0.isFinite ? $0 : nil })
            }
        }
    }

    private static func range(_ values: [Double]) -> ClosedRange<Double>? {
        let finite = values.filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return nil }
        return low...high
    }
}

/// What a table HDU shows: its spectrum, or — when it holds none — its
/// columns, so the file says what it is rather than nothing (QA N1).
public enum FITSTableContent: Sendable, Equatable {
    case spectrum(FITSSpectrum)
    /// The columns, each "NAME [unit]".
    case columns([String])

    /// The content of `hdu`, read from the file's bytes; nil when it is not a binary table.
    public static func read(_ hdu: FITSHDUnit, in file: Data) -> FITSTableContent? {
        guard let table = FITSBinaryTable(header: hdu.header) else { return nil }
        let end = min(file.count, hdu.dataOffset + table.rows * table.rowBytes)
        let rows = hdu.dataOffset < end ? file.subdata(in: hdu.dataOffset..<end) : Data()
        if let spectrum = FITSSpectrum.read(table, rows: rows) { return .spectrum(spectrum) }
        return .columns(table.columns.map(\.description))
    }

    /// The file's first table, the first holding a spectrum preferred; nil
    /// when it has no binary table.
    public static func first(of file: FITSFile, in data: Data) -> (hdu: FITSHDUnit, content: FITSTableContent)? {
        let tables = file.hdus.compactMap { hdu in read(hdu, in: data).map { (hdu: hdu, content: $0) } }
        return tables.first { $0.content.spectrum != nil } ?? tables.first
    }

    public var spectrum: FITSSpectrum? {
        if case .spectrum(let spectrum) = self { return spectrum }
        return nil
    }
}
