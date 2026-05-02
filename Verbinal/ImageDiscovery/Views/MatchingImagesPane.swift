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
                jobIDLine(state: state)
            }
            Spacer()
            staleBadge(state: state)
            statusIndicator(state: state)
            viewLogsButton(state: state)
            dismissErrorButton(imageID: image.id, state: state)
            discoverButton(imageID: image.id, state: state)
        }
        .padding(.vertical, 2)
    }

    /// Displays the failed probe's Skaha session id so the user can
    /// correlate to the Background Jobs panel and know which job to
    /// inspect. Only shown for failed rows that have a captured id.
    @ViewBuilder
    private func jobIDLine(state: ImageDiscoveryModel.RowState) -> some View {
        if case .failed(_, _, let jobID?) = state {
            Text("Job \(jobID)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
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

    /// User-driven Discover/Re-run button. With auto-discovery
    /// disabled, this is the *only* way a probe gets launched —
    /// every row starts in `.neverDiscovered` until the user opts
    /// in. Hidden while a probe is in flight (the spinner replaces
    /// it).
    @ViewBuilder
    private func discoverButton(
        imageID: String,
        state: ImageDiscoveryModel.RowState
    ) -> some View {
        switch state {
        case .running:
            EmptyView()
        case .neverDiscovered:
            Button {
                Task { await model.discover(imageID) }
            } label: {
                Image(systemName: "magnifyingglass.circle")
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

    /// "View logs" affordance — visible only on failed rows whose
    /// captured `jobID` lets us pull container logs/events from
    /// Skaha. Opens a small sheet showing both. State carried via
    /// the parent sheet's `@Bindable` model so the sheet can hand
    /// the user the same connection / cache.
    @ViewBuilder
    private func viewLogsButton(state: ImageDiscoveryModel.RowState) -> some View {
        if case .failed(_, _, let jobID?) = state {
            Button {
                model.jobIDForLogsSheet = jobID
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("View container logs for the failed probe job")
        }
    }

    /// "Dismiss error" affordance — visible only on failed rows.
    /// Drops the cached failure and resets the row to never-
    /// discovered, *without* launching a fresh probe (rediscover
    /// is the button next door for that). Useful when the user
    /// already knows why a probe failed and wants the row out of
    /// their visual triage queue.
    @ViewBuilder
    private func dismissErrorButton(
        imageID: String,
        state: ImageDiscoveryModel.RowState
    ) -> some View {
        if case .failed = state {
            Button {
                Task { await model.clearFailure(imageID) }
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Dismiss this error (does not re-run the probe)")
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
        case .failed(let msg, _, _):
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
        case .failed(let msg, _, _):
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
