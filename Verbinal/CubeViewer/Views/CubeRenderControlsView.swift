// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// Render-control side panel. Window/stretch/colormap are shared by both modes
/// (slice re-renders, debounced; volume picks them up live). Density, spectral
/// scale, MIP, and the transfer function apply to the volume mode.
struct CubeRenderControlsView: View {
    @Bindable var model: CubeViewerModel
    @State private var showExport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                infoSection
                Divider()
                displaySection
                if model.viewMode == .volume {
                    Divider()
                    volumeSection
                }
                #if os(macOS)
                Divider()
                exportSection
                #endif
            }
            .padding(14)
        }
        .frame(width: 270)
        #if os(macOS)
        .sheet(isPresented: $showExport) { CubeExportView(model: model) }
        #endif
    }

    // MARK: Cube info + statistics

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.object.isEmpty, model.object != "—" {
                Text(model.object).font(.headline)
            }
            let meta = [model.telescope, model.instrument].filter { !$0.isEmpty }.joined(separator: " · ")
            if !meta.isEmpty {
                Text(meta).font(.caption).foregroundStyle(.secondary)
            }
            infoRow("Dimensions", "\(model.nx) × \(model.ny) × \(model.nz)")
            if !model.bunit.isEmpty { infoRow("Unit", model.bunit) }
            if let stats = model.stats {
                infoRow("Range", "\(fmt(stats.lo)) … \(fmt(stats.hi))")
                infoRow("Min / Max", "\(fmt(stats.min)) / \(fmt(stats.max))")
                infoRow("Median", fmt(stats.median))
                infoRow("NaN", String(format: "%.1f%%", stats.nanFrac * 100))
            }
            infoRow("Mode", model.isStreamed ? "Streamed" : "Resident")
        }
    }

    // MARK: Display

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Display").font(.subheadline.bold())

            colormapSwatches
            stretchButtons
            windowControl
            colorbar
        }
    }

    private var windowControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Window").font(.caption)
                Spacer()
                let raw = model.rawWindow
                Text("\(fmt(raw.lo)) … \(fmt(raw.hi))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: windowLoBinding, in: 0...1)
            Slider(value: windowHiBinding, in: 0...1)
            HStack(spacing: 6) {
                Button("p99.9") { model.autoWindowPercentile() }
                Button("Min/Max") { model.autoWindowFullRange() }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    /// Colorbar legend — the active colormap ramp with raw min/max labels.
    private var colorbar: some View {
        let raw = model.rawWindow
        return VStack(alignment: .leading, spacing: 2) {
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: colorbarStops, startPoint: .leading, endPoint: .trailing))
                .frame(height: 14)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.quaternary))
            HStack {
                Text(fmt(raw.lo)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text(fmt(raw.hi)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var colorbarStops: [Color] { stops(for: model.colormap) }

    private func stops(for cm: FITSRenderParams.ColormapType) -> [Color] {
        let lut = FITSRenderEngine.colormapRGBA(cm)
        return stride(from: 0, to: 256, by: 16).map { i in
            Color(.sRGB, red: Double(lut[i * 4]) / 255, green: Double(lut[i * 4 + 1]) / 255, blue: Double(lut[i * 4 + 2]) / 255)
        }
    }

    private var colormapSwatches: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Colormap").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 4)], spacing: 4) {
                ForEach(FITSRenderParams.ColormapType.allCases) { cm in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: stops(for: cm), startPoint: .leading, endPoint: .trailing))
                        .frame(height: 18)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(model.colormap == cm ? Color.accentColor : Color.black.opacity(0.15),
                                              lineWidth: model.colormap == cm ? 2 : 1)
                        )
                        .help(cm.rawValue.capitalized)
                        .onTapGesture { model.colormap = cm; model.renderSliceDebounced() }
                }
            }
        }
    }

    private var stretchButtons: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stretch").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 4)], spacing: 4) {
                ForEach(FITSRenderParams.StretchMode.allCases) { mode in
                    Button(mode.rawValue.capitalized) {
                        model.stretch = mode; model.renderSliceDebounced()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(model.stretch == mode ? Color.accentColor : nil)
                }
            }
        }
    }

    // MARK: Volume

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Volume").font(.subheadline.bold())

            Picker("Mode", selection: $model.mip) {
                Text("Emission").tag(false)
                Text("Max-intensity").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if !model.mip {
                labeledSlider("Density", value: $model.density, range: 0.1...3)
            }
            labeledSlider("Spectral scale", value: $model.spectralScale, range: 0.5...4)
            labeledSlider("Quality", value: $model.volumeSteps, range: 96...768)

            Toggle("Slice-plane marker", isOn: $model.showSlicePlane)
                .toggleStyle(.switch).controlSize(.small)
            Toggle("Idle auto-orbit", isOn: $model.autoOrbit)
                .toggleStyle(.switch).controlSize(.small)

            if !model.mip {
                Text("Opacity curve").font(.caption).foregroundStyle(.secondary)
                TransferFunctionEditor(points: $model.transferFunction)
            }
        }
    }

    #if os(macOS)
    private var exportSection: some View {
        Button { showExport = true } label: {
            Label("Export figure…", systemImage: "square.and.arrow.down")
        }
    }
    #endif

    // MARK: Helpers

    @ViewBuilder
    private func labeledSlider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func fmt(_ v: Float) -> String { String(format: "%.3g", v) }

    // Slice-affecting bindings re-render the slice (debounced); the volume reads
    // these live via updateNSView, so no extra plumbing there.
    private var windowLoBinding: Binding<Float> {
        Binding(get: { model.windowLo }, set: { model.windowLo = min($0, model.windowHi - 0.01); model.renderSliceDebounced() })
    }
    private var windowHiBinding: Binding<Float> {
        Binding(get: { model.windowHi }, set: { model.windowHi = max($0, model.windowLo + 0.01); model.renderSliceDebounced() })
    }
}

