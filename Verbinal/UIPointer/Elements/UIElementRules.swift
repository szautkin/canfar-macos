// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation

/// One node of the accessibility tree as the source read it, before any
/// rule (plan 27).
struct UIRawNode: Sendable, Equatable {
    var role: String
    var subrole: String? = nil
    var identifier: String? = nil
    /// `AXDescription`: what VoiceOver says it is.
    var label: String? = nil
    var title: String? = nil
    /// The words of the element that titles it — a slider's or pop-up's caption.
    var titleText: String? = nil
    var placeholder: String? = nil
    var help: String? = nil
    /// A static text's words — the one value ever read. A field's is never.
    var text: String? = nil
    /// On screen, top-left origin, in points.
    var frame: CGRect = .zero
    var enabled: Bool = true
    var expanded: Bool? = nil
    var handle: Int = -1
    var children: [UIRawNode] = []
}

/// Which elements on screen are targets, what each is called and what its
/// id is — the rules, apart from any window (plan 27).
enum UIElementRules {

    struct Result: Equatable, Sendable {
        let elements: [UIElement]
        /// Hand-tagged ids found more than once in the window: the first kept it.
        let duplicateIDs: [String]
    }

    /// Smaller than this, on either side, is not somewhere to send a person.
    static let minimumSide: CGFloat = 4
    static let nameLimit = 120
    private static let idNameLimit = 40

