// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Result from the CADC DataLink service — thumbnail and preview image URLs.
struct DataLinkResult {
    let thumbnails: [URL]
    let previews: [URL]

    var firstThumbnail: URL? { thumbnails.first }
    var firstPreview: URL? { previews.first }
    var isEmpty: Bool { thumbnails.isEmpty && previews.isEmpty }
    /// Best available image: prefer preview, fallback to thumbnail.
    var bestImage: URL? { previews.first ?? thumbnails.first }
}

// MARK: - VOTable Parsing

extension DataLinkResult {

    /// Parse a DataLink VOTable XML response to extract thumbnail and preview URLs.
    static func fromVOTable(_ xml: String) -> DataLinkResult {
        var thumbnails: [URL] = []
        var previews: [URL] = []

        // Extract FIELD names to determine column indices
        let fieldPattern = try! NSRegularExpression(pattern: #"<FIELD[^>]*name="([^"]*)"[^>]*/?>"#, options: .caseInsensitive)
        let fieldNames = fieldPattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: xml) else { return nil }
            return String(xml[range])
        }

        let accessUrlIdx = fieldNames.firstIndex(of: "access_url")
        let semanticsIdx = fieldNames.firstIndex(of: "semantics")
        let errorIdx = fieldNames.firstIndex(of: "error_message")
        let readableIdx = fieldNames.firstIndex(of: "link_authorized")
        let contentTypeIdx = fieldNames.firstIndex(of: "content_type")

        guard let accessUrlIdx, let semanticsIdx else {
            return DataLinkResult(thumbnails: [], previews: [])
        }

        // Extract rows
        let trPattern = try! NSRegularExpression(pattern: #"<TR>([\s\S]*?)</TR>"#, options: .caseInsensitive)
        let tdPattern = try! NSRegularExpression(pattern: #"<TD\s*/?>([^<]*)?(?:</TD>)?"#, options: .caseInsensitive)

        for trMatch in trPattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let rowRange = Range(trMatch.range(at: 1), in: xml) else { continue }
            let rowContent = String(xml[rowRange])

            let cells = tdPattern.matches(in: rowContent, range: NSRange(rowContent.startIndex..., in: rowContent)).map { cellMatch -> String in
                guard let cellRange = Range(cellMatch.range(at: 1), in: rowContent) else { return "" }
                return String(rowContent[cellRange]).trimmingCharacters(in: .whitespaces)
            }

            // Skip rows with errors or unauthorized
            if let errorIdx, errorIdx < cells.count, !cells[errorIdx].isEmpty { continue }
            if let readableIdx, readableIdx < cells.count, cells[readableIdx] != "true" && !cells[readableIdx].isEmpty {
                continue
            }

            guard accessUrlIdx < cells.count, semanticsIdx < cells.count else { continue }
            let accessUrl = cells[accessUrlIdx]
            let semantics = cells[semanticsIdx]
            guard !accessUrl.isEmpty, let url = URL(string: accessUrl) else { continue }

            let contentType = (contentTypeIdx != nil && contentTypeIdx! < cells.count) ? cells[contentTypeIdx!] : ""

            if semantics == "#thumbnail" {
                thumbnails.append(url)
            } else if semantics == "#preview" && contentType.contains("image") {
                previews.append(url)
            }
        }

        return DataLinkResult(thumbnails: thumbnails, previews: previews)
    }
}
