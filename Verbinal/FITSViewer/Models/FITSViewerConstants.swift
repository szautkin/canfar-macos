// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

/// Namespace for FITS viewer magic numbers.
/// All viewer-wide numeric constants live here so call sites are self-documenting.
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
    /// Maximum FITS file size accepted (4 GB).
    static let maxFileSize: Int = 4 * 1024 * 1024 * 1024
    /// Maximum pixel count accepted (500 Mpx cap matches FITSParser).
    static let maxPixels: Int = 500_000_000
    /// Maximum decompressed tile size in bytes (64 MB per tile).
    static let maxTileBytes: Int = 64 * 1024 * 1024
}
