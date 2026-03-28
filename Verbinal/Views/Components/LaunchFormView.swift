// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

struct LaunchFormView: View {
    @Bindable var model: SessionLaunchModel
    var onLaunched: (() -> Void)?
    @State private var showLaunchProgress = false
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
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)

                    if selectedTab == 0 {
                        standardForm
                    } else {
                        advancedForm
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
    }

    // MARK: - Standard Form

    @ViewBuilder
    private var standardForm: some View {
        Form {
            Picker("Session Type", selection: $model.selectedType) {
                ForEach(model.sessionTypes, id: \.self) { type in
                    Text(type.capitalized).tag(type)
                }
            }

            Picker("Registry", selection: $model.repositoryHost) {
                ForEach(model.repositories, id: \.self) { repo in
                    Text(repo).tag(repo)
                }
            }
            .disabled(model.repositories.count <= 1)

            Picker("Project", selection: $model.selectedProject) {
                ForEach(model.projects, id: \.self) { project in
                    Text(project).tag(project)
                }
            }

            Picker("Container Image", selection: $model.selectedImage) {
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
        .fixedSize(horizontal: false, vertical: true)

        Button {
            showLaunchProgress = true
            Task { await model.launch() }
        } label: {
            HStack {
                Image(systemName: "play.fill")
                Text("Launch Session")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.isLaunching || model.isAtSessionLimit || model.selectedImage == nil)
    }

    // MARK: - Advanced Form

    @ViewBuilder
    private var advancedForm: some View {
        Form {
            Picker("Session Type", selection: $model.selectedType) {
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
        .fixedSize(horizontal: false, vertical: true)

        Button {
            model.useCustomImage = true
            showLaunchProgress = true
            Task { await model.launch() }
        } label: {
            HStack {
                Image(systemName: "play.fill")
                Text("Launch (Custom Image)")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.isLaunching || model.isAtSessionLimit || model.customImageUrl.isEmpty)
    }
}
