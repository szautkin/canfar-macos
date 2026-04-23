// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os

/// A single observation row from a TAP search query result.
///
/// Values are stored positionally (matching the column order at load time)
/// and accessed by cleaned column id through ``SearchResultColumns``. This
/// avoids per-row dictionary overhead for large result sets.
///
/// The row also carries pre-computed lowercased haystacks (raw + formatted)
/// per column, so filtering matches whatever the user *sees* as well as the
/// underlying raw value — resolving the long-standing filter/display
/// mismatch (users saw `2024-03-15` but had to type the MJD `60384.x`).
struct SearchResult: Identifiable {
    /// Stable identifier — prefers `obsid`, falls back to publisherID, then UUID.
    let id: String

    /// Raw CSV values, positional. Index matches ``SearchResultColumns/list``.
    let rawValues: [String]

    /// Lowercased `rawValue + " " + formattedValue` per column. Searched by filters.
    let searchIndex: [String]
}

// MARK: - Column metadata

/// Inferred content kind for a column — drives sort comparator selection.
///
/// Inference is done once at load time by sampling a handful of non-empty
/// cells; columns whose cells don't parse as a consistent kind fall to
/// ``ColumnKind/text``. Sort order depends on this classification, not on
/// per-cell parsing, so fields like `targetName` containing `"NGC1e3"` are
/// sorted lexicographically rather than numerically.
enum ColumnKind: Sendable, Equatable {
    case text
    case integer
    case number     // double-convertible
    case mjdDate    // MJD float
    case isoDate    // ISO-8601 timestamp
    case boolean
}

/// Column metadata for search-results display.
struct SearchResultColumn: Identifiable, Equatable {
    /// Cleaned key (unique within a ``SearchResultColumns`` collection).
    let id: String
    /// Display name from the CSV header.
    let label: String
    /// Zero-based index into ``SearchResult/rawValues``.
    let index: Int
    /// Inferred content kind — drives sort comparator selection.
    var kind: ColumnKind
    /// Whether the column is shown in the table.
    var visible: Bool

    static let defaultVisibleKeys: Set<String> = [
        "collection", "targetname", "ra(j20000)", "dec(j20000)",
        "startdate", "instrument", "filter", "callev",
        "obstype", "proposalid", "piname", "obsid",
    ]
}

/// Ordered collection of columns with O(1) id→index lookup.
///
/// Responsible for:
///  • building a unique-id list from CSV headers (disambiguating collisions);
///  • inferring ``ColumnKind`` per column by sampling rows;
///  • providing safe, logged value access by id;
///  • toggling per-column visibility.
struct SearchResultColumns {
    private(set) var list: [SearchResultColumn]
    private var indexByID: [String: Int]

    init() {
        self.list = []
        self.indexByID = [:]
    }

    /// Build columns from CSV headers, disambiguating duplicate cleaned keys
    /// by suffixing `_2`, `_3`, …, and inferring kinds from sample rows.
    init(headers: [String], sampleRows: [[String]]) {
        var list: [SearchResultColumn] = []
        var indexByID: [String: Int] = [:]
        var usedKeys: [String: Int] = [:]

        for (i, header) in headers.enumerated() {
            let base = CSVParser.cleanHeader(header)
            let id: String
            if let count = usedKeys[base] {
                let suffixed = "\(base)_\(count + 1)"
                id = suffixed
                usedKeys[base] = count + 1
                Self.logger.warning("Duplicate header id after cleanHeader: \(base, privacy: .public) → disambiguated as \(suffixed, privacy: .public)")
            } else {
                id = base
                usedKeys[base] = 1
            }

            let label = header
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespaces)

            let kind = Self.inferKind(id: id, columnIndex: i, sampleRows: sampleRows)

            list.append(SearchResultColumn(
                id: id,
                label: label,
                index: i,
                kind: kind,
                visible: SearchResultColumn.defaultVisibleKeys.contains(id)
            ))
            indexByID[id] = i
        }

