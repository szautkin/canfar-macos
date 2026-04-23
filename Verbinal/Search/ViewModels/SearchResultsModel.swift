// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Manages search-results state: filtering, sorting, pagination, column visibility, and export.
///
/// **Pipeline**: the model maintains *stored* `displayedRows`, `filteredCount`, and
/// `totalPages` that are recomputed exactly once on any state mutation via
/// ``refresh(resettingPage:)``. This avoids the recomputation storm of the previous
/// design where each view read (info bar, header, body) triggered a full
/// filter + sort pass through chained computed properties.
///
/// **Filter contract**: `columnFilters` are matched (case-insensitive substring)
/// against a per-row, per-column `searchIndex` built at load time that contains
/// both the raw CSV value and its formatted display string. A user typing
/// `"Cal"` in the `callev` filter matches rows whose raw value is `"1"`.
///
/// **Sort contract**: comparator is chosen by ``SearchResultColumn/kind`` (inferred
/// from samples at load, with overrides for known column ids). Numeric columns
/// reject non-finite values (NaN/Inf) and fall back to the row id for
/// deterministic tie-breaking.
@Observable
@MainActor
final class SearchResultsModel {
    // MARK: - Source data

    /// All loaded rows, in server order.
    private(set) var results: [SearchResult] = []
    /// Column metadata — owns id→index lookup and visibility.
    var columns: SearchResultColumns = SearchResultColumns()
    /// Total number of rows loaded (= `results.count`; retained for test compat).
    private(set) var totalRows: Int = 0
    /// True when the server capped the response at `maxRec`.
    private(set) var maxRecordReached = false
    /// Original ADQL query used to populate the model — consumed by URL export.
    /// Readable/writeable: ``SearchRootView`` copies a saved query's ADQL here
    /// to prefill the ADQL editor tab without re-running the search.
    var adqlQuery = ""

    // MARK: - Derived state (updated only via `refresh`)

    /// The slice currently rendered by the view: filtered + sorted + paginated.
    private(set) var displayedRows: [SearchResult] = []
    /// Number of rows matching the active filter (before pagination).
    private(set) var filteredCount: Int = 0
    /// Number of pages in the current filtered result given `rowsPerPage`.
    private(set) var totalPages: Int = 1

    // MARK: - Filter, sort, pagination state

    /// Per-column filter text. Empty entries are removed eagerly to keep the map tight.
    var columnFilters: [String: String] = [:] {
        didSet { refresh(resettingPage: true) }
    }

    var sortColumnID: String? {
        didSet { refresh(resettingPage: true) }
    }

    var sortAscending: Bool = true {
        didSet { refresh(resettingPage: true) }
    }

    /// Rows per page. `0` means "all" but is capped by `maxRowsForAll`.
    var rowsPerPage: Int = 100 {
        didSet { refresh(resettingPage: false) }
    }

    /// Zero-based page index. Clamped in ``refresh(resettingPage:)``.
    ///
    /// When ``refresh(resettingPage:)`` drives the change, the didSet is
    /// suppressed (see ``suppressPageDidSet``): the refresh itself will
    /// paginate and assign `displayedRows` exactly once, so running the
    /// light-weight rebuild here too would recompute filter+sort a second
    /// time for no reason.
    var currentPage: Int = 0 {
        didSet {
            if suppressPageDidSet { return }
            if currentPage != oldValue { rebuildDisplayedRows() }
        }
    }

    /// Gate that lets ``refresh(resettingPage:)`` mutate `currentPage` without
    /// triggering the standalone rebuild path.
    private var suppressPageDidSet = false

    /// Upper bound when `rowsPerPage == 0` (the "All" option). LazyVStack cannot
    /// safely render unbounded rows; this is a defensive cap until Phase 6
    /// migrates to native `Table` with row virtualization.
    static let maxRowsForAll = 2000

    static let rowsPerPageOptions: [Int] = [50, 100, 500, 0]

