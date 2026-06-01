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
        VStack(spacing: 0) {
            // Pane-scoped image search — narrows the rows below by
            // image label / id substring without touching the
            // package checkboxes in the left pane.
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter images by name / tag…", text: $model.imageSearchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

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
        let isSelected = model.selectedImageID == image.id
        HStack(spacing: 8) {
            selectionRadio(imageID: image.id, isSelected: isSelected)
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
            copyErrorButton(imageID: image.id, state: state)
            viewDetailsButton(imageID: image.id, state: state)
            viewLogsButton(state: state)
            dismissErrorButton(imageID: image.id, state: state)
            discoverButton(imageID: image.id, state: state)
        }
        .padding(.vertical, 2)
    }

    /// Leading single-select radio. Clicking it (or anywhere in the
    /// row) selects the image; the `List(selection:)` binding above
    /// drives the filled/empty state. Distinct from the row's
    /// double-click-to-commit gesture so the user can browse without
    /// committing accidentally.
    @ViewBuilder
    private func selectionRadio(imageID: String, isSelected: Bool) -> some View {
        Button {
            model.selectedImageID = imageID
        } label: {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(isSelected ? "Selected — click \"Use this image\" or press Return" : "Select this image")
        .accessibilityLabel(isSelected ? "Selected" : "Select \(imageID)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            .accessibilityLabel("Discover packages")
        case .discovered, .failed:
            Button {
                Task { await model.rediscover(imageID) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Re-run discovery for this image")
            .accessibilityLabel("Re-run discovery")
        }
    }

    /// "Copy error" affordance — visible on every failed row.
    /// One-click copies the cached failure message verbatim to the
    /// pasteboard so the user can paste it into a CADC ticket / chat
    /// without round-tripping through the detail sheet.
    @ViewBuilder
    private func copyErrorButton(
        imageID: String,
        state: ImageDiscoveryModel.RowState
    ) -> some View {
        if case .failed(let msg, _, _) = state {
            CopyErrorButton(message: msg)
        }
    }

    /// "View details" affordance.
    ///
    /// * On a `.failed` row — opens `FailureDetailSheet` with the
    ///   full Skaha response, scrollable + selectable so the user
    ///   can copy it into a CADC ticket.
    /// * On a `.discovered` row — opens `ManifestDetailSheet`
    ///   showing every section of the cached manifest, with copy-
    ///   as-JSON + reveal-in-Finder in the footer. 2026-05-21
    ///   Phase 3 addition closes the picky-astronomer "I want to
    ///   verify the primary data without digging through
    ///   `~/Library/Application Support/...`" gap.
    /// * Other states (running, never-discovered) — no button,
    ///   nothing useful to show yet.
    @ViewBuilder
    private func viewDetailsButton(
        imageID: String,
        state: ImageDiscoveryModel.RowState
    ) -> some View {
        switch state {
        case .failed(let msg, let attemptedAt, let jobID):
            Button {
                model.failureDetailForSheet = ImageDiscoveryModel.FailureDetail(
                    imageID: imageID,
                    message: msg,
                    attemptedAt: attemptedAt,
                    jobID: jobID
                )
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Show the full failure message")
            .accessibilityLabel("Show failure details")

        case .discovered(let manifest):
            Button {
                model.manifestDetailForSheet = manifest
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Show what this image contains")
            .accessibilityLabel("Show manifest details")

        case .neverDiscovered, .running:
            EmptyView()
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
            .accessibilityLabel("View probe logs")
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
            .accessibilityLabel("Dismiss error")
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
            // 2026-05-21 Phase 2 add: time-since-probe so the
            // picky-astronomer user knows whether they're
            // looking at fresh data or a 3-week-old cache.
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
                Text("•")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(ImageDiscoveryModel.timeAgo(manifest.capturedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Probed \(manifest.capturedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            .lineLimit(1)
        case .failed(let msg, let attemptedAt, _):
            // Two-line layout: category-aware chip on line 1
            // (so the user sees "Timed out · 3m ago · checking
            // in background" at a glance), full message on
            // line 2 truncated to 2 lines max.
            VStack(alignment: .leading, spacing: 1) {
                failureChip(imageID: image.id, attemptedAt: attemptedAt)
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
    }

    /// Category-aware status line for the failed state. Renders
    /// "{Category} · {time-ago}" plus a "checking in background"
    /// hint when the failure is `jobTimedOut` and recent enough
    /// that the coordinator's grace-poll task might still
    /// recover the manifest.
    @ViewBuilder
    private func failureChip(imageID: String, attemptedAt: Date) -> some View {
        let category = model.failureCategories[imageID] ?? .unknown
        let label = ImageDiscoveryModel.categoryLabel(category)
        let recovering = ImageDiscoveryModel.isLikelyStillRecovering(
            category: category,
            attemptedAt: attemptedAt
        )
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.bold())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(failureChipBackground(category), in: Capsule())
                .foregroundStyle(failureChipForeground(category))
            Text("·")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(ImageDiscoveryModel.timeAgo(attemptedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("Last attempt \(attemptedAt.formatted(date: .abbreviated, time: .shortened))")
            if recovering {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Label("checking in background", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .help("The probe job may still be running on Skaha. The coordinator is polling VOSpace for a late-landing manifest; this row will flip to discovered automatically if it arrives.")
            }
        }
    }

    /// Capsule background colour per category. Orange for
    /// transient/retryable categories (timeouts) so the eye
    /// doesn't lock on them as hard fails; red for "you need to
    /// act" categories (submit failed = creds wrong).
    private func failureChipBackground(_ c: LastOutcome.FailureCategory) -> Color {
        switch c {
        case .jobTimedOut:           return .orange.opacity(0.18)
        case .jobSubmitFailed:       return .red.opacity(0.18)
        case .manifestFetchFailed:   return .red.opacity(0.15)
        case .manifestParseFailed:   return .red.opacity(0.15)
        case .cancelled:             return .gray.opacity(0.18)
        case .unknown:               return .red.opacity(0.15)
        }
    }

    private func failureChipForeground(_ c: LastOutcome.FailureCategory) -> Color {
        switch c {
        case .jobTimedOut:           return .orange
        case .jobSubmitFailed:       return .red
        case .manifestFetchFailed:   return .red
        case .manifestParseFailed:   return .red
        case .cancelled:             return .secondary
        case .unknown:               return .red
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

/// Compact pasteboard-copy button. Local `@State` flips the icon
/// from `doc.on.doc` to `checkmark.circle.fill` for ~1.5s after a
/// click so the user gets visible feedback without us needing a
/// global toast / overlay. Shared across the failed-row affordance
/// and the modal footer's banner so both surfaces have the same
/// one-click copy behaviour.
struct CopyErrorButton: View {
    let message: String
    @State private var didCopy: Bool = false

    var body: some View {
        Button {
            PlatformClipboard.copy(message)
            didCopy = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                didCopy = false
            }
        } label: {
            Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(didCopy ? Color.green : Color.accentColor)
        }
        .buttonStyle(.borderless)
        .help(didCopy ? "Copied" : "Copy error message to clipboard")
        .accessibilityLabel(didCopy ? "Copied to clipboard" : "Copy error to clipboard")
    }
}
