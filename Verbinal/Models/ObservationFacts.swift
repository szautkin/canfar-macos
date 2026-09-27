// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// What "Copy Details" copies about an observation. Built from a search
/// result or a Research record, and written by one formatter, so the text
/// reads the same from Search, Research and an agent's `copy_to_clipboard`.
struct ObservationFacts: Equatable, Sendable {
    var observationID = ""
    var collection = ""
    var publisherID = ""
    var target = ""
    var ra: Double?
    var dec: Double?
    var instrument = ""
    var filter = ""
    var date = ""
    var calibrationLevel = ""
    var proposal = ""
    var release = ""

    /// The position as the Search box, Simbad and DS9 read it, with the
    /// degrees beside it: `00:42:44.33 +41:16:09.0 (10.684708°, +41.269167°)`.
    var position: String? {
        guard let ra, let dec, let pair = Sexagesimal.searchPair(ra: ra, dec: dec) else { return nil }
        return "\(pair) (\(String(format: "%.6f", ra))°, \(String(format: "%+.6f", dec))°)"
    }

    /// One "Label: value" line per known fact; empty facts are left out.
    var detailsText: String {
        let lines: [(String, String)] = [
            ("Observation", observationID), ("Collection", collection), ("Publisher ID", publisherID),
            ("Target", target), ("Position", position ?? ""), ("Instrument", instrument), ("Filter", filter),
            ("Date", date), ("Calibration level", calibrationLevel), ("Proposal", proposal), ("Release", release),
        ]
        return lines.filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }
}

extension DownloadedObservation {
    var facts: ObservationFacts {
        ObservationFacts(
            observationID: observationID, collection: collection, publisherID: publisherID, target: targetName,
            ra: Sexagesimal.rightAscension(ra), dec: Sexagesimal.declination(dec),
            instrument: instrument, filter: filter, date: startDate, calibrationLevel: calLevel)
    }
}
