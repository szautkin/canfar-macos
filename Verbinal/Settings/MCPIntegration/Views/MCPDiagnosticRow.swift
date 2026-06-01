// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI

/// One diagnostic row: status icon + title + one-line detail, with an
/// optional inline Fix button.
struct MCPDiagnosticRow: View {
    let check: DiagnosticCheck
    let onFix: (FixAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: check.status.symbol)
                .foregroundStyle(check.status.tint)
                .imageScale(.medium)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(.callout)
                Text(check.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let fix = check.fix {
                Button(fix.title) { onFix(fix) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
