// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import CoreGraphics
@testable import Verbinal

/// Marks made and changed by hand: the shared geometry, the editor's
/// rules, the words and the menu, and the FITS viewer's screen ↔ anchor.
@MainActor
final class MarkEditingTests: XCTestCase {

    private let target = MarkStore.Target(file: URL(fileURLWithPath: "/tmp/editing.fits"), hdu: 0)
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "MarkEditingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Pixels drawn 2 pt each, image origin at (100, 50); `rotation` turns shapes.
    private func projection(rotation: Double = 0, skyScale: Double = 7200) -> MarkProjection {
        MarkProjection(
            point: { a in CGPoint(x: 100 + a.x * 2, y: 50 + a.y * 2) },
            halfSize: { e, a in
                let s = a.space == .sky ? skyScale : 2
                return CGSize(width: e.halfWidth * s, height: e.halfHeight * s)
            },
            anchor: { p, moving in
                let x = (p.x - 100) / 2, y = (p.y - 50) / 2
                guard moving != nil || (x >= 0 && y >= 0) else { return nil }
                return Mark.Anchor(space: moving?.space ?? .imagePixel, x: max(x, 0), y: max(y, 0))
            },
            rotation: rotation)
    }

    private func editor() -> MarkEditor {
        MarkEditor(store: MarkStore(persistence: nil), defaults: defaults)
    }

    private func circle(_ id: String = "m1", at x: Double = 50, _ y: Double = 50, half: Double = 10) -> Mark {
        Mark(id: id, kind: .circle, anchor: .init(space: .imagePixel, x: x, y: y), extent: .square(half),
             author: .user, createdAt: Date())
    }

    // MARK: - Geometry

    /// A mark zoomed far out stays a few points across — and a sky mark's
    /// floor is in points, not half a degree.
    func testDrawnSizeIsFlooredOnScreen() throws {
        let tiny = circle(half: 0.1)
        XCTAssertEqual(try XCTUnwrap(MarkGeometry.frame(of: tiny, in: projection())).half.width, MarkGeometry.minimumHalf)
        let sky = Mark(id: "s", kind: .rect, anchor: .init(space: .sky, x: 10, y: 10), extent: .square(1e-6),
                       author: .user, createdAt: Date())
        XCTAssertEqual(try XCTUnwrap(MarkGeometry.frame(of: sky, in: projection())).half.width, MarkGeometry.minimumHalf)
    }

    func testGripsTurnWithTheView() throws {
        let frame = try XCTUnwrap(MarkGeometry.frame(of: circle(), in: projection(rotation: .pi / 2)))
        let grips = MarkGeometry.handles(of: circle(), frame: frame)
        // (-20, -20) turned a quarter: (20, -20) from the centre (200, 150).
        XCTAssertEqual(grips[0].x, 220, accuracy: 1e-9)
        XCTAssertEqual(grips[0].y, 130, accuracy: 1e-9)
    }

    /// Grip of the selected mark, then its core, then any mark, then empty
    /// space — which draws only with the pencil armed.
    func testWhatAPressAsksFor() {
        let marks = [circle("a"), circle("b", at: 80, 80, half: 3)]
        let p = projection()
        // Centre of "a" is (200, 150), half 20 → corner (220, 170).
        XCTAssertEqual(MarkGeometry.grab(at: CGPoint(x: 221, y: 171), in: marks, projection: p, selectedID: "a", drawing: false),
                       .resize(id: "a"))
        XCTAssertEqual(MarkGeometry.grab(at: CGPoint(x: 219, y: 169), in: marks, projection: p, selectedID: nil, drawing: false),
                       .move(id: "a", offset: CGSize(width: 19, height: 19)), "no grips without selection")
        XCTAssertEqual(MarkGeometry.grab(at: CGPoint(x: 400, y: 400), in: marks, projection: p, selectedID: nil, drawing: false), .none)
        XCTAssertEqual(MarkGeometry.grab(at: CGPoint(x: 400, y: 400), in: marks, projection: p, selectedID: nil, drawing: true), .place)
        // "b" is 6 pt across at the floor: its grips cover it, but the core still moves it.
        XCTAssertEqual(MarkGeometry.grab(at: CGPoint(x: 261, y: 211), in: marks, projection: p, selectedID: "b", drawing: false),
                       .move(id: "b", offset: CGSize(width: 1, height: 1)))
    }

