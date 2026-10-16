// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI
import VerbinalKit

// MARK: - Portal tab

struct PortalSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var selectedType: String = "notebook"
    @State private var selectedProject: String = ""
    @State private var selectedImageID: String = ""
    @State private var resourceMode: String = "none" // "none" | "flexible" | "fixed"
    @State private var resourceCores: Int = 2
    @State private var resourceRam: Int = 8
    @State private var resourceGpus: Int = 0
    @State private var isRefreshing = false
    /// Guards `onChange` handlers from firing during `syncFromSettings()` to prevent
    /// a write-echo cascade (sync sets @State → onChange fires → writes back to disk).
    @State private var isSyncing = false
    /// Cached grouping — recomputed only when the cache's `fetchedAt` changes,
    /// not on every body recomputation. Previously `groupByTypeAndProject` was
    /// called on every render through `availableTypes`/`availableProjects`/`availableImages`.
    @State private var grouped: [String: [String: [ParsedImage]]] = [:]

    private var cache: PortalImageCache? { appState.portalImageCacheService.cache }
    private var settings: PortalSettings? {
        appState.portalSettingsService.settings(for: appState.username)
    }

    private var availableTypes: [String] {
        grouped.keys
            .filter { !["headless", "desktop-app"].contains($0) }
            .sorted()
    }

    private var availableProjects: [String] {
        grouped[selectedType].map { Array($0.keys).sorted() } ?? []
    }

    private var availableImages: [ParsedImage] {
        grouped[selectedType]?[selectedProject] ?? []
    }

    private func rebuildGrouped() {
        guard let cache else { grouped = [:]; return }
        grouped = ImageParser.groupByTypeAndProject(cache.images)
    }

    var body: some View {
        Form {
            Section {
                if appState.username.isEmpty {
                    Label("Log in to manage Portal defaults.", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if cache == nil {
                    Label("No cached images yet — open the Portal tab once to populate these options.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    typePicker
                    projectPicker
                    imagePicker
                    clearRow
                }
            } header: {
                Text("Defaults")
            } footer: {
                Text("These selections are automatically applied whenever you open the Portal tab. " +
                     "They are stored per-user under Application Support.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if cache != nil, !appState.username.isEmpty {
                Section {
                    resourceModePicker
                    if resourceMode == "fixed" {
                        resourceValuePickers
                    }
                } header: {
                    Text("Resource Defaults")
                } footer: {
                    Text("Optional. When set, the launch form starts with these resource settings. " +
                         "CPU / RAM / GPU options are populated from the CANFAR context.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                cacheInfoRow
                cacheActionsRow
            } header: {
                Text("Image Cache")
            } footer: {
                Text("Cached container image metadata makes the Portal tab feel instant. " +
                     "The cache refreshes automatically every 24 hours.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            rebuildGrouped()
            syncFromSettings()
        }
        .onChange(of: appState.portalImageCacheService.cache?.fetchedAt) { _, _ in
            rebuildGrouped()
            syncFromSettings()
        }
    }

    // Resource option lists derived from the cached context.
    private var coreOptions: [Int] { cache?.context?.cores.options ?? [] }
    private var ramOptions: [Int] { cache?.context?.memoryGB.options ?? [] }
    /// What the platform offers in GPUs; nil before its context is cached.
    private var gpuOffer: GPUOffer? { cache?.context?.gpuOffer }

    /// The GPU default as the checkbox shows it (plan 41): one or none, and
    /// none where the platform offers none. Before the context is known, as
    /// saved. A picker over options without a 0 had made it 1.
    static func defaultGPUs(saved: Int, offer: GPUOffer?) -> Int {
        guard let offer else { return saved }
        return offer.offersAny ? min(saved, 1) : 0
    }

    // MARK: - Rows

    private var typePicker: some View {
        Picker("Session Type", selection: $selectedType) {
            Text("No default").tag("")
            ForEach(availableTypes, id: \.self) { type in
                Text(type.capitalized).tag(type)
            }
        }
        .onChange(of: selectedType) { _, newValue in
            guard !isSyncing else { return }
            appState.portalSettingsService.setDefaultSessionType(
                newValue.isEmpty ? nil : newValue,
                for: appState.username
            )
            if !availableProjects.contains(selectedProject) {
                selectedProject = ""
            }
        }
    }

    private var projectPicker: some View {
        Picker("Project", selection: $selectedProject) {
            Text("No default").tag("")
            ForEach(availableProjects, id: \.self) { project in
                Text(project).tag(project)
            }
        }
        .disabled(selectedType.isEmpty || availableProjects.isEmpty)
        .onChange(of: selectedProject) { _, newValue in
            guard !isSyncing else { return }
            appState.portalSettingsService.setDefaultProject(
                newValue.isEmpty ? nil : newValue,
                for: appState.username
            )
            if !availableImages.contains(where: { $0.id == selectedImageID }) {
                selectedImageID = ""
            }
        }
    }

    private var imagePicker: some View {
        Picker("Container Image", selection: $selectedImageID) {
            Text("No default").tag("")
            ForEach(availableImages, id: \.id) { img in
                Text(img.label).tag(img.id)
            }
        }
        .disabled(selectedProject.isEmpty || availableImages.isEmpty)
        .onChange(of: selectedImageID) { _, newValue in
            guard !isSyncing else { return }
            appState.portalSettingsService.setDefaultImage(
                newValue.isEmpty ? nil : newValue,
                for: appState.username
            )
        }
    }

    private var clearRow: some View {
        HStack {
            Spacer()
            Button("Clear All Defaults", role: .destructive) {
                clearDefaults()
            }
            .help("Drop the saved Portal defaults for this account")
            .disabled(settings?.isEmpty ?? true)
        }
    }

    private var resourceModePicker: some View {
        Picker("Preset", selection: $resourceMode) {
            Text("None").tag("none")
            Text("Flexible").tag("flexible")
            Text("Fixed").tag("fixed")
        }
        .onChange(of: resourceMode) { _, _ in
            guard !isSyncing else { return }
            saveResourceDefaults()
        }
    }

    private var resourceValuePickers: some View {
        Group {
            Picker("Cores", selection: $resourceCores) {
                ForEach(coreOptions, id: \.self) { Text("\($0)").tag($0) }
            }
            .disabled(coreOptions.isEmpty)
            .onChange(of: resourceCores) { _, _ in guard !isSyncing else { return }; saveResourceDefaults() }

            Picker("RAM (GB)", selection: $resourceRam) {
                ForEach(ramOptions, id: \.self) { Text("\($0)").tag($0) }
            }
            .disabled(ramOptions.isEmpty)
            .onChange(of: resourceRam) { _, _ in guard !isSyncing else { return }; saveResourceDefaults() }

            if let gpuOffer {
                Toggle("Use a GPU by default", isOn: Binding(get: { resourceGpus > 0 }, set: { resourceGpus = $0 ? 1 : 0 }))
                    .disabled(!gpuOffer.offersAny)
                    .help(gpuOffer.offersAny ? Text("New sessions start with one GPU") : Text("This platform offers no GPUs"))
                    .onChange(of: resourceGpus) { _, _ in guard !isSyncing else { return }; saveResourceDefaults() }
            }
        }
    }

    private var cacheInfoRow: some View {
        HStack {
            Image(systemName: "externaldrive.badge.checkmark")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let fetchedAt = cache?.fetchedAt {
                    Text("Cached \(PortalCacheRelativeFormatter.string(for: fetchedAt))")
                        .font(.callout)
                    Text("\(cache?.images.count ?? 0) images cached for \(cache?.username ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No cache on disk")
                        .font(.callout)
                }
            }
            Spacer()
        }
    }

    private var cacheActionsRow: some View {
        HStack {
            Spacer()
            Button {
                Task {
                    isRefreshing = true
                    _ = try? await appState.portalImageCacheService.fetchFresh(
                        username: appState.username,
                        imageService: appState.imageService
                    )
                    isRefreshing = false
                }
            } label: {
                if isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).scaleEffect(0.7)
                        Text("Refreshing…")
                    }
                } else {
                    Label("Refresh Now", systemImage: "arrow.clockwise")
                }
            }
            .disabled(appState.username.isEmpty || isRefreshing)
            .help("Re-fetch the Skaha image catalogue now")

            Button("Clear Cache", role: .destructive) {
                appState.portalImageCacheService.clear()
            }
            .disabled(cache == nil)
            .help("Delete the cached image list; next open will re-fetch")
        }
    }

    // MARK: - Helpers

    private func syncFromSettings() {
        isSyncing = true
        defer { isSyncing = false }

        guard let settings else {
            selectedType = availableTypes.first ?? ""
            selectedProject = ""
            selectedImageID = ""
            resourceMode = "none"
            return
        }
        selectedType = settings.defaultSessionType ?? ""
        selectedProject = settings.defaultProject ?? ""
        selectedImageID = settings.defaultContainerImageID ?? ""
        resourceMode = settings.defaultResourceType ?? "none"
        if let c = settings.defaultCores { resourceCores = c }
        if let r = settings.defaultRam { resourceRam = r }
        if let g = settings.defaultGpus { resourceGpus = g }

        // Snap values to valid options if the context has changed since last save.
        if !coreOptions.isEmpty && !coreOptions.contains(resourceCores) {
            resourceCores = cache?.context?.cores.default ?? coreOptions.first ?? 2
        }
        if !ramOptions.isEmpty && !ramOptions.contains(resourceRam) {
            resourceRam = cache?.context?.memoryGB.default ?? ramOptions.first ?? 8
        }
        resourceGpus = Self.defaultGPUs(saved: resourceGpus, offer: gpuOffer)
    }

    private func saveResourceDefaults() {
        guard !appState.username.isEmpty else { return }
        if resourceMode == "none" {
            appState.portalSettingsService.setDefaultResources(
                resourceType: nil, cores: nil, ram: nil, gpus: nil,
                for: appState.username
            )
        } else if resourceMode == "fixed" {
            appState.portalSettingsService.setDefaultResources(
                resourceType: "fixed",
                cores: resourceCores,
                ram: resourceRam,
                gpus: resourceGpus,
                for: appState.username
            )
        } else {
            appState.portalSettingsService.setDefaultResources(
                resourceType: "flexible", cores: nil, ram: nil, gpus: nil,
                for: appState.username
            )
        }
    }

    private func clearDefaults() {
        appState.portalSettingsService.setDefaultSessionType(nil, for: appState.username)
        appState.portalSettingsService.setDefaultProject(nil, for: appState.username)
        appState.portalSettingsService.setDefaultImage(nil, for: appState.username)
        appState.portalSettingsService.setDefaultResources(
            resourceType: nil, cores: nil, ram: nil, gpus: nil,
            for: appState.username
        )
        syncFromSettings()
    }

}

/// Confines the not-thread-safe `RelativeDateTimeFormatter` to the MainActor.
///
/// `RelativeDateTimeFormatter` is documented as not thread-safe. The shared
/// instance and its accessor are MainActor-isolated so the safe-usage contract
/// is enforced by the compiler; the sole caller (`PortalSettingsTab`'s
/// `cacheInfoRow`) already runs on the MainActor as a SwiftUI body, so this is
/// behavior-preserving.
enum PortalCacheRelativeFormatter {
    @MainActor
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    /// Returns the relative-time portion of the `Cached <relative time>` label
    /// for a given fetch date.
    @MainActor
    static func string(for fetchedAt: Date, relativeTo now: Date = Date()) -> String {
        formatter.localizedString(for: fetchedAt, relativeTo: now)
    }
}
#endif
