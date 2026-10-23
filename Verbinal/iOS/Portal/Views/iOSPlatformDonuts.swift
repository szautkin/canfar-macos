// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// The platform's load and the person's storage as rings, first in the
/// Portal (the person, 2026-10-22: "the platform load and storage should be
/// donut charts as we have in the macos … platform load and storage first").
/// Large, each ring holds its percentage and its numbers; compact, half the
/// size, the percentage alone.
struct iOSPlatformDonuts: View {
    var platformLoad: PlatformLoadModel
    var storage: StorageModel
    var compact: Bool

    private var known: Bool { platformLoad.load.value != nil }
    private var refreshing: Bool { platformLoad.load.isWorking }

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 6 : 10) {
            iOSDonut(title: "CPU", spokenTitle: "CPU load", load: platformLoad.cpu,
                     unit: String(localized: "cores free"), shows: .free, compact: compact,
                     known: known, refreshing: refreshing)
            iOSDonut(title: "RAM", spokenTitle: "RAM load", load: platformLoad.ram,
                     unit: String(localized: "GB free"), shows: .free, compact: compact,
                     known: known, refreshing: refreshing)
            iOSDonut(title: "GPU", spokenTitle: "GPU load", load: platformLoad.gpu,
                     unit: String(localized: "GPUs free"), shows: .free, compact: compact,
                     known: known, refreshing: refreshing)
            iOSDonut(title: "Storage", spokenTitle: "Storage", load: storageLoad,
                     unit: String(localized: "GB used"), shows: .used, compact: compact,
                     known: storage.load.value != nil || storage.hasData,
                     refreshing: storage.load.isWorking && !storage.hasData)
        }
        .frame(maxWidth: .infinity)
    }

    private var storageLoad: ResourceLoad? {
        storage.hasData ? ResourceLoad(used: storage.usedGB, total: storage.quotaGB) : nil
    }
}

/// One ring: the share in use round it, as the Mac's `LoadDonutView`
/// colours it (accent, orange above 70 %, red above 90 %).
struct iOSDonut: View {
    enum Shows { case free, used }

    let title: LocalizedStringKey
    let spokenTitle: LocalizedStringKey
    let load: ResourceLoad?
    /// "cores free", "GB used".
    let unit: String
    /// Which figure the numbers give: free (the load) or used (storage).
    let shows: Shows
    let compact: Bool
    /// Loaded once: before that, no numbers is not "not reported".
    var known = true
    var refreshing = false

    private var size: CGFloat { compact ? 38 : 76 }
    private var line: CGFloat { compact ? 5 : 8 }

    private var numbers: String? {
        guard let load else { return nil }
        let shown = shows == .free ? load.free : load.used
        return String(localized: "\(LoadDonutView.count(shown)) of \(LoadDonutView.count(load.total))")
    }

    var body: some View {
        VStack(spacing: compact ? 3 : 6) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(load == nil ? 0.15 : 0.2), lineWidth: line)
                if let load {
                    Circle()
                        .trim(from: 0, to: load.percent / 100)
                        .stroke(LoadDonutView.tint(load.percent), style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .appAnimation(AppMotion.quick, value: load.percent)
                }
                center
                    .padding(line + (compact ? 1 : 3))
            }
            .frame(width: size, height: size)

            Text(title)
                .font(compact ? .caption2.weight(.medium) : .caption.weight(.semibold))
            if !compact {
                Text(verbatim: load == nil ? (known ? String(localized: "Not reported") : " ") : unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenTitle))
        .accessibilityValue(Text(verbatim: spokenValue))
    }

    @ViewBuilder
    private var center: some View {
        if load == nil && refreshing {
            ProgressView().controlSize(.small)
        } else {
            VStack(spacing: 1) {
                Text(verbatim: load.map(LoadDonutView.percentText) ?? "—")
                    .font(compact ? .system(size: 10, weight: .semibold, design: .rounded)
                                  : .system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(load == nil ? .tertiary : .primary)
                if !compact, let numbers {
                    Text(verbatim: numbers)
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
        }
    }

    /// "39%, 1,836 of 3,000 cores free", or "Not reported".
    private var spokenValue: String {
        guard let load else { return known ? String(localized: "Not reported") : "—" }
        return "\(LoadDonutView.percentText(load)), \(numbers ?? "") \(unit)"
    }
}