    /// The topmost mark wins, and a mark with no place here does not stop the search.
    func testHitTestingSkipsUnplaceableMarks() {
        let offView = Mark(id: "x", kind: .circle, anchor: .init(space: .data, x: 0, y: 0, z: 5), extent: .square(1),
                           author: .user, createdAt: Date())
        let base = projection()
        let p = MarkProjection(point: { $0.space == .data ? nil : base.point($0) }, halfSize: base.halfSize, anchor: base.anchor)
        XCTAssertEqual(MarkGeometry.mark(at: CGPoint(x: 200, y: 150), in: [circle("a"), circle("b"), offView], projection: p)?.id, "b")
    }

    func testTheWordsCanBeClicked() throws {
        var mark = circle()
        mark.kind = .callout
        mark.text = "NGC 224"
        let frame = try XCTUnwrap(MarkGeometry.frame(of: mark, in: projection()))
        let label = try XCTUnwrap(MarkGeometry.label(of: mark, frame: frame))
        XCTAssertEqual(MarkGeometry.mark(at: CGPoint(x: label.box.midX, y: label.box.midY), in: [mark], projection: projection())?.id, "m1")
        // The leader leaves the circle on its outline.
        let from = try XCTUnwrap(label.leader?.from)
        XCTAssertEqual(hypot(from.x - 200, from.y - 150), 20, accuracy: 1e-9)
    }

    func testResizingABoxTakesEachSideAndACircleKeepsItsShape() throws {
        var box = circle()
        box.kind = .rect
        let boxExtent = try XCTUnwrap(MarkGeometry.resized(box, to: CGPoint(x: 230, y: 160), projection: projection()))
        XCTAssertEqual(boxExtent, Mark.Extent(halfWidth: 15, halfHeight: 5))
        var ellipse = circle()
        ellipse.extent = Mark.Extent(halfWidth: 10, halfHeight: 5)
        let e = try XCTUnwrap(MarkGeometry.resized(ellipse, to: CGPoint(x: 240, y: 160), projection: projection()))
        XCTAssertEqual(e.halfHeight / e.halfWidth, 0.5, accuracy: 1e-12)
        XCTAssertEqual(e.halfWidth, 20, accuracy: 1e-12)
    }

    // MARK: - Editor

    func testDrawingAShapeSizesItStoresItAndAsksForItsWords() throws {
        let marks = editor()
        marks.drawArmed = true
        XCTAssertTrue(marks.press(at: CGPoint(x: 200, y: 150), on: target, projection: projection()))
        XCTAssertTrue(marks.store.marks(on: target).isEmpty, "nothing is written until the drag ends")
        marks.drag(to: CGPoint(x: 240, y: 150), projection: projection())
        marks.release()

        let stored = try XCTUnwrap(marks.store.marks(on: target).first)
        XCTAssertEqual(stored.extent?.halfWidth, 20, "dragged 40 pt at 2 pt per pixel")
        XCTAssertEqual(stored.author, .user)
        XCTAssertEqual(marks.naming?.mark.id, stored.id)
        marks.namingText = "  M31 core "
        marks.commitNaming()
        XCTAssertEqual(marks.store.marks(on: target).first?.text, "M31 core")
        XCTAssertNil(marks.naming)
    }

    /// A callout needs words to be kept: Escape drops it, Return keeps it.
    func testACalloutIsKeptOnlyWithWords() {
        let marks = editor()
        marks.drawArmed = true
        marks.kind = .callout
        _ = marks.press(at: CGPoint(x: 200, y: 150), on: target, projection: projection())
        marks.release()
        XCTAssertTrue(marks.store.marks(on: target).isEmpty)
        XCTAssertEqual(marks.marks(on: target).count, 1, "shown while it is named")
        marks.cancelNaming()
        XCTAssertTrue(marks.marks(on: target).isEmpty)
        XCTAssertNil(marks.store.selected)

        _ = marks.press(at: CGPoint(x: 200, y: 150), on: target, projection: projection())
        marks.release()
        marks.namingText = "jet"
        marks.commitNaming()
        XCTAssertEqual(marks.store.marks(on: target).map(\.text), ["jet"])
    }