    // MARK: - Compatibility accessors (transitional)

    /// Legacy alias for ``columns/visible`` used by older view code.
    var visibleColumns: [SearchResultColumn] { columns.visible }

    // MARK: - Loading

    /// Replace the loaded rows. Resets sort, filter, and pagination state.
    func loadResults(headers: [String], rows: [[String]], query: String, maxRec: Int) {
        adqlQuery = query
        columnFilters = [:]          // didSet triggers refresh — we'll rebuild everything below
        sortColumnID = nil
        currentPage = 0

        columns = SearchResultColumns(headers: headers, sampleRows: rows)
        columns.applyPersistedVisibility()

        results = rows.enumerated().map { rowIndex, row in
            Self.buildResult(row: row, columns: columns, rowIndex: rowIndex)
        }

        totalRows = results.count
        maxRecordReached = totalRows >= maxRec

        refresh(resettingPage: true)
    }

    /// Construct a ``SearchResult`` from a single CSV row, building its
    /// stable id and per-column search haystack.
    private static func buildResult(
        row: [String],
        columns: SearchResultColumns,
        rowIndex: Int
    ) -> SearchResult {
        // rawValues is the positional row; pad shorter rows so indexing is safe.
        var raw = row
        while raw.count < columns.count { raw.append("") }

        // Stable id — prefer obsid, then publisherID, then synthetic row-index.
        let obsid = obtain(rawValue: raw, id: "obsid", columns: columns)
        let pub = obtain(rawValue: raw, id: "publisherid", columns: columns)
        let id: String
        if !obsid.isEmpty { id = obsid }
        else if !pub.isEmpty { id = pub }
        else { id = "row_\(rowIndex)" }

        // Per-column lowercased haystack (raw + formatted), built once.
        var searchIndex: [String] = []
        searchIndex.reserveCapacity(columns.count)
        for col in columns.list {
            let rawCell = raw[col.index]
            let formatted = CellFormatters.format(key: col.id, raw: rawCell)
            if rawCell == formatted {
                searchIndex.append(rawCell.lowercased())
            } else {
                searchIndex.append(rawCell.lowercased() + "\u{1F} " + formatted.lowercased())
            }
        }

        return SearchResult(id: id, rawValues: raw, searchIndex: searchIndex)
    }

    private static func obtain(rawValue: [String], id: String, columns: SearchResultColumns) -> String {
        guard let col = columns.column(id: id), rawValue.indices.contains(col.index) else { return "" }
        return rawValue[col.index]
    }

    // MARK: - Mutations

