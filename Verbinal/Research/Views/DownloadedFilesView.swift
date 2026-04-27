// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct DownloadedFilesView: View {
    var model: ResearchModel
    var searchModel: SearchFormModel?
    @Environment(AppState.self) private var appState

    @State private var showExportDialog = false

    /// Persisted set of collapsed collection names (newline-separated).
    /// Default = empty, meaning everything is expanded on first launch.
    @AppStorage("research.collapsedCollections") private var collapsedCSV: String = ""

    private var collapsedSet: Set<String> {
        Set(collapsedCSV.split(separator: "\n").map(String.init))
    }

    private var isFiltering: Bool {
        !model.filterText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Binding that honors filter mode (force-expanded) and otherwise persists to AppStorage.
    private func expandedBinding(for collection: String) -> Binding<Bool> {
        Binding(
            get: {
                if isFiltering { return true }
                return !collapsedSet.contains(collection)
            },
            set: { expanded in
                if isFiltering { return } // don't persist state while filter forces open
                var set = collapsedSet
                if expanded {
                    set.remove(collection)
                } else {
                    set.insert(collection)
                }
                collapsedCSV = set.sorted().joined(separator: "\n")
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Downloads")
                    .font(.headline)
                Spacer()
                Text("\(model.filteredObservations.count) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #if os(macOS)
                Button {
                    showExportDialog = true
                } label: {
                    if model.exportService.isExporting {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(model.observationStore.observations.isEmpty || model.exportService.isExporting)
                .help("Export observations and notes to a Claude-friendly bundle")
                #endif
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // File list grouped by collection
            if model.filteredObservations.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    if model.observationStore.observations.isEmpty {
                        Image(systemName: "tray.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No downloads yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Search CADC to find observations")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No matches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: Binding(
                    get: { model.selectedObservation?.id },
                    set: { newID in
                        model.selectedObservation = model.observationStore.observations.first { $0.id == newID }
                    }
                )) {
                    let grouped = Dictionary(grouping: model.filteredObservations, by: \.collection)
                    ForEach(grouped.keys.sorted(), id: \.self) { collection in
                        DisclosureGroup(isExpanded: expandedBinding(for: collection)) {
                            ForEach(grouped[collection] ?? []) { obs in
                                observationRow(obs)
                                    .tag(obs.id)
                                    .contextMenu {
                                        #if os(macOS)
                                        Button("Open File") { model.openFile(obs) }
                                        Button("Reveal in Finder") { model.revealInFinder(obs) }
                                        Divider()
                                        #endif
                                        Button("Delete", role: .destructive) { model.deleteObservation(obs) }
                                    }
                            }
                        } label: {
                            sectionHeader(
                                collection: collection,
                                count: grouped[collection]?.count ?? 0
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let binding = expandedBinding(for: collection)
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    binding.wrappedValue.toggle()
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .searchable(text: Bindable(model).filterText, prompt: "Filter downloads")
        #if os(macOS)
        .sheet(isPresented: $showExportDialog) {
            ExportDialogView(
                availableModules: buildAvailableModules(),
                exportService: model.exportService,
                onVOSpaceUpload: { bundleURL in
                    let vospace = VOSpaceBrowserService(network: appState.network)
                    return try await model.exportService.uploadBundleToVOSpace(
                        bundleURL: bundleURL,
                        vospace: vospace,
                        username: appState.username
                    )
                },
                canUploadToVOSpace: appState.isAuthenticated && !appState.username.isEmpty,
                onComplete: { url in
                    NotificationService.sendExportCompleted(
                        bundleName: url.lastPathComponent,
                        moduleSummary: researchItemCountLabel
                    )
                }
            )
        }
        #endif
    }

    #if os(macOS)
    /// Builds the module list dynamically — Research is always available, Search is
    /// optional depending on whether the caller injected a SearchFormModel.
    private func buildAvailableModules() -> [ExportDialogView.ModuleSelection] {
        var modules: [ExportDialogView.ModuleSelection] = []

        modules.append(
            ExportDialogView.ModuleSelection(
                moduleID: "research",
                displayName: "Research",
                itemCountLabel: researchItemCountLabel,
                module: ResearchExporter(
                    observationStore: model.observationStore,
                    noteStore: model.noteStore
                ),
                isEnabled: true
            )
        )

        if let searchModel {
            modules.append(
                ExportDialogView.ModuleSelection(
                    moduleID: "search",
                    displayName: "Search",
                    itemCountLabel: searchItemCountLabel(searchModel),
                    module: SearchExporter(
                        savedQueryStore: searchModel.savedQueryStore,
                        recentSearchStore: searchModel.recentSearchStore
                    ),
                    isEnabled: false
                )
            )
        }

        return modules
    }

    private func searchItemCountLabel(_ model: SearchFormModel) -> String {
        let saved = model.savedQueryStore.queries.count
        let recent = model.recentSearchStore.searches.count
        if saved == 0 && recent == 0 { return "empty" }
        return "\(saved) saved, \(recent) recent"
    }
    #endif

    private var researchItemCountLabel: String {
        ResearchExporter.itemCountLabel(
            observations: model.observationStore.observations.count,
            notes: model.noteStore.notes.count
        )
    }

    /// Collection group label with uppercase title + capsule count badge.
    /// `DisclosureGroup` draws its own always-visible chevron, so this view
    /// only provides the title and badge.
    @ViewBuilder
    private func sectionHeader(collection: String, count: Int) -> some View {
        let isCollapsed = !isFiltering && collapsedSet.contains(collection)

        HStack(spacing: 6) {
            Text(collection)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .tracking(0.3)

            Spacer(minLength: 4)

            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isCollapsed ? Color.white : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background {
                    if isCollapsed {
                        Capsule().fill(Color.accentColor)
                    } else {
                        Capsule().fill(.quaternary)
                    }
                }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(collection), \(count) items, \(isCollapsed ? "collapsed" : "expanded")")
    }

    private func observationRow(_ obs: DownloadedObservation) -> some View {
        HStack(spacing: 8) {
            // Thumbnail
            if let thumbStr = obs.thumbnailURL, let thumbURL = URL(string: thumbStr) {
                AsyncImage(url: thumbURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel(obs.targetName)
            } else {
                Image(systemName: "doc")
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(obs.targetName.isEmpty ? obs.observationID : obs.targetName)
                    .font(.caption)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(obs.instrument)
                    if !obs.filter.isEmpty {
                        Text("/ \(obs.filter)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if let size = obs.fileSize {
                Text(SharedFormatters.bytes(size))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
