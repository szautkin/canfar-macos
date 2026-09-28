// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import XCTest
import VerbinalKit
@testable import Verbinal

/// get_cube_image shows what the viewer shows (plan 15 V2, QA M4, L11): the
/// slice at the size asked for, the viewer's own background, the spectrum.
@MainActor
final class CubeViewPictureTests: XCTestCase {

    private var cubeURL: URL!

    override func tearDown() {
        if let cubeURL { try? FileManager.default.removeItem(at: cubeURL) }
    }

    private func openCube() async throws -> CubeViewerModel {
        cubeURL = try FITSTestFixtures.writeCube()
        let model = CubeViewerModel()
        await model.open(url: cubeURL)
        XCTAssertTrue(model.hasData)
        for _ in 0..<100 where model.sliceImage == nil { try await Task.sleep(for: .milliseconds(20)) }
        _ = try XCTUnwrap(model.sliceImage, "the slice is drawn")
        return model
    }

    private func rgb(_ image: CGImage, _ u: Int, _ v: Int) -> [Int] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -u, y: -(image.height - 1 - v), width: image.width, height: image.height))
        return pixel.prefix(3).map(Int.init)
    }

    /// The 4×3 slice comes back at the size asked for, not 4×3.
    func testTheSliceIsTheSizeAskedFor() async throws {
        let model = try await openCube()
        let picture = try XCTUnwrap(CubeViewPicture.render(model: model, marks: [], maxSide: 800))
        XCTAssertEqual(picture.width, 800)
        XCTAssertEqual(picture.height, 600)
    }

    /// A probed spectrum is under the image, on the viewer's background.
    func testTheSpectrumIsUnderItOnTheViewersBackground() async throws {
        let model = try await openCube()
        model.background = .dark
        await model.probe(x: 1, y: 1)
        XCTAssertTrue(CubeViewPicture.showsSpectrum(model))

        let picture = try XCTUnwrap(CubeViewPicture.render(model: model, marks: [], maxSide: 400))
        XCTAssertEqual(picture.width, 400)
        XCTAssertGreaterThan(picture.height, 300, "the spectrum strip is under the 400×300 slice")
        let corner = rgb(picture, 2, picture.height - 2)
        XCTAssertLessThan(corner.max() ?? 255, 40, "dark, as the viewer says — not white: \(corner)")
    }

    // MARK: - The first look (plan 15 V3, QA M5)

    /// A cube opens on the first look, not on p0.1–p99.9; Auto and R return to it.
    func testACubeOpensOnTheFirstLook() async throws {
        let model = try await openCube()
        let stats = try XCTUnwrap(model.stats)
        var voxels: [Float] = []
        for z in 0..<5 { for y in 0..<3 { for x in 0..<4 { voxels.append(Float(z * 100 + y * 10 + x)) } } }
        XCTAssertEqual(stats.firstLook.lo, LinearCut.firstLook(samples: voxels).lo)
        XCTAssertEqual(model.windowLo, model.firstLookWindow.lo)
        XCTAssertEqual(model.windowHi, model.firstLookWindow.hi)
        model.autoWindowPercentile()
        XCTAssertEqual([model.windowLo, model.windowHi], [0, 1])
        model.autoWindow()
        XCTAssertEqual(model.windowHi, model.firstLookWindow.hi)
    }
}
