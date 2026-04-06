// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Root of a Jupyter .ipynb file (nbformat 4.x).
struct NotebookDocument: Codable {
    var nbformat: Int = 4
    var nbformatMinor: Int = 5
    var metadata: NotebookDocMetadata = NotebookDocMetadata()
    var cells: [NotebookCellData] = []

    enum CodingKeys: String, CodingKey {
        case nbformat
        case nbformatMinor = "nbformat_minor"
        case metadata
        case cells
    }
}

struct NotebookDocMetadata: Codable {
    var kernelspec: KernelSpec?
    var languageInfo: LanguageInfo?

    enum CodingKeys: String, CodingKey {
        case kernelspec
        case languageInfo = "language_info"
    }
}

struct KernelSpec: Codable {
    var name: String = "python3"
    var displayName: String = "Python 3"
    var language: String = "python"

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case language
    }
}

struct LanguageInfo: Codable {
    var name: String = "python"
    var version: String = ""
    var mimetype: String?
    var fileExtension: String?

    enum CodingKeys: String, CodingKey {
        case name, version, mimetype
        case fileExtension = "file_extension"
    }
}

/// A single cell in nbformat 4.x JSON.
struct NotebookCellData: Codable {
    var cellType: String = "code"
    var source: [String] = []
    var metadata: CellMeta = CellMeta()
    var outputs: [CellOutputData]?
    var executionCount: Int?
    var id: String?

    enum CodingKeys: String, CodingKey {
        case cellType = "cell_type"
        case source, metadata, outputs
        case executionCount = "execution_count"
        case id
    }

    /// Join source lines into single string.
    var sourceText: String {
        get { source.joined() }
        set { source = NotebookParser.splitSourceLines(newValue) }
    }
}

struct CellMeta: Codable {
    var collapsed: Bool?
    var tags: [String]?
}

/// Cell output data (stream, execute_result, display_data, error).
struct CellOutputData: Codable {
    var outputType: String
    var name: String?
    var text: StringOrArray?
    var data: [String: StringOrArray]?
    var executionCount: Int?
    var ename: String?
    var evalue: String?
    var traceback: [String]?

    enum CodingKeys: String, CodingKey {
        case outputType = "output_type"
        case name, text, data
        case executionCount = "execution_count"
        case ename, evalue, traceback
    }
}

/// Handles both `"string"` and `["line1", "line2"]` in .ipynb JSON.
enum StringOrArray: Codable {
    case string(String)
    case array([String])

    var text: String {
        switch self {
        case .string(let s): return s
        case .array(let a): return a.joined()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([String].self) {
            self = .array(a)
        } else {
            self = .string("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        }
    }
}
