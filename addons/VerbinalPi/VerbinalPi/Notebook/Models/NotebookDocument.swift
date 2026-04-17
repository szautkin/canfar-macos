// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Root of a Jupyter .ipynb file (nbformat 4.x).
/// All fields use decodeIfPresent to handle real-world .ipynb variations.
struct NotebookDocument: Codable {
    var nbformat: Int
    var nbformatMinor: Int
    var metadata: NotebookDocMetadata
    var cells: [NotebookCellData]

    enum CodingKeys: String, CodingKey {
        case nbformat
        case nbformatMinor = "nbformat_minor"
        case metadata
        case cells
    }

    init(nbformat: Int = 4, nbformatMinor: Int = 5,
         metadata: NotebookDocMetadata = NotebookDocMetadata(),
         cells: [NotebookCellData] = []) {
        self.nbformat = nbformat
        self.nbformatMinor = nbformatMinor
        self.metadata = metadata
        self.cells = cells
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nbformat = (try? c.decode(Int.self, forKey: .nbformat)) ?? 4
        nbformatMinor = (try? c.decode(Int.self, forKey: .nbformatMinor)) ?? 5
        metadata = (try? c.decode(NotebookDocMetadata.self, forKey: .metadata)) ?? NotebookDocMetadata()
        cells = (try? c.decode([NotebookCellData].self, forKey: .cells)) ?? []
    }
}

struct NotebookDocMetadata: Codable {
    var kernelspec: KernelSpec?
    var languageInfo: LanguageInfo?

    enum CodingKeys: String, CodingKey {
        case kernelspec
        case languageInfo = "language_info"
    }

    init(kernelspec: KernelSpec? = nil, languageInfo: LanguageInfo? = nil) {
        self.kernelspec = kernelspec
        self.languageInfo = languageInfo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kernelspec = try? c.decode(KernelSpec.self, forKey: .kernelspec)
        languageInfo = try? c.decode(LanguageInfo.self, forKey: .languageInfo)
    }
}

struct KernelSpec: Codable {
    var name: String
    var displayName: String
    var language: String

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case language
    }

    init(name: String = "python3", displayName: String = "Python 3", language: String = "python") {
        self.name = name
        self.displayName = displayName
        self.language = language
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "python3"
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? "Python 3"
        language = (try? c.decode(String.self, forKey: .language)) ?? "python"
    }
}

struct LanguageInfo: Codable {
    var name: String
    var version: String
    var mimetype: String?
    var fileExtension: String?

    enum CodingKeys: String, CodingKey {
        case name, version, mimetype
        case fileExtension = "file_extension"
    }

    init(name: String = "python", version: String = "", mimetype: String? = nil, fileExtension: String? = nil) {
        self.name = name
        self.version = version
        self.mimetype = mimetype
        self.fileExtension = fileExtension
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "python"
        version = (try? c.decode(String.self, forKey: .version)) ?? ""
        mimetype = try? c.decode(String.self, forKey: .mimetype)
        fileExtension = try? c.decode(String.self, forKey: .fileExtension)
    }
}

/// A single cell in nbformat 4.x JSON.
struct NotebookCellData: Codable {
    var cellType: String
    var source: [String]
    var metadata: CellMeta
    var outputs: [CellOutputData]?
    var executionCount: Int?
    var id: String?

    enum CodingKeys: String, CodingKey {
        case cellType = "cell_type"
        case source, metadata, outputs
        case executionCount = "execution_count"
        case id
    }

    init(cellType: String = "code", source: [String] = [], metadata: CellMeta = CellMeta(),
         outputs: [CellOutputData]? = nil, executionCount: Int? = nil, id: String? = nil) {
        self.cellType = cellType
        self.source = source
        self.metadata = metadata
        self.outputs = outputs
        self.executionCount = executionCount
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cellType = (try? c.decode(String.self, forKey: .cellType)) ?? "code"

        // source can be String or [String]
        if let arr = try? c.decode([String].self, forKey: .source) {
            source = arr
        } else if let str = try? c.decode(String.self, forKey: .source) {
            source = NotebookParser.splitSourceLines(str)
        } else {
            source = []
        }

        metadata = (try? c.decode(CellMeta.self, forKey: .metadata)) ?? CellMeta()
        outputs = try? c.decode([CellOutputData].self, forKey: .outputs)
        executionCount = try? c.decode(Int.self, forKey: .executionCount)
        id = try? c.decode(String.self, forKey: .id)
    }

    var sourceText: String {
        get { source.joined() }
        set { source = NotebookParser.splitSourceLines(newValue) }
    }
}

struct CellMeta: Codable {
    var collapsed: Bool?
    var tags: [String]?

    init(collapsed: Bool? = nil, tags: [String]? = nil) {
        self.collapsed = collapsed
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collapsed = try? c.decode(Bool.self, forKey: .collapsed)
        tags = try? c.decode([String].self, forKey: .tags)
    }

    enum CodingKeys: String, CodingKey {
        case collapsed, tags
    }
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

    init(outputType: String = "stream", name: String? = nil, text: StringOrArray? = nil,
         data: [String: StringOrArray]? = nil, executionCount: Int? = nil,
         ename: String? = nil, evalue: String? = nil, traceback: [String]? = nil) {
        self.outputType = outputType
        self.name = name
        self.text = text
        self.data = data
        self.executionCount = executionCount
        self.ename = ename
        self.evalue = evalue
        self.traceback = traceback
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputType = (try? c.decode(String.self, forKey: .outputType)) ?? "stream"
        name = try? c.decode(String.self, forKey: .name)
        text = try? c.decode(StringOrArray.self, forKey: .text)
        data = try? c.decode([String: StringOrArray].self, forKey: .data)
        executionCount = try? c.decode(Int.self, forKey: .executionCount)
        ename = try? c.decode(String.self, forKey: .ename)
        evalue = try? c.decode(String.self, forKey: .evalue)
        traceback = try? c.decode([String].self, forKey: .traceback)
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
