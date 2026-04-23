// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Writes the currently-visible search results (filter + sort + visible columns
/// applied, pagination ignored) to disk as CSV or TSV.
///
/// Complements the server-side URL export in ``SearchResultsModel/exportURL(format:)``:
/// the server export returns the full raw TAP result; this exporter honours the
/// user's client-side adjustments so what they see is what they get.
enum ClientExporter {

    enum Format {
        case csv
        case tsv

        var delimiter: Character { self == .csv ? "," : "\t" }
        var pathExtension: String { self == .csv ? "csv" : "tsv" }
        var mimeType: String { self == .csv ? "text/csv" : "text/tab-separated-values" }
    }

    /// Write rows + visible columns to `url` atomically. Uses RFC 4180 quoting
    /// for CSV (always quote, escape `"` as `""`) and a simple
    /// tab-separated encoding for TSV (tabs in values are replaced with spaces,
    /// newlines are replaced with spaces — TSV has no universal escape).
    static func write(
        rows: [SearchResult],
        columns: SearchResultColumns,
        format: Format,
        to url: URL
    ) throws {
        let visible = columns.visible
        guard !visible.isEmpty else {
            throw ExportError.noVisibleColumns
        }

        var data = Data()
        data.reserveCapacity(max(1024, rows.count * visible.count * 16))

        // Header row
        let headerLine = visible
            .map { encode($0.label, format: format) }
            .joined(separator: String(format.delimiter))
        data.append(Data(headerLine.utf8))
        data.append(0x0A) // LF

        // Data rows
        for row in rows {
            let line = visible
                .map { col -> String in
                    let raw = columns.value(in: row, forID: col.id)
                    return encode(raw, format: format)
                }
                .joined(separator: String(format.delimiter))
            data.append(Data(line.utf8))
            data.append(0x0A)
        }

        try data.write(to: url, options: [.atomic])
    }

    /// Encode a single field per the format's rules.
    static func encode(_ value: String, format: Format) -> String {
        switch format {
        case .csv:
            // RFC 4180: quote all fields, escape internal quotes.
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        case .tsv:
            // TSV has no standard escape; normalize tabs and newlines to spaces.
            return value
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
    }

    enum ExportError: LocalizedError {
        case noVisibleColumns

        var errorDescription: String? {
            switch self {
            case .noVisibleColumns:
                return String(localized: "No visible columns to export.")
            }
        }
    }
}
