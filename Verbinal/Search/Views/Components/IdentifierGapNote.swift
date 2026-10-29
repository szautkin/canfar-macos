// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Why a query's rows have no publisher ID (plan 54 C3, E1): above the
/// results, and under the ADQL editor with a **Join Plane** fix.
struct IdentifierGapNote: View {
    let gap: ADQLIdentifier.Gap
    /// Joins caom2.Plane into the query; only where the query can change.
    var joinPlane: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(gap.localizedMessage, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let joinPlane, gap.join != nil {
                Button("Join Plane", action: joinPlane)
                    .controlSize(.small)
                    .help(gap.join ?? "")
                    .pointable("adql.joinPlane")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
