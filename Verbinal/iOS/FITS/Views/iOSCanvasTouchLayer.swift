// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import UIKit

/// The image canvases' touches, on UIKit's own recognizers: pinch and rotate
/// together about the fingers (which move the image too), one finger pans, a
/// trackpad or mouse scroll pans, a double tap and a tap, a long press (the
/// loupe), and pointer or Pencil hover. SwiftUI's composed gestures — a long
/// press "exclusively before" a drag, beside a magnify — let two-finger touches
/// go unanswered (the person, 2026-10-23: zoom "not working").
struct iOSCanvasTouchLayer: UIViewRepresentable {
    enum Manipulation {
        /// Two fingers came down, here.
        case began(centroid: CGPoint)
        /// Scaled and turned since they came down; between them now.
        case changed(scale: CGFloat, rotation: CGFloat, centroid: CGPoint)
        case ended
    }

    enum Press {
        case moved(CGPoint)
        case lifted(CGPoint)
        case cancelled
    }

    var onTap: () -> Void
    var onDoubleTap: (CGPoint) -> Void
    var onManipulate: (Manipulation) -> Void
    /// A one-finger drag or a scroll: how far it moved since the last call.
    var onPan: (CGSize) -> Void
    var onPress: (Press) -> Void
    /// Where a pointer or Pencil hovers; nil when it leaves.
    var onHover: (CGPoint?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinched(_:)))
        let rotation = UIRotationGestureRecognizer(target: coordinator, action: #selector(Coordinator.rotated(_:)))
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.allowedScrollTypesMask = .all
        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.require(toFail: doubleTap)
        let press = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.pressed(_:)))
        press.minimumPressDuration = 0.35
        let hover = UIHoverGestureRecognizer(target: coordinator, action: #selector(Coordinator.hovered(_:)))

        for recognizer in [pinch, rotation, pan, doubleTap, tap, press, hover] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        coordinator.pinch = pinch
        coordinator.rotation = rotation
        coordinator.press = press
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.layer = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var layer: iOSCanvasTouchLayer
        weak var pinch: UIPinchGestureRecognizer?
        weak var rotation: UIRotationGestureRecognizer?
        weak var press: UILongPressGestureRecognizer?
        /// A pinch or a turn is under way (the two share one manipulation).
        private var manipulating = false

        init(_ layer: iOSCanvasTouchLayer) { self.layer = layer }

        // MARK: Pinch and rotate, as one

        @objc func pinched(_ recognizer: UIPinchGestureRecognizer) { manipulate(recognizer) }
        @objc func rotated(_ recognizer: UIRotationGestureRecognizer) { manipulate(recognizer) }

        private func manipulate(_ recognizer: UIGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let pinching = Self.isActive(pinch), turning = Self.isActive(rotation)
            switch recognizer.state {
            case .began where !manipulating:
                manipulating = true
                layer.onManipulate(.began(centroid: recognizer.location(in: view)))
                fallthrough
            case .began, .changed:
                layer.onManipulate(.changed(scale: pinching ? pinch?.scale ?? 1 : 1,
                                            rotation: turning ? rotation?.rotation ?? 0 : 0,
                                            centroid: recognizer.location(in: view)))
            case .ended, .cancelled, .failed:
                guard manipulating, !pinching, !turning else { return }
                manipulating = false
                layer.onManipulate(.ended)
            default:
                break
            }
        }

        private static func isActive(_ recognizer: UIGestureRecognizer?) -> Bool {
            guard let state = recognizer?.state else { return false }
            return state == .began || state == .changed
        }

        // MARK: Pan, taps, press, hover

        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view, recognizer.state == .began || recognizer.state == .changed else { return }
            let moved = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            layer.onPan(CGSize(width: moved.x, height: moved.y))
        }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            layer.onDoubleTap(recognizer.location(in: view))
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) { layer.onTap() }

        @objc func pressed(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began, .changed: layer.onPress(.moved(recognizer.location(in: view)))
            case .ended: layer.onPress(.lifted(recognizer.location(in: view)))
            default: layer.onPress(.cancelled)
            }
        }

        @objc func hovered(_ recognizer: UIHoverGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began, .changed: layer.onHover(recognizer.location(in: view))
            default: layer.onHover(nil)
            }
        }

        // MARK: Delegate

        /// Pinch and rotate run together; the loupe runs alone.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            let pair: Set<ObjectIdentifier> = [ObjectIdentifier(gestureRecognizer), ObjectIdentifier(other)]
            guard let pinch, let rotation else { return false }
            return pair == [ObjectIdentifier(pinch), ObjectIdentifier(rotation)]
                || other is UIHoverGestureRecognizer || gestureRecognizer is UIHoverGestureRecognizer
        }

        /// While the loupe is out, nothing pans or zooms under it.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer !== press, let press else { return true }
            return !(press.state == .began || press.state == .changed)
        }
    }
}
