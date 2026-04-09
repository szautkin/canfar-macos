// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A parsed FITS file containing one or more HDUs.
struct FITSFile: Sendable {
    let url: URL
    let hdus: [FITSHDUnit]

    /// First image HDU (NAXIS >= 2).
    var firstImageHDU: FITSHDUnit? {
        hdus.first { $0.header.naxis >= 2 && $0.header.naxis1 > 0 && $0.header.naxis2 > 0 }
    }
}

/// A single Header-Data Unit.
struct FITSHDUnit: Sendable, Identifiable {
    let id: Int // HDU index
    let header: FITSHeader
    let dataOffset: Int     // byte offset in file
    let dataLength: Int     // byte length of data segment
    let wcs: FITSWCSTransform?

    var isImage: Bool { header.naxis >= 2 && header.naxis1 > 0 && header.naxis2 > 0 }
    var label: String { "HDU \(id)\(isImage ? " [\(header.naxis1)×\(header.naxis2)]" : "")" }
}

/// Render parameters (value type, drives Metal uniforms).
struct FITSRenderParams: Sendable, Equatable {
    var minCut: Float = 0
    var maxCut: Float = 1
    var stretch: StretchMode = .linear
    var colormap: ColormapType = .grayscale

    enum StretchMode: String, CaseIterable, Identifiable, Sendable {
        case linear, log, sqrt, squared, asinh
        var id: String { rawValue }
    }

    enum ColormapType: String, CaseIterable, Identifiable, Sendable {
        case grayscale, inverted, heat, cool, viridis
        var id: String { rawValue }
    }
}

/// Viewport state (value type).
struct FITSViewport: Sendable, Equatable {
    var zoom: Double = 1.0
    var panX: Double = 0
    var panY: Double = 0
    var rotation: Double = 0 // radians
    var flipX: Bool = false   // horizontal mirror for parity-flipped WCS
}

/// Sky position with RA and Dec (degrees). Sendable value type for safe cross-actor use.
struct WorldPosition: Sendable {
    let ra: Double
    let dec: Double
}

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

enum FITSError: LocalizedError {
    case invalidFile(String)
    case unsupportedBitpix(Int)
    case noImageHDU

    var errorDescription: String? {
        switch self {
        case .invalidFile(let msg): return "Invalid FITS: \(msg)"
        case .unsupportedBitpix(let bp): return "Unsupported BITPIX: \(bp)"
        case .noImageHDU: return "No image HDU found"
        }
    }
}
