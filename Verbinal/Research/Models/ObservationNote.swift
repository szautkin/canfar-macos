// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A user-authored note attached to an observation (keyed by publisherID so the note
/// survives re-download or local file moves — notes live on the *observation*, not the file).
struct ObservationNote: Codable, Equatable {
    var publisherID: String
    var text: String
    /// Quality rating, 0 = unrated, 1–5 = star rating.
    var rating: Int
    /// Free-form tags (e.g. "usable", "calibration", "reprocess").
    var tags: [String]
    var createdAt: Date
    var modifiedAt: Date

    init(publisherID: String,
         text: String = "",
         rating: Int = 0,
         tags: [String] = [],
         createdAt: Date = Date(),
         modifiedAt: Date = Date()) {
        self.publisherID = publisherID
        self.text = text
        self.rating = rating
        self.tags = tags
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && rating == 0 && tags.isEmpty
    }
}
