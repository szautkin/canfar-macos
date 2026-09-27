// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// Saving marks to a file the person picks.
enum MarkExportPanel {

    /// Asks where and writes one extension's marks. The words for a toast,
    /// or nil when the person cancelled.
    @MainActor
    static func save(_ marks: [Mark], of file: String, hdu: Int?, as format: MarkExport.Format) -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .ds9 ? UTType(filenameExtension: "reg") ?? .plainText : .json]
        let base = (URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent)
        panel.nameFieldStringValue = "\(base)\(hdu.map { "-hdu\($0)" } ?? "")-marks.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let data: Data
            switch format {
            case .ds9: data = Data(MarkExport.ds9(marks).utf8)
            case .json: data = try MarkExport.json([MarkExport.Extension(hdu: hdu, marks: marks)], file: file)
            }
            try data.write(to: url, options: .atomic)
            return String(localized: "Saved \(marks.count) marks to \(url.lastPathComponent)")
        } catch {
            return String(localized: "Could not save the marks: \(error.localizedDescription)")
        }
    }
}
#endif
