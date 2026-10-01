// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Plan 27 A: which elements on screen are targets, what each is called
/// and what its id is — on trees made by hand.
final class UIElementRulesTests: XCTestCase {

    private let window = UIWindowRef(index: 0, kind: .main, title: "Verbinal", screen: "search",
                                     frame: CGRect(x: 100, y: 50, width: 800, height: 600), number: 1)
    private var handle = 0

    private func node(_ role: String, _ frame: CGRect, subrole: String? = nil, label: String? = nil,
                      text: String? = nil, identifier: String? = nil, expanded: Bool? = nil,
                      children: [UIRawNode] = []) -> UIRawNode {
        handle += 1
        return UIRawNode(role: role, subrole: subrole, identifier: identifier, label: label, text: text,
                         frame: frame, expanded: expanded, handle: handle, children: children)
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 80, _ h: CGFloat = 24) -> CGRect {
        CGRect(x: 100 + x, y: 50 + y, width: w, height: h)
    }

    private func elements(_ children: [UIRawNode]) -> UIElementRules.Result {
        UIElementRules.elements(in: node("AXWindow", window.frame, children: children), window: window)
    }

    func testControlsAreTargetsAndMachineryIsNot() {
        let result = elements([
            node("AXButton", rect(10, 10), label: "Run Search"),
            node("AXButton", rect(0, 0, 16, 16), subrole: "AXCloseButton"),
            node("AXScrollBar", rect(780, 40, 16, 400), children: [node("AXButton", rect(780, 40, 16, 16))]),
            node("AXCheckBox", rect(10, 40), label: "Public only"),
        ])
        XCTAssertEqual(result.elements.map(\.name), ["Run Search", "Public only"])
        XCTAssertEqual(result.elements.map(\.kind), [.button, .toggle])
        XCTAssertEqual(result.elements[0].frame, CGRect(x: 10, y: 10, width: 80, height: 24), "in window points")
    }

    func testNamesComeInTheOrderAScreenReaderTakesThem() {
        var titled = node("AXPopUpButton", rect(100, 10))
        titled.titleText = "Resolver"
        var placeheld = node("AXTextField", rect(10, 60))
        placeheld.placeholder = "Target"
        var helped = node("AXButton", rect(10, 100))
        helped.help = "Refresh data train"
        let result = elements([titled, placeheld, helped])
        XCTAssertEqual(result.elements.map(\.name), ["Resolver", "Target", "Refresh data train"])
        XCTAssertNil(result.elements[2].help, "help that is its name is not said twice")
    }

    /// A field with no words of its own is called by the caption a person
    /// reads beside it, or above it.
    func testAnUnnamedFieldIsCalledByItsCaption() {
        let result = elements([
            node("AXStaticText", rect(10, 12, 30, 16), text: "RA"),
            node("AXTextField", rect(50, 10, 120, 24)),
            node("AXStaticText", rect(300, 10, 60, 16), text: "Radius"),
            node("AXTextField", rect(300, 30, 120, 24)),
            node("AXTextField", rect(500, 300, 120, 24)),
        ])
        let fields = result.elements.filter { $0.kind == .textField }
        XCTAssertEqual(fields.map(\.name), ["RA", "Radius", nil])
        XCTAssertEqual(fields[2].id, "search/textField", "no name: its kind")
    }

    /// What a field holds is never read: a text field's value is not in the
    /// tree the source gives, and a static text is the only words used.
    func testAFieldIsNamedNeverByItsValue() {
        var field = node("AXTextField", rect(10, 10))
        field.text = "secret typed words"   // a source must never fill this; a rule must never use it
        let result = elements([field])
        XCTAssertNil(result.elements[0].name)
    }

    func testAScrollAreaClipsWhatIsOutOfSight() {
        let rows = (0..<10).map { i in
            node("AXRow", rect(10, 100 + CGFloat(i) * 24, 300, 24),
                 children: [node("AXStaticText", rect(20, 100 + CGFloat(i) * 24, 100, 16), text: "Row \(i)")])
        }
        let result = elements([node("AXScrollArea", rect(10, 100, 300, 72), children: rows)])
        let listed = result.elements.filter { $0.kind == .row }
        XCTAssertEqual(listed.map(\.name), ["Row 0", "Row 1", "Row 2"], "three fit in 72 pt")
        XCTAssertEqual(listed[2].visible.height, 24)
    }

