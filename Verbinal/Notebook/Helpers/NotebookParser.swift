// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Pure .ipynb JSON parser/serializer. No side effects.
enum NotebookParser {

    /// Parse .ipynb JSON data into a NotebookDocument.
    static func parse(_ data: Data) throws -> NotebookDocument {
        let decoder = JSONDecoder()
        var doc = try decoder.decode(NotebookDocument.self, from: data)
        normalizeCells(&doc)
        return doc
    }

    /// Serialize a NotebookDocument to .ipynb JSON data.
    static func serialize(_ doc: NotebookDocument) throws -> Data {
        var doc = doc
        enforceOutputRules(&doc)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)
        guard var json = String(data: data, encoding: .utf8) else { return data }
        json = normalizeWhitespace(json)
        return Data(json.utf8)
    }

    /// Create an empty notebook with one code cell.
    static func createEmpty() -> NotebookDocument {
        NotebookDocument(
            metadata: NotebookDocMetadata(
                kernelspec: KernelSpec(),
                languageInfo: LanguageInfo(name: "python", version: "3")
            ),
            cells: [
                NotebookCellData(cellType: "code", id: generateCellId())
            ]
        )
    }

    /// Generate an 8-character hex cell ID (Jupyter convention).
    static func generateCellId() -> String {
        let bytes = (0..<4).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Split text into nbformat source lines (each ending with \n except last).
    static func splitSourceLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines: [String] = []
        var start = text.startIndex
        for i in text.indices {
            if text[i] == "\n" {
                lines.append(String(text[start...i]))
                start = text.index(after: i)
            }
        }
        if start < text.endIndex {
            lines.append(String(text[start...]))
        }
        return lines
    }

    /// Load a .py file as a single-cell code notebook.
    static func fromPythonFile(_ data: Data) -> NotebookDocument {
        let source = String(data: data, encoding: .utf8) ?? ""
        var doc = createEmpty()
        doc.cells = [NotebookCellData(cellType: "code", source: splitSourceLines(source), id: generateCellId())]
        return doc
    }

    /// Load a .md file as a single-cell markdown notebook.
    static func fromMarkdownFile(_ data: Data) -> NotebookDocument {
        let source = String(data: data, encoding: .utf8) ?? ""
        var doc = createEmpty()
        doc.cells = [NotebookCellData(cellType: "markdown", source: splitSourceLines(source), id: generateCellId())]
        return doc
    }

    // MARK: - Private

    private static func normalizeCells(_ doc: inout NotebookDocument) {
        for i in doc.cells.indices {
            if doc.cells[i].id == nil || doc.cells[i].id!.isEmpty {
                doc.cells[i].id = generateCellId()
            }
            if doc.cells[i].cellType == "code" && doc.cells[i].outputs == nil {
                doc.cells[i].outputs = []
            }
        }
    }

    private static func enforceOutputRules(_ doc: inout NotebookDocument) {
        for i in doc.cells.indices {
            if doc.cells[i].cellType == "markdown" {
                doc.cells[i].outputs = nil
                doc.cells[i].executionCount = nil
            }
        }
    }

    private static func normalizeWhitespace(_ json: String) -> String {
        // Convert 2-space indent to 1-space (Jupyter convention)
        let lines = json.split(separator: "\n", omittingEmptySubsequences: false)
        let normalized = lines.map { line -> String in
            var spaces = 0
            for char in line {
                if char == " " { spaces += 1 } else { break }
            }
            if spaces >= 2 {
                return String(repeating: " ", count: spaces / 2) + line.dropFirst(spaces)
            }
            return String(line)
        }
        var result = normalized.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }
}
