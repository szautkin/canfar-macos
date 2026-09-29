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

// Colormap gradient stops + the swatch grid live in
// Helpers/ColormapSwatches.swift, shared with the FITS panel.

/// Render-control side panel. Window/stretch/colormap are shared by both modes
/// (slice re-renders coalesced; volume picks them up live). Density, spectral
/// scale, MIP, and the transfer function apply to the volume mode.
struct CubeRenderControlsView: View {
    @Bindable var model: CubeViewerModel
    var marks: MarkEditor?
    var markCommands: MarkCommandHost?
    @State private var showExport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                infoSection
                Divider()
                displaySection
                if model.viewMode == .volume {
                    Divider()
                    volumeSection
                }
                if let marks {
                    Divider()
                    MarksPanel(editor: marks, target: model.markTarget, host: markCommands)
                }
                #if os(macOS)
                Divider()
                exportSection
                #endif
            }
            .padding(16)
        }
        // No fixed width — the host HSplitView bounds the panel
        // (min 240 / ideal 270 / max 340), matching the FITS sidebar.
        #if os(macOS)
        .sheet(isPresented: $showExport) {
            CubeExportView(model: model, marks: model.markTarget.map { marks?.marks(on: $0) ?? [] } ?? [])
        }
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
            Text("Display").font(.subheadline.weight(.semibold))

            colormapSwatches
            stretchButtons
            windowControl
            colorbar
            Picker("Background", selection: $model.background) {
                ForEach(CubeBackground.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var windowControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Window").font(.caption).foregroundStyle(.secondary)
                Spacer()
                let raw = model.rawWindow
                Text("\(fmt(raw.lo)) … \(fmt(raw.hi))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text("Low")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
                Slider(value: windowLoBinding, in: 0...1)
                    .accessibilityLabel("Window low")
            }
            HStack(spacing: 4) {
                Text("High")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
                Slider(value: windowHiBinding, in: 0...1)
                    .accessibilityLabel("Window high")
            }
            HStack(spacing: 6) {
                Button("Auto") { model.autoWindow() }
                    .help("A little below the background to where the brightest percent begins")
                Button("99.9%") { model.autoWindowPercentile() }
                Button("Full Range") { model.autoWindowFullRange() }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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

    private var colorbarStops: [Color] { colormapPreviewStops(model.colormap) }

    private var colormapSwatches: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Colormap").font(.caption).foregroundStyle(.secondary)
            ColormapSwatchGrid(
                selection: Bindable(model).colormap,
                onChange: { model.requestSliceRender() }
            )
        }
    }

    /// Segmented, matching the FITS panel — one single-choice affordance
    /// for the same concept across both viewers (was a grid of tinted
    /// buttons here, a segmented control there).
    private var stretchButtons: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stretch").font(.caption).foregroundStyle(.secondary)
            Picker("Stretch", selection: Binding(
                get: { model.stretch },
                set: { model.stretch = $0; model.requestSliceRender() }
            )) {
                ForEach(FITSRenderParams.StretchMode.allCases) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: Volume

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Volume").font(.subheadline.weight(.semibold))

            Picker("Mode", selection: $model.mip) {
                Text("Emission").tag(false)
                Text("Max Intensity").tag(true)
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
            Label("Export Figure…", systemImage: "square.and.arrow.up")
        }
    }
    #endif

    // MARK: Helpers

    @ViewBuilder
    private func labeledSlider(_ title: LocalizedStringKey, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func infoRow(_ key: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(key).font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func fmt(_ v: Float) -> String { String(format: "%.3g", v) }

    // Slice-affecting bindings re-render the slice (coalesced); the volume reads
    // these live via updateNSView, so no extra plumbing there.
    private var windowLoBinding: Binding<Float> {
        Binding(get: { model.windowLo }, set: { model.windowLo = min($0, model.windowHi - 0.01); model.requestSliceRender() })
    }
    private var windowHiBinding: Binding<Float> {
        Binding(get: { model.windowHi }, set: { model.windowHi = max($0, model.windowLo + 0.01); model.requestSliceRender() })
    }
}

#if os(macOS)
/// Export typography + theme. Light "journal" theme by default — publication-ready.
struct CubeExportStyle: Equatable {
    enum Theme: String, CaseIterable, Identifiable {
        case light, dark
        var id: String { rawValue }
        var background: Color { self == .dark ? Color(white: 0.05) : .white }
        /// `background` as the linear RGBA the Metal snapshot expects — defined
        /// here so the SwiftUI plate and the GPU background can't drift apart.
        var backgroundRGBA: SIMD4<Float> { self == .dark ? SIMD4(0.05, 0.05, 0.05, 1) : SIMD4(1, 1, 1, 1) }
        var foreground: Color { self == .dark ? .white : Color(white: 0.08) }
        var secondary: Color { self == .dark ? Color(white: 0.62) : Color(white: 0.42) }
        var line: Color { self == .dark ? Color(white: 0.30) : Color(white: 0.78) }
    }
    enum FontKind: String, CaseIterable, Identifiable {
        case sans, mono, serif
        var id: String { rawValue }
        var design: Font.Design { self == .mono ? .monospaced : (self == .serif ? .serif : .default) }
    }
    /// Text/accent color for the header + legend. (Axis captions stay light so
    /// they remain legible over the dark volume render.)
    enum TextColor: String, CaseIterable, Identifiable {
        case auto, white, black, cyan, amber
        var id: String { rawValue }
        func main(_ theme: Theme) -> Color {
            switch self {
            case .auto: return theme.foreground
            case .white: return .white
            case .black: return Color(white: 0.08)
            case .cyan: return Color(red: 0.25, green: 0.70, blue: 0.95)
            case .amber: return Color(red: 0.95, green: 0.60, blue: 0.15)
            }
        }
        func secondary(_ theme: Theme) -> Color {
            self == .auto ? theme.secondary : main(theme).opacity(0.65)
        }
    }
    var theme: Theme = .light
    var font: FontKind = .sans
    var scale: Double = 1.0
    var annotate = true
    var transparent = false
    var textColor: TextColor = .auto
    /// Draw the cube's marks on the figure.
    var marks = true

    /// Where the sheet keeps each choice; the agent's exports read them too.
    enum Key {
        static let theme = "cubeExport.theme"
        static let font = "cubeExport.font"
        static let scale = "cubeExport.scale"
        static let annotate = "cubeExport.annotate"
        static let transparent = "cubeExport.transparent"
        static let textColor = "cubeExport.textColor"
        static let marks = "cubeExport.marks"
    }

    /// The style last set in the Export Figure sheet.
    static func stored(_ defaults: UserDefaults = .standard) -> CubeExportStyle {
        CubeExportStyle(
            theme: Theme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .light,
            font: FontKind(rawValue: defaults.string(forKey: Key.font) ?? "") ?? .sans,
            scale: defaults.object(forKey: Key.scale) as? Double ?? 1.0,
            annotate: defaults.object(forKey: Key.annotate) as? Bool ?? true,
            transparent: defaults.object(forKey: Key.transparent) as? Bool ?? false,
            textColor: TextColor(rawValue: defaults.string(forKey: Key.textColor) ?? "") ?? .auto,
            marks: defaults.object(forKey: Key.marks) as? Bool ?? true)
    }
}

/// Export sheet — style controls, a live preview, and PNG/PDF output.
struct CubeExportView: View {
    let model: CubeViewerModel
    /// The cube's marks, drawn on the figure.
    var marks: [Mark] = []
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CubeExportStyle.Key.theme) private var themeRaw = CubeExportStyle.Theme.light.rawValue
    @AppStorage(CubeExportStyle.Key.font) private var fontRaw = CubeExportStyle.FontKind.sans.rawValue
    @AppStorage(CubeExportStyle.Key.scale) private var scale = 1.0
    @AppStorage(CubeExportStyle.Key.annotate) private var annotate = true
    @AppStorage(CubeExportStyle.Key.transparent) private var transparent = false
    @AppStorage(CubeExportStyle.Key.textColor) private var textColorRaw = CubeExportStyle.TextColor.auto.rawValue
    @AppStorage(CubeExportStyle.Key.marks) private var showMarks = true
    @State private var content: CGImage?
    @State private var previewImage: NSImage?
    /// The last save's outcome.
    @State private var message: String?

    private var style: CubeExportStyle {
        CubeExportStyle(theme: CubeExportStyle.Theme(rawValue: themeRaw) ?? .light,
                        font: CubeExportStyle.FontKind(rawValue: fontRaw) ?? .sans,
                        scale: scale, annotate: annotate, transparent: transparent,
                        textColor: CubeExportStyle.TextColor(rawValue: textColorRaw) ?? .auto,
                        marks: showMarks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            Picker("Text color", selection: $textColorRaw) {
                Text("Auto").tag(CubeExportStyle.TextColor.auto.rawValue)
                Text("White").tag(CubeExportStyle.TextColor.white.rawValue)
                Text("Black").tag(CubeExportStyle.TextColor.black.rawValue)
                Text("Cyan").tag(CubeExportStyle.TextColor.cyan.rawValue)
                Text("Amber").tag(CubeExportStyle.TextColor.amber.rawValue)
            }.pickerStyle(.segmented)
            HStack {
                Text("Text scale").font(.callout)
                Slider(value: $scale, in: 0.75...1.5)
                Text(String(format: "%.2f×", scale)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Toggle("Annotations (header + legend)", isOn: $annotate)
            Toggle("Marks", isOn: $showMarks)
                .disabled(marks.isEmpty)
            Toggle("Transparent background", isOn: $transparent)

            HStack(spacing: 10) {
                Button("PNG 2×") { save(.png, scale: 2) }
                Button("PNG 4×") { save(.png, scale: 4) }
                Button("PDF…") { save(.pdf, scale: 1) }
                Spacer()
            }
            .buttonStyle(.borderedProminent)
            .disabled(content == nil)

            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { content = currentContent(); rebuildPreview() }
        .onChange(of: themeRaw) { content = currentContent(); rebuildPreview() }
        .onChange(of: transparent) { content = currentContent(); rebuildPreview() }
        .onChange(of: style) { rebuildPreview() }
    }

    @ViewBuilder
    private var preview: some View {
        Group {
            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                Text("Open a cube and choose Slice or Volume to export.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .background(Color(white: 0.15))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    /// Render the plate to an image for an accurate preview (recomputed on change).
    private func rebuildPreview() {
        guard let content else { previewImage = nil; return }
        let renderer = ImageRenderer(content: CubeExportPlate.make(model: model, content: content, marks: marks, style: style))
        renderer.scale = 1
        previewImage = renderer.nsImage
    }

    private func currentContent() -> CGImage? {
        model.figureContent(style: CubeExportStyle(theme: CubeExportStyle.Theme(rawValue: themeRaw) ?? .light,
                                                   transparent: transparent))
    }

    private func save(_ format: FigureFile.Format, scale: CGFloat) {
        guard let content else { return }
        let plate = CubeExportPlate.make(model: model, content: content, marks: marks, style: style)
        switch FigureFile.save(plate, as: format, scale: scale, name: model.figureBaseName) {
        case .success(let url)?:
            message = String(localized: "Saved \(url.lastPathComponent)")
        case .failure(let error)?:
            message = String(localized: "Could not save the figure: \(error.localizedDescription)")
        case nil:
            break
        }
    }
}

extension CubeViewerModel {
    /// The picture a figure shows: the slice, or a volume snapshot on the
    /// style's background (none when transparent).
    func figureContent(style: CubeExportStyle) -> CGImage? {
        guard viewMode == .volume else { return sliceImage }
        let background: SIMD4<Float>? = style.transparent ? nil : style.theme.backgroundRGBA
        return volumeSnapshot?(CubeViewerConstants.exportWidth, CubeViewerConstants.exportHeight, background)
    }

    /// The figure file's name: the object and the channel or "volume".
    var figureBaseName: String {
        let base = (object.isEmpty || object == "—") ? "cube" : object
        return "\(base)_\(viewMode == .slice ? "ch\(channel + 1)" : "volume")"
    }
}

/// What an agent's `export_cube_figure` asks for. Style fields left out
/// are what the person last chose in the Export Figure sheet.
struct CubeFigureRequest: Codable, Sendable, Equatable {
    var scale: Double = 2
    var format: FigureFile.Format = .png
    var marks: Bool?

    init(scale: Double = 2, format: FigureFile.Format = .png, marks: Bool? = nil) {
        self.scale = scale
        self.format = format
        self.marks = marks
    }

    /// A proposal made before formats and marks held only `scale`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 2
        format = try c.decodeIfPresent(FigureFile.Format.self, forKey: .format) ?? .png
        marks = try c.decodeIfPresent(Bool.self, forKey: .marks)
    }
}

/// Headless figure export for the `export_cube_figure` agent tool — the
/// sheet's output with no sheet and no save panel, in the sheet's last
/// style. Lives in this file because `CubeExportPlate` is deliberately
/// private to it. Returns the written file URL (in ~/Downloads).
@MainActor
func exportCubeFigureHeadless(model: CubeViewerModel, request: CubeFigureRequest, marks: [Mark]) throws -> URL {
    guard model.hasData else {
        throw ToolFailureReason.targetNotResolved(
            "No cube is open in the Cube Viewer — call open_cube, then navigate_to(mode: cubeViewer).")
    }
    var style = CubeExportStyle.stored()
    if let showMarks = request.marks { style.marks = showMarks }
    guard let content = model.figureContent(style: style) else {
        throw ToolFailureReason.backendError(
            "No rendered image is available yet — call navigate_to(mode: cubeViewer) so the render lands, then retry export_cube_figure.")
    }
    let plate = CubeExportPlate.make(model: model, content: content, marks: marks, style: style)
    let dest = DownloadsFolder.timestampedURL(stem: model.figureBaseName, ext: request.format.rawValue)
    try FigureFile.write(plate, as: request.format, scale: request.scale, to: dest)
    return dest
}

/// Publication figure plate: header (title / instrument / file / date), the
/// rendered image, and a legend (colorbar + WCS ranges + dimensions + NaN + mode).
private struct CubeExportPlate: View {
    let model: CubeViewerModel
    let metadata: CubeFigureMetadata
    let date: String
    let content: CGImage
    let stops: [Color]
    let style: CubeExportStyle
    let showAxes: Bool
    let marks: [Mark]

    @MainActor
    static func make(model: CubeViewerModel, content: CGImage, marks: [Mark], style: CubeExportStyle) -> CubeExportPlate {
        CubeExportPlate(model: model, metadata: model.figureMetadata(),
                        date: Date.now.formatted(date: .abbreviated, time: .shortened),
                        content: content, stops: colormapPreviewStops(model.colormap), style: style,
                        showAxes: model.viewMode == .volume, marks: marks)
    }

    var body: some View {
        VStack(spacing: 0) {
            if style.annotate {
                header.padding(16)
                Rectangle().fill(style.theme.line).frame(height: 1)
            }
            Image(decorative: content, scale: 1)
                .resizable()
                .scaledToFit()
                .overlay { if showAxes { CubeAxisCaptions(model: model, distanceScale: CubeViewerConstants.exportDistanceScale) } }
                .overlay {
                    if style.marks, !marks.isEmpty {
                        GeometryReader { geo in
                            if let projection = model.figureMarkProjection(size: geo.size) {
                                MarkOverlay(marks: marks, selectedID: nil, projection: projection, showsGrips: false)
                            }
                        }
                    }
                }
                .padding(style.annotate ? 14 : 0)
            if style.annotate {
                Rectangle().fill(style.theme.line).frame(height: 1)
                footer.padding(16)
            }
        }
        .frame(width: 1000)
        .background(style.transparent ? Color.clear : style.theme.background)
        .foregroundStyle(style.textColor.main(style.theme))
        .font(.system(size: 13 * style.scale, design: style.font.design))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(metadata.title).font(.system(size: 22 * style.scale, weight: .bold, design: style.font.design))
                if !metadata.instrument.isEmpty {
                    Text(metadata.instrument).foregroundStyle(style.textColor.secondary(style.theme))
                }
                Text("\(metadata.channelLabel)   \(metadata.spectral)").foregroundStyle(style.textColor.secondary(style.theme))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if !metadata.fileName.isEmpty { Text(metadata.fileName).foregroundStyle(style.textColor.secondary(style.theme)) }
                Text(date).foregroundStyle(style.textColor.secondary(style.theme))
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
                if !metadata.unit.isEmpty { Text(metadata.unit).foregroundStyle(style.textColor.secondary(style.theme)) }
                Text("· \(metadata.stretch) · \(metadata.colormap)").foregroundStyle(style.textColor.secondary(style.theme))
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
            Text(key).foregroundStyle(style.textColor.secondary(style.theme))
            Text(value)
        }
    }
}
#endif