#if os(macOS)
/// Export typography + theme. Light "journal" theme by default — publication-ready.
struct CubeExportStyle {
    enum Theme: String, CaseIterable, Identifiable {
        case light, dark
        var id: String { rawValue }
        var background: Color { self == .dark ? Color(white: 0.05) : .white }
        var foreground: Color { self == .dark ? .white : Color(white: 0.08) }
        var secondary: Color { self == .dark ? Color(white: 0.62) : Color(white: 0.42) }
        var line: Color { self == .dark ? Color(white: 0.30) : Color(white: 0.78) }
    }
    enum FontKind: String, CaseIterable, Identifiable {
        case sans, mono, serif
        var id: String { rawValue }
        var design: Font.Design { self == .mono ? .monospaced : (self == .serif ? .serif : .default) }
    }
    var theme: Theme = .light
    var font: FontKind = .sans
    var scale: Double = 1.0
    var annotate = true
    var transparent = false
}

/// Export sheet — style controls, a live preview, and PNG/PDF output.
struct CubeExportView: View {
    let model: CubeViewerModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("cubeExport.theme") private var themeRaw = CubeExportStyle.Theme.light.rawValue
    @AppStorage("cubeExport.font") private var fontRaw = CubeExportStyle.FontKind.sans.rawValue
    @AppStorage("cubeExport.scale") private var scale = 1.0
    @AppStorage("cubeExport.annotate") private var annotate = true
    @AppStorage("cubeExport.transparent") private var transparent = false
    @State private var content: CGImage?

