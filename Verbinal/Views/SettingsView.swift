// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI
import VerbinalKit

/// Top-level Preferences window (⌘,). Tabbed layout following the macOS HIG for
/// System Settings-style apps (Mail, Xcode, Music).
struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .environment(appState)
                .tabItem { Label("General", systemImage: "gear") }

            PortalSettingsTab()
                .environment(appState)
                .tabItem { Label("Portal", systemImage: "play.circle") }

            ImageDiscoverySettingsTab()
                .environment(appState)
                .tabItem { Label("Discovery", systemImage: "shippingbox.and.arrow.backward") }

            AgentsSettingsTab()
                .environment(appState)
                .tabItem { Label("Agents", systemImage: "wand.and.rays") }

            MCPIntegrationSettingsTab()
                .environment(appState)
                .tabItem { Label("MCP", systemImage: "network") }

            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - General tab

private struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState

    /// Bridges AppState.preferredLocaleIdentifier (UserDefaults-backed) to a
    /// SwiftUI Picker binding so selection writes-through on change and
    /// re-renders the whole app via the .environment(\.locale) at the root.
    private var localeBinding: Binding<String> {
        Binding(
            get: { appState.preferredLocaleIdentifier },
            set: { appState.preferredLocaleIdentifier = $0 }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: localeBinding) {
                    Text("System").tag("system")
                    Text("English").tag("en")
                    Text("Français").tag("fr")
                } label: {
                    Label("Language", systemImage: "globe")
                }
                .pickerStyle(.menu)

                if appState.languageChangePendingRelaunch {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .foregroundStyle(.tint)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Restart required")
                                .font(.callout.bold())
                            Text("Verbinal needs to restart to apply the new language.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restart Now") {
                            appState.relaunch()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Quit and relaunch Verbinal to apply the new language")
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Language")
            } footer: {
                Text("macOS applies app-language overrides at launch. Changing this setting writes the preference; the next launch picks it up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Portal tab

private struct PortalSettingsTab: View {
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
                    .foregroundStyle(.tertiary)
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
                        .foregroundStyle(.tertiary)
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
                    .foregroundStyle(.tertiary)
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
    private var gpuOptions: [Int] { cache?.context?.gpus.options ?? [] }

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

            if !gpuOptions.isEmpty && gpuOptions != [0] {
                Picker("GPUs", selection: $resourceGpus) {
                    ForEach(gpuOptions, id: \.self) { Text("\($0)").tag($0) }
                }
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
        if !gpuOptions.isEmpty && !gpuOptions.contains(resourceGpus) {
            resourceGpus = gpuOptions.first ?? 0
        }
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

// MARK: - Agents tab

private struct AgentsSettingsTab: View {
    @Environment(AppState.self) private var appState

    private var allowExternalAgents: Binding<Bool> {
        Binding(
            get: { appState.agentsService.isEnabled },
            set: { appState.agentsService.isEnabled = $0 }
        )
    }

    private var autoApplyWrites: Binding<Bool> {
        Binding(
            get: { appState.agentsService.autoApplyWrites },
            set: { appState.agentsService.autoApplyWrites = $0 }
        )
    }

    private var followAgentActivity: Binding<Bool> {
        Binding(
            get: { appState.agentsService.followAgentActivity },
            set: { appState.agentsService.followAgentActivity = $0 }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Allow external AI agents", isOn: allowExternalAgents)
                    .toggleStyle(.switch)
                statusRow
            } header: {
                Text("MCP Server")
            } footer: {
                Text("When enabled, MCP-compatible AI clients (Claude Desktop, etc.) " +
                     "can call into Verbinal via the bundled `canfar-mcp` helper. " +
                     "Read tools run directly; writes are subject to the autonomy " +
                     "setting below.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if appState.agentsService.isEnabled {
                Section {
                    Toggle("Auto-apply agent writes", isOn: autoApplyWrites)
                        .toggleStyle(.switch)
                    Toggle("Follow agent activity", isOn: followAgentActivity)
                        .toggleStyle(.switch)
                } header: {
                    Text("Autonomy")
                } footer: {
                    Text("Auto-apply on: connected agents apply their writes immediately " +
                         "(saved queries, notes, downloads, sessions, VOSpace edits, " +
                         "deletions). Off: every write queues to the proposal strip " +
                         "and waits for your Apply click.\n\n" +
                         "Follow agent activity on: after an auto-applied write the window " +
                         "jumps to the section where the change is visible (Search for " +
                         "queries, Research for observations, Storage for VOSpace, Portal " +
                         "for sessions) so you always see motion. The agent's explicit " +
                         "`navigate_to` tool ignores this toggle — it always works.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if appState.agentsService.isRunning {
                Section {
                    diagnosticsRow
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("View live activity in Console.app via " +
                         "`log show --predicate 'subsystem == \"com.codebg.Verbinal.agent\"'`.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Section {
                    HStack {
                        Label("\(appState.agentsService.activityStore.entries.count) entries",
                              systemImage: "clock.arrow.circlepath")
                            .font(.callout)
                        Spacer()
                        Button("Clear", role: .destructive) {
                            appState.agentsService.activityStore.clear()
                        }
                        .controlSize(.small)
                        .disabled(appState.agentsService.activityStore.entries.isEmpty)
                        .help("Erase the agent-activity breadcrumb log")
                    }
                } header: {
                    Text("Activity History")
                } footer: {
                    Text("Persistent breadcrumb of agent applies, rejections, and " +
                         "live UI ops. Bodies / payloads are never stored — only " +
                         "the same compact summary that showed in the proposal strip.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let coord = appState.imageDiscoveryCoordinator {
                    Section {
                        ImageDiscoveryCacheRow(coordinator: coord)
                    } header: {
                        Text("Image Discovery Cache")
                    } footer: {
                        Text("Per-image package manifests learned by running " +
                             "small probe jobs inside Skaha containers. Stored at " +
                             "Application Support/Verbinal/ImageDiscovery/manifests/. " +
                             "Clearing wipes the local cache; in-flight probes will " +
                             "repopulate when they complete.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Section {
                    auditList
                } header: {
                    Text("Recent Activity")
                } footer: {
                    Text("Hashes and outcomes only — call arguments are never logged.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: appState.agentsService.isRunning ? "checkmark.circle.fill" : "moon.zzz.fill")
                .foregroundStyle(appState.agentsService.isRunning ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.agentsService.isRunning ? "Listening" : "Stopped")
                    .font(.callout)
                if let path = appState.agentsService.socketPath {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
                if let lastError = appState.agentsService.lastError {
                    Text(lastError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
        }
    }

    private var diagnosticsRow: some View {
        HStack {
            Label("\(appState.agentsService.connectionCount) active",
                  systemImage: "personalhotspot")
            Spacer()
            Label("\(appState.agentsService.tools.count) tool\(appState.agentsService.tools.count == 1 ? "" : "s") registered",
                  systemImage: "wrench.and.screwdriver")
        }
        .font(.callout)
    }

    private var auditList: some View {
        let entries = appState.agentsService.recentAuditEntries(limit: 20)
        return Group {
            if entries.isEmpty {
                Text("No agent calls yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(entries.reversed(), id: \.requestID) { entry in
                            HStack(spacing: 8) {
                                Image(systemName: icon(for: entry))
                                    .foregroundStyle(color(for: entry))
                                Text(entry.toolName)
                                    .font(.caption.monospaced())
                                Text(entry.outcome.tag)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if !entry.originLabel.isEmpty, entry.originLabel != "user" {
                                    Text(entry.originLabel)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .help("client \(entry.origin.tag)")
                                }
                                Spacer()
                                Text("\(entry.durationMS) ms")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 160)
            }
        }
    }

    /// Displayed inside the Settings ▸ Agents pane when a discovery
    /// coordinator is alive. Shows the live cache count and a
    /// destructive Clear button. Loading state surfaces on the
    /// initial fetch of `cacheCount()` so the user doesn't see "0
    /// entries" while the actor is hydrating.
    fileprivate struct ImageDiscoveryCacheRow: View {
        let coordinator: ImageDiscoveryCoordinator
        @State private var count: Int? = nil
        @State private var clearing: Bool = false

        var body: some View {
            HStack {
                Label(label, systemImage: "shippingbox")
                    .font(.callout)
                Spacer()
                Button("Clear", role: .destructive) {
                    Task {
                        clearing = true
                        try? await coordinator.clearCache()
                        count = await coordinator.cacheCount()
                        clearing = false
                    }
                }
                .controlSize(.small)
                .help("Drop every cached image manifest; in-flight probes keep running")
                .disabled(clearing || (count ?? 0) == 0)
            }
            .task {
                if count == nil {
                    count = await coordinator.cacheCount()
                }
            }
        }

        private var label: String {
            switch count {
            case nil: return "Loading…"
            case .some(let n) where n == 1: return "1 entry"
            case .some(let n): return "\(n) entries"
            }
        }
    }

    private func icon(for entry: AuditEntry) -> String {
        switch entry.outcome {
        case .ok, .data: return "checkmark.circle"
        case .proposed: return "tray.and.arrow.down"
        case .applied: return "wand.and.stars"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func color(for entry: AuditEntry) -> Color {
        switch entry.outcome {
        case .ok, .data: return .green
        case .proposed: return .blue
        case .applied: return .purple
        case .failed: return .orange
        }
    }
}

// MARK: - About tab

private struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "telescope.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Verbinal")
                .font(.title2.bold())
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("A macOS companion for the CANFAR Science Platform.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
