// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import AppKit
import SwiftUI
import VerbinalKit

/// Writing a figure plate (a SwiftUI view) to PNG or PDF — the one place
/// the viewers' figure exporters do it. A write that fails says so.
enum FigureFile {
    enum Format: String, Codable, Sendable, CaseIterable {
        case png, pdf
    }

    /// PNG bytes of `view` at `scale`× its size; nil if it could not be drawn.
    @MainActor
    static func png<V: View>(_ view: V, scale: CGFloat) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Writes `view` to `url`: a PNG at `scale`×, or a one-page vector PDF —
    /// recorded as a change, whoever exports it (plan 23 C).
    @MainActor
    static func write<V: View>(_ view: V, as format: Format, scale: CGFloat, to url: URL,
                               changes: ChangeLog = .shared) throws {
        let what = "a figure to \(url.lastPathComponent)"
        do {
            try render(view, as: format, scale: scale, to: url)
            changes.done("export_figure", what)
        } catch {
            changes.failed("export_figure", what, because: error.localizedDescription)
            throw error
        }
    }

    @MainActor
    private static func render<V: View>(_ view: V, as format: Format, scale: CGFloat, to url: URL) throws {
        switch format {
        case .png:
            guard let data = png(view, scale: scale) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        case .pdf:
            var written = false
            ImageRenderer(content: view).render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                guard let consumer = CGDataConsumer(url: url as CFURL),
                      let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
                context.closePDF()
                written = true
            }
            guard written else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        }
    }

    /// Asks where to save `view`, then writes it. Nil when the person
    /// cancelled; otherwise the file, or why it could not be written.
    @MainActor
    static func save<V: View>(_ view: V, as format: Format, scale: CGFloat, name: String) -> Result<URL, Error>? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .png ? .png : .pdf]
        panel.nameFieldStringValue = "\(name).\(format.rawValue)"
        guard UIPresentations.shared.runModal(panel, "Save Figure") == .OK, let url = panel.url else { return nil }
        return Result { try write(view, as: format, scale: scale, to: url); return url }
    }
}
#endif
