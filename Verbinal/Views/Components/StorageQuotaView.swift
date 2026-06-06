// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct StorageQuotaView: View {
    @Bindable var model: StorageModel

    /// Boundary discriminator: spinner while loading, the quota readout once
    /// data lands. A poll refresh keeps the state at `.content` (the bar eases
    /// to its new value instead — see `.appAnimation` below).
    private var quotaState: DataState {
        if model.isLoading { return .loading }
        if model.hasData { return .content }
        return .empty
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Storage", systemImage: "internaldrive")
                    .font(.headline)

                DataStateContainer(state: quotaState) {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } empty: {
                    EmptyView()
                } error: {
                    EmptyView()
                } content: {
                    quotaReadout
                }

                if model.hasError {
                    Label(model.errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// The usage bar + Used/Usage/Quota figures, shown once `hasData`.
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
                            Text(String(format: "%.2f GB", model.usedGB))
                                .font(.caption)
                                .fontWeight(.medium)
                        }

                        Spacer()

                        VStack(alignment: .center, spacing: 2) {
                            Text("Usage")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(String(format: "%.1f%%", model.usagePercent))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(model.isWarning ? .red : .primary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Quota")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(String(format: "%.2f GB", model.quotaGB))
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }

            if model.isWarning {
                Label("Storage nearly full!", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}
