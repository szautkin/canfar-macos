// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import AppKit
import ApplicationServices

/// The app's own windows, read through the accessibility API the way
/// VoiceOver reads them (plan 27). It needs no Accessibility permission —
/// a process may ask about itself — and works in the App Sandbox. The first
/// read wakes SwiftUI's accessibility tree, which it builds only when asked.
///
/// It reads what an element is and what it says. It never reads what is
/// typed in a field: only a static text's words are read as a value.
@MainActor
final class AXElementSource: UIElementSource {
    /// A window's place on screen — `search.results`, `settings.agent` — for
    /// the kind of window it is; for a sheet, the screen of its parent.
    typealias ScreenNamer = (_ kind: UIWindowRef.Kind, _ parentScreen: String?, _ title: String) -> String

    private let screenName: ScreenNamer
    private let places: UIWindowPlaces
    /// The elements of the last snapshot, by `UIElement.handle`.
    private(set) var handles: [AXUIElement] = []

    /// Bounds on one read: a tree deeper or wider is cut short, not hung on.
    /// What is in sight is read first; what is scrolled away gets what is
    /// left, for at most `awayTime`.
    static let maxDepth = 60
    static let maxNodes = 6_000
    static let awayTime: Duration = .milliseconds(800)
    private let maxNodes: Int

    init(places: UIWindowPlaces = .shared, maxNodes: Int = AXElementSource.maxNodes,
         screenName: @escaping ScreenNamer) {
        self.places = places
        self.maxNodes = maxNodes
        self.screenName = screenName
    }

    private var awake = false
    /// The windows read before: SwiftUI has built their trees.
    private var warmed: Set<Int> = []

