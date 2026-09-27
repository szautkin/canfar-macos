// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import CoreGraphics
import VerbinalKit
@testable import Verbinal

/// The cube slice's one screen ↔ voxel map, and marks that live on a channel.
@MainActor
final class CubeMarkTests: XCTestCase {

    private var cubeURL: URL!

    override func tearDown() {
        if let cubeURL { try? FileManager.default.removeItem(at: cubeURL) }
    }

    /// A 4×3×5 cube on a 400×300 canvas: 100 pt per voxel, on channel 2.
    private func openCube() async throws -> CubeViewerModel {
        cubeURL = try FITSTestFixtures.writeCube()
        let model = CubeViewerModel()
        await model.open(url: cubeURL)
        XCTAssertTrue(model.hasData)
        model.sliceCanvasSize = CGSize(width: 400, height: 300)
        return model
    }

    // MARK: - The slice map

    /// A click on the right or lower half of a voxel is that voxel — the
    /// probe used to round an edge coordinate and land on the next one.
    func testAClickIsOnTheVoxelUnderIt() throws {
        let frame = try XCTUnwrap(CubeSliceFrame(nx: 4, ny: 3, canvas: CGSize(width: 400, height: 300), zoom: 1, pan: .zero))
        // Voxel (0, 0) is bottom-left: screen x 0…100, y 200…300.
        for point in [CGPoint(x: 10, y: 290), CGPoint(x: 70, y: 210), CGPoint(x: 99, y: 201)] {
            let voxel = try XCTUnwrap(frame.voxelIndex(atScreen: point))
            XCTAssertEqual([voxel.x, voxel.y], [0, 0], "\(point)")
        }
        let next = try XCTUnwrap(frame.voxelIndex(atScreen: CGPoint(x: 110, y: 190)))
        XCTAssertEqual([next.x, next.y], [1, 1])
        XCTAssertNil(frame.voxelIndex(atScreen: CGPoint(x: 401, y: 10)))

        XCTAssertEqual(frame.screen(ofVoxel: 2, 1), CGPoint(x: 250, y: 150))
        let centre = try XCTUnwrap(frame.voxel(atScreen: CGPoint(x: 250, y: 150)))
        XCTAssertEqual([centre.x, centre.y], [2, 1], "a voxel's centre is a whole number")
    }

    func testZoomKeepsThePointUnderThePointerAndCentringCentres() throws {
        let frame = try XCTUnwrap(CubeSliceFrame(nx: 4, ny: 3, canvas: CGSize(width: 400, height: 300), zoom: 1, pan: .zero))
        let pointer = CGPoint(x: 70, y: 210)
        let zoomed = try XCTUnwrap(CubeSliceFrame(nx: 4, ny: 3, canvas: frame.canvas, zoom: 2,
                                                  pan: frame.panKeeping(pointer, atZoom: 2)))
        let kept = zoomed.screen(ofDisplay: frame.display(ofScreen: pointer))
        XCTAssertEqual(kept.x, pointer.x, accuracy: 1e-9)
        XCTAssertEqual(kept.y, pointer.y, accuracy: 1e-9)

        let centred = try XCTUnwrap(CubeSliceFrame(nx: 4, ny: 3, canvas: frame.canvas, zoom: 2,
                                                   pan: zoomed.panCentring(voxel: 0, 0)))
        XCTAssertEqual(centred.screen(ofVoxel: 0, 0), CGPoint(x: 200, y: 150))
    }

    // MARK: - Marks on the slice

    func testAMarkShowsOnItsChannelAndANewOneLandsOnTheChannelShown() async throws {
        let cube = try await openCube()
        XCTAssertEqual(cube.channel, 2)
        let projection = try XCTUnwrap(cube.sliceMarkProjection(canvasSize: cube.sliceCanvasSize))
        XCTAssertEqual(projection.point(Mark.Anchor(space: .data, x: 2, y: 1, z: 2)), CGPoint(x: 250, y: 150))
        XCTAssertNil(projection.point(Mark.Anchor(space: .data, x: 2, y: 1, z: 3)), "another channel's mark")
        XCTAssertNil(projection.point(Mark.Anchor(space: .imagePixel, x: 2, y: 1)))

        XCTAssertEqual(projection.anchor(CGPoint(x: 250, y: 150), nil), Mark.Anchor(space: .data, x: 2, y: 1, z: 2))
        XCTAssertNil(projection.anchor(CGPoint(x: 450, y: 150), nil), "beside the slice")
        let moving = Mark.Anchor(space: .data, x: 0, y: 0, z: 4)
        XCTAssertEqual(projection.anchor(CGPoint(x: 250, y: 150), moving)?.z, 4, "a moved mark keeps its channel")
    }

    func testTheSkyOfACubeMarkAndCentringOnIt() async throws {
        let cube = try await openCube()
        let mark = Mark(id: "m1", kind: .circle, anchor: .init(space: .data, x: 1, y: 0.5, z: 4), extent: .square(1),
                        author: .user, createdAt: Date())
        let sky = try XCTUnwrap(cube.sky(of: mark))
        XCTAssertEqual(sky.ra, 150, accuracy: 1e-9, "CRPIX 2, 1.5 is voxel (1, 0.5)")
        XCTAssertEqual(sky.dec, 2, accuracy: 1e-9)

        cube.centreSlice(onVoxel: 0, 0, channel: 4)
        XCTAssertEqual(cube.channel, 4)
        XCTAssertEqual(cube.sliceFrame()?.screen(ofVoxel: 0, 0), CGPoint(x: 200, y: 150))
    }

