// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Hand tags: the ids that stay the same across runs, languages and
/// redesigns, for the elements tours and handouts name (plan 27). Every
/// other element on screen is a target already, by what it is and what it
/// says (`list_ui_targets`); a tag only fixes its id. The tag is the
/// element's accessibility identifier, so there is nothing else to keep in
/// step with it.
extension View {
    /// This control's stable id. On a `TextEditor`, use `textEditorName`
    /// instead: SwiftUI keeps the identifier off its text view on macOS.
    func pointable(_ id: String) -> some View {
        accessibilityIdentifier(PointableID.encode(id))
    }

    /// A region's stable id — a form's section, a row of column headers. The
    /// region becomes one accessibility container named `label`, so the id
    /// is on it and not on each control inside.
    func pointableArea(_ id: String, label: String) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier(PointableID.encode(id))
    }

    /// One item of a list — a recent launch, an image, a saved query — named
    /// by what the person reads on it, so an assistant can point at the item
    /// and its buttons say whose they are ("Relaunch — notebook1").
    func pointableItem(_ name: String) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityLabel(Text(name))
    }

    /// An image's stable id: a FITS or cube canvas, which hints keep off so
    /// its marks stay in sight.
    func pointableCanvas(_ id: String, label: String) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier(PointableID.encode(id, canvas: true))
    }
}
