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
}

/// Export sheet — style controls, a live preview, and PNG/PDF output.
/// The FITS twin of `CubeExportView` (same layout, same persisted-style
/// idiom, `fitsExport.*` keys).
struct FITSExportView: View {
    let model: FITSViewerModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fitsExport.theme") private var themeRaw = FITSExportStyle.Theme.light.rawValue
    @AppStorage("fitsExport.font") private var fontRaw = FITSExportStyle.FontKind.sans.rawValue
    @AppStorage("fitsExport.scale") private var scale = 1.0
    @AppStorage("fitsExport.annotate") private var annotate = true
    @AppStorage("fitsExport.transparent") private var transparent = false
    @AppStorage("fitsExport.textColor") private var textColorRaw = FITSExportStyle.TextColor.auto.rawValue
    @State private var content: CGImage?
    @State private var previewImage: NSImage?

    private var style: FITSExportStyle {
        FITSExportStyle(theme: FITSExportStyle.Theme(rawValue: themeRaw) ?? .light,
                        font: FITSExportStyle.FontKind(rawValue: fontRaw) ?? .sans,
                        scale: scale, annotate: annotate, transparent: transparent,
                        textColor: FITSExportStyle.TextColor(rawValue: textColorRaw) ?? .auto)
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
        .onAppear { content = model.renderedImage; rebuildPreview() }
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
        guard let content else { previewImage = nil; return }
        let renderer = ImageRenderer(content: FITSExportPlate.make(model: model, content: content, style: style))
        renderer.scale = 1
        previewImage = renderer.nsImage
    }

    private func exportPNG(_ factor: CGFloat) {
        guard let content else { return }
        let renderer = ImageRenderer(content: FITSExportPlate.make(model: model, content: content, style: style))
        renderer.scale = factor
        guard let nsImage = renderer.nsImage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(FITSExportPlate.baseName(for: model)).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let tiff = nsImage.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    private func exportPDF() {
        guard let content else { return }
        let renderer = ImageRenderer(content: FITSExportPlate.make(model: model, content: content, style: style))
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(FITSExportPlate.baseName(for: model)).pdf"
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

/// Headless figure export for the `export_fits_figure` agent tool — the
/// PNG happy path of `FITSExportView` with no sheet and no save panel.
/// Reuses the sheet's persisted style defaults (same `fitsExport.*`
/// keys) so agent exports match what the user last configured.
/// Returns the written file URL (in ~/Downloads).
@MainActor
func exportFITSFigureHeadless(model: FITSViewerModel, scale: CGFloat) throws -> URL {
    guard let content = model.renderedImage else {
        throw ToolFailureReason.targetNotResolved("No rendered FITS image is open in the viewer")
    }
    let d = UserDefaults.standard
    let style = FITSExportStyle(
        theme: FITSExportStyle.Theme(rawValue: d.string(forKey: "fitsExport.theme") ?? "") ?? .light,
        font: FITSExportStyle.FontKind(rawValue: d.string(forKey: "fitsExport.font") ?? "") ?? .sans,
        scale: d.object(forKey: "fitsExport.scale") as? Double ?? 1.0,
        annotate: d.object(forKey: "fitsExport.annotate") as? Bool ?? true,
        transparent: d.object(forKey: "fitsExport.transparent") as? Bool ?? false,
        textColor: FITSExportStyle.TextColor(rawValue: d.string(forKey: "fitsExport.textColor") ?? "") ?? .auto)

    let renderer = ImageRenderer(content: FITSExportPlate.make(model: model, content: content, style: style))
    renderer.scale = scale
    guard let nsImage = renderer.nsImage,
          let tiff = nsImage.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw ToolFailureReason.backendError("Figure rendering failed")
    }

    let dest = FileHelper.timestampedDownloadsURL(
        stem: FITSExportPlate.baseName(for: model), ext: "png")
    try data.write(to: dest)
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
    let content: CGImage
    let stops: [Color]
    let style: FITSExportStyle
    let legend: [(String, String)]

    /// Assemble the plate from the live model (main-actor reads happen
    /// here, once, so the View itself stays a value snapshot).
    @MainActor
    static func make(model: FITSViewerModel, content: CGImage, style: FITSExportStyle) -> FITSExportPlate {
        let header = model.selectedHDU?.header
        let object = header?.string("OBJECT") ?? ""
        let telescope = header?.string("TELESCOP") ?? ""
        let instrument = header?.string("INSTRUME") ?? ""
        let dateObs = header?.string("DATE-OBS") ?? ""
        let subtitleParts = [telescope, instrument, dateObs].filter { !$0.isEmpty }

        var legend: [(String, String)] = []
        legend.append(("Stretch", model.renderParams.stretch.rawValue))
        legend.append(("Cuts", String(format: "%.4g – %.4g",
                                      model.renderParams.minCut, model.renderParams.maxCut)))
        if let header {
            legend.append(("Size", "\(header.naxis1) × \(header.naxis2) px"))
        }
        if let wcs = model.wcs {
            legend.append(("Center", "\(FITSWCSTransform.formatRA(wcs.crval1)) \(FITSWCSTransform.formatDec(wcs.crval2))"))
            legend.append(("Scale", String(format: "%.3g″/px", wcs.pixelScaleArcsec)))
        }

        return FITSExportPlate(
            title: object.isEmpty ? (model.fileURL?.deletingPathExtension().lastPathComponent ?? "FITS image") : object,
            subtitle: subtitleParts.joined(separator: " · "),
            fileName: model.fileURL?.lastPathComponent ?? "",
            date: Date.now.formatted(date: .abbreviated, time: .shortened),
            content: content,
            stops: colormapPreviewStops(model.renderParams.colormap),
            style: style,
            legend: legend)
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
            Image(decorative: content, scale: 1)
                .resizable()
                .scaledToFit()
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
            ForEach(legend, id: \.0) { entry in
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
