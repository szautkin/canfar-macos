// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Dashboard widget that surfaces the Skaha image catalogue with
/// per-image discovery status, segmented by session type. Sits
/// above `RecentLaunchesView` in the dashboard's right column.
///
/// Reuses the existing `GroupBox` + Label header rhythm from
/// `RecentLaunchesView` and `HeadlessJobsView` so the dashboard
/// reads as a unified set of panels rather than this one being a
/// special case.
///
/// The widget is read-only — it doesn't probe images itself.
/// Per-row "Inspect" and footer "More inspection…" both open the
/// existing `ImageDiscoverySheet` which owns the actual probe
/// flow. After the sheet dismisses, the widget refreshes its row
/// states from the coordinator's cache so freshly-discovered
/// rows render correctly.
struct CanfarImagesView: View {
    @Bindable var model: CanfarImagesModel
    /// Toggled by the parent (DashboardView via AppState) to
    /// present the existing image-discovery sheet.
    @Binding var showDiscoverySheet: Bool
    /// Optional pre-selected image for the sheet's "Use this image"
    /// button to default to. Set when the user clicks Inspect on a
    /// specific row.
    @Binding var preselectedImageID: String?
    /// Routes a row's image into the dashboard's launch form. The
    /// dashboard owns both launch models, so it provides the
    /// concrete implementation; the widget just calls back when
    /// the user clicks the "use this image" button on a row.
    /// Carries the widget's currently-selected type (`selectedTab.sessionTypeKey`,
    /// nil for Default/Popular) alongside the image, so the launch form opens the
    /// tab the user was filtering by — not whatever the multi-type image's first
    /// declared type happens to be.
    var onUseInLaunchForm: ((ParsedImage, String?) -> Void)?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                header
                tabBar
                searchField
                content
                    // Cross-fade the row set on a TAB change only. The search
                    // field (a separate per-keystroke filter) is deliberately
                    // NOT keyed here, so typing re-filters instantly.
                    .appAnimation(AppMotion.stateSwap, value: model.selectedTab)
                footer
            }
        }
        .task { if model.totalCatalogueCount == 0 { await model.reload() } }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        // Whole header is a button so the user can open the modal
        // by clicking anywhere on the title row, not just on the
        // distant "More inspection…" footer button. The discovered-
        // count gets a magnifying-glass icon as a clickability cue.
        Button {
            preselectedImageID = nil
            showDiscoverySheet = true
        } label: {
            HStack {
                Label("Canfar Images", systemImage: "shippingbox")
                    .font(.headline)
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption2)
                        Text("\(model.discoveredCount) of \(model.totalCatalogueCount) discovered")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Image Content Discovery")
    }

    // MARK: - Tabs

    /// Eight tabs don't fit comfortably in a 280pt column as a
    /// segmented control. Render as a popup-button dropdown
    /// instead — compact, native macOS, scales to any number of
    /// type filters we add later.
    @ViewBuilder
    private var tabBar: some View {
        HStack(spacing: 8) {
            Text("Show")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $model.selectedTab) {
                ForEach(CanfarImagesTab.allCases) { tab in
                    Text("\(tab.title) (\(model.count(for: tab)))").tag(tab)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            Spacer()
        }
    }

    // MARK: - Search

    @ViewBuilder
    private var searchField: some View {
        TextField("Filter…", text: $model.searchText)
            .textFieldStyle(.roundedBorder)
            .font(.caption)
    }

    // MARK: - Rows

    @ViewBuilder
    private var content: some View {
        let rows = model.filteredRows
        if rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(rows) { row in
                        CanfarImageRowCard(
                            row: row,
                            onInspect: {
                                preselectedImageID = row.image.id
                                showDiscoverySheet = true
                            },
                            onUseInLaunchForm: onUseInLaunchForm.map { handler in
                                { handler(row.image, model.selectedTab.sessionTypeKey) }
                            }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 220)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "shippingbox")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var emptyMessage: String {
        if !model.searchText.isEmpty {
            return "No images match the current filter."
        }
        switch model.selectedTab {
        case .default:
            return "No default images marked yet. Use the star button on the launch form to set one."
        case .popular:
            return "No recent launches yet."
        default:
            return "No images of this type are available for your account."
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            if let banner = model.bannerMessage {
                Label(banner, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                CopyErrorButton(message: banner)
            }
            Spacer()
            Button {
                preselectedImageID = nil
                showDiscoverySheet = true
            } label: {
                Label("More inspection…", systemImage: "magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }
}
