// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Launching from the Portal on iPhone and iPad (plan 47 1.5): a recent
/// launch again, or the Standard form. A custom image and a registry secret
/// stay on the Mac (decision D3).
struct iOSLaunchSheet: View {
    @Bindable var launchModel: SessionLaunchModel
    var recentLaunchStore: RecentLaunchStore
    var onLaunched: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showLaunchProgress = false
    @State private var showRelaunchProgress = false
    @State private var recentFilter = ""

    private var model: SessionLaunchModel { launchModel }

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
        NavigationStack {
            Form {
                if model.isAtSessionLimit {
                    Section {
                        Label(model.sessionLimitMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                if !recentLaunchStore.launches.isEmpty {
                    recentSection
                }

                if model.options.isWorking {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Loading images...")
                            Spacer()
                        }
                    }
                } else {
                    configurationSection
                    resourcesSection
                    Section {
                        Button {
                            showLaunchProgress = true
                            Task { await launchModel.launch(from: .standard) }
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "play.fill")
                                Text("Launch Session")
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.isLaunching || model.isAtSessionLimit || model.selectedImage == nil)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }

                if let problem = model.launchPhase.problem ?? model.options.problem {
                    Section {
                        Label(problem.message, systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Launch Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showLaunchProgress, onDismiss: {
                if model.launchSuccess {
                    model.savePendingRecentLaunch()
                }
            }) {
                LaunchProgressSheet(model: launchModel) {
                    showLaunchProgress = false
                    finish()
                }
                .iosSheetChrome([.medium, .large])
            }
            .sheet(isPresented: $showRelaunchProgress) {
                LaunchProgressSheet(model: launchModel) {
                    showRelaunchProgress = false
                    finish()
                }
                .iosSheetChrome([.medium, .large])
            }
            .alert(
                "Replace Recent Launch?",
                isPresented: $launchModel.showRecentLaunchConflict
            ) {
                Button("Replace") { model.confirmRecentLaunchOverride() }
                Button("Skip", role: .cancel) { model.skipRecentLaunchSave() }
            } message: {
                Text("'\(model.pendingRecentLaunch?.name ?? "")' already exists. Replace it?")
            }
        }
        .iosSheetChrome()
    }

    /// Done: the Portal reloads its sessions, and this sheet goes once the
    /// launch worked.
    private func finish() {
        onLaunched()
        if model.launchSuccess { dismiss() }
    }

    // MARK: - Recent launches

    private var recentSection: some View {
        Section {
            if recentLaunchStore.launches.count > 4 {
                TextField("Filter...", text: $recentFilter)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            ForEach(filteredRecent) { launch in
                recentRow(launch)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            recentLaunchStore.remove(launch)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
            }
        } header: {
            Text("Recent Launches")
        }
    }

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
            Button("Relaunch") { relaunch(launch) }
                .buttonStyle(.bordered)
                .tint(.green)
                .controlSize(.small)
                .disabled(model.isLaunching || model.isAtSessionLimit)
        }
    }

    private func relaunch(_ launch: RecentLaunch) {
        showRelaunchProgress = true
        Task { _ = await launchModel.relaunch(launch) }
    }

    // MARK: - The Standard form

    private var configurationSection: some View {
        Section("Session Configuration") {
            Picker("Type", selection: $launchModel.selectedType) {
                ForEach(model.sessionTypes, id: \.self) { type in
                    Text(type.capitalized).tag(type)
                }
            }

            Picker("Project", selection: $launchModel.selectedProject) {
                ForEach(model.projects, id: \.self) { project in
                    Text(project).tag(project)
                }
            }

            Picker("Image", selection: $launchModel.selectedImage) {
                if model.selectedImage == nil {
                    Text("Select an image").tag(nil as ParsedImage?)
                }
                ForEach(model.images) { img in
                    Text(img.label).tag(Optional(img))
                }
            }

            HStack {
                TextField("Session Name", text: $launchModel.sessionName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button {
                    model.generateSessionName()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(Text("New session name"))
            }
        }
    }

    private var resourcesSection: some View {
        Section("Resources") {
            Picker("Mode", selection: $launchModel.resourceType) {
                Text("Flexible").tag("flexible")
                Text("Fixed").tag("fixed")
            }
            .pickerStyle(.segmented)

            // Standard: one GPU or none (plan 42).
            GPUCheckbox(isOn: $launchModel.usesAGPU, offered: model.gpuOffer.offersAny)

            if model.resourceType == "fixed" {
                ResourceSelectorView(
                    cores: $launchModel.cores,
                    ram: $launchModel.ram,
                    gpus: $launchModel.gpus,
                    coreOptions: model.coreOptions,
                    ramOptions: model.ramOptions,
                    gpuOptions: nil
                )
            }
        }
    }
}
