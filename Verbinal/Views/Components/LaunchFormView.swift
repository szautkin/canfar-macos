// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct LaunchFormView: View {
    @Bindable var model: SessionLaunchModel
    /// Optional headless model — when provided, a third "Headless"
    /// tab appears. `nil` keeps the form to its prior shape, used by
    /// surfaces that don't load a HeadlessService (e.g. tests / iOS).
    var headlessModel: HeadlessLaunchModel?
    /// Optional image-discovery model — when provided, a magnifier
    /// icon next to the image picker opens a sheet that lets the
    /// user search images by installed packages. `nil` hides the
    /// affordance.
    var imageDiscoveryModel: ImageDiscoveryModel?
    var onLaunched: (() -> Void)?
    @State private var showLaunchProgress = false
    @State private var showHeadlessLaunchProgress = false
    @State private var showImageDiscovery = false
    @State private var selectedTab = 0

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Launch Session", systemImage: "play.circle")
                    .font(.headline)

                if model.isAtSessionLimit {
                    Label(model.sessionLimitMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if model.isLoading {
                    HStack {
                        Spacer()
                        ProgressView("Loading images...")
                        Spacer()
                    }
                    .padding()
                } else {
                    Picker("", selection: $selectedTab) {
                        Text("Standard").tag(0)
                        Text("Advanced").tag(1)
                        if headlessModel != nil {
                            Text("Headless").tag(2)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: headlessModel != nil ? 280 : 200)

                    if selectedTab == 0 {
                        standardForm
                    } else if selectedTab == 1 {
                        advancedForm
                    } else if selectedTab == 2, let hm = headlessModel {
                        headlessForm(hm)
                    }
                }

                if model.hasError {
                    Label(model.errorMessage, systemImage: "xmark.circle")
                        .font(.caption)
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
        .alert(
            "Replace Recent Launch?",
            isPresented: $model.showRecentLaunchConflict
        ) {
            Button("Replace") { model.confirmRecentLaunchOverride() }
            Button("Skip", role: .cancel) { model.skipRecentLaunchSave() }
        } message: {
            Text("'\(model.pendingRecentLaunch?.name ?? "")' already exists in recent launches. Replace it?")
        }
        .sheet(isPresented: $showImageDiscovery) {
            if let idm = imageDiscoveryModel {
                ImageDiscoverySheet(
                    model: idm,
                    onPick: { imageID in
                        // Map the picked id back into the launch
                        // model: find it in the current type's
                        // catalogue and assign so the picker rebinds.
                        let pool = model.images(forType: model.selectedType)
                            .values.flatMap { $0 }
                        if let match = pool.first(where: { $0.id == imageID }) {
                            model.selectedImage = match
                        }
                    },
                    catalogue: catalogueForCurrentTab
                )
            }
        }
    }

    /// Flatten the launch-model's per-project catalogue for the
    /// current Standard/Advanced tab's session type. The discovery
    /// sheet shows everything the user can launch *of this type*.
    private var catalogueForCurrentTab: [ParsedImage] {
        model.images(forType: model.selectedType)
            .values.flatMap { $0 }
            .sorted { $0.label < $1.label }
    }

    // MARK: - Headless Form (the third tab)

    @ViewBuilder
    private func headlessForm(_ hm: HeadlessLaunchModel) -> some View {
        HeadlessLaunchTabView(
            model: hm,
            imagesByProject: model.images(forType: "headless"),
            coreOptions: model.coreOptions,
            ramOptions: model.ramOptions,
            gpuOptions: model.gpuOptions,
            onLaunch: {
                Task {
                    await hm.launch()
                    if hm.launchSuccess {
                        onLaunched?()
                    }
                }
            }
        )
        if hm.hasError {
            Label(hm.errorMessage, systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        }
        if hm.launchSuccess, !hm.lastLaunchedJobIDs.isEmpty {
            Label(hm.launchStatus, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    // MARK: - Standard Form

    @ViewBuilder
    private var standardForm: some View {
        Form {
            LabeledContent("Session Type") {
                HStack(spacing: 4) {
                    Picker("", selection: $model.selectedType) {
                        ForEach(model.sessionTypes, id: \.self) { type in
                            Text(type.capitalized).tag(type)
                        }
                    }
                    .labelsHidden()
                    defaultStar(isOn: model.isSelectedSessionTypeDefault,
                                tipOn: "Current default — tap to clear",
                                tipOff: "Set as default session type") {
                        model.toggleDefaultSessionType()
                    }
                }
            }

            Picker("Registry", selection: $model.repositoryHost) {
                ForEach(model.repositories, id: \.self) { repo in
                    Text(repo).tag(repo)
                }
            }
            .disabled(model.repositories.count <= 1)

            LabeledContent("Project") {
                HStack(spacing: 4) {
                    Picker("", selection: $model.selectedProject) {
                        ForEach(model.projects, id: \.self) { project in
                            Text(project).tag(project)
                        }
                    }
                    .labelsHidden()
                    defaultStar(isOn: model.isSelectedProjectDefault,
                                tipOn: "Current default — tap to clear",
                                tipOff: "Set as default project") {
                        model.toggleDefaultProject()
                    }
                    .disabled(model.selectedProject.isEmpty)
                }
            }

            LabeledContent("Container Image") {
                HStack(spacing: 4) {
                    Picker("", selection: $model.selectedImage) {
                        if model.selectedImage == nil {
                            Text("Select an image").tag(nil as ParsedImage?)
                        }
                        ForEach(model.images) { img in
                            Text(img.label).tag(Optional(img))
                        }
                    }
                    .labelsHidden()
                    defaultStar(isOn: model.isSelectedImageDefault,
                                tipOn: "Current default — tap to clear",
                                tipOff: "Set as default container image") {
                        model.toggleDefaultImage()
                    }
                    .disabled(model.selectedImage == nil)
                    if imageDiscoveryModel != nil {
                        Button {
                            showImageDiscovery = true
                        } label: {
                            Image(systemName: "magnifyingglass.circle")
                                .font(.callout)
                        }
                        .buttonStyle(.borderless)
                        .help("Discover images by installed packages")
                    }
                }
            }

            HStack {
                TextField("Session Name", text: $model.sessionName)
                Button {
                    model.generateSessionName()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            LabeledContent("Resources") {
                HStack(spacing: 4) {
                    Picker("", selection: $model.resourceType) {
                        Text("Flexible").tag("flexible")
                        Text("Fixed").tag("fixed")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    defaultStar(isOn: model.isSelectedResourcesDefault,
                                tipOn: "Current default — tap to clear",
                                tipOff: "Set current resources as default") {
                        model.toggleDefaultResources()
                    }
                }
            }

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
        .formStyle(.grouped)
        #if os(macOS)
        .fixedSize(horizontal: false, vertical: true)
        #else
        .scrollDisabled(true)
        #endif

        HStack {
            Spacer()
            Button {
                showLaunchProgress = true
                Task { await model.launch() }
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Launch Session")
                }
                .padding(.horizontal, 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isLaunching || model.isAtSessionLimit || model.selectedImage == nil)
            Spacer()
        }

        cacheStatusBar
    }

    /// Small footer showing cache freshness + manual refresh.
    @ViewBuilder
    private var cacheStatusBar: some View {
        if let age = model.cacheAgeDescription {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("Images cached \(age)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button("Refresh") {
                    Task { await model.refreshImages() }
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .font(.caption2)
                .disabled(model.isLoading)
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    /// Small inline star button used next to Portal default pickers.
    @ViewBuilder
    private func defaultStar(
        isOn: Bool,
        tipOn: String,
        tipOff: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: isOn ? "star.fill" : "star")
                .foregroundStyle(isOn ? Color.yellow : Color.secondary)
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .help(isOn ? tipOn : tipOff)
    }

    // MARK: - Advanced Form

    @ViewBuilder
    private var advancedForm: some View {
        Form {
            LabeledContent("Session Type") {
                HStack(spacing: 4) {
                    Picker("", selection: $model.selectedType) {
                        ForEach(model.sessionTypes, id: \.self) { type in
                            Text(type.capitalized).tag(type)
                        }
                    }
                    .labelsHidden()
                    defaultStar(isOn: model.isSelectedSessionTypeDefault,
                                tipOn: "Current default — tap to clear",
                                tipOff: "Set as default session type") {
                        model.toggleDefaultSessionType()
                    }
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
                .textFieldStyle(.roundedBorder)

            Section("Registry Authentication (optional)") {
                TextField("Username", text: $model.repositoryUsername)
                SecureField("Secret", text: $model.repositorySecret)
            }

            HStack {
                TextField("Session Name", text: $model.sessionName)
                Button {
                    model.generateSessionName()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            Picker("Resources", selection: $model.resourceType) {
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
        .formStyle(.grouped)
        #if os(macOS)
        .fixedSize(horizontal: false, vertical: true)
        #else
        .scrollDisabled(true)
        #endif

        HStack {
            Spacer()
            Button {
                model.useCustomImage = true
                showLaunchProgress = true
                Task { await model.launch() }
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Launch (Custom Image)")
                }
                .padding(.horizontal, 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isLaunching || model.isAtSessionLimit || model.customImageUrl.isEmpty)
            Spacer()
        }
    }
}
