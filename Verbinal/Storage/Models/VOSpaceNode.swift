// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

enum VOSpaceNodeType: String {
    case container
    case dataNode
    case linkNode
}

struct VOSpaceNode: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var path: String
    var type: VOSpaceNodeType
    var sizeBytes: Int64?
    var contentType: String?
    var lastModified: Date?
    var isPublic: Bool = false

    var isContainer: Bool { type == .container }

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    var isFITS: Bool {
        FileHelper.isFITS(fileExtension)
    }

    var formattedSize: String {
        guard let size = sizeBytes else { return "" }
        return SharedFormatters.bytes(size)
    }

    var formattedDate: String {
        guard let date = lastModified else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    var icon: String {
        if isContainer { return "folder.fill" }
        switch fileExtension {
        case "fits", "fit", "fts", "fz": return "star.circle"
        case "csv", "tsv", "vot": return "tablecells"
        case "py", "sh", "bash": return "chevron.left.forwardslash.chevron.right"
        case "ipynb": return "doc.text"
        case "png", "jpg", "jpeg", "gif": return "photo"
        case "pdf": return "doc.richtext"
        case "tar", "gz", "zip": return "archivebox"
        default: return "doc"
        }
    }
}
