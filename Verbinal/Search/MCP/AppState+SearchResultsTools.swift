// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit

/// Search: the results table as the person sees it, and the detail of a row.
extension AppState {
    nonisolated static func columnKindKey(_ kind: ColumnKind) -> String {
        switch kind {
        case .text: return "text"
        case .integer: return "integer"
        case .number: return "number"
        case .mjdDate: return "mjdDate"
        case .isoDate: return "isoDate"
        case .boolean: return "boolean"
        }
    }

    nonisolated static let emptySearchResults = GetSearchResultsTool.Output(
        hasResults: false, adqlQuery: "", totalRows: 0, filteredCount: 0,
        maxRecordReached: false, currentPage: 0, totalPages: 1, rowsPerPage: 100,
        sortColumnID: nil, sortAscending: true, activeFilters: [:], columns: [],
        returnedPage: nil, rowIDs: [], rows: [], rowsTruncated: false)

    func makeGetSearchResultsTool() -> GetSearchResultsTool {
        GetSearchResultsTool(snapshot: { [weak self] args in
            guard let self else { return Self.emptySearchResults }
            return await MainActor.run {
                let resultsModel = self.searchModel.resultsModel
                guard !resultsModel.results.isEmpty else { return Self.emptySearchResults }

                let includeAll = args.allColumns == true
                let cols = resultsModel.columns.list.filter { includeAll || $0.visible }
                let columns = cols.map {
                    GetSearchResultsTool.Output.Column(
                        id: $0.id, label: $0.label,
                        kind: Self.columnKindKey($0.kind),
                        visible: $0.visible,
                        selectedUnit: resultsModel.selectedUnit(for: $0.id),
                        units: CellFormatterRegistry.availableUnits(for: $0.id)?.map(\.unitID))
                }

                var rows: [[String]] = []
                var rowIDs: [String] = []
                var returnedPage: Int?
                var truncated = false
                if args.includeRows ?? true {
                    let full = resultsModel.fullFilteredSortedResults
                    let perPage = resultsModel.rowsPerPage
                    let slice: ArraySlice<SearchResult>
                    if perPage <= 0 {
                        returnedPage = 0
                        slice = full[...]
                    } else {
                        let page = args.page ?? resultsModel.currentPage
                        returnedPage = page
                        let start = page * perPage
                        slice = start < full.count
                            ? full[start..<min(start + perPage, full.count)]
                            : full[0..<0]
                    }
                    let cap = min(max(args.maxRows ?? 200, 1), 1000)
                    truncated = slice.count > cap
                    let limited = slice.prefix(cap)
                    rowIDs = limited.map(\.id)
                    rows = limited.map { row in
                        cols.map { col in
                            row.rawValues.indices.contains(col.index)
                                ? row.rawValues[col.index] : ""
                        }
                    }
                }

                return GetSearchResultsTool.Output(
                    hasResults: true,
                    adqlQuery: resultsModel.adqlQuery,
                    totalRows: resultsModel.totalRows,
                    filteredCount: resultsModel.filteredCount,
                    maxRecordReached: resultsModel.maxRecordReached,
                    currentPage: resultsModel.currentPage,
                    totalPages: resultsModel.totalPages,
                    rowsPerPage: resultsModel.rowsPerPage,
                    sortColumnID: resultsModel.sortColumnID,
                    sortAscending: resultsModel.sortAscending,
                    activeFilters: resultsModel.columnFilters,
                    columns: columns,
                    returnedPage: returnedPage,
                    rowIDs: rowIDs,
                    rows: rows,
                    rowsTruncated: truncated)
            }
        }, readiness: { [weak self] in
            await MainActor.run { (self?.searchModel.readiness ?? .empty, self?.searchModel.searchError) }
        })
    }

