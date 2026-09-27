// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI
import VerbinalKit

/// Export typography + theme for the FITS figure exporter. Mirrors the
/// Cube Viewer's `CubeExportStyle` but stays self-contained: the Cube
/// module is macOS-only *and* excluded from the iOS target as a unit, so
/// the FITS viewer cannot reach into it.
struct FITSExportStyle: Equatable {
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
    /// Draw the image's marks on the figure.
    var marks = true

    /// Where the sheet keeps each choice; the agent's exports read them too.
    enum Key {
        static let theme = "fitsExport.theme"
        static let font = "fitsExport.font"
        static let scale = "fitsExport.scale"
        static let annotate = "fitsExport.annotate"
        static let transparent = "fitsExport.transparent"
        static let textColor = "fitsExport.textColor"
        static let marks = "fitsExport.marks"
    }

    /// The style last set in the Export Figure sheet.
    static func stored(_ defaults: UserDefaults = .standard) -> FITSExportStyle {
        FITSExportStyle(
            theme: Theme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .light,
            font: FontKind(rawValue: defaults.string(forKey: Key.font) ?? "") ?? .sans,
            scale: defaults.object(forKey: Key.scale) as? Double ?? 1.0,
            annotate: defaults.object(forKey: Key.annotate) as? Bool ?? true,
            transparent: defaults.object(forKey: Key.transparent) as? Bool ?? false,
            textColor: TextColor(rawValue: defaults.string(forKey: Key.textColor) ?? "") ?? .auto,
            marks: defaults.object(forKey: Key.marks) as? Bool ?? true)
    }
}

