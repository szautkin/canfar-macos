// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Search results as text for the clipboard: an observation's details, or
/// rows as tab-separated values that paste into a spreadsheet — the cells
/// written as the table shows them, in the units chosen for it.
extension SearchResultsModel {

    /// The cell as the table shows it.
    func displayValue(of row: SearchResult, columnID: String) -> String {
        CellFormatterRegistry.format(id: columnID, raw: columns.value(in: row, forID: columnID),
                                     unitID: selectedUnit(for: columnID))
    }

    func facts(for row: SearchResult) -> ObservationFacts {
        func raw(_ id: String) -> String { columns.value(in: row, forID: id) }
        return ObservationFacts(
            observationID: raw("obsid"), collection: raw("collection"), publisherID: raw("publisherid"),
            target: raw("targetname"),
            ra: Double(raw("ra(j20000)")), dec: Double(raw("dec(j20000)")),
            instrument: raw("instrument"), filter: raw("filter"),
            date: CellFormatterRegistry.format(id: "startdate", raw: raw("startdate"), unitID: nil),
            calibrationLevel: raw("callev"), proposal: raw("proposalid"),
            release: CellFormatterRegistry.format(id: "datarelease", raw: raw("datarelease"), unitID: nil))
    }

    /// A header line, then one line per row; tabs and line breaks inside a
    /// value become spaces so the grid stays a grid.
    func tabSeparated(_ rows: [SearchResult], columns shown: [SearchResultColumn]) -> String {
        func clean(_ value: String) -> String {
            value.components(separatedBy: CharacterSet(charactersIn: "\t\r\n")).joined(separator: " ")
        }
        let header = shown.map { clean($0.label) }.joined(separator: "\t")
        let lines = rows.map { row in shown.map { clean(displayValue(of: row, columnID: $0.id)) }.joined(separator: "\t") }
        return ([header] + lines).joined(separator: "\n")
    }
}
