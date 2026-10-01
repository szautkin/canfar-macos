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
    static let maxDepth = 60
    static let maxNodes = 6_000

    init(places: UIWindowPlaces = .shared, screenName: @escaping ScreenNamer) {
        self.places = places
        self.screenName = screenName
    }

    func snapshot() -> UISnapshot {
        handles = []
        var budget = Self.maxNodes
        let app = AXUIElementCreateApplication(getpid())
        // Front to back, as the accessibility API lists them.
        let axWindows = (Self.value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var refs: [UIWindowRef] = []
        var elements: [UIElement] = []
        var duplicates: [String] = []

        for axWindow in axWindows {
            let frame = Self.frame(of: axWindow)
            guard let window = Self.window(at: frame), window.isVisible else { continue }
            let place = places.place(of: window)
            if place?.isExcluded == true { continue }
            let kind: UIWindowRef.Kind = switch place {
            case .main: .main
            case .settings: .settings
            default: .other
            }
            let title = window.title
            let screen = screenName(kind, nil, title)

            // Its sheet is in front of it: listed first, as its own window.
            let sheets = ((Self.value(axWindow, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
                .filter { (Self.value($0, kAXRoleAttribute) as? String) == "AXSheet" }
            for axSheet in sheets {
                guard let sheetWindow = window.attachedSheet else { continue }
                let ref = UIWindowRef(index: refs.count, kind: .sheet, title: sheetWindow.title,
                                      screen: screenName(.sheet, screen, sheetWindow.title),
                                      frame: Self.frame(of: axSheet), number: sheetWindow.windowNumber)
                let result = UIElementRules.elements(in: read(axSheet, depth: 0, budget: &budget), window: ref)
                refs.append(ref)
                elements += result.elements
                duplicates += result.duplicateIDs
            }

            let ref = UIWindowRef(index: refs.count, kind: kind, title: title, screen: screen,
                                  frame: frame, number: window.windowNumber)
            let result = UIElementRules.elements(in: read(axWindow, depth: 0, budget: &budget), window: ref)
            refs.append(ref)
            elements += result.elements
            duplicates += result.duplicateIDs
        }
        return UISnapshot(windows: refs, elements: elements, duplicateIDs: duplicates)
    }

    /// The element behind a handle from the last snapshot.
    func element(_ handle: Int) -> AXUIElement? {
        handles.indices.contains(handle) ? handles[handle] : nil
    }

    // MARK: - Reading

    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, "AXIdentifier", kAXDescriptionAttribute, kAXTitleAttribute,
        kAXTitleUIElementAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXExpandedAttribute, kAXChildrenAttribute,
    ] as CFArray

    private func read(_ element: AXUIElement, depth: Int, budget: inout Int) -> UIRawNode {
        budget -= 1
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
        guard depth < Self.maxDepth, let children = list[12] as? [AXUIElement] else { return node }
        for child in children where budget > 0 {
            node.children.append(read(child, depth: depth + 1, budget: &budget))
        }
        return node
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

    /// The app's window at an accessibility frame (top-left origin), by its
    /// AppKit frame (bottom-left origin).
    private static func window(at frame: CGRect) -> NSWindow? {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let cocoa = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
        return NSApp.windows.first { window in
            abs(window.frame.minX - cocoa.minX) < 1 && abs(window.frame.minY - cocoa.minY) < 1
                && abs(window.frame.width - cocoa.width) < 1 && abs(window.frame.height - cocoa.height) < 1
        }
    }
}
#endif
