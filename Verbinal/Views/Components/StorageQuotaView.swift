// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct StorageQuotaView: View {
    @Bindable var model: StorageModel

    var body: some View {
        // A reload keeps the figures; before the first load they are dashes,
        // the same height (plan 42).
        PortalCardShell(title: "Storage", systemImage: "internaldrive", phase: model.load,
                        reload: PortalReload(id: "portal.storage.refresh", name: "Refresh storage",
                                             help: "Fetch your storage quota again", action: { await model.reload() })) {
            quotaReadout
                .refreshing(model.load.isWorking && model.hasData)
        }
    }

    /// The usage bar and the Used, Usage and Quota figures; dashes until the
    /// first load.
    @ViewBuilder
    private var quotaReadout: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: min(model.usagePercent, 100), total: 100)
                .tint(model.isWarning ? .red : .accentColor)
                // Ease the bar from old→new on each poll instead of jumping.
                .appAnimation(AppMotion.quick, value: model.usagePercent)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Used")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    (model.hasData ? Text("\(model.usedGB.formatted(.number.precision(.fractionLength(2)))) GB") : Text(verbatim: "—"))
                        .font(.caption)
                        .fontWeight(.medium)
                }

                Spacer()

                VStack(alignment: .center, spacing: 2) {
                    Text("Usage")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(verbatim: model.hasData ? (model.usagePercent / 100).formatted(.percent.precision(.fractionLength(1))) : "—")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(model.isWarning ? .red : .primary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Quota")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    (model.hasData ? Text("\(model.quotaGB.formatted(.number.precision(.fractionLength(2)))) GB") : Text(verbatim: "—"))
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }

            if model.isWarning {
                Label("Storage nearly full", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}
