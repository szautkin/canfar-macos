// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import AppKit
import SwiftUI
import VerbinalKit
@testable import Verbinal

/// Select Area (Windows parity): a box dragged on the FITS image — armed
/// from its button, or with ⌘ held — opens Export Figure on the pixels it
/// covers.
@MainActor
final class FITSAreaSelectionTests: XCTestCase {

    /// A 100×100 image at 4 points a pixel on an 800×600 canvas: it covers
    /// x 200…600 and y 100…500 of the canvas.
    private func tab() -> FITSViewerModel {
        let model = FITSViewerModel()
        FITSTestFixtures.loadRamp(into: model)
        model.renderedImage = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)?.makeImage()
        model.lastCanvasSize = canvas
        model.viewport.zoom = 4
        model.viewport.panX = 0
        model.viewport.panY = 0
        return model
    }

    private let canvas = CGSize(width: 800, height: 600)

    // MARK: - The pixels a box covers

    func testABoxCoversWholePixelsInFITSRowsGoingUp() throws {
        let model = tab()
        let region = model.areaRegion(from: CGPoint(x: 240, y: 140), to: CGPoint(x: 360, y: 300), canvasSize: canvas)
        XCTAssertEqual(region, .box(x: 10, y: 50, width: 30, height: 40), "display rows 10…50 are FITS rows 50…90")
        XCTAssertEqual(try model.figureRect(XCTUnwrap(region), marks: []), CGRect(x: 10, y: 10, width: 30, height: 40),
                       "the figure is of the pixels under the box")
        XCTAssertEqual(model.areaRegion(from: CGPoint(x: 360, y: 300), to: CGPoint(x: 240, y: 140), canvasSize: canvas), region,
                       "dragged either way")
        XCTAssertEqual(model.areaRegion(from: CGPoint(x: 241, y: 141), to: CGPoint(x: 359, y: 299), canvasSize: canvas), region,
                       "a part of a pixel is the whole pixel")
    }

    func testABoxPartlyOffTheImageIsCutToItAndOneOffItIsNothing() {
        let model = tab()
        XCTAssertEqual(model.areaRegion(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 240, y: 140), canvasSize: canvas),
                       .box(x: 0, y: 90, width: 10, height: 10))
        XCTAssertNil(model.areaRegion(from: .zero, to: CGPoint(x: 100, y: 50), canvasSize: canvas))
        XCTAssertNil(FITSViewerModel().areaRegion(from: .zero, to: CGPoint(x: 10, y: 10), canvasSize: canvas), "no image")
    }

    func testAFlippedViewIsReadAsItIsShown() {
        let model = tab()
        model.viewport.flipX = true
        XCTAssertEqual(model.areaRegion(from: CGPoint(x: 240, y: 140), to: CGPoint(x: 360, y: 300), canvasSize: canvas),
                       .box(x: 60, y: 50, width: 30, height: 40), "the left of the canvas is the right of the image")
    }

    func testLettingGoOpensExportFigureOnTheBoxAndPutsSelectAreaDown() {
        let model = tab()
        model.selectingArea = true
        model.areaBand = CGRect(x: 240, y: 140, width: 120, height: 160)
        XCTAssertNil(model.finishArea(from: CGPoint(x: 240, y: 140), to: CGPoint(x: 360, y: 300), canvasSize: canvas))
        XCTAssertEqual(model.figureRegion, .box(x: 10, y: 50, width: 30, height: 40))
        XCTAssertFalse(model.selectingArea)
        XCTAssertNil(model.areaBand)
        XCTAssertEqual(model.figureRegion?.boxSize?.width, 30)

        let off = tab()
        off.selectingArea = true
        XCTAssertNotNil(off.finishArea(from: .zero, to: CGPoint(x: 100, y: 50), canvasSize: canvas))
        XCTAssertNil(off.figureRegion, "nothing to export")
        XCTAssertTrue(off.selectingArea, "still armed, to try again")
    }

    // MARK: - The gesture

    private final class Seen {
        var bands: [CGRect?] = []
        var ended: [(CGPoint, CGPoint)] = []
        var clicks: [CGPoint] = []
        var drags = 0
        var disarmed = 0
    }

    private func canvasView(armed: Bool, _ seen: Seen) -> ScrollCaptureNSView {
        let view = ScrollCaptureNSView(frame: NSRect(origin: .zero, size: canvas))
        view.onClick = { seen.clicks.append($0) }
        view.onDrag = { _, _ in seen.drags += 1 }
        view.area = .init(armed: armed, changed: { seen.bands.append($0) }, ended: { seen.ended.append(($0, $1)) },
                          disarm: { seen.disarmed += 1 })
        return view
    }

    /// A mouse event at `point` on the canvas (y down, as the canvas reads it).
    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: canvas.height - point.y), modifierFlags: flags,
                           timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testCommandDragDrawsABoxAndABareDragPans() {
        let seen = Seen()
        let view = canvasView(armed: false, seen)
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 240, y: 140), .command))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 360, y: 300), .command))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 360, y: 300), .command))
        XCTAssertEqual(seen.bands.last, CGRect(x: 240, y: 140, width: 120, height: 160))
        XCTAssertEqual(seen.ended.map(\.0), [CGPoint(x: 240, y: 140)])
        XCTAssertEqual(seen.ended.map(\.1), [CGPoint(x: 360, y: 300)])
        XCTAssertEqual(seen.drags, 0, "no pan")

        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 240, y: 140)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 360, y: 300)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 360, y: 300)))
        XCTAssertEqual(seen.drags, 1, "a bare drag pans, as before")
        XCTAssertEqual(seen.ended.count, 1)
    }

    func testArmedEveryDragDrawsABox() {
        let seen = Seen()
        let view = canvasView(armed: true, seen)
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 240, y: 140)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 300, y: 200)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 200)))
        XCTAssertEqual(seen.ended.count, 1)
        XCTAssertEqual(seen.drags, 0)
    }

    func testACommandClickIsStillAClickAndEscapePutsSelectAreaDown() {
        let seen = Seen()
        let view = canvasView(armed: false, seen)
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 240, y: 140), .command))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 240, y: 140), .command))
        XCTAssertEqual(seen.clicks, [CGPoint(x: 240, y: 140)])
        XCTAssertTrue(seen.ended.isEmpty)

        let armed = Seen()
        let armedView = canvasView(armed: true, armed)
        armedView.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 240, y: 140)))
        armedView.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 240, y: 140)))
        XCTAssertTrue(armed.clicks.isEmpty, "armed, a click places nothing")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                      context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                      isARepeat: false, keyCode: 53)!
        armedView.keyDown(with: escape)
        XCTAssertEqual(armed.disarmed, 1)
    }

    // MARK: - An assistant

    private func ctx() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "test"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
    }

    func testAnAssistantArmsSelectAreaForThePersonAndReadsIt() async throws {
        let state = AppState()
        let model = state.fitsTabHost.addTab()
        FITSTestFixtures.loadRamp(into: model, path: "/tmp/area.fits")
        model.renderedImage = tab().renderedImage
        let set = state.makeSetFITSViewTool()
        _ = await set.invoke(arguments: Data(#"{"selectArea": true}"#.utf8), context: ctx())
        XCTAssertTrue(model.selectingArea)
        let get = try XCTUnwrap(state.makeAgentTools().first { $0.name == "get_fits_view" })
        guard case .data(let data) = await get.invoke(arguments: Data("{}".utf8), context: ctx()) else {
            return XCTFail("no view")
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["selectingArea"] as? Bool, true)
        _ = await set.invoke(arguments: Data(#"{"selectArea": false}"#.utf8), context: ctx())
        XCTAssertFalse(model.selectingArea)
    }
}

/// The FITS viewer's panel is 220 to 320 points wide; a row wider than that
/// pushes the whole panel off both edges — the five-segment Stretch picker
/// did (291 points), seen 2026-10-13.
@MainActor
final class FITSPanelWidthTests: XCTestCase {
    func testTheRenderControlsFitTheNarrowestPanel() {
        let model = FITSViewerModel()
        FITSTestFixtures.loadRamp(into: model)
        model.renderedImage = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)?.makeImage()
        let host = NSHostingController(rootView: FITSRenderControlsView(model: model, marks: nil))
        for width in [220.0, 260, 320] {
            let size = host.sizeThatFits(in: CGSize(width: width, height: 2000))
            // A third of a point is text rounding, not a row that cannot shrink.
            XCTAssertLessThanOrEqual(size.width, width + 1, "the controls are wider than a \(Int(width))-point panel")
        }
    }
}
