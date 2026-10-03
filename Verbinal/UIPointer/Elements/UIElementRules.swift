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
        /// What is in sight.
        let elements: [UIElement]
        /// What is scrolled out of sight inside a scroll area: not listed,
        /// but brought into view when a hint names it.
        var outOfSight: [UIElement] = []
        /// Hand-tagged ids found more than once in the window: the first kept it.
        let duplicateIDs: [String]
    }

    /// At most this many elements out of sight are kept, per window.
    static let maxOutOfSight = 2_000

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
        case nil, .row, .item, .area, .popUp, .menuButton, .menu: true
        default: false
        }
    }

    // MARK: - The elements of a window

    /// `shown`: the presentations shown now, by name in lower case — a
    /// control that opens one of them is not closed.
    static func elements(in root: UIRawNode, window: UIWindowRef, shown: Set<String> = []) -> Result {
        var drafts: [Draft] = []
        var texts: [Text] = []
        var seen: Set<String> = []
        var duplicates: [String] = []
        walk(root, clip: window.frame, clips: [], area: nil, item: nil, holderName: nil, window: window, shown: shown,
             drafts: &drafts, texts: &texts, seen: &seen, duplicates: &duplicates)

        // A control with no words of its own is called by its caption — one
        // in sight by what is in sight, one scrolled away by where it lies. A
        // row is called by the words drawn over it — a list's section heading
        // — never by a caption: the words above a list name no row of it.
        let inSightTexts = texts.filter(\.inSight).map { (frame: $0.frame, words: $0.words) }
        let allTexts = texts.map { (frame: $0.frame, words: $0.words) }
        for index in drafts.indices where drafts[index].name == nil && drafts[index].kind.isControl {
            let draft = drafts[index]
            let frame = draft.inSight ? draft.visible : draft.frame
            let among = draft.inSight ? inSightTexts : allTexts
            drafts[index].name = draft.kind == .row
                ? heading(over: frame, among: among)
                : caption(for: frame, among: among, after: draft.kind == .disclosure)
        }

        // In sight first, so their ids are the same whatever is scrolled away.
        let ordered = drafts.filter(\.inSight).sorted(by: readingOrder)
            + drafts.filter { !$0.inSight }.sorted(by: readingOrder).prefix(maxOutOfSight)
        var counts: [String: Int] = [:]
        let all = ordered.map { draft -> UIElement in
            let id: String
            if let stable = draft.stableID {
                id = stable
            } else {
                // A control in a list's item or row is named with it: "Relaunch — notebook1" —
                // unless it is what names the row ("☐ centos").
                let named = draft.item.flatMap { item in
                    draft.kind.holds || draft.name == item ? nil : draft.name.map { "\($0) — \(item)" }
                } ?? draft.name
                let base = derivedID(screen: window.screen, kind: draft.kind, name: named)
                let count = counts[base, default: 0] + 1
                counts[base] = count
                id = count == 1 ? base : "\(base)#\(count)"
            }
            let origin = window.frame.origin
            return UIElement(
                id: id, stable: draft.stableID != nil, kind: draft.kind, name: draft.name,
                help: draft.help == draft.name ? nil : draft.help, enabled: draft.enabled, closed: draft.closed,
                screen: window.screen, area: draft.area, item: draft.kind.holds ? nil : draft.item,
                presents: draft.presents,
                frame: draft.frame.offsetBy(dx: -origin.x, dy: -origin.y),
                visible: draft.inSight ? draft.visible.offsetBy(dx: -origin.x, dy: -origin.y) : .null,
                window: window.index, handle: draft.handle, clips: draft.clips)
        }
        return Result(elements: all.filter(\.inSight), outOfSight: all.filter { !$0.inSight }, duplicateIDs: duplicates)
    }

    private struct Text {
        let frame: CGRect
        let words: String
        let inSight: Bool
    }

    private struct Draft {
        var kind: UIElementKind
        var stableID: String?
        var name: String?
        var help: String?
        var enabled: Bool
        var closed: Bool
        var presents: String?
        var area: String?
        var item: String?
        var frame: CGRect
        var visible: CGRect
        var handle: Int
        var clips: [Int]
        var inSight: Bool
    }

    private static func walk(_ node: UIRawNode, clip: CGRect, clips: [Int], area: String?, item: String?,
                             holderName: String?, window: UIWindowRef, shown: Set<String>,
                             drafts: inout [Draft], texts: inout [Text],
                             seen: inout Set<String>, duplicates: inout [String]) {
        if machineryRoles.contains(node.role) || node.subrole.map(machinerySubroles.contains) == true { return }

        let clip = Self.clip(inside: node.role, frame: node.frame, clip)
        let clips = node.role == "AXScrollArea" ? clips + [node.handle] : clips
        // A text editor takes the name of what holds it: SwiftUI keeps a
        // `TextEditor`'s label off its text view.
        let holderName = (node.role == "AXGroup" || node.role == "AXScrollArea") ? clean(node.label) ?? holderName : holderName
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
        // An item of a list (`pointableItem`) is one, whatever its role — one
        // with an action reads as a button; so is a group with a name of its own.
        let marked = node.identifier == PointableID.item
        let itemKind: UIElementKind? = marked || (node.role == "AXGroup" && clean(node.label) != nil) ? .item : nil
        // A button that opens a list as a pop-up does is one; one drawn as a
        // tab is a tab.
        let popUp = node.identifier == PointableID.popUp || node.identifier == PointableID.popUpOpen
        let tab = node.identifier == PointableID.tab
        let kind: UIElementKind? = tagged.map { $0.canvas ? .canvas : (roleKind ?? .area) }
            ?? (marked ? .item : popUp ? .popUp : tab ? .tab : roleKind ?? itemKind)

        // Scrolled away inside a scroll area: kept apart, to bring into view.
        let scrolledAway = !shows && !clips.isEmpty
            && node.frame.width >= minimumSide && node.frame.height >= minimumSide
        if let kind, shows || scrolledAway {
            let name = ownName(node, kind: kind)
            if kind == .text, let words = name { texts.append(Text(frame: shows ? visible : node.frame, words: words, inSight: shows)) }
            let open = node.children.contains { $0.role == "AXMenu" } || node.identifier == PointableID.popUpOpen
            // A control that opens a sheet or popover is closed while that is not shown.
            let presents = PointableID.opens(node.identifier)
            let closed = kind == .disclosure ? node.expanded == false
                : presents.map { !shown.contains($0.lowercased()) } ?? (kind.opens && !open)
            let lent = node.role == "AXTextArea" ? holderName : nil
            drafts.append(Draft(kind: kind, stableID: tagged?.id, name: name ?? rowWords(node, kind: kind) ?? lent,
                                help: clean(node.help), enabled: node.enabled, closed: closed, presents: presents,
                                area: area, item: item, frame: node.frame, visible: shows ? visible : .null, handle: node.handle,
                                clips: clips, inSight: shows))
        }
        guard walksInside(kind) else { return }
        let inner = kind == .area ? tagged?.id ?? area : area
        // An item or a row lends its name to the controls in it.
        let innerItem = kind?.holds == true ? clean(node.label) ?? rowWords(node, kind: .row) ?? item : item
        for child in node.children where !ownWindowRoles.contains(child.role) {
            walk(child, clip: clip, clips: clips, area: inner, item: innerItem, holderName: holderName, window: window,
                 shown: shown, drafts: &drafts, texts: &texts, seen: &seen, duplicates: &duplicates)
        }
    }

    /// What an element's insides show within: a scroll area, only what is in
    /// it; a popover, all of itself, wherever it hangs; anything else, what
    /// shows of what holds it.
    static func clip(inside role: String, frame: CGRect, _ clip: CGRect) -> CGRect {
        switch role {
        case "AXScrollArea": clip.intersection(frame)
        case "AXPopover": frame
        default: clip
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

    /// A row with no words of its own reads as its first text — or, with
    /// none, as the first thing in it that says what it is: a filter's
    /// checkbox ("☐ centos"), or an entry read as one ("qa-run, Failed").
    private static func rowWords(_ node: UIRawNode, kind: UIElementKind) -> String? {
        guard kind == .row else { return nil }
        func first(_ node: UIRawNode) -> String? {
            if node.role == "AXStaticText", let words = clean(node.text) ?? clean(node.label) { return words }
            return node.children.lazy.compactMap(first).first
        }
        func said(_ node: UIRawNode) -> String? {
            clean(node.label) ?? clean(node.title) ?? node.children.lazy.compactMap(said).first
        }
        return first(node) ?? node.children.lazy.compactMap(said).first
    }

    /// The words drawn over a row of its own: a section heading, which a list
    /// draws apart from the row that holds its place.
    static func heading(over row: CGRect, among texts: [(frame: CGRect, words: String)]) -> String? {
        texts.first { row.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }?.words
    }

    /// The text a person reads as a control's caption: just before it on its
    /// row, or just above it — for a disclosure arrow, just after it ("▶ HST").
    static func caption(for control: CGRect, among texts: [(frame: CGRect, words: String)],
                        after: Bool = false) -> String? {
        if after {
            let following = texts.filter { text in
                text.frame.minX >= control.maxX - 4 && text.frame.minX - control.maxX <= 40
                    && text.frame.midY >= control.minY && text.frame.midY <= control.maxY
            }
            if let nearest = following.min(by: { $0.frame.minX < $1.frame.minX }) { return nearest.words }
        }
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
        let fa = a.inSight ? a.visible : a.frame, fb = b.inSight ? b.visible : b.frame
        let rowA = (fa.minY / 6).rounded(.down), rowB = (fb.minY / 6).rounded(.down)
        if rowA != rowB { return rowA < rowB }
        if fa.minX != fb.minX { return fa.minX < fb.minX }
        return a.handle < b.handle
    }

    /// `screen/kind/name` — what it is and what it says, where it is.
    static func derivedID(screen: String, kind: UIElementKind, name: String?) -> String {
        guard let name else { return "\(screen)/\(kind.rawValue)" }
        let slug = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "#", with: "")
        return "\(screen)/\(kind.rawValue)/\(slug.count > idNameLimit ? String(slug.prefix(idNameLimit)) : slug)"
    }
}
