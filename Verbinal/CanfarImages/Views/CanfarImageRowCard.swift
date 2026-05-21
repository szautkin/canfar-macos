// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// One row in the Canfar Images widget. Compact (one line of label,
/// one line of meta, trailing-edge button). Visual rhythm matches
/// `RecentLaunchesView.recentLaunchCard(_:)` so the widget reads
/// like a cousin of the Recent Launches panel sitting next to it.
struct CanfarImageRowCard: View {
    let row: CanfarImageRow
    var onInspect: () -> Void
    /// Optional "use this image in the launch form" action. When
    /// `nil`, the affordance is hidden — keeps surfaces that
    /// shouldn't drive a launch form (tests, future preview-only
    /// listings) free of a button that would dangle.
    var onUseInLaunchForm: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            typeIcon

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.image.label)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if row.isUserDefault {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .help("Your default for this session type")
                    }
                    if row.isRecentlyLaunched {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Recently launched")
                    }
                }
                metaLine
            }

            Spacer()

            statusIndicator
            if let onUseInLaunchForm {
                Button {
                    onUseInLaunchForm()
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Use this image in the Launch Session form")
                .accessibilityLabel("Use \(row.image.label) in launch form")
            }
            Button {
                onInspect()
            } label: {
                Image(systemName: "magnifyingglass.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Inspect this image's installed packages")
            .accessibilityLabel("Inspect \(row.image.label) packages")
        }
        .padding(10)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.platformSeparator, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var typeIcon: some View {
        let primaryType = row.image.types.first ?? "notebook"
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(SessionDisplay.typeColor(primaryType).opacity(0.15))
            Image(systemName: SessionDisplay.typeIcon(primaryType))
                .font(.caption)
                .foregroundStyle(SessionDisplay.typeColor(primaryType))
        }
        .frame(width: 28, height: 28)
    }

    @ViewBuilder
    private var metaLine: some View {
        switch row.status {
        case .discovered:
            HStack(spacing: 6) {
                if let manifest = row.manifest, manifest.osFamily != "unknown" {
                    Text("\(manifest.osFamily) \(manifest.osVersion)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("\(row.packageCount) packages")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        case .failed:
            Text(row.failureMessage ?? "Probe failed")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.middle)
        case .unknown:
            Text(row.image.id)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch row.status {
        case .discovered:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .help("Manifest cached")
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(row.failureMessage ?? "Last probe failed")
        case .unknown:
            Image(systemName: "circle.dotted")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Not yet inspected")
        }
    }
}