    func testTextIsNamedTheMomentItLands() {
        let marks = editor()
        marks.drawArmed = true
        marks.kind = .text
        XCTAssertTrue(marks.press(at: CGPoint(x: 120, y: 60), on: target, projection: projection()))
        XCTAssertNotNil(marks.naming)
        marks.release()
        marks.commitNaming()
        XCTAssertTrue(marks.store.marks(on: target).isEmpty, "a text without words is no mark")
    }

    func testAPressBesideTheImageDrawsNothing() {
        let marks = editor()
        marks.drawArmed = true
        XCTAssertFalse(marks.press(at: CGPoint(x: 10, y: 10), on: target, projection: projection()))
    }

    /// Moving writes once, at the end; a click on the picked-out mark lets it go.
    func testMovingAndLettingGo() throws {
        let marks = editor()
        try marks.store.add(circle(), to: target)
        XCTAssertTrue(marks.press(at: CGPoint(x: 205, y: 150), on: target, projection: projection()))
        marks.drag(to: CGPoint(x: 245, y: 170), projection: projection())
        XCTAssertEqual(marks.store.marks(on: target).first?.anchor.x, 50, "the store waits for the release")
        XCTAssertEqual(marks.marks(on: target).first?.anchor.x, 70, "…while the mark follows the pointer")
        marks.release()
        let moved = try XCTUnwrap(marks.store.marks(on: target).first)
        XCTAssertEqual(moved.anchor.x, 70)
        XCTAssertEqual(moved.anchor.y, 60)
        XCTAssertEqual(marks.selectedID(on: target), "m1")

        _ = marks.press(at: CGPoint(x: 241, y: 171), on: target, projection: projection())
        marks.release()
        XCTAssertNil(marks.selectedID(on: target), "a click on the picked-out mark lets it go")
    }

    func testPressingAwayLetsGoAndLeavesThePressToTheView() throws {
        let marks = editor()
        try marks.store.add(circle(), to: target)
        marks.select("m1", on: target)
        XCTAssertFalse(marks.press(at: CGPoint(x: 400, y: 400), on: target, projection: projection()))
        XCTAssertNil(marks.selectedID(on: target))
    }

    func testStyleGoesToThePickedOutMarkElseTheNextOne() throws {
        let marks = editor()
        try marks.store.add(circle(), to: target)
        var red = Mark.Style.userDefault
        red.colour = "#ff0000"
        marks.applyStyle(red, on: target)
        XCTAssertEqual(marks.nextStyle.colour, "#ff0000")
        XCTAssertEqual(MarkEditor(store: MarkStore(persistence: nil), defaults: defaults).nextStyle.colour, "#ff0000",
                       "remembered")

        marks.select("m1", on: target)
        var bold = red
        bold.bold = true
        marks.applyStyle(bold, on: target)
        XCTAssertEqual(marks.store.marks(on: target).first?.style?.bold, true)
        XCTAssertFalse(marks.nextStyle.bold)
    }

    func testDeleteKeyRemovesThePickedOutMark() throws {
        let marks = editor()
        try marks.store.add(circle(), to: target)
        XCTAssertFalse(marks.deleteSelected(on: target))
        marks.select("m1", on: target)
        XCTAssertTrue(marks.deleteSelected(on: target))
        XCTAssertTrue(marks.store.marks(on: target).isEmpty)
    }

    // MARK: - Words and menu

