// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

/// Hard limits enforced by the FITS parsing/decompression layer.
///
/// Centralised here so that any extension consuming `VerbinalKit` (Quick Look,
/// File Provider, App Intents, etc.) gets the same caps as the host app
/// without having to reach into UI-side constants.
public enum FITSLimits {
    /// Maximum FITS file size accepted (4 GB).
    public static let maxFileSize: Int = 4 * 1024 * 1024 * 1024
    /// Maximum image pixel count accepted (500 Mpx).
    public static let maxPixels: Int = 500_000_000
    /// Maximum decompressed tile size in bytes (64 MB per tile).
    public static let maxTileBytes: Int = 64 * 1024 * 1024
}
