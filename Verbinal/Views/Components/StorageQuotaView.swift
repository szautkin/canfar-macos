// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct StorageQuotaView: View {
    @Bindable var model: StorageModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A reload under way, the figures kept.
    private var refreshing: Bool { model.load.isWorking && model.hasData }
    private var barValue: Double { Self.bar(usage: model.usagePercent, refreshing: refreshing, reduceMotion: reduceMotion) }

    var body: some View {
        // A reload keeps the figures; before the first load they are dashes,
        // the same height (plan 42).
        PortalCardShell(title: "Storage", systemImage: "internaldrive", phase: model.load,
                        reload: PortalReload(id: "portal.storage.refresh", name: "Refresh storage",
                                             help: "Fetch your storage quota again", action: { await model.reload() })) {
            quotaReadout
                .refreshing(refreshing)
        }
    }

    /// The usage bar and the Used, Usage and Quota figures; dashes until the
    /// first load.
    @ViewBuilder
    private var quotaReadout: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: barValue, total: 100)
                .tint(model.isWarning ? .red : .accentColor)
                // A reload runs the bar back to the start, quickly; the
                // answer fills it to the usage, slower.
                .appAnimation(refreshing ? .easeIn(duration: 0.3) : .easeOut(duration: 0.8), value: barValue)
                .accessibilityValue(refreshing ? Text("Refreshing")
                                               : Text(verbatim: (model.usagePercent / 100).formatted(.percent.precision(.fractionLength(1)))))

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

    /// Where the bar stands, of 100: at the start while a reload is under
    /// way, then at the usage (the person's ask, 2026-10-16). With Reduce
    /// Motion it stays at the usage: no running back.
    static func bar(usage: Double, refreshing: Bool, reduceMotion: Bool) -> Double {
        refreshing && !reduceMotion ? 0 : min(usage, 100)
    }
}
