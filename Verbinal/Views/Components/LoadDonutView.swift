// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// One resource of the platform load as a ring (plan 41): the share in use
/// round it, the percentage inside, and below, its name and how much is
/// free of how much. With no numbers, a grey ring and "—", and the help
/// says why.
struct LoadDonutView: View {
    let title: LocalizedStringKey
    /// "CPU load": what VoiceOver and an assistant read it as.
    let spokenTitle: LocalizedStringKey
    let load: ResourceLoad?
    /// "cores free", "GB free", "GPUs free".
    let freeUnit: String
    /// Why there are no numbers, when there are none.
    let missing: LocalizedStringKey
    let id: String
    /// The stats have loaded once: before that, no numbers is not "not
    /// reported".
    var known = true

    private static let size: CGFloat = 64
    private static let line: CGFloat = 7

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(load == nil ? 0.15 : 0.2), lineWidth: Self.line)
                if let load {
                    Circle()
                        .trim(from: 0, to: load.percent / 100)
                        .stroke(Self.tint(load.percent), style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        // Eases from old to new on each refresh instead of jumping.
                        .appAnimation(AppMotion.quick, value: load.percent)
                }
                Text(load.map { Self.percentText($0) } ?? "—")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(load == nil ? .tertiary : .primary)
            }
            .frame(width: Self.size, height: Self.size)

            Text(title)
                .font(.caption.weight(.medium))
            if let load {
                VStack(spacing: 0) {
                    Text("\(Self.count(load.free)) of \(Self.count(load.total))")
                        .monospacedDigit()
                    Text(freeUnit)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                // Two lines, as with numbers: the card keeps its height.
                VStack(spacing: 0) {
                    (known ? Text("Not reported") : Text(verbatim: "—"))
                    Text(verbatim: " ")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenTitle))
        .accessibilityValue(Text(verbatim: spokenValue))
        .help(load != nil ? Text(verbatim: spokenValue) : known ? Text(missing) : Text("Loading the platform's statistics"))
        .pointable(id)
    }

    /// "39%, 1,836 of 3,000 cores free", or "Not reported".
    private var spokenValue: String {
        guard let load else { return known ? String(localized: "Not reported") : "—" }
        return "\(Self.percentText(load)), \(String(localized: "\(Self.count(load.free)) of \(Self.count(load.total))")) \(freeUnit)"
    }

    static func percentText(_ load: ResourceLoad) -> String {
        (load.percent / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    /// Whole numbers: 1,836 cores, 3,185 GB, 92 GPUs.
    static func count(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    /// As the bars were: the accent colour, orange above 70 %, red above 90 %.
    static func tint(_ percent: Double) -> Color {
        percent > 90 ? .red : percent > 70 ? .orange : .accentColor
    }
}
