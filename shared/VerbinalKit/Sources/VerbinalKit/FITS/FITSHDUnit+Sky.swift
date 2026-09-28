// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

extension FITSHDUnit {
    /// The image's corners on the sky, from its WCS — for a cube, its first
    /// two axes; empty without a WCS.
    public var skyCorners: [SkyPoint] {
        guard let wcs else { return [] }
        let w = Double(header.naxis1) - 0.5, h = Double(header.naxis2) - 0.5
        return [(-0.5, -0.5), (w, -0.5), (w, h), (-0.5, h)].map {
            let sky = wcs.pixelToWorld(x: $0.0, y: $0.1)
            return SkyPoint(ra: sky.ra, dec: sky.dec)
        }
    }
}
