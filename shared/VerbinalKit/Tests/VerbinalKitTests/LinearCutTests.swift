// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VerbinalKit

/// The first look under a linear stretch (plan 15 V3, QA M5: the auto-cut
/// washed out a JWST deep field — its faint galaxies and noise above
/// median + 3σ all white, the sky mid-grey; a cube's window rendered black).
final class LinearCutTests: XCTestCase {

    /// A deterministic deep field: sky N(100, 5) for most pixels, faint
    /// galaxy wings 110–200, a few bright cores up to 5000.
    private func deepField(count: Int = 60_000, border: Double = 0) -> [Float] {
        var state: UInt64 = 42
        func uniform() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        return (0..<count).map { _ in
            let u = uniform()
            if u < border { return 0 }
            let r = (u - border) / (1 - border)
            if r < 0.85 {   // Box–Muller sky
                return Float(100 + 5 * (-2 * log(max(uniform(), 1e-12))).squareRoot() * cos(2 * .pi * uniform()))
            }
            if r < 0.97 { return Float(110 + 90 * uniform()) }
            return Float(200 + 4800 * uniform())
        }
    }

    private func saturated(_ pixels: [Float], above hi: Float) -> Double {
        Double(pixels.filter { $0 >= hi }.count) / Double(pixels.count)
    }

    func testADeepFieldKeepsItsBackgroundDarkAndItsGalaxies() {
        let field = deepField()
        let cut = LinearCut.firstLook(samples: field)
        XCTAssertLessThan(saturated(field, above: cut.hi), 0.015, "only the brightest part is white")
        XCTAssertLessThan((100 - cut.lo) / (cut.hi - cut.lo), 0.3, "the sky is dark: \(cut)")
        XCTAssertGreaterThan(cut.lo, 80, "black is a little below the sky, not far below it")
        XCTAssertGreaterThan(cut.hi, 200, "faint galaxies have room above the sky")
    }

    /// A mosaic with a zero-filled border: the border is not the sky.
    func testAFillBorderIsNotTakenForTheSky() {
        let mosaic = deepField(border: 0.6)
        let cut = LinearCut.firstLook(samples: mosaic)
        XCTAssertGreaterThan(cut.lo, 80, "\(cut)")
        XCTAssertLessThan((100 - cut.lo) / (cut.hi - cut.lo), 0.3, "\(cut)")
    }

    /// A pure-noise frame has no bright part; its white point stays well above the noise.
    func testNoiseAloneIsNotStretchedToWhite() {
        let noise = deepField().filter { abs($0 - 100) < 25 }
        let cut = LinearCut.firstLook(samples: noise)
        XCTAssertGreaterThanOrEqual(cut.hi, 120, "\(cut)")
    }

    func testDegenerateInputs() {
        XCTAssertTrue(LinearCut.firstLook(samples: []) == (0, 1))
        XCTAssertTrue(LinearCut.firstLook(samples: [.nan, .infinity]) == (0, 1))
        let one = LinearCut.firstLook(samples: [42])
        XCTAssertLessThanOrEqual(one.lo, one.hi)
        let flat = LinearCut.firstLook(samples: [Float](repeating: 7, count: 100))
        XCTAssertLessThanOrEqual(flat.lo, flat.hi)
    }

    /// The FITS viewer's Auto and first look are this cut.
    func testTheFITSAutoCutIsTheFirstLook() {
        let field = deepField()
        let auto = FITSParser.autoCut(pixels: field)
        let look = LinearCut.firstLook(samples: field)
        XCTAssertEqual(auto.min, look.lo)
        XCTAssertEqual(auto.max, look.hi)
    }
}