    func testRowsSayWhatAndWhere() {
        var agent = circle()
        agent.author = .agent
        XCTAssertEqual(MarkSummary.title(agent), "(circle)")
        XCTAssertEqual(MarkSummary.detail(agent), "circle — pixel 50, 50 — by the assistant")
        let sky = Mark(id: "s", kind: .rect, anchor: .init(space: .sky, x: 10.684708, y: 41.269167), extent: .square(0.01),
                       text: "M31", author: .user, createdAt: Date())
        XCTAssertEqual(MarkSummary.detail(sky), "box — 00:42:44.33 +41:16:09.0")
        XCTAssertEqual(MarkSummary.filtered([agent, sky], by: "00:42").map(\.id), ["s"], "found by where it is")
        XCTAssertEqual(MarkSummary.filtered([agent, sky], by: "m31").map(\.id), ["s"])
    }

    /// Copy Position pastes into the Search box as a position.
    func testCopyPositionIsWhatSearchReads() {
        XCTAssertEqual(MarkSummary.clipboardText(circle(), sky: (10.684708, 41.269167)), "00:42:44.33 +41:16:09.0")
        XCTAssertEqual(MarkSummary.clipboardText(circle(), sky: nil), "x=50.00, y=50.00 px")
    }

    private struct Host: MarkCommandHost {
        var onSky: Bool
        func canLocateOnSky(_ mark: Mark) -> Bool { onSky }
        func perform(_ command: MarkCommand, on mark: Mark) {}
        func export(_ format: MarkExport.Format) {}
    }

    func testTheMenuGreysSearchWithoutASkyAndPutsDeleteLast() {
        let without = MarkMenuItem.items(for: circle(), host: Host(onSky: false))
        let search = without.first { $0.command == .searchHere }
        XCTAssertEqual(search?.enabled, false)
        XCTAssertNotNil(search?.disabledReason)
        XCTAssertEqual(without.last?.command, .delete)
        XCTAssertEqual(without.filter(\.destructive).map(\.command), [.delete])
        XCTAssertEqual(MarkMenuItem.items(for: circle(), host: Host(onSky: true)).first { $0.command == .searchHere }?.enabled, true)
    }

    // MARK: - The FITS viewer

    private func loadedTab(wcs: Bool) -> FITSViewerModel {
        let model = FITSViewerModel()
        FITSTestFixtures.loadRamp(into: model, wcsCards: wcs ? [
            ("CRPIX1", "51"), ("CRPIX2", "51"), ("CRVAL1", "80.0"), ("CRVAL2", "-69.0"),
            ("CDELT1", "-2.8e-4"), ("CDELT2", "2.8e-4"),
            ("CTYPE1", "'RA---TAN'"), ("CTYPE2", "'DEC--TAN'"),
        ] : [])
        model.renderedImage = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)?.makeImage()
        model.viewport.zoom = 3
        model.viewport.rotation = 0.4
        return model
    }

    /// A press lands a mark on the pixel under it — and on the sky when the
    /// image has a WCS — and it is drawn back where the press was.
    func testAMarkLandsWhereItIsPlacedAndIsDrawnThere() throws {
        let canvas = CGSize(width: 500, height: 400)
        for wcs in [false, true] {
            let tab = loadedTab(wcs: wcs)
            let projection = try XCTUnwrap(tab.markProjection(canvasSize: canvas))
            let press = CGPoint(x: 260, y: 190)
            let anchor = try XCTUnwrap(projection.anchor(press, nil))
            XCTAssertEqual(anchor.space, wcs ? .sky : .imagePixel)
            let back = try XCTUnwrap(projection.point(anchor))
            XCTAssertEqual(back.x, press.x, accuracy: 1e-6)
            XCTAssertEqual(back.y, press.y, accuracy: 1e-6)
        }
    }

    func testOffTheImageAPressMissesButADragSlidesAlongTheEdge() throws {
        let tab = loadedTab(wcs: false)
        tab.viewport.rotation = 0
        let projection = try XCTUnwrap(tab.markProjection(canvasSize: CGSize(width: 500, height: 400)))
        let farLeft = CGPoint(x: 1, y: 200)
        XCTAssertNil(projection.anchor(farLeft, nil))
        let moving = Mark.Anchor(space: .imagePixel, x: 10, y: 10)
        let slid = try XCTUnwrap(projection.anchor(farLeft, moving))
        XCTAssertEqual(slid.x, -0.5, "the left edge of pixel 0")
    }
}
