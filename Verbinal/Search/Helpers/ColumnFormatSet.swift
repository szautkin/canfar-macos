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
struct ColumnFormatSet: Sendable {
    /// All available options, in menu-display order.
    let choices: [ColumnFormatChoice]
    /// Id of the choice used when the user hasn't selected anything.
    let defaultUnitID: String

    /// Look up a choice by id; `nil` if unknown.
    func choice(for unitID: String) -> ColumnFormatChoice? {
        choices.first { $0.unitID == unitID }
    }

    /// The default choice — guaranteed non-nil because constructors validate
    /// `defaultUnitID` is present.
    var defaultChoice: ColumnFormatChoice {
        choice(for: defaultUnitID) ?? choices[0]
    }
}
