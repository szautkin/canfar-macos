// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A parsed FITS file containing one or more HDUs.
public struct FITSFile: Sendable {
    public let url: URL
    public let hdus: [FITSHDUnit]

    public init(url: URL, hdus: [FITSHDUnit]) {
        self.url = url
        self.hdus = hdus
    }

    /// First image HDU (NAXIS >= 2).
    public var firstImageHDU: FITSHDUnit? {
        hdus.first { $0.header.naxis >= 2 && $0.header.naxis1 > 0 && $0.header.naxis2 > 0 }
    }
}

/// A single Header-Data Unit.
public struct FITSHDUnit: Sendable, Identifiable {
    public let id: Int // HDU index
    public let header: FITSHeader
    public let dataOffset: Int     // byte offset in file
    public let dataLength: Int     // byte length of data segment
    public let wcs: FITSWCSTransform?

    public init(id: Int, header: FITSHeader, dataOffset: Int, dataLength: Int, wcs: FITSWCSTransform?) {
        self.id = id
        self.header = header
        self.dataOffset = dataOffset
        self.dataLength = dataLength
        self.wcs = wcs
    }

    public var isImage: Bool { header.naxis >= 2 && header.naxis1 > 0 && header.naxis2 > 0 }
    public var label: String { "HDU \(id)\(isImage ? " [\(header.naxis1)×\(header.naxis2)]" : "")" }
}

/// Render parameters (value type, drives Metal uniforms).
public struct FITSRenderParams: Sendable, Equatable {
    public var minCut: Float = 0
    public var maxCut: Float = 1
    public var stretch: StretchMode = .linear
    public var colormap: ColormapType = .grayscale

    public init(minCut: Float = 0, maxCut: Float = 1, stretch: StretchMode = .linear, colormap: ColormapType = .grayscale) {
        self.minCut = minCut
        self.maxCut = maxCut
        self.stretch = stretch
        self.colormap = colormap
    }

    public enum StretchMode: String, CaseIterable, Identifiable, Sendable {
        case linear, log, sqrt, squared, asinh
        public var id: String { rawValue }
    }

    public enum ColormapType: String, CaseIterable, Identifiable, Sendable {
        case grayscale, inverted, heat, cool, viridis, inferno, magma, plasma
        public var id: String { rawValue }
    }
}

/// Viewport state (value type).
public struct FITSViewport: Sendable, Equatable {
    public var zoom: Double = 1.0
    public var panX: Double = 0
    public var panY: Double = 0
    public var rotation: Double = 0 // radians
    public var flipX: Bool = false   // horizontal mirror for parity-flipped WCS

    public init(zoom: Double = 1.0, panX: Double = 0, panY: Double = 0, rotation: Double = 0, flipX: Bool = false) {
        self.zoom = zoom
        self.panX = panX
        self.panY = panY
        self.rotation = rotation
        self.flipX = flipX
    }
}

/// Sky position with RA and Dec (degrees). Sendable value type for safe cross-actor use.
public struct WorldPosition: Sendable {
    public let ra: Double
    public let dec: Double

    public init(ra: Double, dec: Double) {
        self.ra = ra
        self.dec = dec
    }
}

public enum FITSError: LocalizedError {
    case invalidFile(String)
    case unsupportedBitpix(Int)
    case noImageHDU

    public var errorDescription: String? {
        switch self {
        case .invalidFile(let msg): return "Invalid FITS: \(msg)"
        case .unsupportedBitpix(let bp): return "Unsupported BITPIX: \(bp)"
        case .noImageHDU: return "No image HDU found"
        }
    }
}
