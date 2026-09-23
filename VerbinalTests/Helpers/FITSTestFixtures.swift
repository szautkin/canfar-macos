// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit
@testable import Verbinal

/// Shared fixtures for FITS / Cube viewer tests.
@MainActor
enum FITSTestFixtures {

    /// A `.fits`-named temp file whose bytes are a PDF — a mislabeled
    /// download. Caller removes it.
    static func writeNonFITSFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-fits-\(UUID().uuidString).fits")
        try Data("%PDF-1.4 not a FITS file".utf8).write(to: url)
        return url
    }

    /// Loads a synthetic `width`×`height` image into `model` without
    /// touching disk. The sample at FITS array (x, y) is `y * width + x`,
    /// so a read from the mirrored row is caught. `wcsCards` (e.g. CRPIX,
    /// CDELT, PC, CTYPE) produce a WCS through the real header parser.
    static func loadRamp(
        into model: FITSViewerModel,
        width: Int = 100,
        height: Int = 100,
        wcsCards: [(String, String)] = [],
        path: String = "/tmp/ramp.fits"
    ) {
        var header = FITSHeader()
        let base = [("BITPIX", "-32"), ("NAXIS", "2"),
                    ("NAXIS1", "\(width)"), ("NAXIS2", "\(height)")]
        for (keyword, value) in base + wcsCards {
            header.add(FITSCard(keyword: keyword, value: value, comment: ""))
        }
        let hdu = FITSHDUnit(id: 0, header: header, dataOffset: 0,
                             dataLength: width * height * 4,
                             wcs: FITSWCSTransform.fromHeader(header))
        model.file = FITSFile(url: URL(fileURLWithPath: path), hdus: [hdu])
        model.fileURL = model.file?.url
        model.selectedHDUIndex = 0
        model.pixels = (0..<(width * height)).map(Float.init)
    }

    /// Ramp value at FITS array (x, y) for an image `width` columns wide.
    static func rampValue(x: Int, y: Int, width: Int = 100) -> Float {
        Float(y * width + x)
    }
}
