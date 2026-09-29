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

    /// A small FITS cube on disk: `nx`×`ny`×`nz` float32 with value
    /// `z*100 + y*10 + x`, a TAN celestial WCS and a FREQ axis. The caller
    /// removes it.
    static func writeCube(nx: Int = 4, ny: Int = 3, nz: Int = 5) throws -> URL {
        var data = Data()
        for z in 0..<nz {
            for y in 0..<ny {
                for x in 0..<nx {
                    var be = Float(z * 100 + y * 10 + x).bitPattern.bigEndian
                    data.append(Data(bytes: &be, count: 4))
                }
            }
        }
        let cards: [(String, String)] = [
            ("SIMPLE", "T"), ("BITPIX", "-32"), ("NAXIS", "3"),
            ("NAXIS1", "\(nx)"), ("NAXIS2", "\(ny)"), ("NAXIS3", "\(nz)"),
            ("OBJECT", "'TestObj'"), ("BUNIT", "'Jy'"),
            ("CTYPE1", "'RA---TAN'"), ("CTYPE2", "'DEC--TAN'"),
            ("CRVAL1", "150.0"), ("CRVAL2", "2.0"), ("CRPIX1", "2.0"), ("CRPIX2", "1.5"),
            ("CD1_1", "-0.001"), ("CD2_2", "0.001"),
            ("CTYPE3", "'FREQ'"), ("CUNIT3", "'Hz'"),
            ("CRVAL3", "1000000000.0"), ("CRPIX3", "1.0"), ("CDELT3", "1000000.0"),
            ("RESTFRQ", "1000000000.0"),
        ]
        var header = ""
        for (k, v) in cards {
            let key = k.padding(toLength: 8, withPad: " ", startingAt: 0)
            header += String((key + "= " + v).prefix(80)).padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        header += "END".padding(toLength: 80, withPad: " ", startingAt: 0)

        func pad(_ data: inout Data, with byte: UInt8) {
            let rem = data.count % 2880
            if rem != 0 { data.append(Data(repeating: byte, count: 2880 - rem)) }
        }
        var bytes = Data(header.utf8)
        pad(&bytes, with: 0x20)   // space-pad header to 2880
        pad(&data, with: 0x00)    // zero-pad data to 2880
        bytes.append(data)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cube-\(UUID().uuidString).fits")
        try bytes.write(to: url)
        return url
    }

    /// An HST `_x1d`-shaped file on disk: an empty primary HDU, then a
    /// table of one row whose WAVELENGTH (D, Angstroms) and FLUX (E) are
    /// arrays of four: 5000, 5010, 5020, 5030 Å and 1, 2, 3, 4 × 10⁻¹⁴.
    /// The caller removes it.
    static func writeSpectrumTable() throws -> URL {
        func block(_ cards: [(String, String)]) -> Data {
            var text = cards.map { k, v in
                String((k.padding(toLength: 8, withPad: " ", startingAt: 0) + "= " + v).prefix(80))
                    .padding(toLength: 80, withPad: " ", startingAt: 0)
            }.joined()
            text += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
            var data = Data(text.utf8)
            data.append(Data(repeating: 0x20, count: (2880 - data.count % 2880) % 2880))
            return data
        }
        var bytes = block([("SIMPLE", "T"), ("BITPIX", "8"), ("NAXIS", "0"), ("EXTEND", "T")])
        bytes += block([("XTENSION", "'BINTABLE'"), ("BITPIX", "8"), ("NAXIS", "2"), ("NAXIS1", "48"), ("NAXIS2", "1"),
                        ("PCOUNT", "0"), ("GCOUNT", "1"), ("TFIELDS", "2"),
                        ("TTYPE1", "'WAVELENGTH'"), ("TFORM1", "'4D'"), ("TUNIT1", "'Angstroms'"),
                        ("TTYPE2", "'FLUX'"), ("TFORM2", "'4E'"), ("TUNIT2", "'erg/s/cm**2/Angstrom'"),
                        ("EXTNAME", "'SCI'")])
        var row = Data()
        for w in [5000.0, 5010, 5020, 5030] {
            var be = w.bitPattern.bigEndian
            row.append(Data(bytes: &be, count: 8))
        }
        for f in [1e-14, 2e-14, 3e-14, 4e-14] as [Float] {
            var be = f.bitPattern.bigEndian
            row.append(Data(bytes: &be, count: 4))
        }
        row.append(Data(repeating: 0, count: 2880 - row.count))
        bytes += row
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x1d-\(UUID().uuidString).fits")
        try bytes.write(to: url)
        return url
    }
}
