// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// What the query tools say about a query's publisher ID (plan 54 D2).
struct IdentifierReport: Encodable, Sendable, Equatable {
    /// `product` (a publisher ID), `observation` (an observation URI), or
    /// nil when its rows have neither.
    let identifies: String?
    /// The select item Verbinal added so each row names its product.
    let added: String?
    /// Why its rows have no publisher ID, when they have none.
    let note: String?
    /// The JOIN that gives each row its product.
    let join: String?

    init(_ checked: ADQLIdentifier.Checked) {
        identifies = checked.identifies?.rawValue
        added = checked.added
        note = checked.gap?.message
        join = checked.gap?.join
    }
}

/// The product a per-product tool is asked about: its `publisher_id`, or
/// the `row` of the results table that names it (plan 54 D3) — 0-based on
/// the page shown, as `show_search_row_detail` takes it.
enum ProductReference {
    /// The identifier of a row of the page shown: its publisher ID, or,
    /// with `metadata`, its observation URI when it has no publisher ID.
    typealias Resolve = @Sendable (_ row: Int, _ metadata: Bool) async throws -> String

    /// For tools built without the Search screen (tests).
    static let noResults: Resolve = { _, _ in
        throw ToolFailureReason.invalidArgument("No results on screen — pass publisher_id")
    }

    static let schemaProperties = #"""
    "publisher_id": { "type": "string", "description": "The product's publisher ID (a search row's publisherID)." },
    "row": { "type": "integer", "minimum": 0, "description": "Instead of publisher_id: a row of the Search results table, 0-based on the page shown." }
    """#

    static func identifier(publisherID: String?, row: Int?, metadata: Bool = false,
                           resolve: Resolve) async throws -> String {
        let given = publisherID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (given.isEmpty, row) {
        case (false, nil): return given
        case (true, let row?): return try await resolve(row, metadata)
        case (false, _?): throw ToolFailureReason.invalidArgument("Pass publisher_id or row, not both")
        case (true, nil): throw ToolFailureReason.invalidArgument("publisher_id (or row) is required")
        }
    }
}
