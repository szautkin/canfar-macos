// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VerbinalKit

/// SIP distortion against astropy 7.2 (`all_pix2world` / `all_world2pix`,
/// origin 0) on a WFC3/UVIS-shaped TAN-SIP header whose distortion reaches
/// 8.4 px at the chip corners. Values from `scripts/reference/sip_astropy.py`.
final class SIPDistortionTests: XCTestCase {

    private static let linear: [String: String] = [
        "NAXIS": "2", "NAXIS1": "4096", "NAXIS2": "2051",
        "CRPIX1": "2048.0", "CRPIX2": "1026.0",
        "CRVAL1": "150.1163213", "CRVAL2": "2.2009211",
        "CD1_1": "-8.5E-06", "CD1_2": "-9.8E-06", "CD2_1": "-1.02E-05", "CD2_2": "8.1E-06",
    ]

    private static let forwardTerms: [String: Double] = [
        "A_2_0": -2.9e-07, "A_1_1": 6.1e-07, "A_0_2": -2.2e-06, "A_3_0": 1.1e-11, "A_2_1": -3.0e-11,
        "A_1_2": 1.8e-11, "A_0_3": -2.4e-11, "A_4_0": 2.0e-15, "A_2_2": -4.0e-15, "A_0_4": 3.0e-15,
        "B_2_0": 4.4e-07, "B_1_1": -1.9e-06, "B_0_2": 5.3e-07, "B_3_0": -1.5e-11, "B_2_1": 2.2e-11,
        "B_1_2": -2.7e-11, "B_0_3": 1.3e-11, "B_4_0": -1.0e-15, "B_1_3": 2.5e-15, "B_0_4": -2.0e-15,
    ]

    /// AP/BP least-squares fitted to the forward terms (residual 3e-5 px).
    private static let inverseTerms: [String: Double] = [
        "AP_0_0": 5.647123411670202e-12, "AP_0_1": -8.689674852586905e-09,
        "AP_0_2": 2.2000002743134132e-06, "AP_0_3": 2.0339783331988427e-11,
        "AP_0_4": -3.1232036435266233e-15, "AP_1_0": 1.3077630672043593e-08,
        "AP_1_1": -6.099988705703041e-07, "AP_1_2": -7.675427991547332e-12,
        "AP_1_3": 4.04159009831568e-16, "AP_2_0": 2.899987403850097e-07,
        "AP_2_1": 2.6390631846649473e-11, "AP_2_2": 3.672650005957468e-15,
        "AP_3_0": -1.0578158911700902e-11, "AP_3_1": 1.9814757350715478e-16,
        "AP_4_0": -2.035848680965783e-15,
        "BP_0_0": -1.858548697396285e-12, "BP_0_1": 2.909617368360389e-08,
        "BP_0_2": -5.299994398738122e-07, "BP_0_3": -8.301477499578002e-12,
        "BP_0_4": 2.121922939331785e-15, "BP_1_0": -2.975652538669906e-08,
        "BP_1_1": 1.8999975959976518e-06, "BP_1_2": 2.093209109680197e-11,
        "BP_1_3": -2.7736493651328782e-15, "BP_2_0": -4.399986794925972e-07,
        "BP_2_1": -1.6866328561843802e-11, "BP_2_2": 3.714495999342937e-16,
        "BP_3_0": 1.393196609143943e-11, "BP_3_1": -1.9169493558545555e-16,
        "BP_4_0": 1.0571786060500453e-15,
    ]

    /// Pixel (0-based) → sky, from astropy.
    private static let astropy: [(x: Double, y: Double, ra: Double, dec: Double)] = [
        (x: 0.0, y: 0.0, ra: 150.14381996721932, dec: 2.2135078995422295),
        (x: 4095.0, y: 0.0, ra: 150.1089317514886, dec: 2.1718240443074293),
        (x: 0.0, y: 2050.0, ra: 150.12365924222985, dec: 2.2302086491237443),
        (x: 4095.0, y: 2050.0, ra: 150.08888385257538, dec: 2.188343080229709),
        (x: 2047.0, y: 1025.0, ra: 150.1163213, dec: 2.200921100000002),
        (x: 1000.0, y: 1500.0, ra: 150.12056325485568, dec: 2.2154725470094374),
        (x: 3500.0, y: 300.0, ra: 150.11106121678165, dec: 2.1802765745869976),
        (x: 2047.5, y: 1025.5, ra: 150.11631214325135, dec: 2.2009200500028765),
    ]

