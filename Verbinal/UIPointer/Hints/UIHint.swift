// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation

/// A hint on the app's interface: a ring round an element, and, for a
/// bubble, the assistant's words beside it (plan 27). Transient — never
/// saved, never exported — and not a mark on an image.
struct UIHint: Identifiable, Equatable, Sendable {
    enum Style: String, Sendable, Codable { case bubble, ring }

    /// The element's id: one hint per element.
    let id: String
    /// The set it came in.
    let set: String
    let style: Style
    let title: String?
    let text: String?
    /// Its number, in a numbered set.
    let number: Int?
    /// Where the element is — its visible part, in its window's points.
    var frame: CGRect
    var kind: UIElementKind
    let screen: String
    /// The `NSWindow` it is on.
    var window: Int
}

/// Hints shown together, by one call.
struct UIHintSet: Equatable, Sendable {
    let id: String
    let numbered: Bool
    let dim: Bool
    /// Nil: until the person closes them.
    let seconds: Double?
}

/// How hints went.
enum UIHintDismissal: String, Sendable, Codable {
    case timedOut, closed, escape, cleared, replaced, screenChanged, elementGone, windowClosed
}