    func testTheCursorReadsTheVoxelUnderIt() async throws {
        let cube = try await openCube()
        await cube.updateCursor(x: 0.4, y: 1)
        XCTAssertEqual(cube.cursorValue, "210 Jy")
        await cube.updateCursor(x: 0.6, y: 1)
        XCTAssertEqual(cube.cursorValue, "211 Jy")
    }

    // MARK: - Marks in the volume

    /// The camera looks at the cube's centre: the middle voxel is the
    /// middle of the view, whatever the orbit.
    func testTheVolumeCameraLooksAtTheMiddleOfTheCube() async throws {
        let cube = try await openCube()
        let size = CGSize(width: 600, height: 400)
        for azimuth: Float in [0, 0.7, 2.1] {
            cube.cameraAzimuth = azimuth
            let camera = try XCTUnwrap(cube.camera(for: size))
            let middle = try XCTUnwrap(camera.screen(ofBoxPoint: CubeCamera.boxPoint(voxelX: 1.5, 1, 2, nx: 4, ny: 3, nz: 5), in: size))
            XCTAssertEqual(middle.x, 300, accuracy: 1e-3)
            XCTAssertEqual(middle.y, 200, accuracy: 1e-3)
        }
    }

    /// The volume shows every channel's marks, larger as the camera comes closer.
    func testTheVolumeShowsEveryChannelsMarks() async throws {
        let cube = try await openCube()
        let size = CGSize(width: 600, height: 400)
        let projection = try XCTUnwrap(cube.volumeMarkProjection(canvasSize: size))
        XCTAssertNotNil(projection.point(Mark.Anchor(space: .data, x: 0, y: 0, z: 0)))
        XCTAssertNotNil(projection.point(Mark.Anchor(space: .data, x: 3, y: 2, z: 4)))
        XCTAssertNil(projection.anchor(CGPoint(x: 300, y: 200), nil), "marks are placed on the slice, not in the volume")

        let middle = Mark.Anchor(space: .data, x: 1.5, y: 1, z: 2)
        let far = try XCTUnwrap(projection.halfSize(.square(1), middle)).width
        cube.cameraDistance /= 2
        let near = try XCTUnwrap(cube.volumeMarkProjection(canvasSize: size)?.halfSize(.square(1), middle)).width
        XCTAssertGreaterThan(near, far * 1.5)
    }

    // MARK: - Tools

    private func ctx() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
    }

    private func call<T: AITool>(_ tool: T, _ json: String) async throws -> [String: Any] {
        let result = await tool.invoke(arguments: Data(json.utf8), context: ctx())
        guard case .data(let bytes) = result else { throw ToolFailureReason.backendError("\(result)") }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    private func refusal<T: AITool>(_ tool: T, _ json: String) async -> String? {
        let result = await tool.invoke(arguments: Data(json.utf8), context: ctx())
        if case .failed(.invalidArgument(let why)) = result { return why }
        XCTFail("expected a refusal, got \(result)")
        return nil
    }

    func testAnAgentMarksAChannelOfTheCubeOnScreen() async throws {
        let state = AppState(marks: MarkStore(persistence: nil))
        state.cubeTabHost.tabs = [try await openCube()]

        let added = try await call(state.makeAnnotateCubeTool(), #"{"x":2,"y":1,"channel":3,"radius":1,"text":"line wing"}"#)
        XCTAssertEqual((added["mark"] as? [String: Any])?["channel"] as? Int, 3)

        let refusedChannel = await refusal(state.makeAnnotateCubeTool(), #"{"x":2,"y":1,"channel":9,"radius":1}"#)
        XCTAssertTrue(refusedChannel?.contains("0–4") ?? false, refusedChannel ?? "")
        let refusedSky = await refusal(state.makeUpdateAnnotationTool(), #"{"id":"m1","viewer":"cube","raDeg":150,"decDeg":2}"#)
        XCTAssertNotNil(refusedSky)
        let refusedHDU = await refusal(state.makeListCubeAnnotationsTool(), #"{"target":"\#(cubeURL.path)","hdu":1}"#)
        XCTAssertNotNil(refusedHDU, "the schema has no hdu, and the resolver says why")

        _ = try await call(state.makeUpdateAnnotationTool(), #"{"id":"m1","viewer":"cube","channel":4}"#)
        let listed = try await call(state.makeListCubeAnnotationsTool(), "{}")
        let entry = try XCTUnwrap((listed["marks"] as? [[String: Any]])?.first?["mark"] as? [String: Any])
        XCTAssertEqual(entry["channel"] as? Int, 4, "moved to another channel alone")
        XCTAssertEqual(entry["x"] as? Double, 2)

        _ = try await call(state.makeSelectAnnotationTool(), #"{"id":"m1","viewer":"cube"}"#)
        XCTAssertEqual(state.cubeViewer.channel, 4, "the cube goes to the mark's channel")

        let fits = try await call(state.makeListFITSAnnotationsTool(), #"{"target":"\#(cubeURL.path)"}"#)
        XCTAssertEqual(fits["count"] as? Int, 0, "a cube's marks are not the FITS viewer's")

        let json = try await call(state.makeExportAnnotationsTool(), #"{"viewer":"cube","format":"json"}"#)
        XCTAssertTrue((json["content"] as? String ?? "").contains("\"z\" : 4"))

        let cleared = try await call(state.makeClearAnnotationsTool(), #"{"viewer":"cube"}"#)
        XCTAssertEqual(cleared["removed"] as? Int, 1)
    }

    func testAFITSMarkTakesNoChannel() async {
        let state = AppState(marks: MarkStore(persistence: nil))
        let why = await refusal(state.makeAnnotateFITSTool(), #"{"target":"/tmp/x.fits","x":1,"y":2,"channel":3,"radius":1}"#)
        XCTAssertTrue(why?.contains("annotate_cube") ?? false, why ?? "")
    }
}
