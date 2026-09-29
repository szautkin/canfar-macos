// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Charts
import SwiftUI
import VerbinalKit

/// A table HDU in the FITS viewer: its spectrum plotted — flux against
/// wavelength, an echelle order per line, the error as a band — or, when
/// it holds no spectrum, what its columns are (plan 17 U4, QA N1).
struct FITSTableContentView: View {
    let content: FITSTableContent
    let fileName: String

    var body: some View {
        switch content {
        case .spectrum(let spectrum):
            FITSSpectrumPlot(spectrum: spectrum, fileName: fileName)
        case .columns(let columns):
            ContentUnavailableView {
                Label("No spectrum in this table", systemImage: "tablecells")
            } description: {
                Text("It has no wavelength and flux columns. Its columns: \(columns.joined(separator: ", "))")
                    .textSelection(.enabled)
            }
        }
    }
}

/// How a plot's axis writes very small or very large numbers: in units of
/// a power of ten, named once in the axis title (flux of 4 × 10⁻¹⁴).
enum SpectrumAxis {
    /// The power of ten to write values in, 0 when they read well as they are.
    static func exponent(for range: ClosedRange<Double>?) -> Int {
        guard let range else { return 0 }
        let largest = max(abs(range.lowerBound), abs(range.upperBound))
        guard largest.isFinite, largest > 0 else { return 0 }
        let power = Int(log10(largest).rounded(.down))
        return (-2...4).contains(power) ? 0 : power
    }

    /// "Flux (10^-14 erg/s/cm**2/Angstrom)".
    static func title(_ name: String, unit: String?, exponent: Int) -> String {
        let scale = exponent == 0 ? nil : "10^\(exponent)"
        let inside = [scale, unit].compactMap { $0 }.joined(separator: " ")
        return inside.isEmpty ? name : "\(name) (\(inside))"
    }
}

private struct FITSSpectrumPlot: View {
    let spectrum: FITSSpectrum
    let fileName: String

    /// Enough points for any screen, few enough to draw at once.
    private static let maxPoints = 4000

    private var segments: [[FITSSpectrum.Point]] { spectrum.binned(maxPoints: Self.maxPoints) }
    private var exponent: Int { SpectrumAxis.exponent(for: spectrum.fluxRange) }

    var body: some View {
        let scale = pow(10, Double(exponent))
        let segments = segments
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(fileName).font(.headline)
                Text("\(spectrum.fluxColumn) against \(spectrum.wavelengthColumn) · \(spectrum.pointCount) points")
                    .font(.caption).foregroundStyle(.secondary)
                if spectrum.segments.count > 1 {
                    Text("\(spectrum.segments.count) orders").font(.caption).foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(segments.indices, id: \.self) { index in
                    ForEach(segments[index].indices, id: \.self) { point in
                        let p = segments[index][point]
                        if let error = p.error {
                            AreaMark(x: .value("Wavelength", p.wavelength),
                                     yStart: .value("Low", (p.flux - error) / scale),
                                     yEnd: .value("High", (p.flux + error) / scale),
                                     series: .value("Order", "e\(index)"))
                                .foregroundStyle(.tint.opacity(0.18))
                        }
                        LineMark(x: .value("Wavelength", p.wavelength), y: .value("Flux", p.flux / scale),
                                 series: .value("Order", "f\(index)"))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .foregroundStyle(.tint)
                    }
                }
            }
            .chartXScale(domain: spectrum.wavelengthRange ?? 0...1)
            .chartXAxisLabel(SpectrumAxis.title(String(localized: "Wavelength"), unit: spectrum.wavelengthUnit, exponent: 0))
            .chartYAxisLabel(SpectrumAxis.title(String(localized: "Flux"), unit: spectrum.fluxUnit, exponent: exponent))
            .accessibilityLabel(Text("Spectrum of \(fileName)"))
        }
        .padding(16)
    }
}
