// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import AppKit
import ApplicationServices

/// Follows each hinted element on screen (plan 27 O): it holds the
/// element's accessibility object, and the scroll areas that clip it, and
/// reads where they are now — a few attributes each, never a whole tree.
@MainActor
final class UIHintTracker {
    struct Followed {
        let element: AXUIElement
        let clips: [AXUIElement]
        let window: Int
    }

    private var followed: [String: Followed] = [:]

    var isEmpty: Bool { followed.isEmpty }

    func follow(_ id: String, _ what: Followed) { followed[id] = what }

    /// Forgets what is no longer hinted.
    func keep(only ids: Set<String>) { followed = followed.filter { ids.contains($0.key) } }

    /// Where each followed element is now — its visible part, in its window's
    /// points — and those gone: no longer in the tree, or clipped out of
    /// sight.
    func read() -> (frames: [String: (frame: CGRect, window: Int)], gone: Set<String>) {
        var frames: [String: (frame: CGRect, window: Int)] = [:]
        var gone: Set<String> = []
        for (id, what) in followed {
            guard let window = NSApp.window(withWindowNumber: what.window), window.isVisible,
                  let frame = Self.frame(of: what.element) else {
                gone.insert(id)
                continue
            }
            let windowFrame = Self.accessibilityFrame(of: window)
            var visible = frame.intersection(windowFrame)
            for clip in what.clips {
                guard let clipFrame = Self.frame(of: clip) else { continue }
                visible = visible.intersection(clipFrame)
            }
            guard !visible.isNull, visible.width >= UIElementRules.minimumSide,
                  visible.height >= UIElementRules.minimumSide else {
                gone.insert(id)
                continue
            }
            frames[id] = (visible.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY), what.window)
        }
        return (frames, gone)
    }

    /// A window's frame as the accessibility API gives frames: top-left origin.
    static func accessibilityFrame(of window: NSWindow) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: window.frame.minX, y: top - window.frame.maxY,
                      width: window.frame.width, height: window.frame.height)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
}
#endif
