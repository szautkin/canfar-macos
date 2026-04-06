// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A saved RA/Dec position for quick navigation in the FITS viewer.
struct CoordinateBookmark: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    let ra: Double
    let dec: Double
    let sourceFilePath: String
    let savedAt: Date

    var formattedCoords: String {
        "\(FITSWCSTransform.formatRA(ra))  \(FITSWCSTransform.formatDec(dec))"
    }

    init(label: String, ra: Double, dec: Double, sourceFilePath: String) {
        self.id = UUID()
        self.label = label
        self.ra = ra
        self.dec = dec
        self.sourceFilePath = sourceFilePath
        self.savedAt = Date()
    }
}
