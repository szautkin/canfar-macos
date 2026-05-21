// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Modal sheet the user opens via the magnifying-glass icon next to
/// the launch form's image picker. Two-pane layout: filter on the
/// left (sectioned package checkboxes), matching images on the
/// right (project-grouped). Returns the selected image id to the
/// caller via `onPick`.
///
/// Layout: plain `HStack` with a 280pt fixed-width left pane, a
/// native `Divider`, and the right pane filling remaining space.
/// `NavigationSplitView` was rejected because the panes are parallel
/// constraint editors, not a drill-down. `HSplitView` was rejected
/// because the resize handle is overkill for a discovery dialog the
/// user opens infrequently.
struct ImageDiscoverySheet: View {
    @Bindable var model: ImageDiscoveryModel
    /// Called with the selected image id when the user commits.
    /// The parent sheet caller dismisses and applies.
    var onPick: (String) -> Void
    /// Catalogue of images the user can pick from — passed in so the
    /// sheet can drive `model.onAppear` once it's visible.
    var catalogue: [ParsedImage]

    @Environment(\.dismiss) private var dismiss
    @State private var didLoad = false

    var body: some View {
        VStack(spacing: 0) {
            header

            // Chips bar — visible only when one or more filters
            // are active. Spans both panes so the user always sees
            // what's currently constraining the right pane.
            ActiveFiltersBar(model: model)

            HStack(spacing: 0) {
                PackageFilterPane(model: model)
                    .frame(width: 280)
                Divider()
                MatchingImagesPane(model: model, onCommit: commitAndClose)
                    .frame(maxWidth: .infinity)
            }

            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 480, idealHeight: 600)
        .task {
            // Single-shot load: the sheet might be re-presented; the
            // model lives across showings so cached state survives.
            guard !didLoad else { return }
            didLoad = true
            await model.onAppear(catalogue: catalogue)
        }
        .onDisappear { model.onDisappear() }
        .sheet(isPresented: Binding(
            get: { model.jobIDForLogsSheet != nil },
            set: { if !$0 { model.jobIDForLogsSheet = nil } }
        )) {
            if let jobID = model.jobIDForLogsSheet {
                ProbeLogsSheet(model: model, jobID: jobID)
            }
        }
        .sheet(item: $model.failureDetailForSheet) { detail in
            FailureDetailSheet(detail: detail)
        }
        // Manifest-detail sheet for a `.discovered` row — Phase 3
        // of the 2026-05-20 UX audit. `Optional<ImageManifest>`
        // isn't `Identifiable` natively; wrap via the model's
        // optional binding so SwiftUI presents iff non-nil.
        .sheet(
            isPresented: Binding(
                get: { model.manifestDetailForSheet != nil },
                set: { if !$0 { model.manifestDetailForSheet = nil } }
            )
        ) {
            if let manifest = model.manifestDetailForSheet {
                ManifestDetailSheet(manifest: manifest)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("Image Content Discovery")
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.failedCount > 0 {
                Button {
                    Task { await model.clearAllFailures() }
                } label: {
                    Label("Clear \(model.failedCount) error\(model.failedCount == 1 ? "" : "s")",
                          systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Drop every cached failure outcome (does not re-run probes)")
            }
            if model.isDiscoveryRunning {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Discovering…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var headerSubtitle: String {
        let total = catalogue.count
        let known = model.rowStates.values.filter {
            if case .discovered = $0 { return true }; return false
        }.count
        return "Discovered \(known) of \(total) images"
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            if let banner = model.bannerMessage {
                Label(banner, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                CopyErrorButton(message: banner)
                Button {
                    model.bannerMessage = nil
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Dismiss this banner")
                .accessibilityLabel("Dismiss banner")
            }
            Spacer()
            // "Close" rather than "Cancel" — probes that are
            // currently running on Skaha continue in the background
            // after the sheet dismisses (per
            // `ImageDiscoveryModel.onDisappear`). The
            // LaunchFormView's magnifier-icon badge tracks in-flight
            // probe count so the user retains awareness from
            // outside the sheet. "Cancel" implied stopping the
            // work, which was misleading.
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .help("Close this dialog. In-flight probes continue in the background; reopen later to see their results.")
            Button("Use this image") {
                if let id = model.selectedImageID {
                    commitAndClose(id)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedImageID == nil)
            .keyboardShortcut(.defaultAction)
            .help("Pick the selected image for the launch form and close (↩)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func commitAndClose(_ imageID: String) {
        onPick(imageID)
        dismiss()
    }
}