    private func header(ctype sip: Bool = true, inverse: Bool = false) -> FITSHeader {
        var h = FITSHeader()
        let suffix = sip ? "-SIP" : ""
        h.add(FITSCard(keyword: "CTYPE1", value: "'RA---TAN\(suffix)'", comment: ""))
        h.add(FITSCard(keyword: "CTYPE2", value: "'DEC--TAN\(suffix)'", comment: ""))
        for (k, v) in Self.linear { h.add(FITSCard(keyword: k, value: v, comment: "")) }
        h.add(FITSCard(keyword: "A_ORDER", value: "4", comment: ""))
        h.add(FITSCard(keyword: "B_ORDER", value: "4", comment: ""))
        for (k, v) in Self.forwardTerms { h.add(FITSCard(keyword: k, value: "\(v)", comment: "")) }
        if inverse {
            h.add(FITSCard(keyword: "AP_ORDER", value: "4", comment: ""))
            h.add(FITSCard(keyword: "BP_ORDER", value: "4", comment: ""))
            for (k, v) in Self.inverseTerms { h.add(FITSCard(keyword: k, value: "\(v)", comment: "")) }
        }
        return h
    }

    func testPixelToSkyMatchesAstropy() throws {
        let wcs = try XCTUnwrap(FITSWCSTransform.fromHeader(header()))
        XCTAssertNotNil(wcs.sip)
        for p in Self.astropy {
            let sky = wcs.pixelToWorld(x: p.x, y: p.y)
            // 1e-9° is 3.6 µas — far below the 0.3″ SIP moves a corner.
            XCTAssertEqual(sky.ra, p.ra, accuracy: 1e-9, "RA at (\(p.x), \(p.y))")
            XCTAssertEqual(sky.dec, p.dec, accuracy: 1e-9, "Dec at (\(p.x), \(p.y))")
        }
    }

    /// Only the forward terms: the inverse is solved, not skipped.
    func testSkyToPixelLandsOnItsOwnPixelWithoutAPBP() throws {
        let wcs = try XCTUnwrap(FITSWCSTransform.fromHeader(header()))
        XCTAssertTrue(wcs.sip?.ap.isEmpty ?? false)
        for p in Self.astropy {
            let pixel = try XCTUnwrap(wcs.worldToPixel(ra: p.ra, dec: p.dec))
            XCTAssertEqual(pixel.x, p.x, accuracy: 1e-6)
            XCTAssertEqual(pixel.y, p.y, accuracy: 1e-6)
        }
    }

    /// AP/BP are a starting point; the answer is still the forward's inverse.
    func testSkyToPixelWithAPBPIsRefinedToTheForwardInverse() throws {
        let wcs = try XCTUnwrap(FITSWCSTransform.fromHeader(header(inverse: true)))
        XCTAssertFalse(wcs.sip?.ap.isEmpty ?? true)
        for p in Self.astropy {
            let pixel = try XCTUnwrap(wcs.worldToPixel(ra: p.ra, dec: p.dec))
            XCTAssertEqual(pixel.x, p.x, accuracy: 1e-6)
            XCTAssertEqual(pixel.y, p.y, accuracy: 1e-6)
        }
    }

    func testDistortionMattersAtTheCorners() throws {
        let without = try XCTUnwrap(FITSWCSTransform.fromHeader(header(ctype: false)))
        XCTAssertNil(without.sip, "coefficients without -SIP on CTYPE are not applied")
        // Where a linear WCS would put each true position; astropy's worst
        // corner is 8.4 px off.
        let misses = try Self.astropy.map { p -> Double in
            let naive = try XCTUnwrap(without.worldToPixel(ra: p.ra, dec: p.dec))
            return hypot(naive.x - p.x, naive.y - p.y)
        }
        XCTAssertEqual(try XCTUnwrap(misses.max()), 8.37, accuracy: 0.01)
    }

    func testHeaderReadsADoublePrecisionExponent() {
        var h = FITSHeader()
        h.add(FITSCard(keyword: "A_2_0", value: "-2.9D-07", comment: ""))
        XCTAssertEqual(h.double("A_2_0"), -2.9e-07)
    }
}