    private var style: CubeExportStyle {
        CubeExportStyle(theme: CubeExportStyle.Theme(rawValue: themeRaw) ?? .light,
                        font: CubeExportStyle.FontKind(rawValue: fontRaw) ?? .sans,
                        scale: scale, annotate: annotate, transparent: transparent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Export Figure").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }

            preview

            Picker("Theme", selection: $themeRaw) {
                Text("Journal light").tag(CubeExportStyle.Theme.light.rawValue)
                Text("Cockpit dark").tag(CubeExportStyle.Theme.dark.rawValue)
            }.pickerStyle(.segmented)
            Picker("Font", selection: $fontRaw) {
                Text("Sans").tag(CubeExportStyle.FontKind.sans.rawValue)
                Text("Mono").tag(CubeExportStyle.FontKind.mono.rawValue)
                Text("Serif").tag(CubeExportStyle.FontKind.serif.rawValue)
            }.pickerStyle(.segmented)
            HStack {
                Text("Text scale").font(.callout)
                Slider(value: $scale, in: 0.75...1.5)
                Text(String(format: "%.2f×", scale)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Toggle("Annotations (header + legend)", isOn: $annotate)
            Toggle("Transparent background", isOn: $transparent)

            HStack(spacing: 10) {
                Button("PNG 2×") { exportPNG(2) }
                Button("PNG 4×") { exportPNG(4) }
                Button("PDF…") { exportPDF() }
                Spacer()
            }
            .buttonStyle(.borderedProminent)
            .disabled(content == nil)
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { content = currentContent() }
    }

    @ViewBuilder
    private var preview: some View {
        if let content {
            GeometryReader { geo in
                CubeExportPlate(metadata: model.figureMetadata(), date: dateString, content: content, stops: stops, style: style)
                    .frame(width: 1000)
                    .scaleEffect(geo.size.width / 1000, anchor: .topLeading)
            }
            .frame(height: 250)
            .clipped()
            .background(Color(white: 0.2))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        } else {
            Text("Open a cube and choose Slice or Volume to export.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).frame(height: 250)
        }
    }

    private var dateString: String { Date.now.formatted(date: .abbreviated, time: .shortened) }

    private var stops: [Color] {
        let lut = FITSRenderEngine.colormapRGBA(model.colormap)
        return stride(from: 0, to: 256, by: 16).map { i in
            Color(.sRGB, red: Double(lut[i * 4]) / 255, green: Double(lut[i * 4 + 1]) / 255, blue: Double(lut[i * 4 + 2]) / 255)
        }
    }

    private func currentContent() -> CGImage? {
        model.viewMode == .slice ? model.sliceImage : model.volumeSnapshot?(1400, 1050)
    }

    private var baseName: String {
        let base = (model.object.isEmpty || model.object == "—") ? "cube" : model.object
        return "\(base)_\(model.viewMode == .slice ? "ch\(model.channel + 1)" : "volume")"
    }

    private func plate(_ image: CGImage) -> CubeExportPlate {
        CubeExportPlate(metadata: model.figureMetadata(), date: dateString, content: image, stops: stops, style: style)
    }

    private func exportPNG(_ factor: CGFloat) {
        guard let content else { return }
        let renderer = ImageRenderer(content: plate(content))
        renderer.scale = factor
        guard let nsImage = renderer.nsImage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(baseName).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let tiff = nsImage.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    private func exportPDF() {
        guard let content else { return }
        let renderer = ImageRenderer(content: plate(content))
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(baseName).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        renderer.render { size, renderInContext in
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
            context.beginPDFPage(nil)
            renderInContext(context)
            context.endPDFPage()
            context.closePDF()
        }
    }
}

/// Publication figure plate: header (title / instrument / file / date), the
/// rendered image, and a legend (colorbar + WCS ranges + dimensions + NaN + mode).
private struct CubeExportPlate: View {
    let metadata: CubeFigureMetadata
    let date: String
    let content: CGImage
    let stops: [Color]
    let style: CubeExportStyle

    var body: some View {
        VStack(spacing: 0) {
            if style.annotate {
                header.padding(16)
                Rectangle().fill(style.theme.line).frame(height: 1)
            }
            Image(decorative: content, scale: 1)
                .resizable()
                .scaledToFit()
                .padding(style.annotate ? 14 : 0)
            if style.annotate {
                Rectangle().fill(style.theme.line).frame(height: 1)
                footer.padding(16)
            }
        }
        .frame(width: 1000)
        .background(style.transparent ? Color.clear : style.theme.background)
        .foregroundStyle(style.theme.foreground)
        .font(.system(size: 13 * style.scale, design: style.font.design))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(metadata.title).font(.system(size: 22 * style.scale, weight: .bold, design: style.font.design))
                if !metadata.instrument.isEmpty {
                    Text(metadata.instrument).foregroundStyle(style.theme.secondary)
                }
                Text("\(metadata.channelLabel)   \(metadata.spectral)").foregroundStyle(style.theme.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if !metadata.fileName.isEmpty { Text(metadata.fileName).foregroundStyle(style.theme.secondary) }
                Text(date).foregroundStyle(style.theme.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(metadata.valueLo).monospacedDigit()
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 12)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(style.theme.line))
                Text(metadata.valueHi).monospacedDigit()
                if !metadata.unit.isEmpty { Text(metadata.unit).foregroundStyle(style.theme.secondary) }
                Text("· \(metadata.stretch) · \(metadata.colormap)").foregroundStyle(style.theme.secondary)
            }
            HStack(alignment: .top, spacing: 22) {
                legend("DIMENSIONS", metadata.dimensions)
                if let ra = metadata.raRange { legend(metadata.lonLabel, ra) }
                if let dec = metadata.decRange { legend(metadata.latLabel, dec) }
                if !metadata.spectralRange.isEmpty { legend("SPECTRAL", metadata.spectralRange) }
                legend("NaN", metadata.nan)
                legend("MODE", metadata.mode)
            }
            .font(.system(size: 11 * style.scale, design: style.font.design))
        }
    }

    private func legend(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key).foregroundStyle(style.theme.secondary)
            Text(value)
        }
    }
}
#endif
