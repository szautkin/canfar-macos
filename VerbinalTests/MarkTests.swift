// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import os
import VerbinalKit
@testable import Verbinal

@MainActor
final class MarkTests: XCTestCase {

    private var fileName = ""

    override func setUp() {
        fileName = "test-marks-\(UUID().uuidString).json"
    }

    override func tearDown() {
        if let url = persistence().fileURL { try? FileManager.default.removeItem(at: url) }
    }

    private func persistence() -> DiskPersistence<[String: [Mark]]> {
        DiskPersistence(subdirectory: "VerbinalTests", fileName: fileName, logger: Logger(subsystem: "test", category: "marks"))
    }

    private func store() -> MarkStore { MarkStore(persistence: persistence()) }

    private func circle(_ id: String = "m1", x: Double = 10, y: Double = 20) -> Mark {
        Mark(id: id, kind: .circle, anchor: .init(space: .imagePixel, x: x, y: y), extent: .square(5),
             author: .user, createdAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Model

    func testAMarkThatCannotBeDrawnIsRefused() {
        var mark = circle()
        mark.anchor.x = .nan
        XCTAssertNotNil(mark.problem)
        XCTAssertNotNil(Mark(id: "s", kind: .circle, anchor: .init(space: .sky, x: 10, y: 120), extent: .square(1),
                             author: .user, createdAt: Date()).problem, "Dec 120° is not a place")
        XCTAssertNotNil(Mark(id: "r", kind: .rect, anchor: .init(space: .imagePixel, x: 1, y: 1),
                             author: .user, createdAt: Date()).problem, "a box needs a size")
        XCTAssertNotNil(Mark(id: "c", kind: .callout, anchor: .init(space: .imagePixel, x: 1, y: 1),
                             author: .user, createdAt: Date()).problem, "a callout needs text")
        XCTAssertNil(circle().problem)
    }

    func testStylesAreClampedAndColoursNormalised() {
        let style = Mark.Style(colour: "FF8800", fontSize: 200, bold: true, stroke: 0).sane()
        XCTAssertEqual(style.colour, "#ff8800")
        XCTAssertEqual(style.fontSize, 72)
        XCTAssertEqual(style.stroke, 0.5)
        XCTAssertNil(Mark.Style.normalisedColour("red"))
    }

    // MARK: - Store

    /// Windows lost marks to another spelling of the same path.
    func testMarksAreKeptPerFileAndExtensionUnderOneSpelling() throws {
        let marks = store()
        let a = MarkStore.Target(file: URL(fileURLWithPath: "/tmp/field/m31.fits"), hdu: 1)
        let respelled = MarkStore.Target(file: URL(fileURLWithPath: "/tmp/field/./sub/../m31.fits"), hdu: 1)
        try marks.add(circle(), to: a)
        XCTAssertEqual(marks.marks(on: respelled).map(\.id), ["m1"])
        XCTAssertTrue(marks.marks(on: .init(file: URL(fileURLWithPath: "/tmp/field/m31.fits"), hdu: 2)).isEmpty,
                      "each extension has its own")
        XCTAssertEqual(marks.targets(of: URL(fileURLWithPath: "/tmp/field/m31.fits")).map(\.hdu), [1])
    }

    func testMarksSurviveAReopenOfTheStore() throws {
        let target = MarkStore.Target(file: URL(fileURLWithPath: "/tmp/a.fits"), hdu: 0)
        try store().add(circle(), to: target)
        XCTAssertEqual(store().marks(on: target).map(\.id), ["m1"], "read back from disk")
    }

    func testUpdateRemoveAndClear() throws {
        let marks = store()
        let target = MarkStore.Target(file: URL(fileURLWithPath: "/tmp/b.fits"), hdu: 0)
        try marks.add(circle("m1"), to: target)
        try marks.add(circle("m2"), to: target)
        try marks.update("m1", on: target) { $0.text = "core" }
        XCTAssertEqual(marks.marks(on: target).first?.text, "core")
        XCTAssertThrowsError(try marks.update("m1", on: target) { $0.extent = nil }, "an update that breaks a circle is refused")
        try marks.remove("m2", from: target)
        XCTAssertThrowsError(try marks.remove("m2", from: target))
        XCTAssertEqual(marks.clear([target]), 1)
        XCTAssertEqual(marks.newID(on: target), "m1")
    }

    // MARK: - DS9

    func testDS9WritesSkyInArcsecondsAndPixelsOneBased() {
        let sky = Mark(id: "s", kind: .circle, anchor: .init(space: .sky, x: 10.684708, y: 41.269167),
                       extent: .square(0.001), text: "M31 {core}", author: .agent, createdAt: Date())
        let box = Mark(id: "p", kind: .rect, anchor: .init(space: .imagePixel, x: 99, y: 49),
                       extent: .init(halfWidth: 5, halfHeight: 2), author: .user, createdAt: Date())
        let region = MarkExport.ds9([sky, box])
        XCTAssertTrue(region.contains("fk5\ncircle(10.68471,41.26917,3.6\") # color=#8cffcc width=1 text={M31 (core)}"), region)
        XCTAssertTrue(region.contains("image\nbox(100,50,10,4,0)"), region)
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

    func testAnAgentMarksAFileThatIsNotOpenThenListsChangesAndClearsIt() async throws {
        let state = AppState(marks: store())
        let path = "/tmp/not-open-\(UUID().uuidString).fits"
        let added = try await call(state.makeAnnotateFITSTool(),
                                   #"{"target":"\#(path)","kind":"callout","raDeg":10.68,"decDeg":41.27,"text":"M31","hdu":1}"#)
        let mark = try XCTUnwrap(added["mark"] as? [String: Any])
        XCTAssertEqual(mark["author"] as? String, "agent")
        XCTAssertEqual(mark["raDeg"] as? Double, 10.68)

        let listed = try await call(state.makeListFITSAnnotationsTool(), #"{"target":"\#(path)"}"#)
        XCTAssertEqual(listed["count"] as? Int, 1, "without hdu, a file not on screen lists every extension")

        _ = try await call(state.makeUpdateAnnotationTool(), ##"{"id":"m1","target":"\##(path)","hdu":1,"text":"M31 nucleus","colour":"#ff0000"}"##)
        let changed = state.marks.marks(on: .init(file: URL(fileURLWithPath: path), hdu: 1)).first
        XCTAssertEqual(changed?.text, "M31 nucleus")
        XCTAssertEqual(changed?.effectiveStyle.colour, "#ff0000")

        let exported = try await call(state.makeExportAnnotationsTool(), #"{"target":"\#(path)"}"#)
        XCTAssertTrue((exported["content"] as? String ?? "").contains("text={M31 nucleus}"))

        let cleared = try await call(state.makeClearAnnotationsTool(), #"{"target":"\#(path)","allHdus":true}"#)
        XCTAssertEqual(cleared["removed"] as? Int, 1)
    }

    /// A region file is for one image; JSON keeps each mark's extension.
    func testExportAcrossExtensionsIsJSONOnly() async throws {
        let state = AppState(marks: store())
        let path = "/tmp/two-hdus-\(UUID().uuidString).fits"
        for hdu in [1, 2] {
            _ = try await call(state.makeAnnotateFITSTool(), #"{"target":"\#(path)","x":5,"y":5,"radius":2,"hdu":\#(hdu)}"#)
        }
        let ds9 = await state.makeExportAnnotationsTool().invoke(arguments: Data(#"{"target":"\#(path)"}"#.utf8), context: ctx())
        guard case .failed(.invalidArgument(let why)) = ds9 else { return XCTFail("\(ds9)") }
        XCTAssertTrue(why.contains("1, 2"), why)

        let json = try await call(state.makeExportAnnotationsTool(), #"{"target":"\#(path)","format":"json"}"#)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((json["content"] as? String ?? "").utf8)) as? [String: Any])
        XCTAssertEqual((envelope["extensions"] as? [[String: Any]])?.compactMap { $0["hdu"] as? Int }, [1, 2])
        XCTAssertEqual(envelope["file"] as? String, path)

        let single = try await call(state.makeExportAnnotationsTool(), #"{"target":"\#(path)","hdu":2}"#)
        XCTAssertEqual(single["count"] as? Int, 1)

        let cleared = try await call(state.makeClearAnnotationsTool(), #"{"target":"/tmp/unmarked.fits"}"#)
        XCTAssertEqual(cleared["file"] as? String, "/tmp/unmarked.fits", "the file is named even when it had no marks")
    }

    func testHalfAPositionOrTwoPositionsAreRefused() async {
        let state = AppState(marks: store())
        for bad in [#"{"target":"/tmp/x.fits","x":1,"radius":2}"#,
                    #"{"target":"/tmp/x.fits","x":1,"y":2,"raDeg":3,"decDeg":4,"radius":2}"#] {
            let result = await state.makeAnnotateFITSTool().invoke(arguments: Data(bad.utf8), context: ctx())
            guard case .failed(.invalidArgument) = result else { return XCTFail("\(bad) → \(result)") }
        }
    }

    // MARK: - Drawing

    /// A mark on FITS pixel (30, 70) is drawn where the viewer draws that pixel.
    func testTheCanvasProjectionPutsAPixelMarkOnItsPixel() throws {
        let model = FITSViewerModel()
        FITSTestFixtures.loadRamp(into: model)
        model.renderedImage = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)?.makeImage()
        model.viewport.zoom = 2
        let canvas = CGSize(width: 400, height: 300)
        let projection = try XCTUnwrap(model.markProjection(canvasSize: canvas))
        let point = try XCTUnwrap(projection.point(.init(space: .imagePixel, x: 30, y: 70)))
        let expected = ViewportTransform(zoom: 2, rotation: 0, flipX: false, panX: model.viewport.panX, panY: model.viewport.panY,
                                         imageSize: CGSize(width: 100, height: 100), canvasSize: canvas)
            .imageToScreen(CGPoint(x: 30.5, y: 29.5))
        XCTAssertEqual(point.x, expected.x, accuracy: 1e-9)
        XCTAssertEqual(point.y, expected.y, accuracy: 1e-9)
        XCTAssertEqual(projection.halfSize(.square(5), .init(space: .imagePixel, x: 0, y: 0))?.width, 10)
    }
}
