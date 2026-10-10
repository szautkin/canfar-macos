// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import CoreGraphics
import os.log
#if os(macOS)
import AppKit
#endif
import VerbinalKit

/// The crosshair: placing it, and what it says of the pixel under it.
extension FITSViewerModel {
    // MARK: - Crosshair

    /// Clear the crosshair and all associated coordinate/value state.
    func clearCrosshair() {
        crosshairPixel = nil
        crosshairRA = ""
        crosshairDec = ""
        crosshairValue = ""
        crosshairRADeg = nil
        crosshairDecDeg = nil
        crosshairOutOfBounds = false
        outOfBoundsRA = ""
        outOfBoundsDec = ""
    }

    /// Reconcile the crosshair with a newly-selected HDU's bounds: clear it
    /// entirely if it now falls outside, or — when it's still valid (or
    /// absent) — clear any stale out-of-bounds RA/Dec readout left over from a
    /// prior linked operation so the sidebar never shows old out-of-bounds
    /// coordinates on a valid view. Extracted from `selectHDU` for testability.
    func reconcileCrosshair(naxis1: Int, naxis2: Int) {
        guard let crosshair = crosshairPixel else {
            clearStaleOutOfBounds()
            return
        }
        let w = Double(naxis1), h = Double(naxis2)
        if crosshair.x < 0 || crosshair.x >= w || crosshair.y < 0 || crosshair.y >= h {
            Self.logger.info("selectHDU: clearing crosshair out of new HDU bounds (\(crosshair.x), \(crosshair.y)) vs \(naxis1)×\(naxis2)")
            clearCrosshair()
        } else {
            clearStaleOutOfBounds()
        }
    }

    func clearStaleOutOfBounds() {
        guard crosshairOutOfBounds else { return }
        crosshairOutOfBounds = false
        outOfBoundsRA = ""
        outOfBoundsDec = ""
    }

    /// Dispatch a "search at crosshair" action if WCS coordinates are available.
    func searchAtCrosshair() {
        guard let ra = crosshairRADeg, let dec = crosshairDecDeg else { return }
        onSearchAtPosition?(ra, dec)
    }

    #if os(macOS)
    /// Copy the current crosshair RA/Dec to the system clipboard.
    func copyCoordsToClipboard() {
        PlatformClipboard.copy("\(crosshairRA), \(crosshairDec)")
    }
    #endif
}
