// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// What a search's "Spatial cutout" and "Spectral cutout" boxes ask of a
/// download from its results — the search's circle and wavelengths — and
/// what a cutout editor opened from it starts from.
struct SearchCutout: Equatable, Sendable {
    var hints: CutoutHints?
    var spatial = false
    var spectral = false

    /// A download from the search should be a cutout, when the file allows.
    var isRequested: Bool { (spatial || spectral) && hints != nil }

    /// The cutout of `file` the boxes ask for; nil for the whole file.
    func spec(for file: CutoutFile) -> CutoutSpec? {
        guard isRequested else { return nil }
        return CutoutPrefill.fromSearchFlags(file, hints: hints, spatial: spatial, spectral: spectral)
    }
}
