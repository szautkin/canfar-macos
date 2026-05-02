// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// RIGHT pane — project-grouped list of images that satisfy the
/// current package filters and search text. Each row shows the
/// image label, a per-row state indicator (never-discovered /
/// running / failed / discovered with package count), and is
/// double-click to commit.
struct MatchingImagesPane: View {
    @Bindable var model: ImageDiscoveryModel
    /// Called when the user double-clicks (or presses Return) on a
    /// row — the parent sheet uses this to dismiss + apply.
    var onCommit: (String) -> Void

    var body: some View {
        Group {
            if model.filteredImagesByProject.isEmpty {
                emptyState
            } else {
                imageList
            }
        }
    }

    @ViewBuilder
    private var imageList: some View {
        List(selection: $model.selectedImageID) {
            ForEach(model.filteredImagesByProject, id: \.project) { group in
                Section(group.project) {
                    ForEach(group.images, id: \.id) { image in
                        row(image)
                            .tag(image.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onCommit(image.id) }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func row(_ image: ParsedImage) -> some View {
        let state = model.rowStates[image.id] ?? .neverDiscovered
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(image.label)
                    .font(.body)
                    .lineLimit(1)
                detailLine(image: image, state: state)
            }
            Spacer()
            staleBadge(state: state)
            statusIndicator(state: state)
            rediscoverButton(imageID: image.id, state: state)
        }
        .padding(.vertical, 2)
    }

    /// Stale-tag indicator — only rendered for rolling-tag images
    /// whose manifest is older than the freshness window.
    @ViewBuilder
    private func staleBadge(state: ImageDiscoveryModel.RowState) -> some View {
        if case .discovered(let manifest) = state,
           let label = RollingTagPolicy.staleAgeLabel(for: manifest) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
                .help(label)
        }
    }

    /// Per-image Rediscover button. Drops the cached manifest and
    /// re-runs the probe through the coordinator. Hidden while the
    /// image is currently being probed.
    @ViewBuilder
    private func rediscoverButton(
        imageID: String,
        state: ImageDiscoveryModel.RowState
    ) -> some View {
        switch state {
        case .running:
            EmptyView()
        case .neverDiscovered:
            // Manual kick: useful when the user wants to be sure
            // discovery actually fires for this image without waiting
            // for the background sweep.
            Button {
                Task { await model.rediscover(imageID) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Discover packages for this image")
        case .discovered, .failed:
            Button {
                Task { await model.rediscover(imageID) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Re-run discovery for this image")
        }
    }

    @ViewBuilder
    private func detailLine(image: ParsedImage, state: ImageDiscoveryModel.RowState) -> some View {
        switch state {
        case .neverDiscovered:
            Text(image.id)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .running:
            Text("Discovering…")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .discovered(let manifest):
            HStack(spacing: 6) {
                Text(manifest.osFamily == "unknown" ? "—" : "\(manifest.osFamily) \(manifest.osVersion)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("•")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("\(packageCount(manifest)) packages")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        case .failed(let msg, _):
            Text(msg)
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func statusIndicator(state: ImageDiscoveryModel.RowState) -> some View {
        switch state {
        case .neverDiscovered:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.tertiary)
                .help("Not yet discovered")
        case .running:
            ProgressView()
                .controlSize(.small)
        case .discovered:
            EmptyView()
        case .failed(let msg, _):
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .help(msg)
        }
    }

    private func packageCount(_ m: ImageManifest) -> Int {
        m.dpkgPackages.count + m.rpmPackages.count + m.apkPackages.count +
        m.pythonPackages.count + m.rPackages.count
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No images match the current filters")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !model.query.isEmpty {
                Text("Try removing some constraints.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
