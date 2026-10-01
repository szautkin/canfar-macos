// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation

/// What sort of thing an element is, in the words an assistant uses (plan 27).
enum UIElementKind: String, Codable, Sendable, CaseIterable {
    case button, toggle, radio, segment, tab, textField, secureField, popUp, menuButton
    case slider, stepper, disclosure, link, row, item, menu, menuItem
    case image, canvas, indicator, text, area

    /// A control a person acts on — what `list_ui_targets` lists by default.
    var isControl: Bool {
        switch self {
        case .image, .canvas, .indicator, .text, .area: false
        default: true
        }
    }

    /// One entry of a list, holding its own controls: they are named with it.
    var holds: Bool { self == .item || self == .row }

    /// Closed until opened: a menu's choices, a folded section's contents.
    var opens: Bool {
        switch self {
        case .popUp, .menuButton, .menu, .disclosure: true
        default: false
        }
    }
}

/// A window, as its elements know it.
struct UIWindowRef: Equatable, Sendable {
    enum Kind: String, Sendable { case main, settings, sheet, other }

    /// Front to back, from 0.
    let index: Int
    let kind: Kind
    let title: String
    /// The place it shows: `search.results`, `settings.agent`, `sheet.login`.
    let screen: String
    /// On screen, top-left origin, in points.
    let frame: CGRect
    /// The `NSWindow`'s number, to draw over it.
    let number: Int
}

/// One thing on screen an assistant can name — never a value typed into a
/// field (plan 27).
struct UIElement: Equatable, Sendable, Identifiable {
    /// Hand-tagged (`stable`) or derived from where it is and what it says.
    let id: String
    let stable: Bool
    let kind: UIElementKind
    /// What the person reads on or beside it; nil when it has no words.
    let name: String?
    let help: String?
    let enabled: Bool
    /// A folded section or a menu, shut.
    let closed: Bool
    let screen: String
    /// The hand-tagged area it is in, if any.
    let area: String?
    /// The list item it belongs to — a recent launch, an image — by name.
    var item: String? = nil
    /// The whole element, and the part not clipped by a scroll area — both
    /// in its window's points, top-left origin. `visible` is null for an
    /// element scrolled out of sight.
    let frame: CGRect
    let visible: CGRect
    /// `UIWindowRef.index`.
    let window: Int
    /// The source's handle, for acting on it (a scroll, opening it).
    let handle: Int
    /// The handles of the scroll areas it is in, outermost first: what
    /// clips it, for following it as it moves.
    let clips: [Int]

    /// In sight — not scrolled away inside a scroll area.
    var inSight: Bool { !visible.isNull }
}

/// Hand-tagged ids, as the accessibility tree carries them: `vb:` before a
/// control's or an area's id, `vbc:` before a canvas's. Other identifiers —
/// SF Symbol names SwiftUI sets — are not ids.
enum PointableID {
    static let prefix = "vb:"
    static let canvasPrefix = "vbc:"
    /// Windows Verbinal names, to place or to leave out.
    static let windowPrefix = "vb-window:"

    static func encode(_ id: String, canvas: Bool = false) -> String {
        (canvas ? canvasPrefix : prefix) + id
    }

    /// The id, and whether it is a canvas; nil for an identifier that is not one.
    static func decode(_ identifier: String?) -> (id: String, canvas: Bool)? {
        guard let identifier else { return nil }
        if identifier.hasPrefix(canvasPrefix) { return (String(identifier.dropFirst(canvasPrefix.count)), true) }
        if identifier.hasPrefix(prefix) { return (String(identifier.dropFirst(prefix.count)), false) }
        return nil
    }

    /// The windows Verbinal names.
    enum Window: String, Sendable {
        case main, settings
        /// Where the person allows a session (plan 25): never a target.
        case sessionApproval
        /// The hints' own overlay: never a target.
        case hints

        var identifier: String { PointableID.windowPrefix + rawValue }

        init?(identifier: String?) {
            guard let identifier, identifier.hasPrefix(PointableID.windowPrefix) else { return nil }
            self.init(rawValue: String(identifier.dropFirst(PointableID.windowPrefix.count)))
        }

        /// The person's own: no element in it is a target.
        var isExcluded: Bool { self == .sessionApproval || self == .hints }
    }
}
