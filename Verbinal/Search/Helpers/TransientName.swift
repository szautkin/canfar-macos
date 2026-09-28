// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// An IAU transient designation — `AT 2023ixf`, `SN2023ixf`, `2023ixf` —
/// and the spellings the resolver's services know it by.
///
/// The TNS names a transient `AT` until it is classified; NED knows the
/// classified one as `SN 2023ixf`, SIMBAD as `SN2023ixf`, and neither the
/// `AT` form nor the bare one (QA M12). A TNS lookup of its own would need
/// an account; these spellings reach the same object through the services
/// the resolver already asks.
struct TransientName: Equatable {
    /// The designation without a prefix: the year and its letters, `2023ixf`.
    let core: String

    /// Nil for a name that is not a transient designation.
    init?(_ text: String) {
        let pattern = #"^(?:(?:AT|SN|TDE)\s*)?((?:19|20)\d{2}[a-zA-Z]{1,3})$"#
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let designation = String(trimmed[match])
        guard let start = designation.firstIndex(where: \.isNumber) else { return nil }
        core = String(designation[start...])
    }

    /// The spellings to try after `given` found nothing, most likely first.
    func alternates(to given: String) -> [String] {
        let tried = given.trimmingCharacters(in: .whitespaces).lowercased()
        return ["SN \(core)", "SN\(core)", "AT \(core)", "AT\(core)"].filter { $0.lowercased() != tried }
    }
}
