// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Charts
import SwiftUI
import VerbinalKit

/// A table HDU in the FITS viewer: its spectrum plotted — flux against
/// wavelength, an echelle order per line, the error as a band — with
/// Export Figure; or, when it holds no spectrum, what its columns are
/// (plan 17 U4, plan 19 F1).
struct FITSTableContentView: View {
    let content: FITSTableContent
    let caption: FITSFigureCaption

    @State private var message: String?

    var body: some View {
        switch content {
        case .spectrum(let spectrum):
            VStack(alignment: .leading, spacing: 0) {
                FITSSpectrumPlot(spectrum: spectrum, title: caption.title, subtitle: caption.subtitle)
                HStack {
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Menu("Export Figure") {
                        Button("PNG 2×") { save(spectrum, .png, scale: 2) }
                        Button("PNG 4×") { save(spectrum, .png, scale: 4) }
                        Button("PDF…") { save(spectrum, .pdf, scale: 1) }
                    }
                    .fixedSize()
                    .pointable("fits.spectrumExport", label: String(localized: "Export Figure"), screen: "fits")
                }
                .padding([.horizontal, .bottom], 16)
            }
        case .columns(let columns):
            ContentUnavailableView {
                Label("No spectrum in this table", systemImage: "tablecells")
            } description: {
                Text("It has no wavelength and flux columns. Its columns: \(columns.joined(separator: ", "))")
                    .textSelection(.enabled)
            }
        }
    }

    private func save(_ spectrum: FITSSpectrum, _ format: FigureFile.Format, scale: CGFloat) {
        let figure = FITSSpectrumFigure(spectrum: spectrum, caption: caption,
                                        dark: FITSExportStyle.stored().theme == .dark)
        switch FigureFile.save(figure, as: format, scale: scale, name: caption.baseName) {
        case .success(let url)?: message = String(localized: "Saved \(url.lastPathComponent)")
        case .failure(let error)?: message = String(localized: "Could not save the figure: \(error.localizedDescription)")
        case nil: break
        }
    }
}

/// A spectrum as a publication figure: the plot the viewer draws, on a
/// plate of fixed size, light or dark (plan 19 F1, QA N13).
struct FITSSpectrumFigure: View {
    let spectrum: FITSSpectrum
    let caption: FITSFigureCaption
    let dark: Bool

    static let size = CGSize(width: 900, height: 540)

    var body: some View {
        FITSSpectrumPlot(spectrum: spectrum, title: caption.title, subtitle: caption.subtitle)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(dark ? Color(white: 0.05) : .white)
            .environment(\.colorScheme, dark ? .dark : .light)
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

/// The plot itself — on screen and in a figure alike.
struct FITSSpectrumPlot: View {
    let spectrum: FITSSpectrum
    let title: String
    var subtitle = ""

    /// Enough points for any screen, few enough to draw at once.
    private static let maxPoints = 4000

    private var exponent: Int { SpectrumAxis.exponent(for: spectrum.fluxRange) }

    var body: some View {
        let scale = pow(10, Double(exponent))
        let segments = spectrum.binned(maxPoints: Self.maxPoints)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 8) {
                Text("\(spectrum.fluxColumn) against \(spectrum.wavelengthColumn) · \(spectrum.pointCount) points")
                if spectrum.segments.count > 1 { Text("\(spectrum.segments.count) orders") }
            }
            .font(.caption).foregroundStyle(.secondary)
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
            .accessibilityLabel(Text("Spectrum of \(title)"))
        }
        .padding(16)
    }
}
