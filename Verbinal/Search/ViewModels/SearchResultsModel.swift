// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Manages search results state: sorting, column visibility, and export.
@Observable
@MainActor
final class SearchResultsModel {
    var results: [SearchResult] = []
    var columns: [SearchResultColumn] = []
    var totalRows: Int = 0
    var maxRecordReached = false
    var adqlQuery = ""

    var visibleColumns: [SearchResultColumn] {
        columns.filter(\.visible)
    }

    /// Populate results from parsed CSV data.
    func loadResults(headers: [String], rows: [[String]], query: String, maxRec: Int) {
        adqlQuery = query

        // Build columns from headers
        columns = headers.enumerated().map { index, header in
            let cleanKey = CSVParser.cleanHeader(header)
            let label = header
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespaces)
            return SearchResultColumn(
                id: cleanKey,
                label: label,
                visible: SearchResultColumn.defaultVisibleKeys.contains(cleanKey)
            )
        }

        // Build result rows
        results = rows.map { row in
            var values: [String: String] = [:]
            for (i, header) in headers.enumerated() where i < row.count {
                let key = CSVParser.cleanHeader(header)
                values[key] = row[i]
            }
            return SearchResult(values: values)
        }

        totalRows = results.count
        maxRecordReached = totalRows >= maxRec
    }

    func toggleColumnVisibility(_ columnId: String) {
        if let index = columns.firstIndex(where: { $0.id == columnId }) {
            columns[index].visible.toggle()
        }
    }

    func clearResults() {
        results = []
        columns = []
        totalRows = 0
        maxRecordReached = false
        adqlQuery = ""
    }

    /// Build a TAP URL for downloading results in a specific format.
    func exportURL(format: String) -> URL? {
        guard !adqlQuery.isEmpty else { return nil }
        var components = URLComponents(string: "\(TAPConfig.baseURL)\(TAPConfig.syncPath)")
        components?.queryItems = [
            URLQueryItem(name: "LANG", value: "ADQL"),
            URLQueryItem(name: "FORMAT", value: format),
            URLQueryItem(name: "QUERY", value: adqlQuery),
            URLQueryItem(name: "MAXREC", value: String(TAPConfig.maxRecords)),
        ]
        return components?.url
    }
}
