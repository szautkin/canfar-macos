// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

enum ImageParser {

    static func parse(_ raw: RawImage) -> ParsedImage {
        let fullId = raw.id
        let parts = fullId.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        let registry: String
        let project: String
        let nameWithVersion: String

        switch parts.count {
        case 3...:
            registry = parts[0]
            project = parts[1]
            nameWithVersion = parts[2...].joined(separator: "/")
        case 2:
            registry = ""
            project = parts[0]
            nameWithVersion = parts[1]
        default:
            registry = ""
            project = ""
            nameWithVersion = parts.first ?? fullId
        }

        let name: String
        let version: String

        if let lastColon = nameWithVersion.lastIndex(of: ":") {
            name = String(nameWithVersion[nameWithVersion.startIndex..<lastColon])
            version = String(nameWithVersion[nameWithVersion.index(after: lastColon)...])
        } else {
            name = nameWithVersion
            version = "latest"
        }

        let label = "\(name):\(version)"

        return ParsedImage(
            id: fullId,
            registry: registry,
            project: project,
            name: name,
            version: version,
            label: label,
            types: raw.types
        )
    }

    /// Groups parsed images by session type and then by project.
    /// Result: [type: [project: [ParsedImage]]]
    static func groupByTypeAndProject(_ rawImages: [RawImage]) -> [String: [String: [ParsedImage]]] {
        var result: [String: [String: [ParsedImage]]] = [:]

        for raw in rawImages {
            let parsed = parse(raw)
            for type in parsed.types {
                let typeLower = type.lowercased()
                if result[typeLower] == nil {
                    result[typeLower] = [:]
                }
                if result[typeLower]![parsed.project] == nil {
                    result[typeLower]![parsed.project] = []
                }
                result[typeLower]![parsed.project]!.append(parsed)
            }
        }

        // Sort images within each project by version descending
        for type in result.keys {
            for project in result[type]!.keys {
                result[type]![project]!.sort { $0.label > $1.label }
            }
        }

        return result
    }
}
