// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit

/// The image's controls, in a sheet that leaves the image usable (plan 47
/// 4.2): how it is shown, whether it is right, its header, its HDUs.
struct iOSFITSControls: View {
    @Bindable var model: FITSViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .display

    enum Section: String, CaseIterable, Identifiable {
        case display, verify, header, hdus
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .display: return "Display"
            case .verify: return "Verify"
            case .header: return "Header"
            case .hdus: return "HDUs"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $section) {
                    ForEach(Section.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                switch section {
                case .display:
                    iOSFITSDisplayPanel(model: model)
                case .verify:
                    iOSFITSVerifyPanel(model: model)
                case .header:
                    if let hdu = model.selectedHDU {
                        iOSHeaderView(title: model.displayName, cards: hdu.header.orderedCards)
                    }
                case .hdus:
                    List(model.viewableHDUs) { hdu in
                        Button {
                            Task { await model.selectHDU(hdu.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: iOSFileView.title(of: hdu))
                                    Text(verbatim: iOSFileView.shape(of: hdu)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if hdu.id == model.selectedHDUIndex {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(model.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Display

/// How the image is shown: the cuts (presets, and a histogram whose black
/// and white points move under the finger), the stretch, the colormap.
struct iOSFITSDisplayPanel: View {
    @Bindable var model: FITSViewerModel
    @State private var bins: [Int] = []
    @State private var range: (lo: Float, hi: Float)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    preset("Auto") { FITSParser.autoCut(pixels: model.pixels) }
                    preset("99.5 %") { FITSVerify.percentileCut(model.pixels, kept: 0.995) }
                    preset("Min–Max") { (model.pixelMin, model.pixelMax) }
                }

                if let range, !bins.isEmpty {
                    iOSCutHistogram(bins: bins, lo: range.lo, hi: range.hi,
                                    black: $model.renderParams.minCut, white: $model.renderParams.maxCut) {
                        model.renderImageDebounced()
                    }
                    .frame(height: 96)
                    HStack {
                        Label("\(Self.cut(model.renderParams.minCut))", systemImage: "circle.fill")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Label("\(Self.cut(model.renderParams.maxCut))", systemImage: "circle")
                    }
                    .font(.caption.monospacedDigit())
                    .labelStyle(.titleAndIcon)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Stretch").font(.subheadline.weight(.semibold))
                    Picker("Stretch", selection: $model.renderParams.stretch) {
                        ForEach(FITSRenderParams.StretchMode.allCases) { mode in
                            Text(verbatim: mode.rawValue.capitalized).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.renderParams.stretch) { _, _ in model.renderImage() }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Colormap").font(.subheadline.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(FITSRenderParams.ColormapType.allCases) { colormap in
                                swatch(colormap)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding()
        }
        .task(id: "\(model.id)-\(model.selectedHDUIndex)-\(model.pixelMin)-\(model.pixelMax)") { await measure() }
    }

    private func preset(_ title: LocalizedStringKey, _ cuts: @escaping () -> (min: Float, max: Float)?) -> some View {
        Button(title) {
            guard let cut = cuts(), cut.min < cut.max else { return }
            model.renderParams.minCut = cut.min
            model.renderParams.maxCut = cut.max
            model.renderImage()
        }
        .buttonStyle(.bordered)
        .disabled(model.pixels.isEmpty)
    }

    private func swatch(_ colormap: FITSRenderParams.ColormapType) -> some View {
        let selected = model.renderParams.colormap == colormap
        return Button {
            model.renderParams.colormap = colormap
            model.renderImage()
        } label: {
            VStack(spacing: 4) {
                if let ramp = Self.ramp(colormap) {
                    Image(decorative: ramp, scale: 1)
                        .resizable()
                        .frame(width: 64, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(verbatim: colormap.rawValue.capitalized)
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A colormap's ramp, drawn by the image's own renderer.
    @MainActor private static var ramps: [FITSRenderParams.ColormapType: CGImage] = [:]
    @MainActor private static func ramp(_ colormap: FITSRenderParams.ColormapType) -> CGImage? {
        if let kept = ramps[colormap] { return kept }
        let values = (0..<128).map { Float($0) / 127 }
        let image = FITSRenderEngine.render(pixels: values, width: 128, height: 1,
                                            params: FITSRenderParams(minCut: 0, maxCut: 1, stretch: .linear, colormap: colormap))
        ramps[colormap] = image
        return image
    }

    static func cut(_ value: Float) -> String {
        Double(value).formatted(.number.precision(.significantDigits(1...5)))
    }

    /// The histogram's range — the values without their extreme tenth of a
    /// percent, widened to the cuts — and its bins, away from the main thread.
    private func measure() async {
        let pixels = model.pixels
        let cuts = (model.renderParams.minCut, model.renderParams.maxCut)
        let result = await Task.detached(priority: .userInitiated) { () -> ((Float, Float), [Int])? in
            guard let middle = FITSVerify.percentileCut(pixels, kept: 0.998) else { return nil }
            let lo = min(middle.min, cuts.0), hi = max(middle.max, cuts.1)
            return ((lo, hi), FITSVerify.histogram(pixels, lo: lo, hi: hi, bins: 96))
        }.value
        guard let result else { return }
        range = result.0
        bins = result.1
    }
}

/// The values' histogram (counts on a log scale), with the black and white
/// points as handles: a drag moves the nearer one.
struct iOSCutHistogram: View {
    let bins: [Int]
    let lo: Float
    let hi: Float
    @Binding var black: Float
    @Binding var white: Float
    var onChange: () -> Void

    @State private var moving: Bool?   // true: black, false: white

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let peak = log1p(Double(bins.max() ?? 1))
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let barWidth = size.width / CGFloat(bins.count)
                    for (index, count) in bins.enumerated() where count > 0 {
                        let barHeight = CGFloat(log1p(Double(count)) / peak) * size.height
                        let rect = CGRect(x: CGFloat(index) * barWidth, y: size.height - barHeight,
                                          width: max(1, barWidth - 0.5), height: barHeight)
                        context.fill(Path(rect), with: .color(.secondary.opacity(0.5)))
                    }
                }
                handle(at: x(black, width), height: height, filled: true)
                handle(at: x(white, width), height: height, filled: false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if moving == nil {
                            moving = abs(value.startLocation.x - x(black, width)) <= abs(value.startLocation.x - x(white, width))
                        }
                        let target = self.value(value.location.x, width)
                        if moving == true { black = min(target, white - (hi - lo) / 1000) } else { white = max(target, black + (hi - lo) / 1000) }
                        onChange()
                    }
                    .onEnded { _ in moving = nil }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Histogram"))
        .accessibilityValue(Text(verbatim: "\(iOSFITSDisplayPanel.cut(black)) – \(iOSFITSDisplayPanel.cut(white))"))
    }

    private func x(_ value: Float, _ width: CGFloat) -> CGFloat {
        CGFloat((min(max(value, lo), hi) - lo) / (hi - lo)) * width
    }

    private func value(_ x: CGFloat, _ width: CGFloat) -> Float {
        lo + Float(min(max(x / width, 0), 1)) * (hi - lo)
    }

    private func handle(at x: CGFloat, height: CGFloat, filled: Bool) -> some View {
        ZStack {
            Rectangle().fill(Color.accentColor).frame(width: 2, height: height)
            Circle()
                .fill(filled ? Color.accentColor : Color(uiColor: .systemBackground))
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                .frame(width: 18, height: 18)
                .offset(y: height / 2 - 9)
        }
        .position(x: x, y: height / 2)
        .allowsHitTesting(false)
    }
}

// MARK: - Verify

/// Is it right? The file's checksums, its values, where it is on the sky, and
/// the cards that say what was observed (plan 47 4.3).
struct iOSFITSVerifyPanel: View {
    var model: FITSViewerModel
    @State private var integrity: FITSVerify.Integrity?
    @State private var stats: FITSVerify.Stats?

    var body: some View {
        List {
            Section("Whole") {
                switch integrity {
                case .intact?:
                    Label("Intact: DATASUM and CHECKSUM match", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                case .damaged(let why)?:
                    Label(why, systemImage: "xmark.seal.fill").foregroundStyle(.red)
                case .noChecksum?:
                    Label("No checksum in this HDU", systemImage: "seal").foregroundStyle(.secondary)
                case .notChecked(let why)?:
                    Label(why, systemImage: "seal").foregroundStyle(.secondary)
                case nil:
                    HStack { ProgressView(); Text("Checking…").foregroundStyle(.secondary) }
                }
                if let hdu = model.selectedHDU {
                    LabeledContent("Size", value: iOSFileView.shape(of: hdu))
                }
            }

            Section("Values") {
                if let stats {
                    value("Min", stats.min)
                    value("Max", stats.max)
                    LabeledContent(stats.medianSampled ? LocalizedStringKey("Median (sampled)") : LocalizedStringKey("Median"),
                                   value: iOSFITSDisplayPanel.cut(stats.median))
                    LabeledContent("Mean", value: Double(stats.mean).formatted(.number.precision(.significantDigits(1...5))))
                    LabeledContent("σ", value: stats.sigma.formatted(.number.precision(.significantDigits(1...5))))
                    LabeledContent("Blank (NaN)", value: stats.blank.formatted())
                    if let saturated = stats.saturated {
                        LabeledContent("At SATURATE or above", value: saturated.formatted())
                    }
                } else {
                    HStack { ProgressView(); Text("Measuring…").foregroundStyle(.secondary) }
                }
            }
            .monospacedDigit()

            if let wcs = model.wcs, let hdu = model.selectedHDU {
                Section("Sky") {
                    let width = Double(hdu.header.naxis1), height = Double(hdu.header.naxis2)
                    let (ra, dec) = wcs.pixelToWorld(x: width / 2, y: height / 2)
                    LabeledContent("Centre", value: "\(Sexagesimal.readoutHMS(degrees: ra)) \(Sexagesimal.readoutDMS(degrees: dec))")
                    LabeledContent("Pixel", value: "\(wcs.pixelScaleArcsec.formatted(.number.precision(.significantDigits(1...4))))″")
                    LabeledContent("Field", value: "\(iOSScaleBar.label(width * wcs.pixelScaleArcsec)) × \(iOSScaleBar.label(height * wcs.pixelScaleArcsec))")
                    LabeledContent("North from up", value: "\(wcs.northAngle.formatted(.number.precision(.fractionLength(1))))°")
                    LabeledContent("Projection", value: "\(wcs.projection)".uppercased())
                }
            }

            if let header = model.selectedHDU?.header ?? model.file?.hdus.first?.header {
                let keys = ["OBJECT", "DATE-OBS", "EXPTIME", "FILTER", "TELESCOP", "INSTRUME", "BUNIT"].filter { header.contains($0) }
                if !keys.isEmpty {
                    Section("Observation") {
                        ForEach(keys, id: \.self) { key in
                            LabeledContent(key, value: header.string(key) ?? "")
                        }
                    }
                }
            }
        }
        .task(id: "\(model.id)-\(model.selectedHDUIndex)-\(model.pixelMin)") { await check() }
    }

    private func value(_ title: LocalizedStringKey, _ value: Float) -> some View {
        LabeledContent(title, value: iOSFITSDisplayPanel.cut(value))
    }

    /// The checksums from the file's bytes, the values from its pixels —
    /// away from the main thread.
    private func check() async {
        integrity = nil
        stats = nil
        let pixels = model.pixels
        let saturate = model.selectedHDU?.header.contains("SATURATE") == true
            ? Float(model.selectedHDU?.header.double("SATURATE") ?? 0) : nil
        stats = await Task.detached(priority: .userInitiated) { FITSVerify.stats(pixels, saturate: saturate) }.value

        guard let url = model.fileURL, let hdus = model.file?.hdus, model.selectedHDUIndex < hdus.count else {
            integrity = .notChecked(String(localized: "The file is not on this device."))
            return
        }
        let index = model.selectedHDUIndex
        integrity = await Task.detached(priority: .userInitiated) { () -> FITSVerify.Integrity in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return .notChecked(String(localized: "The file could not be read."))
            }
            let starts = FITSVerify.headerStarts(hdus)
            return FITSVerify.integrity(of: hdus[index], headerStart: starts[index], in: bytes)
        }.value
    }
}
