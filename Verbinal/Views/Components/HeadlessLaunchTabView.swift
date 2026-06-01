// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// The "Headless" tab of the launch form. Reads the image catalogue
/// from the parent's `SessionLaunchModel` (single source) and writes
/// launch state to `HeadlessLaunchModel`.
///
/// Why a tab and not a separate dashboard panel: it sits next to the
/// Standard / Advanced launch tabs because conceptually it's the same
/// affordance — "launch a thing on Skaha." The Background Jobs panel
/// (`HeadlessJobsView`) is the read surface for already-running jobs;
/// this is the write surface for new ones.
struct HeadlessLaunchTabView: View {
    @Bindable var model: HeadlessLaunchModel
    /// Image catalogue scoped to `type=headless`, keyed by project.
    var imagesByProject: [String: [ParsedImage]]
    var coreOptions: [Int]
    var ramOptions: [Int]
    var gpuOptions: [Int]
    var onLaunch: () -> Void

    private var availableProjects: [String] {
        Array(imagesByProject.keys).sorted()
    }

    private var imagesForCurrentProject: [ParsedImage] {
        imagesByProject[model.selectedProject] ?? []
    }

    var body: some View {
        Form {
            LabeledContent("Job Name") {
                TextField("e.g. nightly-reduction", text: $model.sessionName)
                    .textFieldStyle(.roundedBorder)
            }

            if availableProjects.isEmpty {
                Label(
                    "No headless images available for this account. Contact CADC support if you expect to see batch images here.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                LabeledContent("Project") {
                    Picker("", selection: $model.selectedProject) {
                        ForEach(availableProjects, id: \.self) { project in
                            Text(project).tag(project)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: model.selectedProject) { _, _ in
                        // Auto-select first image when project changes.
                        if let first = imagesForCurrentProject.first {
                            model.selectedImage = first
                        } else {
                            model.selectedImage = nil
                        }
                    }
                }

                LabeledContent("Image") {
                    Picker("", selection: Binding(
                        get: { model.selectedImage?.id ?? "" },
                        set: { newID in
                            model.selectedImage = imagesForCurrentProject.first { $0.id == newID }
                        }
                    )) {
                        ForEach(imagesForCurrentProject, id: \.id) { image in
                            Text(image.label).tag(image.id)
                        }
                    }
                    .labelsHidden()
                }
            }

            LabeledContent("Command") {
                TextField("e.g. python /arc/home/me/reduce.py", text: $model.cmd)
                    .textFieldStyle(.roundedBorder)
                    .help("The command the container runs. Required.")
            }

            LabeledContent("Arguments") {
                TextField("optional, space-separated", text: $model.args)
                    .textFieldStyle(.roundedBorder)
                    .help("Single string of additional arguments. Skaha treats this as one parameter and splits it server-side.")
            }

            LabeledContent("Replicas") {
                Stepper(value: $model.replicas, in: 1...20) {
                    Text("\(model.replicas)")
                        .monospacedDigit()
                }
                .help("Number of parallel container replicas. REPLICA_ID and REPLICA_COUNT are auto-injected as env vars.")
            }

            ResourceFormSection(
                resourceType: $model.resourceType,
                cores: $model.cores,
                ram: $model.ram,
                gpus: $model.gpus,
                coreOptions: coreOptions,
                ramOptions: ramOptions,
                gpuOptions: gpuOptions
            )

            HStack {
                Spacer()
                Button {
                    onLaunch()
                } label: {
                    if model.isLaunching {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 20)
                    } else {
                        Label(
                            model.replicas > 1 ? "Launch \(model.replicas) Replicas" : "Launch Job",
                            systemImage: "play.fill"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canLaunch)
            }
        }
    }
}
