// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// RFC 4180 compliant CSV parser for TAP query responses.
enum CSVParser {

    /// Parse a complete CSV string into headers and rows.
    /// First line is treated as the header row.
    static func parse(_ csv: String) -> (headers: [String], rows: [[String]]) {
        let lines = splitLines(csv)
        guard let headerLine = lines.first else {
            return ([], [])
        }

        let headers = parseLine(headerLine)
        let rows = lines.dropFirst().compactMap { line -> [String]? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let fields = parseLine(line)
            guard fields.count == headers.count else { return nil }
            return fields
        }

        return (headers, rows)
    }

    /// Parse headers from the first line of CSV, cleaning up quotes and whitespace.
    static func parseHeaders(_ headerLine: String) -> [String] {
        parseLine(headerLine).map { cleanHeader($0) }
    }

    /// Clean a header string: remove quotes, dots, spaces, and lowercase.
    static func cleanHeader(_ header: String) -> String {
        header
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    // MARK: - Private

    /// Split CSV text into lines, respecting quoted fields that contain newlines.
    private static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var inQuotes = false

        for char in text {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if char == "\n" && !inQuotes {
                lines.append(current)
                current = ""
            } else if char == "\r" && !inQuotes {
                // Skip carriage return
                continue
            } else {
                current.append(char)
            }
        }

        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(current)
        }

        return lines
    }

    /// Parse a single CSV line into fields, handling quoted values.
    private static func parseLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()

        while let char = iterator.next() {
            if char == "\"" {
                if inQuotes {
                    // Check for escaped quote ""
                    if let next = iterator.next() {
                        if next == "\"" {
                            current.append("\"")
                        } else {
                            inQuotes = false
                            if next == "," {
                                fields.append(current)
                                current = ""
                            } else {
                                current.append(next)
                            }
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            } else if char == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }

        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