    /// Waits until what is on screen can be read whole. The app builds its
    /// accessibility tree when first asked, a run-loop turn or more later:
    /// until then a window has no frame. And a window read for the first
    /// time — Settings just opened, a sheet — comes back half-built, so it is
    /// asked once and given a moment. At most two seconds; none when the
    /// service is not answering at all.
    func ready() async {
        let app = AXUIElementCreateApplication(getpid())
        for _ in 0..<20 where !awake {
            let windows = (Self.value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            if windows.contains(where: { Self.frame(of: $0).width > 0 }) {
                awake = true
            } else if Self.unanswered(windows) {
                return
            } else {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let fresh = Set(NSApp.windows.filter { window in
            window.isVisible && PointableID.Window(identifier: window.identifier?.rawValue) != .hints
        }.map(\.windowNumber)).subtracting(warmed)
        guard awake, !fresh.isEmpty else { return }
        _ = snapshot()
        warmed.formUnion(fresh)
        try? await Task.sleep(for: .milliseconds(250))
    }

    /// The service hands back the application where each window should be:
    /// nothing can be read until it recovers.
    private static func unanswered(_ windows: [AXUIElement]) -> Bool {
        !windows.isEmpty && windows.allSatisfy { (value($0, kAXRoleAttribute) as? String) == "AXApplication" }
    }

    /// Whether the app's own windows can be read now.
    static var readable: Bool {
        let app = AXUIElementCreateApplication(getpid())
        let windows = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return !unanswered(windows)
    }

    func snapshot() -> UISnapshot {
        handles = []
        var reading = Reading(budget: maxNodes)
        let app = AXUIElementCreateApplication(getpid())
        // Front to back, as the accessibility API lists them.
        let axWindows = (Self.value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var reads: [(ref: UIWindowRef, root: UIRawNode)] = []

        var seenWindows: Set<Int> = []
        for axWindow in axWindows {
            let frame = Self.frame(of: axWindow)
            // A window is read once: another at the same frame (an overlay)
            // must not read as it.
            guard let window = Self.window(at: frame), seenWindows.insert(window.windowNumber).inserted else { continue }
            let place = places.place(of: window)
            if place?.isExcluded == true { continue }
            let kind: UIWindowRef.Kind = switch place {
            case .main: .main
            case .settings: .settings
            default: .other
            }
            let title = window.title
            let screen = screenName(kind, nil, title)

            // Its sheet is in front of it — and a sheet's own sheet in front of
            // that, as the launch form's Image Content Discovery: each listed
            // first, as its own window.
            var sheets: [(ax: AXUIElement, window: NSWindow, screen: String)] = []
            var host = (ax: axWindow, window: window, screen: screen)
            while let sheetWindow = host.window.attachedSheet,
                  let axSheet = Self.element(of: sheetWindow, among: [host.ax, axWindow]) {
                host = (axSheet, sheetWindow, screenName(.sheet, host.screen, sheetWindow.title))
                sheets.append(host)
            }
            for sheet in sheets.reversed() where seenWindows.insert(sheet.window.windowNumber).inserted {
                let ref = UIWindowRef(index: reads.count, kind: .sheet, title: sheet.window.title, screen: sheet.screen,
                                      frame: Self.frame(of: sheet.ax), number: sheet.window.windowNumber)
                reads.append((ref, read(sheet.ax, depth: 0, clip: ref.frame, at: [], in: ref.index, &reading)))
            }

            let ref = UIWindowRef(index: reads.count, kind: kind, title: title, screen: screen,
                                  frame: frame, number: window.windowNumber)
            reads.append((ref, read(axWindow, depth: 0, clip: frame, at: [], in: ref.index, &reading)))
        }
        readAway(&reading, into: &reads)

        var elements: [UIElement] = []
        var outOfSight: [UIElement] = []
        var duplicates: [String] = []
        for (ref, root) in reads {
            let result = UIElementRules.elements(in: root, window: ref)
            elements += result.elements
            outOfSight += result.outOfSight
            duplicates += result.duplicateIDs
        }
        let refs = reads.map(\.ref)
        var snapshot = UISnapshot(windows: refs, elements: elements, duplicateIDs: duplicates)
        snapshot.outOfSight = outOfSight
        let own = NSApp.windows.filter { PointableID.Window(identifier: $0.identifier?.rawValue) != .hints }
        snapshot.problem = UISnapshot.problem(
            windowsRead: refs.count, unanswered: Self.unanswered(axWindows), anyUp: own.contains(where: \.isVisible),
            anyShowing: !NSApp.isHidden && own.contains { $0.isVisible && !$0.isMiniaturized && $0.isOnActiveSpace })
        return snapshot
    }

    /// The element behind a handle from the last snapshot.
    func element(_ handle: Int) -> AXUIElement? {
        handles.indices.contains(handle) ? handles[handle] : nil
    }

    /// Every element of the last snapshot, by identity.
    func everything() -> Set<AXUIElement> { Set(handles) }

    /// The handle the same element has in the last snapshot.
    func handle(of element: AXUIElement) -> Int? {
        handles.firstIndex { CFEqual($0, element) }
    }

    /// Scrolls each scroll area round an element of the last snapshot —
    /// innermost first — until the element is in sight in it, and answers
    /// its accessibility object, to find again in the next snapshot.
    /// SwiftUI's controls do not take the accessibility action for this, so
    /// the scroll view behind each area is asked directly, as AppKit asks it;
    /// when that does not bring it in, the area is paged towards it, as
    /// VoiceOver pages, a page at a time.
    func scrollIntoView(_ element: UIElement) async -> AXUIElement? {
        guard let target = self.element(element.handle) else { return nil }
        for clip in element.clips.reversed() {
            guard let area = self.element(clip) else { continue }
            if let areaFrame = Self.readFrame(area), let targetFrame = Self.readFrame(target),
               !Self.shows(targetFrame, in: areaFrame), let scrollView = Self.scrollView(at: areaFrame) {
                Self.reveal(targetFrame, in: scrollView)
                try? await Task.sleep(for: .milliseconds(80))
            }
            var last: CGRect?
            for _ in 0..<Self.maxPages {
                guard let areaFrame = Self.readFrame(area), let targetFrame = Self.readFrame(target),
                      !Self.shows(targetFrame, in: areaFrame), targetFrame != last else { break }
                last = targetFrame
                let page = targetFrame.minY < areaFrame.minY ? "AXScrollUpByPage" : "AXScrollDownByPage"
                guard AXUIElementPerformAction(area, page as CFString) == .success else { break }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        return target
    }

    /// Selects a list's row or item of the last snapshot, as a click selects
    /// it: a row by its selected state — confirmed, since a list without a
    /// selection keeps none — an item by its own action, which for an item
    /// is its selection (`pointableItem(select:)`). Nothing else: a button is
    /// never pressed by this. Answers whether it is selected.
    func select(_ element: UIElement) async -> Bool {
        guard let target = self.element(element.handle) else { return false }
        switch element.kind {
        case .row:
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(target, kAXSelectedAttribute as CFString, &settable) == .success,
                  settable.boolValue,
                  AXUIElementSetAttributeValue(target, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
            else { return false }
            try? await Task.sleep(for: .milliseconds(120))
            return (Self.value(target, kAXSelectedAttribute) as? Bool) == true
        case .item:
            var names: CFArray?
            guard AXUIElementCopyActionNames(target, &names) == .success,
                  (names as? [String])?.contains(kAXPressAction) == true else { return false }
            return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
        default:
            return false
        }
    }

    /// Opens a closed section or menu of the last snapshot, as a click opens
    /// it (plan 27 C). A section is confirmed open. A menu opens after this
    /// returns: an open menu holds the app until the person chooses from it
    /// or presses Esc, and the answer must not wait on them. Answers whether
    /// it is open, or opening.
    func open(_ element: UIElement) async -> Bool {
        guard let target = self.element(element.handle), element.closed else { return false }
        switch element.kind {
        case .disclosure:
            guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else { return false }
            try? await Task.sleep(for: .milliseconds(150))
            return Self.expanded(target) == true
        case .popUp, .menuButton, .menu:
            DispatchQueue.main.async { AXUIElementPerformAction(target, kAXPressAction as CFString) }
            return true
        default:
            return false
        }
    }

    /// Closes an open section, or an open menu, as the person would.
    func close(_ element: UIElement) async -> Bool {
        guard let target = self.element(element.handle), !element.closed else { return false }
        switch element.kind {
        case .disclosure:
            guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else { return false }
            try? await Task.sleep(for: .milliseconds(150))
            return Self.expanded(target) == false
        case .popUp, .menuButton, .menu:
            let menus = ((Self.value(target, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
                .filter { (Self.value($0, kAXRoleAttribute) as? String) == "AXMenu" }
            return menus.contains { AXUIElementPerformAction($0, kAXCancelAction as CFString) == .success }
        default:
            return false
        }
    }

    /// Whether a disclosure is open: by `AXExpanded`, or by its 0-or-1 state.
    private static func expanded(_ element: AXUIElement) -> Bool? {
        if let expanded = value(element, kAXExpandedAttribute) as? Bool { return expanded }
        return (value(element, kAXValueAttribute) as? NSNumber).map { $0.intValue != 0 }
    }

    /// Pages tried, at most, in one scroll area.
    static let maxPages = 30

    /// Whether `frame` shows in `area`: wholly, or — for one taller than the
    /// area — in part.
    private static func shows(_ frame: CGRect, in area: CGRect) -> Bool {
        frame.height < area.height
            ? frame.minY >= area.minY - 1 && frame.maxY <= area.maxY + 1
            : frame.intersects(area)
    }

    private static func readFrame(_ element: AXUIElement) -> CGRect? {
        let frame = frame(of: element)
        return frame.width > 0 || frame.height > 0 ? frame : nil
    }

    /// The scroll view behind a scroll area whose frame on screen is `frame`
    /// (accessibility coordinates, top-left origin): the one that overlaps
    /// it most. Not the same frame: a form under a toolbar scrolls beneath
    /// it, and its area starts below.
    private static func scrollView(at frame: CGRect) -> NSScrollView? {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        func onScreen(_ view: NSView) -> CGRect? {
            guard let window = view.window else { return nil }
            let cocoa = window.convertToScreen(view.convert(view.bounds, to: nil))
            return CGRect(x: cocoa.minX, y: top - cocoa.maxY, width: cocoa.width, height: cocoa.height)
        }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        func overlap(_ a: CGRect) -> CGFloat {
            let common = a.intersection(frame)
            guard !common.isNull else { return 0 }
            let shared = common.width * common.height
            return shared / (a.width * a.height + frame.width * frame.height - shared)
        }
        let all = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(scrollViews)
        let scored = all.compactMap { view in onScreen(view).map { (view: view, score: overlap($0)) } }
        return scored.filter { $0.score > 0.5 }.max { $0.score < $1.score }?.view
    }

    /// Scrolls `scrollView` so `rect` (accessibility coordinates) shows,
    /// with a little room round it.
    private static func reveal(_ rect: CGRect, in scrollView: NSScrollView) {
        guard let window = scrollView.window, let document = scrollView.documentView else { return }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let cocoa = CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        let inDocument = document.convert(window.convertFromScreen(cocoa), from: nil)
        document.scrollToVisible(inDocument.insetBy(dx: -8, dy: -8))
    }

    // MARK: - Reading

    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, "AXIdentifier", kAXDescriptionAttribute, kAXTitleAttribute,
        kAXTitleUIElementAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXExpandedAttribute, kAXChildrenAttribute,
    ] as CFArray

    /// One read of the windows: what is left of its budget, and what was
    /// put off because it is scrolled away.
    private struct Reading {
        var budget: Int
        var away: [Away] = []
    }

    /// The insides of something scrolled away — or the rows of a list out of
    /// sight, nearest first — read once everything in sight is, so a long
    /// list never hides what shows beside it.
    private struct Away {
        let window: Int
        let path: [Int]
        let depth: Int
        let children: [AXUIElement]
    }

    /// Reads an element and what is inside it. With a `clip` — the part of
    /// the window its scroll areas show — what lies outside it is put off;
    /// without one, everything is read.
    private func read(_ element: AXUIElement, depth: Int, clip: CGRect?, at path: [Int], in window: Int,
                      _ reading: inout Reading) -> UIRawNode {
        reading.budget -= 1
        handles.append(element)
        var node = UIRawNode(role: "AXUnknown", handle: handles.count - 1)
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, Self.attributes, [], &values) == .success,
              let list = values as? [AnyObject], list.count == 13 else { return node }
        func string(_ i: Int) -> String? { list[i] as? String }
        node.role = string(0) ?? "AXUnknown"
        node.subrole = string(1)
        node.identifier = string(2)
        node.label = string(3)
        node.title = string(4)
        if CFGetTypeID(list[5]) == AXUIElementGetTypeID() {
            // A caption is a static text: its words are its value.
            node.titleText = Self.value(list[5] as! AXUIElement, kAXValueAttribute) as? String
        }
        node.placeholder = string(6)
        node.help = string(7)
        node.frame = CGRect(origin: Self.point(list[8]) ?? .zero, size: Self.size(list[9]) ?? .zero)
        node.enabled = (list[10] as? Bool) ?? true
        node.expanded = list[11] as? Bool
        if node.expanded == nil, node.role == "AXDisclosureTriangle" {
            // A disclosure says whether it is open by its state, 0 or 1 — a
            // control's state, not anything typed.
            node.expanded = (Self.value(element, kAXValueAttribute) as? NSNumber).map { $0.intValue != 0 }
        }
        // A sheet is read as its own window.
        if depth > 0, UIElementRules.ownWindowRoles.contains(node.role) { return node }
        if node.role == "AXStaticText" {
            // The one value read: the words a static text shows.
            node.text = Self.value(element, kAXValueAttribute) as? String
        }
        guard depth < Self.maxDepth, let children = list[12] as? [AXUIElement], !children.isEmpty else { return node }
        guard let shown = clip else {
            for child in children where reading.budget > 0 {
                node.children.append(read(child, depth: depth + 1, clip: nil, at: [], in: window, &reading))
            }
            return node
        }
        if node.frame.width > 0, node.frame.height > 0, !node.frame.intersects(shown) {
            reading.away.append(Away(window: window, path: path, depth: depth, children: children))
            return node
        }
        let inner = node.role == "AXScrollArea" ? shown.intersection(node.frame) : shown
        // A list says which of its rows show: the others are not even looked
        // at until everything in sight has been read.
        let showing = Self.rowsInSight(of: element, role: node.role)
        var later: [Int] = []
        for (index, child) in children.enumerated() where reading.budget > 0 {
            if let showing, !showing.contains(child) {
                later.append(index)
                continue
            }
            node.children.append(read(child, depth: depth + 1, clip: inner, at: path + [node.children.count],
                                      in: window, &reading))
        }
        if !later.isEmpty {
            let first = children.indices.first { showing?.contains(children[$0]) == true } ?? 0
            let nearest = later.sorted { abs($0 - first) < abs($1 - first) }
            reading.away.append(Away(window: window, path: path, depth: depth, children: nearest.map { children[$0] }))
        }
        return node
    }

    /// The rows of a list that show, as the list says; nil when it does not.
    private static func rowsInSight(of element: AXUIElement, role: String) -> Set<AXUIElement>? {
        let attribute: String
        switch role {
        case "AXTable", "AXOutline": attribute = "AXVisibleRows"
        case "AXList": attribute = "AXVisibleChildren"
        default: return nil
        }
        guard let rows = value(element, attribute) as? [AXUIElement], !rows.isEmpty else { return nil }
        return Set(rows)
    }

    /// What was put off, a row from each in turn, while budget and time last.
    private func readAway(_ reading: inout Reading, into reads: inout [(ref: UIWindowRef, root: UIRawNode)]) {
        let deadline = ContinuousClock.now + Self.awayTime
        var taken = Array(repeating: 0, count: reading.away.count)
        var found = Array(repeating: [UIRawNode](), count: reading.away.count)
        var more = true
        while more, reading.budget > 0, ContinuousClock.now < deadline {
            more = false
            for index in reading.away.indices where taken[index] < reading.away[index].children.count {
                guard reading.budget > 0 else { break }
                let away = reading.away[index]
                found[index].append(read(away.children[taken[index]], depth: away.depth + 1, clip: nil, at: [],
                                         in: away.window, &reading))
                taken[index] += 1
                more = true
            }
        }
        for (away, children) in zip(reading.away, found) where !children.isEmpty {
            reads[away.window].root.append(children, at: away.path[...])
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func point(_ value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func frame(of element: AXUIElement) -> CGRect {
        CGRect(origin: value(element, kAXPositionAttribute).flatMap(point) ?? .zero,
               size: value(element, kAXSizeAttribute).flatMap(size) ?? .zero)
    }

    // MARK: - Windows

    /// A sheet's accessibility element: among the children of what it hangs
    /// from, or of the window under them all.
    private static func element(of sheet: NSWindow, among hosts: [AXUIElement]) -> AXUIElement? {
        for host in hosts {
            let children = (value(host, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            if let found = children.first(where: { child in
                (value(child, kAXRoleAttribute) as? String) == "AXSheet" && window(at: frame(of: child)) === sheet
            }) { return found }
        }
        return nil
    }

    /// The app's window at an accessibility frame (top-left origin), by its
    /// AppKit frame (bottom-left origin).
    private static func window(at frame: CGRect) -> NSWindow? {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let cocoa = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
        // A closed window can linger in the list, at the same frame: only one
        // showing counts. Verbinal's own overlays are never it.
        return NSApp.windows.first { window in
            window.isVisible && PointableID.Window(identifier: window.identifier?.rawValue) != .hints
                && abs(window.frame.minX - cocoa.minX) < 1 && abs(window.frame.minY - cocoa.minY) < 1
                && abs(window.frame.width - cocoa.width) < 1 && abs(window.frame.height - cocoa.height) < 1
        }
    }
}

private extension UIRawNode {
    /// Adds what was read later to the node at `path`.
    mutating func append(_ more: [UIRawNode], at path: ArraySlice<Int>) {
        guard let first = path.first else {
            children += more
            return
        }
        children[first].append(more, at: path.dropFirst())
    }
}
#endif
