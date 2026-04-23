// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// One selectable unit option for a column.
///
/// `unitID` is the stable key persisted across sessions and used as the
/// dispatch lookup; `label` is what the header menu shows to the user.
struct ColumnFormatChoice: Sendable {
    /// Stable identifier (e.g. `"hms"`, `"nm"`, `"arcsec"`). Must be unique
    /// within a ``ColumnFormatSet``.
    let unitID: String
    /// Human-readable label shown in the unit-selector menu.
    let label: String
    /// The formatter that renders a raw value into this unit.
    let formatter: any ColumnFormatter
}

/// A group of alternative formatters for one column — the unit-switch
/// equivalent of a ``ColumnFormatter`` entry.
///
/// When a column has only one meaningful unit (collection name, calibration
/// level, etc.) it should still use ``CellFormatterRegistry/byID`` to stay
/// in the simpler code path. `ColumnFormatSet` is for columns where the
/// astronomer reasonably wants to flip units — RA / Dec / wavelength /
/// duration / angular resolution.
///
/// **Invariants (enforced at init):**
///  • `choices` is non-empty — an "empty unit menu" is meaningless, and
///    `defaultChoice` would have nothing to fall back to.
///  • `defaultUnitID` matches some entry in `choices` — a default the menu
///    can't surface would silently route to `choices[0]` instead, hiding
///    a real registration bug.
/// Violations are treated as programmer error and trap in debug / release.
struct ColumnFormatSet: Sendable {
    /// All available options, in menu-display order.
    let choices: [ColumnFormatChoice]
    /// Id of the choice used when the user hasn't selected anything.
    let defaultUnitID: String

    init(choices: [ColumnFormatChoice], defaultUnitID: String) {
        precondition(!choices.isEmpty, "ColumnFormatSet must have at least one choice")
        precondition(
            choices.contains { $0.unitID == defaultUnitID },
            "ColumnFormatSet defaultUnitID '\(defaultUnitID)' is not one of the registered choices \(choices.map(\.unitID))"
        )
        // Duplicate unitIDs would make `choice(for:)` order-dependent — catch it.
        let ids = choices.map(\.unitID)
        precondition(
            Set(ids).count == ids.count,
            "ColumnFormatSet choices must have unique unitIDs (\(ids))"
        )

        self.choices = choices
        self.defaultUnitID = defaultUnitID
    }

    /// Look up a choice by id; `nil` if unknown.
    func choice(for unitID: String) -> ColumnFormatChoice? {
        choices.first { $0.unitID == unitID }
    }

    /// The default choice — the init preconditions guarantee this is the
    /// real default entry (not a silent fallback).
    var defaultChoice: ColumnFormatChoice {
        choice(for: defaultUnitID) ?? choices[0]
    }
}
