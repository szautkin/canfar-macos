// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import VerbinalKit

/// Cutting a FITS file on this computer: the right pixels, the geometry
/// rewritten so the same sky lands on the same pixel, and checksums that verify.
final class FITSCutterTests: XCTestCase {

    // MARK: - Synthetic files

    private func card(_ key: String, _ value: String) -> String {
        FITSCutter.card(key, value)
    }

    /// A header block: cards, END, space padding.
    private func header(_ cards: [String]) -> Data {
        var bytes = Data((cards + ["END".padding(toLength: 80, withPad: " ", startingAt: 0)]).joined().utf8)
        let r = bytes.count % 2880
        if r != 0 { bytes.append(Data(repeating: 0x20, count: 2880 - r)) }
        return bytes
    }

    /// A 16-bit image, value y*100 + x (scaled by BZERO 1000), with a TAN WCS
    /// at 1″ a pixel whose reference pixel is `crpix`, looking at (ra, dec).
    private func image(width: Int, height: Int, ra: Double, dec: Double, crpix: (Double, Double),
                       first: [String], extra: [String] = []) -> Data {
        var cards = first + [card("BITPIX", "16"), card("NAXIS", "2"), card("NAXIS1", "\(width)"), card("NAXIS2", "\(height)")]
        if first.first?.hasPrefix("XTENSION") == true { cards += [card("PCOUNT", "0"), card("GCOUNT", "1")] }
        cards += extra + [card("BZERO", "1000.0"), card("BSCALE", "1.0"),
                          card("CTYPE1", "'RA---TAN'"), card("CTYPE2", "'DEC--TAN'"),
                          card("CRVAL1", "\(ra)"), card("CRVAL2", "\(dec)"),
                          card("CRPIX1", "\(crpix.0)"), card("CRPIX2", "\(crpix.1)"),
                          card("CD1_1", "-0.000277777778"), card("CD2_2", "0.000277777778")]
        var data = Data()
        for y in 0..<height {
            for x in 0..<width {
                let stored = Int16(y * 100 + x - 1000)
                withUnsafeBytes(of: stored.bigEndian) { data.append(contentsOf: $0) }
            }
        }
        let r = data.count % 2880
        if r != 0 { data.append(Data(repeating: 0, count: 2880 - r)) }
        return header(cards) + data
    }

    private func single() -> Data {
        image(width: 40, height: 30, ra: 150, dec: 2, crpix: (20.5, 15.5), first: [card("SIMPLE", "T")],
              extra: [card("OBJECT", "'Test'")])
    }

    private func mef() -> Data {
        header([card("SIMPLE", "T"), card("BITPIX", "8"), card("NAXIS", "0"), card("EXTEND", "T"), card("OBJECT", "'Mosaic'")])
            + image(width: 40, height: 30, ra: 150, dec: 2, crpix: (20.5, 15.5), first: [card("XTENSION", "'IMAGE   '")],
                    extra: [card("EXTNAME", "'SCI'"), card("EXTVER", "1")])
            + image(width: 40, height: 30, ra: 150.1, dec: 2, crpix: (20.5, 15.5), first: [card("XTENSION", "'IMAGE   '")],
                    extra: [card("EXTNAME", "'SCI'"), card("EXTVER", "2")])
    }

    /// Every HDU of `data` sums to −0.
    private func assertChecksumsVerify(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let parsed = try FITSParser.parse(from: data)
        for (i, hdu) in parsed.hdus.enumerated() {
            let end = i + 1 < parsed.hdus.count ? parsed.hdus[i + 1].headerOffset : data.count
            XCTAssertEqual(FITSChecksum.sum(data[hdu.headerOffset..<end]), 0xFFFF_FFFF, "HDU \(i)", file: file, line: line)
        }
    }

    // MARK: - Checksums

