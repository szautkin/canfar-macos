// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import AppKit
import SwiftUI

/// Invisible NSView that captures scroll wheel, click, and drag events —
/// the input surface of the FITS canvas and the cube slice.
/// - Scroll: zoom toward cursor
/// - Shift+scroll: horizontal pan
/// - Click (no drag): place crosshair
/// - Drag: pan image
/// Marks (`pointer`) get the first say over every press, so a press on a
/// mark moves it instead of panning the image out from under it — after
/// `area`: while it is armed, or with ⌘ held, a drag draws a box.
struct ScrollCaptureView: NSViewRepresentable {
    let onScroll: (CGFloat, CGPoint) -> Void
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onHover: ((CGPoint) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    /// The pointer left the view.
    var onHoverEnd: (() -> Void)?
    var pointer: ScrollCaptureNSView.Pointer?
    var area: ScrollCaptureNSView.Area?
    /// False where the host takes keys through SwiftUI focus (the cube):
    /// a click must not move the keyboard to this view.
    var takesKeyFocus = true

    func makeNSView(context: Context) -> ScrollCaptureNSView {
        let view = ScrollCaptureNSView()
        apply(to: view)
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: view)
        view.addTrackingArea(area)
        return view
    }

    func updateNSView(_ nsView: ScrollCaptureNSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: ScrollCaptureNSView) {
        view.onScroll = onScroll
        view.onPan = onPan
        view.onClick = onClick
        view.onDrag = onDrag
        view.onHover = onHover
        view.onMagnify = onMagnify
        view.onHoverEnd = onHoverEnd
        view.takesKeyFocus = takesKeyFocus
        let drawing = (pointer?.drawing ?? false) || (area?.armed ?? false)
        view.pointer = pointer
        view.area = area
        if drawing != view.drawCursor {
            view.drawCursor = drawing
            view.window?.invalidateCursorRects(for: view)
        }
    }
}

class ScrollCaptureNSView: NSView {
    /// What else the pointer and keys do over the canvas — the marks.
    struct Pointer {
        /// A press; true when it is taken, and the view must not pan.
        var press: (CGPoint) -> Bool
        var drag: (CGPoint) -> Void
        var release: () -> Void
        /// A double-click; true when it was taken.
        var doubleClick: (CGPoint) -> Bool
        /// The menu for a right-click here; nil leaves the view's own.
        var menu: (CGPoint) -> NSMenu?
        var key: (Key) -> Bool
        /// Drawing is armed: the pointer is a crosshair.
        var drawing: Bool
    }

    enum Key { case delete, escape }

    /// Dragging out a box — Select Area. It is asked before the marks and
    /// the pan, because arming it, or holding ⌘, says what the drag is for.
    struct Area {
        /// Every drag draws a box, not only one with ⌘ held.
        var armed: Bool
        /// The box as it is dragged, in the view's points; nil when it is gone.
        var changed: (CGRect?) -> Void
        /// Let go, from the press to here.
        var ended: (CGPoint, CGPoint) -> Void
        /// Escape: put it down.
        var disarm: () -> Void
    }

    var onScroll: ((CGFloat, CGPoint) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onHover: ((CGPoint) -> Void)?
    var onHoverEnd: (() -> Void)?
    var pointer: Pointer?
    var area: Area?
    var drawCursor = false
    var takesKeyFocus = true

    private var mouseDownLocation: CGPoint?
    private var didDrag = false
    /// The press went to `pointer`.
    private var pointerHasPress = false
    /// Where a box being dragged out began, and whether it was armed.
    private var areaStart: (point: CGPoint, armed: Bool)?
    private var areaMoved = false
    private static let dragThreshold: CGFloat = 3.0

    override func scrollWheel(with event: NSEvent) {
        let location = flippedLocation(for: event)

        if event.modifierFlags.contains(.command) {
            // Cmd+scroll = zoom toward crosshair/cursor (matches Windows Ctrl+scroll)
            let delta = event.scrollingDeltaY
            if abs(delta) > 0.1 { onScroll?(delta, location) }
            return
        }

        if event.modifierFlags.contains(.shift) {
            // Shift+scroll = horizontal pan
            let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            if abs(dx) > 0.1 { onPan?(dx, 0) }
            return
        }

        // Bare scroll = vertical pan (matches Windows bare scroll)
        let dy = event.scrollingDeltaY
        if abs(dy) > 0.1 { onPan?(0, -dy) }
    }

    override func mouseDown(with event: NSEvent) {
        let location = flippedLocation(for: event)
        if let area, area.armed || event.modifierFlags.contains(.command) {
            areaStart = (location, area.armed)
            areaMoved = false
            return
        }
        if event.clickCount == 2, pointer?.doubleClick(location) == true { return }
        pointerHasPress = pointer?.press(location) ?? false
        guard !pointerHasPress else { return }
        mouseDownLocation = location
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = areaStart?.point {
            let current = flippedLocation(for: event)
            if !areaMoved && hypot(current.x - start.x, current.y - start.y) < Self.dragThreshold { return }
            areaMoved = true
            area?.changed(CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                                 width: abs(current.x - start.x), height: abs(current.y - start.y)))
            return
        }
        if pointerHasPress {
            pointer?.drag(flippedLocation(for: event))
            return
        }
        guard let start = mouseDownLocation else { return }
        let current = flippedLocation(for: event)
        let dx = current.x - start.x
        let dy = current.y - start.y
        if !didDrag && sqrt(dx * dx + dy * dy) < Self.dragThreshold { return }
        didDrag = true
        onDrag?(event.deltaX, -event.deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        if let (start, armed) = areaStart {
            areaStart = nil
            if areaMoved {
                area?.ended(start, flippedLocation(for: event))
            } else {
                area?.changed(nil)
                // ⌘-click without a drag is a click, as before.
                if !armed { onClick?(start) }
            }
            return
        }
        if pointerHasPress {
            pointerHasPress = false
            pointer?.release()
            return
        }
        if !didDrag, let loc = mouseDownLocation {
            onClick?(loc)
        }
        mouseDownLocation = nil
        didDrag = false
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(flippedLocation(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        onHoverEnd?()
    }

    var onMagnify: ((CGFloat) -> Void)?

    override func magnify(with event: NSEvent) {
        // Trackpad pinch: use magnification directly (not routed through scroll)
        if abs(event.magnification) > 0.001 {
            onMagnify?(event.magnification)
        }
    }

    override var acceptsFirstResponder: Bool { takesKeyFocus }

    override func menu(for event: NSEvent) -> NSMenu? {
        pointer?.menu(flippedLocation(for: event)) ?? super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        let key: Key?
        switch event.specialKey {
        case .delete?, .deleteForward?: key = .delete
        default: key = event.keyCode == 53 ? .escape : nil
        }
        if key == .escape, let area, area.armed || areaStart != nil {
            areaStart = nil
            area.changed(nil)
            area.disarm()
            return
        }
        if let key, pointer?.key(key) == true { return }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        if drawCursor { addCursorRect(bounds, cursor: .crosshair) }
    }

    private func flippedLocation(for event: NSEvent) -> CGPoint {
        let loc = convert(event.locationInWindow, from: nil)
        return CGPoint(x: loc.x, y: bounds.height - loc.y)
    }
}
#endif