    /// Apply a filter to a column; empty strings remove the entry.
    func setFilter(_ columnID: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            columnFilters.removeValue(forKey: columnID)
        } else {
            columnFilters[columnID] = trimmed
        }
    }

    /// Toggle sort. Same column flips direction; different column starts ascending.
    func toggleSort(_ columnID: String) {
        if sortColumnID == columnID {
            sortAscending.toggle()
        } else {
            sortAscending = true
            sortColumnID = columnID
        }
    }

    /// Toggle visibility of a column by id. Persists across sessions.
    func toggleColumnVisibility(_ columnID: String) {
        columns.toggleVisibility(id: columnID)
        columns.persistVisibility()
    }

    /// Reset column visibility to the default-visible policy and clear any
    /// stored overrides so the default policy applies on next session too.
    func resetColumnVisibility() {
        columns.resetVisibilityToDefault()
        SearchResultColumns.clearPersistedVisibility()
    }

    /// Show or hide every column in one pass. Persists across sessions.
    func setAllColumnsVisible(_ visible: Bool) {
        for col in columns.list {
            columns.setVisibility(id: col.id, visible: visible)
        }
        columns.persistVisibility()
    }

    /// Clear all loaded rows and state.
    func clearResults() {
        results = []
        columns = SearchResultColumns()
        totalRows = 0
        maxRecordReached = false
        adqlQuery = ""
        sortColumnID = nil
        columnFilters = [:]
        currentPage = 0
        displayedRows = []
        filteredCount = 0
        totalPages = 1
    }

    // MARK: - Refresh pipeline

    /// Run the full filter → sort → paginate pipeline once. The only entry
    /// point that mutates `displayedRows`, `filteredCount`, `totalPages`,
    /// and that clamps `currentPage`. The currentPage assignment is wrapped
    /// in ``suppressPageDidSet`` so the standalone rebuild doesn't fire —
    /// the pipeline would then run twice.
    private func refresh(resettingPage: Bool) {
        suppressPageDidSet = true
        defer { suppressPageDidSet = false }

        let filtered = applyFilter(results)
        let sorted = applySort(filtered)

        filteredCount = sorted.count
        totalPages = computeTotalPages(rowCount: sorted.count)

        if resettingPage {
            currentPage = 0
        } else {
            currentPage = max(0, min(currentPage, totalPages - 1))
        }

        displayedRows = paginate(sorted)
    }

    /// Recompute just the paginated slice from the last filter+sort result.
    /// Used when only `currentPage` changed — skips the full pipeline.
    ///
    /// We intentionally keep this lean: it re-derives filter+sort because we
    /// don't cache the sorted array. For the row sizes this app sees
    /// (typically ≤ MAXREC 30k) this is fast enough in practice; if that
    /// becomes a bottleneck we can cache `sorted` under a dependency hash.
    private func rebuildDisplayedRows() {
        let filtered = applyFilter(results)
        let sorted = applySort(filtered)
        displayedRows = paginate(sorted)
    }

    /// A resolved filter predicate bound to a concrete column index.
    ///
    /// Numeric predicates compare the cell's raw value as a `Double` (finite
    /// only); substring predicates match against the precomputed haystack in
    /// `row.searchIndex[i]`.
    private struct ResolvedPredicate {
        let index: Int
        let expression: FilterExpression
    }

    private func applyFilter(_ rows: [SearchResult]) -> [SearchResult] {
        guard !columnFilters.isEmpty else { return rows }

        // Resolve each filter once before the hot loop.
        let predicates: [ResolvedPredicate] = columnFilters.compactMap { id, query in
            guard let col = columns.column(id: id) else { return nil }
            let numericEligible = Self.isNumericKind(col.kind)
            guard let expr = FilterExpression.parse(query, numericEligible: numericEligible) else {
                return nil
            }
            return ResolvedPredicate(index: col.index, expression: expr)
        }
        guard !predicates.isEmpty else { return rows }

        return rows.filter { row in
            for p in predicates {
                if !Self.matches(row: row, predicate: p) { return false }
            }
            return true
        }
    }

    /// Evaluate a resolved predicate against a row.
    private static func matches(row: SearchResult, predicate: ResolvedPredicate) -> Bool {
        switch predicate.expression {
        case .numeric(let op, let threshold):
            guard row.rawValues.indices.contains(predicate.index),
                  let value = finiteDouble(row.rawValues[predicate.index]) else {
                return false
            }
            return op.matches(value, against: threshold)
        case .substring(let needle):
            guard row.searchIndex.indices.contains(predicate.index) else { return false }
            return row.searchIndex[predicate.index].contains(needle)
        }
    }

    /// Whether operator-based numeric filtering is valid for the kind. Date
    /// columns use MJD under the hood (numeric) but as-typed user input
    /// should substring-match the *formatted* text, so they route through
    /// the substring path.
    private static func isNumericKind(_ kind: ColumnKind) -> Bool {
        switch kind {
        case .number, .integer: return true
        case .text, .mjdDate, .isoDate, .boolean: return false
        }
    }

    private func applySort(_ rows: [SearchResult]) -> [SearchResult] {
        guard let id = sortColumnID, let col = columns.column(id: id) else { return rows }

        let ascending = sortAscending
        let kind = col.kind
        let idx = col.index

        return rows.sorted { a, b in
            guard a.rawValues.indices.contains(idx), b.rawValues.indices.contains(idx) else {
                return a.id < b.id
            }
            let order = Self.compare(a.rawValues[idx], b.rawValues[idx], kind: kind)
            if order != .orderedSame {
                return ascending ? (order == .orderedAscending) : (order == .orderedDescending)
            }
            // Deterministic tiebreaker on stable id — keeps sort stable across toggles.
            return a.id < b.id
        }
    }

    /// Core comparator — pure, testable. Non-finite numbers (NaN/Inf) and
    /// missing parses sort *after* valid values.
    static func compare(_ a: String, _ b: String, kind: ColumnKind) -> ComparisonResult {
        switch kind {
        case .text:
            return a.localizedCaseInsensitiveCompare(b)

        case .integer:
            let pa = Int(a)
            let pb = Int(b)
            return compareOptionals(pa, pb, stringA: a, stringB: b)

        case .number, .mjdDate:
            // `finiteDouble` is the single canonical numeric guard used
            // across formatters and the comparator — non-finite sorts last.
            let pa = finiteDouble(a)
            let pb = finiteDouble(b)
            return compareOptionals(pa, pb, stringA: a, stringB: b)

        case .isoDate:
            let pa = Self.iso8601.date(from: a) ?? Self.iso8601Fractional.date(from: a)
            let pb = Self.iso8601.date(from: b) ?? Self.iso8601Fractional.date(from: b)
            return compareOptionals(pa.map(\.timeIntervalSince1970),
                                    pb.map(\.timeIntervalSince1970),
                                    stringA: a, stringB: b)

        case .boolean:
            let pa = BooleanValue.parse(a)
            let pb = BooleanValue.parse(b)
            return compareOptionals(pa.map { $0 ? 1 : 0 },
                                    pb.map { $0 ? 1 : 0 },
                                    stringA: a, stringB: b)
        }
    }

    private static func compareOptionals<T: Comparable>(
        _ a: T?,
        _ b: T?,
        stringA: String,
        stringB: String
    ) -> ComparisonResult {
        switch (a, b) {
        case let (x?, y?):
            if x == y { return .orderedSame }
            return x < y ? .orderedAscending : .orderedDescending
        case (nil, _?):
            return .orderedDescending  // nulls last
        case (_?, nil):
            return .orderedAscending
        case (nil, nil):
            return stringA.compare(stringB)
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func computeTotalPages(rowCount: Int) -> Int {
        guard rowCount > 0 else { return 1 }
        guard rowsPerPage > 0 else { return 1 }
        return max(1, (rowCount + rowsPerPage - 1) / rowsPerPage)
    }

    private func paginate(_ rows: [SearchResult]) -> [SearchResult] {
        // `rowsPerPage == 0` = "All" but capped for LazyVStack safety.
        if rowsPerPage <= 0 {
            return rows.count > Self.maxRowsForAll
                ? Array(rows.prefix(Self.maxRowsForAll))
                : rows
        }
        let start = currentPage * rowsPerPage
        guard start < rows.count else { return [] }
        let end = min(start + rowsPerPage, rows.count)
        return Array(rows[start..<end])
    }

    // MARK: - Export (server-side)

    /// Build a TAP URL that re-runs the original query server-side. Reflects
    /// the *raw* result, not client filters or column visibility.
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

    // MARK: - Export (client-side)

    /// Whether any client-side filter, sort, or column-hide is active — if so,
    /// server-side export would include more rows/columns than the user sees.
    var hasClientSideAdjustments: Bool {
        !columnFilters.isEmpty
            || sortColumnID != nil
            || columns.list.contains { !$0.visible }
    }

    /// Rows currently matching the filter + sort, ignoring pagination.
    /// Used by the client-side exporter so export is consistent whether the
    /// user is on page 1 or page 17.
    var fullFilteredSortedResults: [SearchResult] {
        applySort(applyFilter(results))
    }
}
