// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

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