    func testHandTaggedIdsWinAndSymbolNamesAreNotIds() {
        let result = elements([
            node("AXButton", rect(10, 10), label: "Search", identifier: "vb:search.run"),
            node("AXButton", rect(100, 10), label: "Trash", identifier: "trash"),
            node("AXGroup", rect(10, 50, 300, 200), label: "Spatial constraints", identifier: "vb:search.spatial",
                 children: [node("AXButton", rect(20, 60), label: "Clear")]),
            node("AXGroup", rect(400, 50, 300, 200), identifier: "vbc:fits.image"),
        ])
        let byName = Dictionary(uniqueKeysWithValues: result.elements.map { ($0.name ?? $0.id, $0) })
        XCTAssertEqual(byName["Search"]?.id, "search.run")
        XCTAssertEqual(byName["Search"]?.stable, true)
        XCTAssertEqual(byName["Trash"]?.id, "search/button/Trash")
        XCTAssertEqual(byName["Trash"]?.stable, false)
        XCTAssertEqual(byName["Spatial constraints"]?.kind, .area)
        XCTAssertEqual(byName["Clear"]?.area, "search.spatial")
        XCTAssertEqual(byName["fits.image"]?.kind, .canvas)
    }

    func testRepeatsAreNumberedInReadingOrderAndATaggedIdIsKeptOnce() {
        let result = elements([
            node("AXButton", rect(10, 200), label: "Delete"),
            node("AXButton", rect(10, 100), label: "Delete"),
            node("AXButton", rect(200, 300), label: "Export", identifier: "vb:results.export"),
            node("AXButton", rect(300, 300), label: "Export again", identifier: "vb:results.export"),
        ])
        let deletes = result.elements.filter { $0.name == "Delete" }
        XCTAssertEqual(deletes.map(\.id), ["search/button/Delete", "search/button/Delete#2"])
        XCTAssertEqual(deletes.map(\.visible.minY), [100, 200], "top first")
        XCTAssertEqual(result.duplicateIDs, ["results.export"])
        XCTAssertEqual(result.elements.filter { $0.id == "results.export" }.count, 1)
    }

    /// A folded section and a menu are shut until opened, and nothing behind
    /// them is listed.
    func testClosedThingsAreSaidToBeClosed() {
        let result = elements([
            node("AXDisclosureTriangle", rect(10, 10), label: "Advanced", expanded: false),
            node("AXDisclosureTriangle", rect(10, 40), label: "Basic", expanded: true),
            node("AXPopUpButton", rect(10, 80), label: "Mode"),
            node("AXMenuButton", rect(10, 120), label: "Columns",
                 children: [node("AXMenu", rect(10, 150, 200, 100),
                                 children: [node("AXMenuItem", rect(10, 150, 200, 20), label: "RA")])]),
        ])
        let closed = Dictionary(uniqueKeysWithValues: result.elements.map { ($0.name ?? "", $0.closed) })
        XCTAssertEqual(closed["Advanced"], true)
        XCTAssertEqual(closed["Basic"], false)
        XCTAssertEqual(closed["Mode"], true)
        XCTAssertEqual(closed["Columns"], false, "its menu is open")
        XCTAssertEqual(result.elements.first { $0.name == "RA" }?.kind, .menuItem)
    }

    /// A sheet is its own window: not walked as part of its parent's.
    func testASheetIsNotPartOfItsParent() {
        let result = elements([
            node("AXButton", rect(10, 10), label: "Behind"),
            node("AXSheet", rect(100, 100, 400, 300), children: [node("AXButton", rect(120, 120), label: "Sign In")]),
        ])
        XCTAssertEqual(result.elements.map(\.name), ["Behind"])
    }
}
