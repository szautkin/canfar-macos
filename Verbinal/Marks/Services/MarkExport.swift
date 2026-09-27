// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Marks as a DS9 region file or as JSON with where they came from.
enum MarkExport {

    enum Format: String, CaseIterable, Sendable {
        case ds9, json

        var fileExtension: String { self == .ds9 ? "reg" : "json" }
    }

    /// A DS9 region file. Sky marks go out in fk5 (degrees; sizes in
    /// arcseconds), pixel marks in image coordinates — DS9's are 1-based,
    /// so the 0-based array pixel gains one.
    static func ds9(_ marks: [Mark]) -> String {
        var lines = ["# Region file format: DS9 version 4.1",
                     "global color=green width=1 font=\"helvetica 10 normal roman\""]
        let sky = marks.filter { $0.anchor.space == .sky }
        let pixel = marks.filter { $0.anchor.space != .sky }
        if !sky.isEmpty {
            lines.append("fk5")
            lines += sky.map { region($0, x: $0.anchor.x, y: $0.anchor.y, size: 3600, unit: "\"") }
        }
        if !pixel.isEmpty {
            lines.append("image")
            lines += pixel.map { region($0, x: $0.anchor.x + 1, y: $0.anchor.y + 1, size: 1, unit: "") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One extension's marks (no `hdu` for a file without extensions).
    struct Extension: Encodable, Sendable {
        let hdu: Int?
        let marks: [Mark]
    }

    /// The marks of a file's extensions, each with its extension, and when.
    static func json(_ extensions: [Extension], file: String, exportedAt: Date = Date()) throws -> Data {
        struct Envelope: Encodable {
            let format = "verbinal-marks"
            let version = 1
            let file: String
            let exportedAt: Date
            let extensions: [Extension]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Envelope(file: file, exportedAt: exportedAt, extensions: extensions))
    }

    private static func region(_ mark: Mark, x: Double, y: Double, size scale: Double, unit: String) -> String {
        func n(_ v: Double) -> String { String(format: "%.7g", v) }
        let style = mark.effectiveStyle
        var props = "color=\(style.colour) width=\(Int(style.stroke.rounded()))"
        let label = mark.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
        if !label.isEmpty { props += " text={\(label)}" }

        guard let extent = mark.extent else {
            return mark.kind == .text
                ? "text(\(n(x)),\(n(y))) # \(props)"
                : "point(\(n(x)),\(n(y))) # point=circle \(props)"
        }
        let a = extent.halfWidth * scale, b = extent.halfHeight * scale
        switch mark.kind {
        case .rect:
            return "box(\(n(x)),\(n(y)),\(n(2 * a))\(unit),\(n(2 * b))\(unit),0) # \(props)"
        case .circle, .callout, .text:
            return a == b
                ? "circle(\(n(x)),\(n(y)),\(n(a))\(unit)) # \(props)"
                : "ellipse(\(n(x)),\(n(y)),\(n(a))\(unit),\(n(b))\(unit),0) # \(props)"
        }
    }
}