    func makeSetResultsViewTool() -> SetResultsViewTool {
        let activity = agentsService.activityStore
        return SetResultsViewTool(apply: { [weak self] args in
            guard let self else { return .rejected("App state unavailable") }
            return await MainActor.run {
                let resultsModel = self.searchModel.resultsModel
                guard !resultsModel.results.isEmpty else {
                    return .rejected("No search results are loaded")
                }

                // Validate every reference before mutating anything, so a
                // rejected call leaves the table exactly as the user had it.
                if let id = args.sortColumnID, resultsModel.columns.column(id: id) == nil {
                    return .rejected("Unknown column '\(id)'")
                }
                if let visible = args.visibleColumns {
                    guard !visible.isEmpty else {
                        return .rejected("visibleColumns must not be empty")
                    }
                    for id in visible where resultsModel.columns.column(id: id) == nil {
                        return .rejected("Unknown column '\(id)'")
                    }
                }
                if let filters = args.filters {
                    for id in filters.keys where resultsModel.columns.column(id: id) == nil {
                        return .rejected("Unknown column '\(id)'")
                    }
                }
                if let units = args.columnUnits {
                    // The columns that have a choice of units, to name when one is not.
                    let withUnits = resultsModel.columns.list.map(\.id).filter { CellFormatterRegistry.availableUnits(for: $0) != nil }
                    for (id, unit) in units {
                        guard resultsModel.columns.column(id: id) != nil else {
                            return .rejected("Unknown column '\(id)'; the columns with units are \(withUnits.joined(separator: ", "))")
                        }
                        guard let available = CellFormatterRegistry.availableUnits(for: id) else {
                            return .rejected("Column '\(id)' has no unit choices; the columns with units are \(withUnits.joined(separator: ", "))")
                        }
                        guard available.contains(where: { $0.unitID == unit }) else {
                            let ids = available.map(\.unitID).joined(separator: ", ")
                            return .rejected("Unknown unit '\(unit)' for column '\(id)': it takes \(ids)")
                        }
                    }
                }
                if let perPage = args.rowsPerPage,
                   !SearchResultsModel.rowsPerPageOptions.contains(perPage) {
                    return .rejected("rowsPerPage must be one of 50, 100, 500, or 0 (all)")
                }

                if args.clearSort == true { resultsModel.sortColumnID = nil }
                if let id = args.sortColumnID {
                    resultsModel.sortAscending = args.sortAscending ?? true
                    resultsModel.sortColumnID = id
                } else if let ascending = args.sortAscending {
                    resultsModel.sortAscending = ascending
                }
                if args.clearFilters == true { resultsModel.columnFilters = [:] }
                if let filters = args.filters {
                    for (id, text) in filters { resultsModel.setFilter(id, text: text) }
                }
                if args.resetColumnVisibility == true { resultsModel.resetColumnVisibility() }
                if let visible = args.visibleColumns {
                    let visibleSet = Set(visible)
                    for col in resultsModel.columns.list {
                        resultsModel.columns.setVisibility(
                            id: col.id, visible: visibleSet.contains(col.id))
                    }
                    resultsModel.columns.persistVisibility()
                }
                if let units = args.columnUnits {
                    for (id, unit) in units {
                        resultsModel.setUnit(columnID: id, unitID: unit)
                    }
                }
                if let perPage = args.rowsPerPage { resultsModel.rowsPerPage = perPage }
                if let page = args.page {
                    resultsModel.currentPage = max(0, min(page, resultsModel.totalPages - 1))
                }

                activity.append(.live(
                    kind: "set_results_view",
                    summary: "Adjusted the results table",
                    origin: .external(clientID: "set_results_view")))
                return .applied(.init(
                    filteredCount: resultsModel.filteredCount,
                    currentPage: resultsModel.currentPage,
                    totalPages: resultsModel.totalPages))
            }
        })
    }

    /// Opens the detail sheet for a loaded results row — the one path the
    /// three detail tools share. Returns why not, or nil.
    @MainActor
    func openObservationDetail(rowID: String, via tool: String) -> String? {
        let model = searchModel
        guard model.resultsModel.result(forID: rowID) != nil else {
            return "No results row with id '\(rowID)' — ids come from get_search_results"
        }
        if currentMode != .search { navigateTo(.search) }
        model.selectedTab = .results
        model.resultsModel.pendingDetailRequest = .init(rowID: rowID)
        agentsService.activityStore.append(.live(
            kind: tool, summary: "Opened observation detail for \(rowID)", origin: .external(clientID: tool)))
        return nil
    }

    func makeOpenObservationDetailTool() -> LiveActionTool<ObservationDetailActions.RowIDArgs> {
        ObservationDetailActions.openByRowID { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await self.openObservationDetail(rowID: args.rowID, via: "open_observation_detail")
        }
    }

    func makeShowSearchRowDetailTool() -> LiveActionTool<ObservationDetailActions.RowArgs> {
        ObservationDetailActions.openByRow { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let rows = self.searchModel.resultsModel.displayedRows
                guard rows.indices.contains(args.row) else {
                    return rows.isEmpty
                        ? "No results on screen — run a search first"
                        : "row \(args.row) is not on the page shown (0…\(rows.count - 1))"
                }
                return self.openObservationDetail(rowID: rows[args.row].id, via: "show_search_row_detail")
            }
        }
    }

    func makeShowObservationDetailTool() -> LiveActionTool<ObservationDetailActions.PublisherArgs> {
        ObservationDetailActions.openByPublisherID { [weak self] args in
            guard let self else { return "App state unavailable" }
            let wanted = args.publisherId.trimmingCharacters(in: .whitespaces)
            return await MainActor.run {
                guard let row = self.searchModel.resultsModel.result(publisherID: wanted) else {
                    return "\(wanted) is not among the current search results — search for it first (set_search_form with its observationID), then call this again"
                }
                return self.openObservationDetail(rowID: row.id, via: "show_observation_detail")
            }
        }
    }
}
