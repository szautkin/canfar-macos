// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Where a Research file is, at a glance: a laptop for this Mac and a cloud
/// for the person's storage, each lit where the file is (the person's
/// request, 2026-10-09).
struct FilePlacesBadge: View {
    let places: FilePlaces

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(places.onMac ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            Image(systemName: places.inStorage ? "cloud.fill" : "cloud")
                .foregroundStyle(places.inStorage ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
        }
        .font(.caption)
        .help(Text(places.title))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(places.title))
    }
}

/// A Research file's place, and the person's moves between this Mac and
/// their storage: each copy made first, and the other removed only once it
/// is there — a file always keeps one copy.
struct FilePlacesMenu: View {
    let file: KeptFile
    let record: DownloadedObservation
    var model: ResearchModel

    /// A move that removes a copy, until the person confirms it.
    @State private var confirming: Confirm?
    @State private var failure: String?

    enum Confirm: Identifiable {
        case moveToStorage, moveToMac, removeFromMac, removeFromStorage
        var id: Self { self }
    }

    private var transfer: ResearchFileTransfer { model.transfer }
    private var places: FilePlaces { file.places }
    private var signedIn: Bool { transfer.storage != nil }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    /// The badge as one picture (plan 44 F-6, F-7): a menu's label on macOS
    /// draws only its first image — the cloud was never seen — and is what
    /// the menu is read by: "Laptop computer", not where the file is.
    @ViewBuilder private var badge: some View {
        #if os(macOS)
        let renderer = ImageRenderer(content: FilePlacesBadge(places: places).environment(\.colorScheme, colorScheme))
        let _ = (renderer.scale = displayScale)
        if let image = renderer.nsImage {
            Image(nsImage: image)
                .opacity(signedIn ? 1 : 0.45)
                .accessibilityLabel(Text("Where \(file.name) is: \(places.title)"))
        } else {
            FilePlacesBadge(places: places)
        }
        #else
        FilePlacesBadge(places: places)
        #endif
    }

    var body: some View {
        Group {
            if transfer.isBusy(file.name, of: record.id) {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    Section(places.title) {
                        if places.onMac && !places.inStorage {
                            Button("Send a Copy to Storage") { run { try await transfer.send(file.name, of: record.id) } }
                            Button("Move to Storage…") { confirming = .moveToStorage }
                        }
                        if places.inStorage && !places.onMac {
                            Button("Get a Copy from Storage") { run { try await transfer.fetch(file.name, of: record.id) } }
                            Button("Move to This Mac…") { confirming = .moveToMac }
                        }
                        if places.onMac && places.inStorage {
                            Button("Remove from This Mac…") { confirming = .removeFromMac }
                            Button("Remove from Storage…") { confirming = .removeFromStorage }
                        }
                    }
                    if let path = file.storagePath {
                        Section("In your storage at") { Text(path) }
                    }
                } label: {
                    badge
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!signedIn)
                .accessibilityLabel(Text("Where \(file.name) is: \(places.title)"))
                .help(signedIn ? Text(places.title) : Text("Sign in to CANFAR to move files to and from your storage"))
            }
        }
        .uiPresented("Move or Remove a Copy?", .confirmation, item: $confirming)
        .confirmationDialog(title, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button(confirmButton, role: .destructive) { confirm() }
        } message: {
            Text(message)
        }
        .uiPresented("Could Not Move the File", .alert, isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }))
        .alert("Could not move the file", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private var title: String {
        switch confirming {
        case .moveToStorage: String(localized: "Move \(file.name) to your storage?")
        case .moveToMac: String(localized: "Move \(file.name) to this Mac?")
        case .removeFromMac: String(localized: "Remove \(file.name) from this Mac?")
        case .removeFromStorage, .none: String(localized: "Remove \(file.name) from your storage?")
        }
    }

    private var confirmButton: String {
        switch confirming {
        case .moveToStorage, .moveToMac: String(localized: "Move")
        default: String(localized: "Remove")
        }
    }

    private var message: String {
        switch confirming {
        case .moveToStorage: String(localized: "It is copied to your storage first, and deleted from this Mac only once it is there. Opening it again needs your storage.")
        case .moveToMac: String(localized: "It is copied to this Mac first, and deleted from your storage only once it is here.")
        case .removeFromMac: String(localized: "The copy on this Mac is deleted. The one in your storage stays, and you can get it back.")
        case .removeFromStorage, .none: String(localized: "The copy in your storage is deleted. The one on this Mac stays.")
        }
    }

    private func confirm() {
        guard let asked = confirming else { return }
        confirming = nil
        let name = file.name, id = record.id
        switch asked {
        case .moveToStorage: run { try await transfer.move(name, of: id, to: .storage) }
        case .moveToMac: run { try await transfer.move(name, of: id, to: .mac) }
        case .removeFromMac: run { try await transfer.removeFromMac(name, of: id) }
        case .removeFromStorage: run { try await transfer.removeFromStorage(name, of: id) }
        }
    }

    /// Runs a move; the record shown is the one it leaves.
    private func run(_ work: @escaping () async throws -> DownloadedObservation) {
        Task {
            do {
                let updated = try await work()
                if model.selectedObservation?.id == updated.id { model.selectedObservation = updated }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// A record's files, wherever each is (plan 34 F; the person's request,
/// 2026-10-09): its name, where it is, and what can be done with it.
struct ResearchFilesSection: View {
    let observation: DownloadedObservation
    var model: ResearchModel

    /// The file the person asked to remove from this Mac when it has no other copy.
    @State private var removingFile: KeptFile?
    @State private var removeFileError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Files")
                .font(.subheadline.bold())
            ForEach(observation.allFiles) { file in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if file.places.onMac {
                            Text(DownloadsFolder.displayPath(file.localPath))
                                .font(.caption)
                                .foregroundStyle(file.local.exists ? Color.secondary : Color.orange)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        if let path = file.storagePath {
                            Label(path, systemImage: "cloud")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    if let size = file.size {
                        Text(SharedFormatters.bytes(size))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    FilePlacesMenu(file: file, record: observation, model: model)
                    if file.places.onMac {
                        KeptFileButtons(file: file, research: model) { removingFile = file }
                    }
                }
            }
            if let removeFileError {
                Text(removeFileError).font(.caption).foregroundStyle(.red)
            }
        }
        .uiPresented("Remove a File?", .confirmation, item: $removingFile)
        .confirmationDialog(String(localized: "Remove \(removingFile?.name ?? "")?"), isPresented: Binding(
            get: { removingFile != nil }, set: { if !$0 { removingFile = nil } })) {
            Button("Remove File", role: .destructive) {
                guard let file = removingFile else { return }
                removingFile = nil
                Task {
                    do { try await model.removeFile(named: file.name, of: observation) } catch {
                        removeFileError = String(localized: "Could not remove the file: \(error.localizedDescription)")
                    }
                }
            }
        } message: {
            if removingFile?.places.inStorage == true {
                Text("The copy on this Mac is deleted. The one in your storage stays, and you can get it back.")
            } else {
                Text("The file is deleted from this computer. The observation stays in Research, with its notes, and you can download the file again.")
            }
        }
    }
}
