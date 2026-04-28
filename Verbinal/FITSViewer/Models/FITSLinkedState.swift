// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

/// Shared state store for linked tabs (pull-on-activation pattern).
/// Active tab writes here; tabs read on activation.
@Observable
@MainActor
final class FITSLinkedState {
    var sharedCrosshair: WorldPosition?
    var sharedPixel: CGPoint?            // pixel position fallback (for images without WCS)
    var sharedAngularZoom: Double?       // arcsec per screen pixel
    var sharedUserRotation: Double?      // North-relative user rotation (radians)
    var linkCrosshair = false
    var linkZoom = false
}
