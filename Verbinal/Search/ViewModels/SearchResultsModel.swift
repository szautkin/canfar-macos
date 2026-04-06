// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Manages search results state: sorting, filtering, pagination, column visibility, and export.
@Observable
@MainActor
final class SearchResultsModel {
    var results: [SearchResult] = []
    var columns: [SearchResultColumn] = []
    var totalRows: Int = 0
    var maxRecordReached = false
    var adqlQuery = ""

    // Sorting
    var sortColumnId: String?
    var sortAscending = true

    // Per-column filters
    var columnFilters: [String: String] = [:]

    // Pagination
    var rowsPerPage = 100
    var currentPage = 0
    static let rowsPerPageOptions = [50, 100, 500, 0] // 0 = all

    var visibleColumns: [SearchResultColumn] {
        columns.filter(\.visible)
    }

    /// Filtered results (applying per-column text filters).
    var filteredResults: [SearchResult] {
        var filtered = results

        for (columnId, filterText) in columnFilters {
            let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
            guard !query.isEmpty else { continue }
            filtered = filtered.filter { result in
                let value = result.values[columnId] ?? ""
                return value.lowercased().contains(query)
            }
        }

        return filtered
    }

    /// Sorted + filtered results.
    var sortedResults: [SearchResult] {
        var sorted = filteredResults

        if let sortCol = sortColumnId {
            sorted.sort { a, b in
                let aVal = a.values[sortCol] ?? ""
                let bVal = b.values[sortCol] ?? ""
                // Try numeric comparison first
                if let aNum = Double(aVal), let bNum = Double(bVal) {
                    return sortAscending ? aNum < bNum : aNum > bNum
                }
                return sortAscending
                    ? aVal.localizedCaseInsensitiveCompare(bVal) == .orderedAscending
                    : aVal.localizedCaseInsensitiveCompare(bVal) == .orderedDescending
            }
        }

        return sorted
    }

    /// Paginated slice of sorted results.
    var paginatedResults: [SearchResult] {
        let all = sortedResults
        guard rowsPerPage > 0 else { return all }
        let start = currentPage * rowsPerPage
        guard start < all.count else { return [] }
        let end = min(start + rowsPerPage, all.count)
        return Array(all[start..<end])
    }

    var totalPages: Int {
        guard rowsPerPage > 0 else { return 1 }
        return max(1, (sortedResults.count + rowsPerPage - 1) / rowsPerPage)
    }

    var filteredCount: Int { filteredResults.count }

    // MARK: - Loading

    func loadResults(headers: [String], rows: [[String]], query: String, maxRec: Int) {
        adqlQuery = query
        sortColumnId = nil
        columnFilters = [:]
        currentPage = 0

        columns = headers.enumerated().map { _, header in
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

    // MARK: - Sorting

    func toggleSort(_ columnId: String) {
        if sortColumnId == columnId {
            sortAscending.toggle()
        } else {
            sortColumnId = columnId
            sortAscending = true
        }
        currentPage = 0
    }

    // MARK: - Filtering

    func setFilter(_ columnId: String, text: String) {
        columnFilters[columnId] = text
        currentPage = 0
    }

    // MARK: - Column Visibility

    func toggleColumnVisibility(_ columnId: String) {
        if let index = columns.firstIndex(where: { $0.id == columnId }) {
            columns[index].visible.toggle()
        }
    }

    // MARK: - Clear

    func clearResults() {
        results = []
        columns = []
        totalRows = 0
        maxRecordReached = false
        adqlQuery = ""
        sortColumnId = nil
        columnFilters = [:]
        currentPage = 0
    }

    // MARK: - Export

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
