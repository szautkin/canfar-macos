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

    // MARK: - The spectrum as a researcher asks for it (plan 15 V5, QA M13)

    func testASpectrumIsBinnedOverTheChannelsAskedFor() throws {
        let spectrum: [Float] = [1, 2, 3, .nan, .nan, 6, 7]
        let slice = try CubeSpectrumSlice.make(spectrum, first: 1, last: 6, bin: 2, axisValue: { Double($0) * 10 }).get()
        XCTAssertEqual(slice.values, [2.5, nil, 6.5])
        XCTAssertEqual(slice.axis, [15, 35, 55], "each value at its channels' mean place on the axis")
        XCTAssertEqual(slice.blanked, [1])
        XCTAssertFalse(slice.truncated)

        let whole = try CubeSpectrumSlice.make(spectrum, first: nil, last: nil, bin: nil, axisValue: nil).get()
        XCTAssertEqual(whole.values.count, 7)
        XCTAssertNil(whole.axis)
        guard case .failure(let problem) = CubeSpectrumSlice.make(spectrum, first: 5, last: 2, bin: 1, axisValue: nil) else {
            return XCTFail("a backwards range is refused")
        }
        XCTAssertTrue(problem.message.contains("0…6"), problem.message)
        XCTAssertTrue(try CubeSpectrumSlice.make([Float](repeating: 1, count: 9000), first: nil, last: nil, bin: 1,
                                                 axisValue: nil).get().truncated)
    }

    /// The probe says the unit and where each value is on the spectral axis.
    func testTheProbeSaysItsUnitAndAxis() async throws {
        let model = try await openCube()
        await model.probe(x: 1, y: 2)
        let spectrum = try XCTUnwrap(model.probeSpectrum)
        let axis = try XCTUnwrap(model.wcs?.spectral)
        let slice = try CubeSpectrumSlice.make(spectrum, first: 1, last: 4, bin: 2,
                                               axisValue: { axis.value(atChannel: $0) }).get()
        // Voxel values are z*100 + y*10 + x; channels 1–2 and 3–4 at (1, 2).
        XCTAssertEqual(slice.values, [171, 371])
        XCTAssertEqual(slice.axis?.first ?? 0, 1.0015e9, accuracy: 1, "FREQ from 1 GHz in 1 MHz steps")
        XCTAssertEqual(model.bunit, "Jy")
        XCTAssertEqual(axis.ctype, "FREQ")
    }

    /// Plan 30 P: the channel profile takes a range and a bin as the
    /// spectrum does, and by default comes binned to at most 500 values.
    func testTheChannelProfileIsBinnedLikeTheSpectrum() async throws {
        XCTAssertEqual(CubeSpectrumSlice.bin(toAtMost: 500, count: 3610, first: nil, last: nil), 8, "3,610 channels as 452 values")
        XCTAssertEqual(CubeSpectrumSlice.bin(toAtMost: 500, count: 3610, first: 100, last: 199), 1)

        let state = AppState()
        cubeURL = try FITSTestFixtures.writeCube()
        await state.cubeViewer.open(url: cubeURL)
        XCTAssertTrue(state.cubeViewer.hasData)
        let nz = state.cubeViewer.nz
        let context = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget())
        func profile(_ json: String) async throws -> [String: Any] {
            guard case .data(let data) = await state.makeGetCubeChannelProfileTool().invoke(arguments: Data(json.utf8), context: context) else {
                XCTFail(json)
                return [:]
            }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let whole = try await profile("{}")
        XCTAssertEqual(whole["bin"] as? Int, 1, "a short cube is not binned")
        XCTAssertEqual((whole["means"] as? [Any])?.count, nz)
        XCTAssertEqual((whole["axis"] as? [Any])?.count, nz)
        XCTAssertEqual(whole["unit"] as? String, "Jy")

        let part = try await profile(#"{"firstChannel":1,"lastChannel":4,"bin":2}"#)
        XCTAssertEqual((part["means"] as? [Any])?.count, 2)
        XCTAssertEqual(part["firstChannel"] as? Int, 1)

        let backwards = await state.makeGetCubeChannelProfileTool().invoke(arguments: Data(#"{"firstChannel":4,"lastChannel":1}"#.utf8),
                                                                          context: context)
        guard case .failed(.invalidArgument) = backwards else { return XCTFail("\(backwards)") }
    }
}
