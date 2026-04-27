// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

struct LocalFileNode: Identifiable, Equatable {
    let id: String // full path
    let name: String
    let url: URL
    let isDirectory: Bool
    let fileSize: Int64?
    let modifiedDate: Date?

    var fileExtension: String { url.pathExtension.lowercased() }

    var isFITS: Bool { FileHelper.isFITS(fileExtension) }
    var isNotebook: Bool { fileExtension == "ipynb" }
    var isPython: Bool { fileExtension == "py" }
    var isMarkdown: Bool { fileExtension == "md" }

    var icon: String {
        if isDirectory { return "folder.fill" }
        if isFITS { return "star.circle" }
        if isNotebook { return "doc.text" }
        if isPython { return "chevron.left.forwardslash.chevron.right" }
        if isMarkdown { return "doc.richtext" }
        return "doc"
    }

    var formattedSize: String {
        guard let size = fileSize else { return "" }
        return SharedFormatters.bytes(size)
    }

    /// Supported file types for the file browser filter.
    static let supportedExtensions: Set<String> = ["fits", "fit", "fts", "fz", "ipynb", "py", "md"]
}
