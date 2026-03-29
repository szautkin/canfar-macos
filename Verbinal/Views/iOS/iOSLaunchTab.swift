// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(iOS)
import SwiftUI

struct iOSLaunchTab: View {
    var launchModel: SessionLaunchModel
    var recentLaunchStore: RecentLaunchStore
    var onLaunched: () -> Void

    var body: some View {
        iOSLaunchFormView(
            model: launchModel,
            recentLaunchStore: recentLaunchStore,
            onLaunched: onLaunched
        )
        .navigationTitle("Launch Session")
    }
}

/// iOS-native launch form — single scrollable Form with all sections.
private struct iOSLaunchFormView: View {
    @Bindable var model: SessionLaunchModel
    var recentLaunchStore: RecentLaunchStore
    var onLaunched: (() -> Void)?
    @State private var showLaunchProgress = false
    @State private var showRelaunchProgress = false
    @State private var selectedTab = 0
    @State private var recentFilter = ""

    private var filteredRecent: [RecentLaunch] {
        guard !recentFilter.isEmpty else { return recentLaunchStore.launches }
        let query = recentFilter.lowercased()
        return recentLaunchStore.launches.filter {
            $0.name.lowercased().contains(query) ||
            $0.type.lowercased().contains(query) ||
            $0.imageLabel.lowercased().contains(query)
        }
    }

    var body: some View {
        Form {
            if model.isAtSessionLimit {
                Section {
                    Label(model.sessionLimitMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if model.isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading images...")
                        Spacer()
                    }
                }
            } else {
                // Standard / Advanced toggle
                Section {
                    Picker("", selection: $selectedTab) {
                        Text("Standard").tag(0)
                        Text("Advanced").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if selectedTab == 0 {
                    standardSections
                } else {
                    advancedSections
                }

                // Shared: Resources
                Section("Resources") {
                    Picker("Mode", selection: $model.resourceType) {
                        Text("Flexible").tag("flexible")
                        Text("Fixed").tag("fixed")
                    }
                    .pickerStyle(.segmented)

                    if model.resourceType == "fixed" {
                        ResourceSelectorView(
                            cores: $model.cores,
                            ram: $model.ram,
                            gpus: $model.gpus,
                            coreOptions: model.coreOptions,
                            ramOptions: model.ramOptions,
                            gpuOptions: model.gpuOptions
                        )
                    }
                }

                // Launch button
                Section {
                    Button {
                        if selectedTab == 1 { model.useCustomImage = true }
                        showLaunchProgress = true
                        Task { await model.launch() }
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "play.fill")
                            Text(selectedTab == 0 ? "Launch Session" : "Launch (Custom Image)")
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(launchDisabled)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                // Recent launches
                if !recentLaunchStore.launches.isEmpty {
                    Section {
                        TextField("Filter...", text: $recentFilter)
                            .autocorrectionDisabled()

                        ForEach(filteredRecent) { launch in
                            recentRow(launch)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        recentLaunchStore.remove(launch)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        relaunch(launch)
                                    } label: {
                                        Label("Relaunch", systemImage: "play.fill")
                                    }
                                    .tint(.green)
                                    .disabled(model.isAtSessionLimit)
                                }
                        }
                    } header: {
                        HStack {
                            Text("Recent Launches")
                            Spacer()
                            Button("Clear All", role: .destructive) {
                                recentLaunchStore.clear()
                            }
                            .font(.caption)
                        }
                    }
                }
            }

            if model.hasError {
                Section {
                    Label(model.errorMessage, systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                }
            }
        }
        .sheet(isPresented: $showLaunchProgress, onDismiss: {
            if model.launchSuccess {
                model.savePendingRecentLaunch()
            }
        }) {
            LaunchProgressSheet(model: model) {
                showLaunchProgress = false
                onLaunched?()
            }
        }
        .sheet(isPresented: $showRelaunchProgress) {
            LaunchProgressSheet(model: model) {
                showRelaunchProgress = false
                onLaunched?()
            }
        }
        .alert(
            "Replace Recent Launch?",
            isPresented: $model.showRecentLaunchConflict
        ) {
            Button("Replace") { model.confirmRecentLaunchOverride() }
            Button("Skip", role: .cancel) { model.skipRecentLaunchSave() }
        } message: {
            Text("'\(model.pendingRecentLaunch?.name ?? "")' already exists. Replace it?")
        }
    }

    // MARK: - Standard

    @ViewBuilder
    private var standardSections: some View {
        Section("Session Configuration") {
            Picker("Type", selection: $model.selectedType) {
                ForEach(model.sessionTypes, id: \.self) { type in
                    Text(type.capitalized).tag(type)
                }
            }

            Picker("Project", selection: $model.selectedProject) {
                ForEach(model.projects, id: \.self) { project in
                    Text(project).tag(project)
                }
            }

            Picker("Image", selection: $model.selectedImage) {
                if model.selectedImage == nil {
                    Text("Select an image").tag(nil as ParsedImage?)
                }
                ForEach(model.images) { img in
                    Text(img.label).tag(Optional(img))
                }
            }

            HStack {
                TextField("Session Name", text: $model.sessionName)
                Button {
                    model.generateSessionName()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advancedSections: some View {
        Section("Custom Image") {
            Picker("Type", selection: $model.selectedType) {
                ForEach(model.sessionTypes, id: \.self) { type in
                    Text(type.capitalized).tag(type)
                }
            }

            if !model.repositories.isEmpty {
                Picker("Registry", selection: $model.repositoryHost) {
                    ForEach(model.repositories, id: \.self) { repo in
                        Text(repo).tag(repo)
                    }
                }
            }

            TextField("Container Image URL", text: $model.customImageUrl)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }

        Section("Registry Authentication (optional)") {
            TextField("Username", text: $model.repositoryUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Secret", text: $model.repositorySecret)
        }

        Section {
            HStack {
                TextField("Session Name", text: $model.sessionName)
                Button {
                    model.generateSessionName()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: - Helpers

    private var launchDisabled: Bool {
        if model.isLaunching || model.isAtSessionLimit { return true }
        if selectedTab == 0 { return model.selectedImage == nil }
        return model.customImageUrl.isEmpty
    }

    // MARK: - Recent Launch Row

    @ViewBuilder
    private func recentRow(_ launch: RecentLaunch) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(launch.name)
                        .fontWeight(.medium)
                    Text(launch.type.capitalized)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                }
                Text(launch.imageLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                relaunch(launch)
            } label: {
                Text("Relaunch")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .disabled(model.isAtSessionLimit)

            Button(role: .destructive) {
                recentLaunchStore.remove(launch)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    private func relaunch(_ launch: RecentLaunch) {
        showRelaunchProgress = true
        Task {
            let success = await model.relaunch(launch)
            if success { onLaunched?() }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
}
#endif