    /// On screen, but not somewhere to send a person: scrolling machinery
    /// and window widgets. Their insides are skipped too.
    static let machineryRoles: Set<String> = ["AXScrollBar", "AXValueIndicator", "AXSplitter", "AXGrowArea", "AXHandle"]
    static let machinerySubroles: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
        "AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage",
    ]
    /// Shown in their own window, so not walked as part of their parent's.
    static let ownWindowRoles: Set<String> = ["AXSheet"]

    static func kind(role: String, subrole: String?) -> UIElementKind? {
        switch role {
        case "AXButton", "AXColorWell": .button
        case "AXCheckBox": .toggle
        case "AXRadioButton":
            switch subrole {
            case "AXTabButton": .tab
            case "AXSegment": .segment
            default: .radio
            }
        case "AXTextField", "AXTextArea", "AXDateField": subrole == "AXSecureTextField" ? .secureField : .textField
        case "AXPopUpButton", "AXComboBox": .popUp
        case "AXMenuButton": .menuButton
        case "AXSlider": .slider
        case "AXIncrementor": .stepper
        case "AXDisclosureTriangle": .disclosure
        case "AXLink": .link
        case "AXRow": .row
        case "AXMenuBarItem": .menu
        case "AXMenuItem": .menuItem
        case "AXImage": .image
        case "AXStaticText", "AXHeading": .text
        case "AXLevelIndicator", "AXProgressIndicator", "AXBusyIndicator": .indicator
        default: nil
        }
    }

    /// A control is pointed at as a whole: what is inside it is not listed
    /// apart. Rows, areas and menus hold controls of their own.
    private static func walksInside(_ kind: UIElementKind?) -> Bool {
        switch kind {
        case nil, .row, .area, .popUp, .menuButton, .menu: true
        default: false
        }
    }

    // MARK: - The elements of a window

    static func elements(in root: UIRawNode, window: UIWindowRef) -> Result {
        var drafts: [Draft] = []
        var texts: [(frame: CGRect, words: String)] = []
        var seen: Set<String> = []
        var duplicates: [String] = []
        walk(root, clip: window.frame, area: nil, window: window,
             drafts: &drafts, texts: &texts, seen: &seen, duplicates: &duplicates)

        // A control with no words of its own is called by its caption.
        for index in drafts.indices where drafts[index].name == nil && drafts[index].kind.isControl {
            drafts[index].name = caption(for: drafts[index].visible, among: texts)
        }

        let ordered = drafts.sorted(by: readingOrder)
        var counts: [String: Int] = [:]
        let elements = ordered.map { draft -> UIElement in
            let id: String
            if let stable = draft.stableID {
                id = stable
            } else {
                let base = derivedID(screen: window.screen, kind: draft.kind, name: draft.name)
                let count = counts[base, default: 0] + 1
                counts[base] = count
                id = count == 1 ? base : "\(base)#\(count)"
            }
            let origin = window.frame.origin
            return UIElement(
                id: id, stable: draft.stableID != nil, kind: draft.kind, name: draft.name,
                help: draft.help == draft.name ? nil : draft.help, enabled: draft.enabled, closed: draft.closed,
                screen: window.screen, area: draft.area,
                frame: draft.frame.offsetBy(dx: -origin.x, dy: -origin.y),
                visible: draft.visible.offsetBy(dx: -origin.x, dy: -origin.y),
                window: window.index, handle: draft.handle)
        }
        return Result(elements: elements, duplicateIDs: duplicates)
    }

    private struct Draft {
        var kind: UIElementKind
        var stableID: String?
        var name: String?
        var help: String?
        var enabled: Bool
        var closed: Bool
        var area: String?
        var frame: CGRect
        var visible: CGRect
        var handle: Int
    }

    private static func walk(_ node: UIRawNode, clip: CGRect, area: String?, window: UIWindowRef,
                             drafts: inout [Draft], texts: inout [(frame: CGRect, words: String)],
                             seen: inout Set<String>, duplicates: inout [String]) {
        if machineryRoles.contains(node.role) || node.subrole.map(machinerySubroles.contains) == true { return }

        // A scroll area shows only what is inside it.
        let clip = node.role == "AXScrollArea" ? clip.intersection(node.frame) : clip
        let visible = node.frame.intersection(clip)
        let shows = !visible.isNull && visible.width >= minimumSide && visible.height >= minimumSide

        var tagged = PointableID.decode(node.identifier)
        if let id = tagged?.id {
            if seen.contains(id) {
                duplicates.append(id)
                tagged = nil
            } else {
                seen.insert(id)
            }
        }
        let roleKind = kind(role: node.role, subrole: node.subrole)
        let kind: UIElementKind? = tagged.map { $0.canvas ? .canvas : (roleKind ?? .area) } ?? roleKind

        if let kind, shows {
            let name = ownName(node, kind: kind)
            if kind == .text, let words = name { texts.append((visible, words)) }
            let open = node.children.contains { $0.role == "AXMenu" }
            let closed = kind == .disclosure ? node.expanded == false : (kind.opens && !open)
            drafts.append(Draft(kind: kind, stableID: tagged?.id, name: name ?? rowWords(node, kind: kind),
                                help: clean(node.help), enabled: node.enabled, closed: closed,
                                area: area, frame: node.frame, visible: visible, handle: node.handle))
        }
        guard walksInside(kind) else { return }
        let inner = kind == .area ? tagged?.id ?? area : area
        for child in node.children where !ownWindowRoles.contains(child.role) {
            walk(child, clip: clip, area: inner, window: window,
                 drafts: &drafts, texts: &texts, seen: &seen, duplicates: &duplicates)
        }
    }

    // MARK: - Names

    /// Its own words, in the order a screen reader takes them; a static
    /// text's are its text.
    static func ownName(_ node: UIRawNode, kind: UIElementKind) -> String? {
        let chain = kind == .text
            ? [node.label, node.title, node.text]
            : [node.label, node.title, node.titleText, node.placeholder, node.help]
        return chain.lazy.compactMap(clean).first
    }

    /// A row with no words of its own reads as its first text.
    private static func rowWords(_ node: UIRawNode, kind: UIElementKind) -> String? {
        guard kind == .row else { return nil }
        func first(_ node: UIRawNode) -> String? {
            if node.role == "AXStaticText", let words = clean(node.text) ?? clean(node.label) { return words }
            return node.children.lazy.compactMap(first).first
        }
        return first(node)
    }

    /// The text a person reads as a control's caption: just before it on its
    /// row, or just above it.
    static func caption(for control: CGRect, among texts: [(frame: CGRect, words: String)]) -> String? {
        let sameRow = texts.filter { text in
            text.frame.maxX <= control.minX + 4 && control.minX - text.frame.maxX <= 200
                && text.frame.midY >= control.minY && text.frame.midY <= control.maxY
        }
        if let nearest = sameRow.min(by: { control.minX - $0.frame.maxX < control.minX - $1.frame.maxX }) {
            return nearest.words
        }
        let above = texts.filter { text in
            text.frame.maxY <= control.minY + 2 && control.minY - text.frame.maxY <= 32
                && text.frame.minX < control.maxX && text.frame.maxX > control.minX
        }
        return above.min(by: { control.minY - $0.frame.maxY < control.minY - $1.frame.maxY })?.words
    }

    /// Words worth showing: whitespace folded, at most `nameLimit` long;
    /// nil when there are none.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let folded = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !folded.isEmpty else { return nil }
        return folded.count > nameLimit ? String(folded.prefix(nameLimit - 1)) + "…" : folded
    }

    // MARK: - Order and ids

    /// Top to bottom, then left to right; a row is anything within 6 pt.
    private static func readingOrder(_ a: Draft, _ b: Draft) -> Bool {
        let rowA = (a.visible.minY / 6).rounded(.down), rowB = (b.visible.minY / 6).rounded(.down)
        if rowA != rowB { return rowA < rowB }
        if a.visible.minX != b.visible.minX { return a.visible.minX < b.visible.minX }
        return a.handle < b.handle
    }

    /// `screen/kind/name` — what it is and what it says, where it is.
    static func derivedID(screen: String, kind: UIElementKind, name: String?) -> String {
        guard let name else { return "\(screen)/\(kind.rawValue)" }
        let slug = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "#", with: "")
        return "\(screen)/\(kind.rawValue)/\(slug.count > idNameLimit ? String(slug.prefix(idNameLimit)) : slug)"
    }
}