        self.list = list
        self.indexByID = indexByID
    }

    /// Column count.
    var count: Int { list.count }

    /// All columns flagged visible, in original order.
    var visible: [SearchResultColumn] { list.filter(\.visible) }

    /// Column by id, or nil.
    func column(id: String) -> SearchResultColumn? {
        guard let i = indexByID[id], list.indices.contains(i) else { return nil }
        return list[i]
    }

    /// Raw value for a cell — nil if the column id is unknown or the row is short.
    func rawValue(in row: SearchResult, forID id: String) -> String? {
        guard let i = indexByID[id], row.rawValues.indices.contains(i) else { return nil }
        return row.rawValues[i]
    }

    /// Raw value convenience that returns "" rather than nil. Views should
    /// prefer this to avoid branching on optional for missing columns.
    func value(in row: SearchResult, forID id: String) -> String {
        rawValue(in: row, forID: id) ?? ""
    }

    /// Toggle a column's visibility in place.
    mutating func toggleVisibility(id: String) {
        guard let i = indexByID[id], list.indices.contains(i) else { return }
        list[i].visible.toggle()
    }

    /// Set a column's visibility explicitly.
    mutating func setVisibility(id: String, visible: Bool) {
        guard let i = indexByID[id], list.indices.contains(i) else { return }
        list[i].visible = visible
    }

    /// Reset all columns to the default visibility policy.
    mutating func resetVisibilityToDefault() {
        for i in list.indices {
            list[i].visible = SearchResultColumn.defaultVisibleKeys.contains(list[i].id)
        }
    }

    /// Apply saved visibility overrides from `store`. Columns without a stored
    /// override are left at their default-computed visibility, so newly-added
    /// columns respect the default policy.
    mutating func applyPersistedVisibility(
        store: any ColumnVisibilityStore = UserDefaultsColumnVisibilityStore()
    ) {
        for i in list.indices where store.isVisibilitySet(forID: list[i].id) {
            list[i].visible = store.visibility(forID: list[i].id)
        }
    }

    /// Persist the current visibility state for each known column id.
    func persistVisibility(
        store: any ColumnVisibilityStore = UserDefaultsColumnVisibilityStore()
    ) {
        for col in list {
            store.setVisible(col.visible, forID: col.id)
        }
    }

    /// Clear all saved visibility overrides — restores default-visible policy
    /// on next load.
    static func clearPersistedVisibility(
        store: any ColumnVisibilityStore = UserDefaultsColumnVisibilityStore()
    ) {
        store.clearAll()
    }

    // MARK: - Kind inference

    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "SearchResultColumns")

    /// Known-kind overrides — take precedence over sample-based inference.
    /// Keys here are the *cleaned* column ids.
    private static let kindOverrides: [String: ColumnKind] = [
        "startdate": .mjdDate,
        "enddate": .mjdDate,
        "datarelease": .isoDate,
        "provelastexecuted": .isoDate,
        "download": .boolean,
        "movingtarget": .boolean,
        "ra(j20000)": .number,
        "dec(j20000)": .number,
        "inttime": .number,
        "callev": .integer,
        "minwavelength": .number,
        "maxwavelength": .number,
        "restframeenergy": .number,
        "pixelscale": .number,
        "fieldofview": .number,
    ]

    private static let sampleLimit = 25

    /// Infer column kind by sampling up to `sampleLimit` non-empty cells.
    /// Mixed-kind columns fall through to `.text`.
    private static func inferKind(id: String, columnIndex: Int, sampleRows: [[String]]) -> ColumnKind {
        if let forced = kindOverrides[id] { return forced }

        var nonEmpty = 0
        var numberHits = 0
        var integerHits = 0
        var booleanHits = 0
        var isoHits = 0

        for row in sampleRows.prefix(sampleLimit) {
            guard row.indices.contains(columnIndex) else { continue }
            let raw = row[columnIndex].trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            nonEmpty += 1

            if BooleanValue.looksBoolean(raw) {
                booleanHits += 1
            }
            if Int(raw) != nil {
                integerHits += 1
                numberHits += 1
            } else if Double(raw) != nil {
                // Accept NaN / Infinity as "looks numeric" so a column with
                // one sentinel value in a sea of doubles is still classified
                // .number — the comparator handles non-finite at sort time.
                numberHits += 1
            }
            if looksLikeISO8601(raw) {
                isoHits += 1
            }
        }

        guard nonEmpty > 0 else { return .text }

        if isoHits == nonEmpty { return .isoDate }
        if booleanHits == nonEmpty { return .boolean }
        if integerHits == nonEmpty { return .integer }
        if numberHits == nonEmpty { return .number }
        return .text
    }

    private static func looksLikeISO8601(_ s: String) -> Bool {
        // YYYY-MM-DD at minimum, with optional T/space time and Z
        guard s.count >= 10 else { return false }
        let chars = Array(s)
        return chars[0].isNumber && chars[1].isNumber && chars[2].isNumber
            && chars[3].isNumber && chars[4] == "-"
            && chars[5].isNumber && chars[6].isNumber && chars[7] == "-"
            && chars[8].isNumber && chars[9].isNumber
    }
}
