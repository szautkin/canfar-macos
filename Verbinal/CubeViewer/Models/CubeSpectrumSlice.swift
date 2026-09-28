// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Part of a spectrum, binned: channels `first…last`, `bin` at a time, each
/// value the mean of its bin's measured channels, placed at the mean of
/// their spectral values.
///
/// A whole NIRSpec spectrum came back as 3610 bare values — about 60 KB,
/// with no wavelength and no unit (QA M13).
struct CubeSpectrumSlice: Equatable {
    /// Values returned at most; a longer slice is cut short and says so.
    static let maxValues = 8192

    let first: Int
    let last: Int
    let bin: Int
    /// Mean of each bin's measured channels; nil where all were blank.
    let values: [Double?]
    /// Each value's place on the spectral axis; nil without a spectral WCS.
    let axis: [Double]?
    /// Indices into `values` whose bins were all blank.
    let blanked: [Int]
    let truncated: Bool

    /// Nil, with why, when the range or bin is not one the spectrum has.
    static func make(_ spectrum: [Float], first: Int?, last: Int?, bin: Int?,
                     axisValue: ((Int) -> Double)?) -> Result<CubeSpectrumSlice, RangeProblem> {
        let count = spectrum.count
        let first = first ?? 0, last = last ?? count - 1, bin = bin ?? 1
        guard count > 0 else { return .failure(.init("the spectrum is empty")) }
        guard (0..<count).contains(first), (0..<count).contains(last), first <= last else {
            return .failure(.init("channels must be 0…\(count - 1) with firstChannel ≤ lastChannel; got \(first)…\(last)"))
        }
        guard bin >= 1 else { return .failure(.init("bin must be 1 or more; got \(bin)")) }

        var values: [Double?] = [], axis: [Double] = [], blanked: [Int] = []
        var start = first
        while start <= last, values.count < maxValues {
            let channels = start...min(start + bin - 1, last)
            let measured = channels.map { spectrum[$0] }.filter(\.isFinite)
            if measured.isEmpty { blanked.append(values.count) }
            values.append(measured.isEmpty ? nil : measured.reduce(0) { $0 + Double($1) } / Double(measured.count))
            if let axisValue { axis.append(channels.reduce(0) { $0 + axisValue($1) } / Double(channels.count)) }
            start += bin
        }
        return .success(CubeSpectrumSlice(first: first, last: last, bin: bin, values: values,
                                          axis: axisValue == nil ? nil : axis, blanked: blanked,
                                          truncated: start <= last))
    }

    struct RangeProblem: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