/// Export sheet — region, style controls, a live preview, and PNG/PDF
/// output. The FITS twin of `CubeExportView` (same layout, same
/// persisted-style idiom, `fitsExport.*` keys).
struct FITSExportView: View {
    let model: FITSViewerModel
    /// The image's marks, drawn on the figure.
    var marks: [Mark] = []
    /// The region the sheet opens on.
    var initialRegion: FITSFigureRegion = .image
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FITSExportStyle.Key.theme) private var themeRaw = FITSExportStyle.Theme.light.rawValue
    @AppStorage(FITSExportStyle.Key.font) private var fontRaw = FITSExportStyle.FontKind.sans.rawValue
    @AppStorage(FITSExportStyle.Key.scale) private var scale = 1.0
    @AppStorage(FITSExportStyle.Key.annotate) private var annotate = true
    @AppStorage(FITSExportStyle.Key.transparent) private var transparent = false
    @AppStorage(FITSExportStyle.Key.textColor) private var textColorRaw = FITSExportStyle.TextColor.auto.rawValue
    @AppStorage(FITSExportStyle.Key.marks) private var showMarks = true
    @State private var region: FITSFigureRegion = .image
    @State private var previewImage: NSImage?
    /// Why the figure cannot be made, or the last save's outcome.
    @State private var message: String?

    private var style: FITSExportStyle {
        FITSExportStyle(theme: FITSExportStyle.Theme(rawValue: themeRaw) ?? .light,
                        font: FITSExportStyle.FontKind(rawValue: fontRaw) ?? .sans,
                        scale: scale, annotate: annotate, transparent: transparent,
                        textColor: FITSExportStyle.TextColor(rawValue: textColorRaw) ?? .auto,
                        marks: showMarks)
    }

    /// The figure of the chosen region, or why there is none.
    private var figure: Result<FITSFigure, FITSFigureProblem> {
        Result { () throws(FITSFigureProblem) in try model.figure(region, marks: marks) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Export Figure").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }

            preview

            Picker("Region", selection: $region) {
                Text("Whole image").tag(FITSFigureRegion.image)
                Text("View on screen").tag(FITSFigureRegion.view)
                if case .mark(let id) = initialRegion, let mark = marks.first(where: { $0.id == id }) {
                    Text("Around \(MarkSummary.title(mark))").tag(initialRegion)
                }
            }
            Picker("Theme", selection: $themeRaw) {
                Text("Journal light").tag(FITSExportStyle.Theme.light.rawValue)
                Text("Cockpit dark").tag(FITSExportStyle.Theme.dark.rawValue)
            }.pickerStyle(.segmented)
            Picker("Font", selection: $fontRaw) {
                Text("Sans").tag(FITSExportStyle.FontKind.sans.rawValue)
                Text("Mono").tag(FITSExportStyle.FontKind.mono.rawValue)
                Text("Serif").tag(FITSExportStyle.FontKind.serif.rawValue)
            }.pickerStyle(.segmented)
            Picker("Text color", selection: $textColorRaw) {
                Text("Auto").tag(FITSExportStyle.TextColor.auto.rawValue)
                Text("White").tag(FITSExportStyle.TextColor.white.rawValue)
                Text("Black").tag(FITSExportStyle.TextColor.black.rawValue)
                Text("Cyan").tag(FITSExportStyle.TextColor.cyan.rawValue)
                Text("Amber").tag(FITSExportStyle.TextColor.amber.rawValue)
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
            .disabled(previewImage == nil)

            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { region = initialRegion; rebuildPreview() }
        .onChange(of: style) { rebuildPreview() }
        .onChange(of: region) { rebuildPreview() }
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
                Text("Open a FITS image to export.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .background(Color(white: 0.15))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    private func rebuildPreview() {
        switch figure {
        case .success(let figure):
            message = nil
            let renderer = ImageRenderer(content: FITSExportPlate.make(model: model, figure: figure, style: style))
            renderer.scale = 1
            previewImage = renderer.nsImage
        case .failure(let problem):
            previewImage = nil
            message = problem.message
        }
    }

    private func save(_ format: FigureFile.Format, scale: CGFloat) {
        guard case .success(let figure) = figure else { return }
        let plate = FITSExportPlate.make(model: model, figure: figure, style: style)
        switch FigureFile.save(plate, as: format, scale: scale, name: FITSExportPlate.baseName(for: model)) {
        case .success(let url)?:
            message = String(localized: "Saved \(url.lastPathComponent)")
        case .failure(let error)?:
            message = String(localized: "Could not save the figure: \(error.localizedDescription)")
        case nil:
            break
        }
    }
}

/// Headless figure export for the `export_fits_figure` agent tool — the
/// sheet's output with no sheet and no save panel, in the sheet's last
/// style unless the request says otherwise. Returns the file written (in
/// ~/Downloads).
@MainActor
func exportFITSFigureHeadless(model: FITSViewerModel, request: FITSFigureRequest, marks: [Mark]) throws -> URL {
    let figure = try model.figure(request.region, marks: marks)
    var style = FITSExportStyle.stored()
    if let showMarks = request.marks { style.marks = showMarks }
    if let annotate = request.annotate { style.annotate = annotate }
    if let dark = request.dark { style.theme = dark ? .dark : .light }
    let plate = FITSExportPlate.make(model: model, figure: figure, style: style)
    let dest = FileHelper.timestampedDownloadsURL(stem: FITSExportPlate.baseName(for: model), ext: request.format.rawValue)
    try FigureFile.write(plate, as: request.format, scale: request.scale, to: dest)
    return dest
}

/// Publication figure plate: header (object / instrument / file / date),
/// the rendered image, and a legend (colorbar + stretch + cuts + WCS +
/// dimensions).
private struct FITSExportPlate: View {
    let title: String
    let subtitle: String
    let fileName: String
    let date: String
    let figure: FITSFigure
    let stops: [Color]
    let style: FITSExportStyle

    /// Assemble the plate from the live model (main-actor reads happen
    /// here, once, so the View itself stays a value snapshot).
    @MainActor
    static func make(model: FITSViewerModel, figure: FITSFigure, style: FITSExportStyle) -> FITSExportPlate {
        let header = model.selectedHDU?.header
        let object = header?.string("OBJECT") ?? ""
        let telescope = header?.string("TELESCOP") ?? ""
        let instrument = header?.string("INSTRUME") ?? ""
        let dateObs = header?.string("DATE-OBS") ?? ""
        let subtitleParts = [telescope, instrument, dateObs].filter { !$0.isEmpty }

        return FITSExportPlate(
            title: object.isEmpty ? (model.fileURL?.deletingPathExtension().lastPathComponent ?? "FITS image") : object,
            subtitle: subtitleParts.joined(separator: " · "),
            fileName: model.fileURL?.lastPathComponent ?? "",
            date: Date.now.formatted(date: .abbreviated, time: .shortened),
            figure: figure,
            stops: colormapPreviewStops(model.renderParams.colormap),
            style: style)
    }

    @MainActor
    static func baseName(for model: FITSViewerModel) -> String {
        let object = model.selectedHDU?.header.string("OBJECT") ?? ""
        if !object.isEmpty {
            return object.replacingOccurrences(of: " ", with: "_")
        }
        return model.fileURL?.deletingPathExtension().lastPathComponent ?? "fits_figure"
    }

    var body: some View {
        VStack(spacing: 0) {
            if style.annotate {
                headerView.padding(16)
                Rectangle().fill(style.theme.line).frame(height: 1)
            }
            Image(decorative: figure.content, scale: 1)
                .resizable()
                .scaledToFit()
                .overlay {
                    if style.marks, !figure.marks.isEmpty {
                        GeometryReader { geo in
                            if let projection = figure.markProjection(width: geo.size.width) {
                                MarkOverlay(marks: figure.marks, selectedID: nil, projection: projection, showsGrips: false)
                            }
                        }
                    }
                }
                .padding(style.annotate ? 14 : 0)
            if style.annotate {
                Rectangle().fill(style.theme.line).frame(height: 1)
                footerView.padding(16)
            }
        }
        .frame(width: 760)
        .background(style.transparent ? Color.clear : style.theme.background)
        .fontDesign(style.font.design)
    }

    private var headerView: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17 * style.scale, weight: .semibold))
                    .foregroundStyle(style.textColor.main(style.theme))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11 * style.scale))
                        .foregroundStyle(style.textColor.secondary(style.theme))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if !fileName.isEmpty {
                    Text(fileName)
                        .font(.system(size: 10 * style.scale, design: .monospaced))
                        .foregroundStyle(style.textColor.secondary(style.theme))
                }
                Text(date)
                    .font(.system(size: 10 * style.scale))
                    .foregroundStyle(style.textColor.secondary(style.theme))
            }
        }
    }

    private var footerView: some View {
        HStack(alignment: .center, spacing: 16) {
            LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
                .frame(width: 120, height: 10)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(style.theme.line))
            ForEach(figure.legend, id: \.0) { entry in
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.0)
                        .font(.system(size: 8.5 * style.scale, weight: .medium))
                        .foregroundStyle(style.textColor.secondary(style.theme))
                    Text(entry.1)
                        .font(.system(size: 10 * style.scale, design: .monospaced))
                        .foregroundStyle(style.textColor.main(style.theme))
                }
            }
            Spacer()
        }
    }
}
#endif
