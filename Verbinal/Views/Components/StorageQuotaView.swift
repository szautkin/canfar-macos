// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

struct StorageQuotaView: View {
    @Bindable var model: StorageModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Storage", systemImage: "internaldrive")
                    .font(.headline)

                if model.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else if model.hasData {
                    ProgressView(value: min(model.usagePercent, 100), total: 100)
                        .tint(model.isWarning ? .red : .accentColor)

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

                if model.hasError {
                    Label(model.errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
