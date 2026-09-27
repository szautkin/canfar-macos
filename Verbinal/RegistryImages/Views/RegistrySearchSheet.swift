// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Search the registry behind the platform for images its catalogue does
/// not list, add them to your own list, and take them out again. Added
/// images join the catalogue in the images card and on the launch form.
struct RegistrySearchSheet: View {
    @Bindable var model: RegistrySearchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                Section {
                    results
                } header: {
                    if model.phase == .found { Text("Found for “\(model.searched)”") }
                }
                Section("Your images") {
                    if model.store.images.isEmpty {
                        Text("None yet — images you add appear here, in the images card and on the launch form.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.store.images) { image in
                        row(image) {
                            Button("Remove", role: .destructive) { model.remove(image) }
                                .buttonStyle(.borderless)
                                .help("Take it out of your list; the image itself is untouched")
                        }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 520)
        .uiPointerOverlay()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Find in Registry", systemImage: "shippingbox.and.arrow.backward")
                .font(.headline)
            Text("Images the platform's catalogue does not list — a colleague's build, a tag not yet picked up. Uses the registry and credentials of Settings ▸ Image Discovery.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Repository name or part of it", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.run() } }
                    .pointable("registry.query", label: "Registry search", screen: "portal")
                Button("Search") { Task { await model.run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSearch)
                    .pointable("registry.search", label: "Search the registry", screen: "portal")
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var results: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(alignment: .top) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                CopyErrorButton(message: message)
            }
        case .found where model.results.isEmpty:
            Text("Nothing in the registry matched that.").foregroundStyle(.secondary)
        case .found:
            ForEach(model.results) { image in
                row(image) {
                    if model.isAdded(image) {
                        Label("In your images", systemImage: "checkmark").foregroundStyle(.secondary)
                    } else {
                        Button("Add") { model.add(image) }
                            .buttonStyle(.borderless)
                            .help("Add it to your images")
                    }
                }
            }
        }
    }

    private func row(_ image: RegistryImage, @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(image.id)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(RegistrySearchModel.typesLine(image))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
    }
}