    func testAWrittenHDUSumsToMinusZero() throws {
        let block = try FITSCutter.block(cards: [card("SIMPLE", "T"), card("BITPIX", "8"), card("NAXIS", "1"), card("NAXIS1", "5")],
                                         data: Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(FITSChecksum.sum(block), 0xFFFF_FFFF)
        XCTAssertTrue(String(decoding: block, as: UTF8.self).contains("DATASUM = '"))
        XCTAssertEqual(FITSChecksum.encode(0).count, 16)
        XCTAssertFalse(FITSChecksum.encode(0x1234_5678).contains { ":;<=>?@[\\]^_`".contains($0) }, "no punctuation")
    }

    // MARK: - The box

    func testTheBoxIsThePixelsARegionCovers() throws {
        let file = try FITSParser.parse(from: single())
        let wcs = try XCTUnwrap(file.hdus[0].wcs)
        // 2.2″ around the reference pixel (0-based 19.5, 14.5): x 17.3…21.7, y 12.3…16.7 —
        // the pixels whose squares that touches, 17…22 × 12…17.
        let box = try XCTUnwrap(PixelBox.around(.circle(ra: 150, dec: 2, radius: 2.2 / 3600), wcs: wcs, width: 40, height: 30))
        XCTAssertEqual(box, PixelBox(x0: 17, y0: 12, x1: 23, y1: 18))
        XCTAssertNil(PixelBox.around(.circle(ra: 151, dec: 2, radius: 1.0 / 3600), wcs: wcs, width: 40, height: 30))
        let edge = try XCTUnwrap(PixelBox.around(.circle(ra: 150.0055, dec: 2, radius: 5.0 / 3600), wcs: wcs, width: 40, height: 30))
        XCTAssertEqual(edge.x0, 0, "clamped to the image")
    }

    // MARK: - A cut

    func testACutKeepsThePixelsAndTheSkyOnThem() throws {
        let data = single()
        let file = try FITSParser.parse(from: data)
        let region = SkyRegion.box(ra: 150, dec: 2, width: 6.0 / 3600, height: 4.0 / 3600)
        let parts = try FITSCutter.plan(file, region: region)
        XCTAssertEqual(parts.map(\.name), ["0"])
        let box = parts[0].box
        let cut = try FITSCutter.cut(data, file: file, parts: parts, history: "Verbinal cutout of test.fits")
        try assertChecksumsVerify(cut)

        let result = try FITSParser.parse(from: cut)
        XCTAssertEqual(result.hdus.count, 1)
        let hdu = result.hdus[0]
        XCTAssertEqual([hdu.header.naxis1, hdu.header.naxis2], [box.width, box.height])
        XCTAssertEqual(hdu.header.bitpix, 16, "the same BITPIX")
        XCTAssertEqual(hdu.header.bzero, 1000)
        XCTAssertEqual(hdu.header.string("OBJECT"), "Test")
        XCTAssertEqual(hdu.header.double("LTV1"), -Double(box.x0))
        XCTAssertEqual(hdu.header.double("LTV2"), -Double(box.y0))

        // The same pixel values: y*100 + x of the whole image.
        let pixels = try FITSParser.extractPixels(from: cut, hdu: hdu)
        XCTAssertEqual(pixels[0], Float(box.y0 * 100 + box.x0))
        XCTAssertEqual(pixels[box.width + 1], Float((box.y0 + 1) * 100 + box.x0 + 1))

        // The same sky on the same pixel, shifted by the box's corner.
        let whole = try XCTUnwrap(file.hdus[0].wcs).worldToPixel(ra: 150.0003, dec: 2.0002)!
        let part = try XCTUnwrap(hdu.wcs).worldToPixel(ra: 150.0003, dec: 2.0002)!
        XCTAssertEqual(part.x, whole.x - Double(box.x0), accuracy: 1e-9)
        XCTAssertEqual(part.y, whole.y - Double(box.y0), accuracy: 1e-9)
        XCTAssertTrue(String(decoding: cut, as: UTF8.self).contains("HISTORY Verbinal cutout of test.fits [\(box.x0 + 1):\(box.x1),\(box.y0 + 1):\(box.y1)]"))
    }

    func testAMosaicKeepsItsPrimaryAndTheImagesTheRegionFallsOn() throws {
        let data = mef()
        let file = try FITSParser.parse(from: data)
        XCTAssertEqual(FITSCutter.images(of: file).map(FITSCutter.name(of:)), ["SCI,1", "SCI,2"])
        let parts = try FITSCutter.plan(file, region: .circle(ra: 150, dec: 2, radius: 3.0 / 3600))
        XCTAssertEqual(parts.map(\.name), ["SCI,1"], "SCI,2 looks elsewhere")
        let cut = try FITSCutter.cut(data, file: file, parts: parts, history: "cut")
        try assertChecksumsVerify(cut)
        let result = try FITSParser.parse(from: cut)
        XCTAssertEqual(result.hdus.count, 2)
        XCTAssertEqual(result.hdus[0].header.naxis, 0)
        XCTAssertEqual(result.hdus[0].header.string("OBJECT"), "Mosaic")
        XCTAssertEqual(result.hdus[1].header.string("EXTNAME"), "SCI")
        XCTAssertEqual(result.hdus[1].header.int("EXTVER"), 1)

        XCTAssertThrowsError(try FITSCutter.plan(file, region: .circle(ra: 150, dec: 2, radius: 0.001), images: ["SCI,3"])) { error in
            XCTAssertEqual(error as? FITSCutter.Failure, .unknownImage("SCI,3", available: ["SCI,1", "SCI,2"]))
        }
        XCTAssertThrowsError(try FITSCutter.plan(file, region: .circle(ra: 200, dec: 2, radius: 0.001))) { error in
            XCTAssertEqual(error as? FITSCutter.Failure, .offImage)
        }
    }

    /// A primary image cut together with an extension becomes a primary that says EXTEND.
    func testAPrimaryImageCutWithAnExtensionSaysExtend() throws {
        let data = single() + image(width: 40, height: 30, ra: 150, dec: 2, crpix: (20.5, 15.5),
                                    first: [card("XTENSION", "'IMAGE   '")], extra: [card("EXTNAME", "'WHT'")])
        let file = try FITSParser.parse(from: data)
        let parts = try FITSCutter.plan(file, region: .circle(ra: 150, dec: 2, radius: 3.0 / 3600))
        XCTAssertEqual(parts.map(\.name), ["0", "WHT"])
        let cut = try FITSCutter.cut(data, file: file, parts: parts, history: "cut")
        try assertChecksumsVerify(cut)
        let result = try FITSParser.parse(from: cut)
        XCTAssertEqual(result.hdus.count, 2)
        XCTAssertTrue(result.hdus[0].header.bool("EXTEND"))
    }

    // MARK: - Cubes

    /// A 10×8×6 float cube, value z·1000 + y·100 + x, WAVE in metres from 500 nm by 10 nm.
    private func cube() -> Data {
        let cards = [card("SIMPLE", "T"), card("BITPIX", "-32"), card("NAXIS", "3"), card("NAXIS1", "10"), card("NAXIS2", "8"),
                     card("NAXIS3", "6"), card("CTYPE1", "'RA---TAN'"), card("CTYPE2", "'DEC--TAN'"), card("CRVAL1", "150.0"),
                     card("CRVAL2", "2.0"), card("CRPIX1", "5.5"), card("CRPIX2", "4.5"), card("CD1_1", "-0.000277777778"),
                     card("CD2_2", "0.000277777778"), card("CTYPE3", "'WAVE'"), card("CUNIT3", "'m'"), card("CRVAL3", "5.0E-07"),
                     card("CRPIX3", "1.0"), card("CDELT3", "1.0E-08")]
        var data = Data()
        for z in 0..<6 {
            for y in 0..<8 {
                for x in 0..<10 {
                    withUnsafeBytes(of: Float(z * 1000 + y * 100 + x).bitPattern.bigEndian) { data.append(contentsOf: $0) }
                }
            }
        }
        let r = data.count % 2880
        if r != 0 { data.append(Data(repeating: 0, count: 2880 - r)) }
        return header(cards) + data
    }

    func testACubeIsCutToTheChannelsOfABand() throws {
        let data = cube()
        let file = try FITSParser.parse(from: data)
        XCTAssertEqual(FITSCutter.wavelengths(of: file.hdus[0])?.count, 6)
        let parts = try FITSCutter.plan(file, region: .circle(ra: 150, dec: 2, radius: 1.2 / 3600), band: (5.15e-7, 5.35e-7))
        XCTAssertEqual(parts.first?.channels, 2..<4, "520 and 530 nm")
        let cut = try FITSCutter.cut(data, file: file, parts: parts, history: "cut")
        try assertChecksumsVerify(cut)
        let result = try FITSParser.parse(from: cut).hdus[0]
        XCTAssertEqual(result.header.int("NAXIS3"), 2)
        XCTAssertEqual(result.header.double("CRPIX3"), -1, "channel 2 is the first now")
        let box = parts[0].box
        let first = cut[result.dataOffset..<(result.dataOffset + 4)]
        let value = Float(bitPattern: first.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
        XCTAssertEqual(value, Float(2000 + box.y0 * 100 + box.x0))
        XCTAssertTrue(String(decoding: cut, as: UTF8.self).contains(",3:4]"), "the channels in the HISTORY section")

        XCTAssertThrowsError(try FITSCutter.plan(file, region: .circle(ra: 150, dec: 2, radius: 0.001), band: (1e-6, 2e-6))) {
            XCTAssertEqual($0 as? FITSCutter.Failure, .outsideBand)
        }
        let whole = try FITSCutter.plan(file, region: .circle(ra: 150, dec: 2, radius: 0.001))
        XCTAssertNil(whole.first?.channels, "no band keeps every channel")
    }

    func testSpectralAxesGiveWavelengths() throws {
        let freq = SpectralWCS(ctype: "FREQ", cunit: "GHz", restfrq: nil, table: nil, crval: 230, crpix: 1, cdelt: 1)
        XCTAssertEqual(try XCTUnwrap(freq.wavelengthMetres(atChannel: 0)), 299_792_458 / 230e9, accuracy: 1e-12)
        let wavenumber = SpectralWCS(ctype: "WAVN", cunit: "cm-1", restfrq: nil, table: nil, crval: 1000, crpix: 1, cdelt: 1)
        XCTAssertEqual(try XCTUnwrap(wavenumber.wavelengthMetres(atChannel: 0)), 1e-5, accuracy: 1e-15)
        let radio = SpectralWCS(ctype: "VRAD", cunit: "km/s", restfrq: 1e9, table: nil, crval: 0, crpix: 1, cdelt: 1)
        XCTAssertEqual(try XCTUnwrap(radio.wavelengthMetres(atChannel: 0)), 0.299792458, accuracy: 1e-12, "at rest")
        XCTAssertNil(SpectralWCS(ctype: "STOKES", cunit: "", restfrq: nil, table: nil, crval: 1, crpix: 1, cdelt: 1).wavelengthMetres(atChannel: 0))
    }
}
