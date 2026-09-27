// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A CAOM publisher ID, `ivo://cadc.nrc.ca/COLLECTION?OBSERVATION/PRODUCT`,
/// read into its parts — what an observation is called when nothing else
/// about it is known.
struct PublisherID: Equatable, Sendable {
    let collection: String
    let observationID: String
    let productID: String

    /// Nil for text that is not an `ivo://…/COLLECTION?OBS/PRODUCT` URI.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("ivo://"),
              let query = trimmed.firstIndex(of: "?") else { return nil }
        let collection = trimmed[..<query].split(separator: "/").last.map(String.init) ?? ""
        let parts = trimmed[trimmed.index(after: query)...].split(separator: "/", maxSplits: 1).map(String.init)
        guard !collection.isEmpty, let observation = parts.first, !observation.isEmpty else { return nil }
        self.collection = collection
        observationID = observation
        productID = parts.count > 1 ? parts[1] : ""
    }
}
