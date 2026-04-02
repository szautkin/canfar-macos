// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A single observation row from a TAP search query result.
struct SearchResult: Identifiable {
    let id = UUID()
    let values: [String: String]

    // Convenience accessors for commonly displayed columns
    var collection: String { values["collection"] ?? "" }
    var targetName: String { values["targetname"] ?? "" }
    var ra: String { values["ra(j20000)"] ?? "" }
    var dec: String { values["dec(j20000)"] ?? "" }
    var startDate: String { values["startdate"] ?? "" }
    var instrument: String { values["instrument"] ?? "" }
    var filter: String { values["filter"] ?? "" }
    var calLevel: String { values["callev"] ?? "" }
    var obsType: String { values["obstype"] ?? "" }
    var proposalID: String { values["proposalid"] ?? "" }
    var piName: String { values["piname"] ?? "" }
    var observationID: String { values["obsid"] ?? "" }
    var dataType: String { values["datatype"] ?? "" }
    var integrationTime: String { values["inttime"] ?? "" }
    var dataRelease: String { values["datarelease"] ?? "" }
    var publisherID: String { values["publisherid"] ?? "" }
    var band: String { values["band"] ?? "" }
}

/// Column metadata for search results display.
struct SearchResultColumn: Identifiable {
    let id: String          // cleaned key
    let label: String       // display name from CSV header
    var visible: Bool

    static let defaultVisibleKeys: Set<String> = [
        "collection", "targetname", "ra(j20000)", "dec(j20000)",
        "startdate", "instrument", "filter", "callev",
        "obstype", "proposalid", "piname", "obsid",
    ]
}
