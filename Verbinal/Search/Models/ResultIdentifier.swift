// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What identifies a row of archive results (plan 54).
///
/// - `product`: a plane's publisher ID
///   (`ivo://cadc.nrc.ca/CFHT?1227446/1227446g`). DataLink, previews,
///   CAOM-2 metadata and downloads all take it.
/// - `observation`: an observation's URI (`caom:CFHT/1227446`), for a query
///   of observations without their products. CAOM-2 metadata takes it;
///   DataLink does not, so its rows have no previews or downloads.
enum ResultIdentifier: String, Sendable, Equatable {
    case product
    case observation

    /// The header Verbinal gives the column when it adds it.
    var header: String {
        switch self {
        case .product: "Publisher ID"
        case .observation: "Observation URI"
        }
    }

    /// Which identifier a result header carries, whatever its case or
    /// punctuation: `publisherID`, "Publisher ID", `publisher_id`,
    /// `publisherDID`, `obs_publisher_did`; `observationURI`, "Observation URI".
    static func of(header: String) -> ResultIdentifier? {
        let name = String(header.lowercased().filter { $0.isLetter || $0.isNumber })
        if ["publisherid", "publisherdid", "obspublisherdid"].contains(name) { return .product }
        if name == "observationuri" { return .observation }
        return nil
    }

    /// A table's identifier column.
    struct Column: Sendable, Equatable {
        let name: String
        let identifies: ResultIdentifier
    }

    /// The column of `table` that identifies its rows: by its utype in the
    /// schema (plan 54 A2), else the archive's own tables as CADC's
    /// `TAP_SCHEMA` named them on 2026-10-28, for when the schema is not
    /// loaded yet.
    static func column(of table: String, schema: TapSchema?) -> Column? {
        if let columns = schema?.table(table)?.columns {
            for identifies in [ResultIdentifier.product, .observation] {
                if let found = columns.first(where: { identifies.utypes.contains($0.utype.lowercased()) }) {
                    return Column(name: found.name, identifies: identifies)
                }
            }
        }
        let written = table.lowercased()
        return knownColumns[written]
            ?? knownColumns.first { !written.contains(".") && $0.key.hasSuffix(".\(written)") }?.value
    }

    /// The utypes that mark the column in `TAP_SCHEMA`, lowercased.
    private var utypes: Set<String> {
        switch self {
        case .product: ["caom2:plane.publisherid", "obscore:curation.publisherdid"]
        case .observation: ["caom2:observation.uri"]
        }
    }

    private static let knownColumns: [String: Column] = [
        "caom2.plane": Column(name: "publisherID", identifies: .product),
        "ivoa.obscore": Column(name: "obs_publisher_did", identifies: .product),
        "caom2.siav1": Column(name: "publisherDID", identifies: .product),
        "caom2.observation": Column(name: "observationURI", identifies: .observation),
    ]
}
