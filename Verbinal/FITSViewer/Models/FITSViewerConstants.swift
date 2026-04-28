// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import VerbinalKit

/// Namespace for FITS viewer magic numbers.
/// Hard parser limits (max file size, max pixels, max tile bytes) live in
/// `VerbinalKit.FITSLimits` so both the host app and any FITS-aware
/// extension (Quick Look, etc.) enforce the same caps.
enum FITSViewerConstants {
    /// Minimum permitted viewport zoom level.
    static let zoomMin: Double = 0.05
    /// Maximum permitted viewport zoom level.
    static let zoomMax: Double = 20.0
    /// Fraction of the canvas used when fitting image to window (5% margin).
    static let fitMargin: Double = 0.95
    /// Multiplicative step applied per scroll-wheel tick when zooming.
    static let scrollZoomFactor: Double = 1.15
    /// Viewport zoom threshold above which a crosshair click auto-centers the view.
    static let autoCenterThreshold: Double = 1.05
    /// Debounce delay in milliseconds for slider-driven renders.
    static let renderDebounceMs: Int = 80

    // Re-exports of the parser caps so existing call sites (e.g. AppState's
    // file-size guard) keep working unchanged.
    static var maxFileSize: Int { FITSLimits.maxFileSize }
    static var maxPixels: Int { FITSLimits.maxPixels }
    static var maxTileBytes: Int { FITSLimits.maxTileBytes }
}
