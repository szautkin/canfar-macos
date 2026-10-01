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

    /// A text editor is called by what holds it: SwiftUI keeps a
    /// `TextEditor`'s label off its text view. A one-line field is not.
    func testATextEditorIsCalledByWhatHoldsIt() {
        let result = elements([
            node("AXGroup", rect(10, 10, 400, 200), label: "ADQL query",
                 children: [node("AXScrollArea", rect(10, 10, 400, 200),
                                 children: [node("AXTextArea", rect(10, 10, 400, 200))])]),
            node("AXGroup", rect(10, 300, 400, 60), label: "Spatial constraints",
                 children: [node("AXTextField", rect(10, 300, 100, 24))]),
        ])
        XCTAssertEqual(result.elements.filter { $0.kind == .textField }.map(\.name), ["ADQL query", nil])
    }

    /// A disclosure arrow is called by the words after it, as a person reads "▶ HST".
    func testADisclosureIsCalledByTheWordsAfterIt() {
        let result = elements([
            node("AXDisclosureTriangle", rect(10, 10, 14, 20), expanded: false),
            node("AXStaticText", rect(30, 12, 60, 16), text: "HST, 3 items"),
        ])
        XCTAssertEqual(result.elements.first?.name, "HST, 3 items")
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
        // The rest are kept apart, out of sight, to bring into view.
        let away = result.outOfSight.filter { $0.kind == .row }
        XCTAssertEqual(away.map(\.name), (3..<10).map { "Row \($0)" })
        XCTAssertTrue(away.allSatisfy { !$0.inSight })
        XCTAssertEqual(away.first?.frame.minY, 100 + 3 * 24, "where it lies, in window points")
    }

    /// A caption and the control it names share the name: the name means the control.
    func testACaptionAndItsControlAreOneAnswer() {
        let targets: [UIPointerMatcher.Target] = [
            .init(id: "settings.agent/text/Session Instructions", label: "Session Instructions", screen: "settings.agent", control: false),
            .init(id: "settings.agent/textField/Session Instructions", label: "Session Instructions", screen: "settings.agent"),
        ]
        XCTAssertEqual(UIPointerMatcher.best(targets, for: "Session Instructions")?.id,
                       "settings.agent/textField/Session Instructions")
        let two = targets + [.init(id: "x/button/Session Instructions", label: "Session Instructions", screen: "x")]
        XCTAssertNil(UIPointerMatcher.best(two, for: "Session Instructions"), "two controls: a question")
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

    /// An item of a list — a group with a name — and a row lend their names
    /// to the controls in them, so each "Relaunch" says whose it is.
    func testAListsItemsAndRowsNameTheirControls() {
        let result = elements([
            node("AXGroup", rect(10, 10, 300, 60), label: "notebook1, astroml:latest",
                 children: [node("AXButton", rect(20, 40, 60, 20), label: "Relaunch")]),
            node("AXGroup", rect(10, 80, 300, 60), label: "desktop2, desktop:1.0",
                 children: [node("AXButton", rect(20, 110, 60, 20), label: "Relaunch")]),
            node("AXRow", rect(10, 150, 300, 30), children: [
                node("AXCell", rect(10, 150, 300, 30), children: [
                    node("AXStaticText", rect(20, 155, 100, 16), text: "job-42"),
                    node("AXButton", rect(200, 155, 60, 20), label: "Cancel"),
                ]),
            ]),
        ])
        let byID = Dictionary(uniqueKeysWithValues: result.elements.map { ($0.id, $0) })
        XCTAssertEqual(byID["search/item/notebook1, astroml:latest"]?.kind, .item)
        XCTAssertEqual(byID["search/button/Relaunch — notebook1, astroml:latest"]?.item, "notebook1, astroml:latest")
        XCTAssertNotNil(byID["search/button/Relaunch — desktop2, desktop:1.0"], "each Relaunch says whose")
        XCTAssertEqual(byID["search/row/job-42"]?.kind, .row)
        XCTAssertEqual(byID["search/button/Cancel — job-42"]?.item, "job-42")
    }

    /// A name is matched first against what the call acts on: "CFHT" opens
    /// the CFHT collection though rows and texts say CFHT too, and selects
    /// a row though a button says it.
    func testANameMeansWhatTheCallActsOn() {
        let result = elements([
            node("AXDisclosureTriangle", rect(10, 10, 14, 20), label: "CFHT, 15 items, expanded", expanded: true),
            node("AXRow", rect(10, 40, 300, 24), children: [node("AXStaticText", rect(20, 44, 100, 16), text: "CFHT 1121260")]),
            node("AXButton", rect(10, 80, 100, 24), label: "CFHT archive"),
        ])
        let snapshot = UISnapshot(windows: [window], elements: result.elements, duplicateIDs: [])
        guard case .found(let section) = UITargetScope.match("CFHT", in: snapshot, preferring: [.disclosure, .popUp, .menuButton, .menu]) else {
            return XCTFail("open: the section")
        }
        XCTAssertEqual(section.kind, .disclosure)
        guard case .found(let row) = UITargetScope.match("CFHT", in: snapshot, preferring: [.row, .item]) else {
            return XCTFail("select: the row")
        }
        XCTAssertEqual(row.kind, .row)
        guard case .found(let named) = UITargetScope.match("CFHT", in: snapshot) else {
            return XCTFail("pointing: the one whose name is CFHT")
        }
        XCTAssertEqual(named.kind, .disclosure)
        let twice = UISnapshot(windows: [window], elements: elements([
            node("AXDisclosureTriangle", rect(10, 10, 14, 20), label: "CFHT, 15 items", expanded: true),
            node("AXDisclosureTriangle", rect(10, 40, 14, 20), label: "CFHT, 2 items", expanded: true),
        ]).elements, duplicateIDs: [])
        guard case .missing = UITargetScope.match("CFHT", in: twice) else {
            return XCTFail("two named CFHT: a question")
        }
    }

    /// An item marked by `pointableItem` is an item whatever role it reads as.
    func testAMarkedItemIsAnItemEvenAsAButton() {
        let result = elements([node("AXButton", rect(0, 10, 600, 24), label: ".astropy", identifier: PointableID.item)])
        XCTAssertEqual(result.elements.first?.kind, .item)
        XCTAssertEqual(result.elements.first?.id, "search/item/.astropy")
        XCTAssertEqual(result.elements.first?.stable, false)
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
