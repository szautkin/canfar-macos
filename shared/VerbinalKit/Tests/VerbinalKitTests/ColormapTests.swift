// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VerbinalKit

/// The perceptual maps are matplotlib's own tables, so a figure labelled
/// VIRIDIS matches astropy and ds9. Values from matplotlib 3.10.8.
final class ColormapTests: XCTestCase {

    private func entry(_ type: FITSRenderParams.ColormapType, _ i: Int) -> [UInt8] {
        let lut = FITSRenderEngine.colormapRGBA(type)
        return Array(lut[i * 4 ..< i * 4 + 3])
    }

    func testPerceptualMapsMatchMatplotlib() {
        let expected: [(FITSRenderParams.ColormapType, [[UInt8]])] = [
            (.viridis, [[68, 1, 84], [33, 145, 140], [253, 231, 37]]),
            (.inferno, [[0, 0, 4], [188, 55, 84], [252, 255, 164]]),
            (.magma, [[0, 0, 4], [183, 55, 121], [252, 253, 191]]),
            (.plasma, [[13, 8, 135], [204, 71, 120], [240, 249, 33]]),
        ]
        for (type, stops) in expected {
            XCTAssertEqual(entry(type, 0), stops[0], "\(type) first")
            XCTAssertEqual(entry(type, 128), stops[1], "\(type) middle")
            XCTAssertEqual(entry(type, 255), stops[2], "\(type) last")
        }
    }

    /// The defining property of these maps: they only get lighter.
    func testPerceptualMapsGetLighterAlongTheRamp() {
        for type in [FITSRenderParams.ColormapType.viridis, .inferno, .magma, .plasma] {
            let luma = stride(from: 0, to: 256, by: 16).map { i -> Double in
                let c = entry(type, i).map(Double.init)
                return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
            }
            XCTAssertEqual(luma, luma.sorted(), "\(type) luminance must rise")
            XCTAssertEqual(Set(luma).count, luma.count, "\(type) luminance must strictly rise")
        }
    }

    func testEveryMapHasOpaqueAlpha() {
        for type in FITSRenderParams.ColormapType.allCases {
            let lut = FITSRenderEngine.colormapRGBA(type)
            XCTAssertEqual(lut.count, 256 * 4)
            XCTAssertTrue(stride(from: 3, to: lut.count, by: 4).allSatisfy { lut[$0] == 255 }, "\(type)")
        }
    }
}
